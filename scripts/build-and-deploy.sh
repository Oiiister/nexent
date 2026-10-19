#!/usr/bin/env bash
#
# Rebuild the Nexent images affected by local changes and deploy them with one
# version tag. Intended for single-host Docker deployments where this repository
# is also the build context.
#
# The script never edits VERSION or deploy options. It detects which images are
# affected by the git delta since the last successful release, builds only those
# images, retags the unchanged images to the same tag, verifies that every image
# required by the deployment exists, and then calls deploy.sh with --version.
#
# Usage:
#   bash scripts/build-and-deploy.sh [options] [-- extra deploy.sh args]
#
# Examples:
#   bash scripts/build-and-deploy.sh --dry-run
#   bash scripts/build-and-deploy.sh --tag v2.7.0-oyster.1
#   bash scripts/build-and-deploy.sh --all --tag v2.7.0-oyster.2
#   bash scripts/build-and-deploy.sh --images web --tag v2.7.0-oyster.3 --no-deploy
#   bash scripts/build-and-deploy.sh --tag v2.7.0-oyster.4 --backup
#
# Notes:
#   * A clean working tree is required unless --allow-dirty is passed. Builds
#     from a dirty tree are not reproducible: build.sh copies the working tree.
#   * The first run has no release state and rebuilds every image required by
#     deploy/docker/deploy.options. Later runs build only affected images.
#   * SQL migrations are mounted from deploy/sql at deploy time. They are not
#     baked into images, but a deployment with SQL changes should be backed up.
#   * Images are built locally (--load). This script does not push to a registry.
#   * For a web deployment under a subpath, build nexent-web manually with
#     --build-arg CONFIGURED_BASE_PATH=/subpath, then run this script with
#     --no-build --tag <that-tag> so the prebuilt image is reused.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/deploy/images/build.sh"
DEPLOY_SCRIPT="$ROOT_DIR/deploy.sh"
DEPLOY_OPTIONS="$ROOT_DIR/deploy/docker/deploy.options"
ENV_GENERATED="$ROOT_DIR/deploy/docker/.env.generated"
DEPLOY_ENV="$ROOT_DIR/deploy/env/.env"
VERSION_FILE="$ROOT_DIR/VERSION"
REPO_KEY="$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')"
STATE_DIR="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/nexent/$REPO_KEY"
STATE_FILE="$STATE_DIR/release-state"
LOCK_FILE="${TMPDIR:-/tmp}/nexent-build-and-deploy.lock"

TAG=""
BASE_TAG=""
TAG_EXPLICIT=false
IMAGES=""
BUILD_ALL=false
DO_BUILD=true
DO_DEPLOY=true
DRY_RUN=false
ASSUME_YES=false
ALLOW_DIRTY=false
FORCE=false
BACKUP=false
BACKUP_DIR="/mnt/backup/nexent"
REGISTRY="general"
PLATFORM=""
NO_CACHE=false
DEPLOY_MODE="defaults"
DEPLOY_EXTRA=()

usage() {
  cat <<'USAGE'
Usage: bash scripts/build-and-deploy.sh [options] [-- extra deploy.sh args]

Options:
  --tag TAG                Image tag for this release. Default:
                           <VERSION>-<short-commit>[-dirty] when images are built,
                           otherwise the currently deployed tag.
  --base-tag TAG           Tag of the images currently deployed. Default: read
                           from deploy/docker/.env.generated, then VERSION.
  --images LIST            Comma-separated images to build instead of auto-detection.
                           Valid names: main,web,data-process,mcp,sandbox,
                           sandbox-full,terminal,docs
  --all                    Rebuild every image required by deploy.options.
  --no-build               Skip builds; only retag/verify and deploy.
  --no-deploy              Build and retag only; do not run deploy.sh.
  --registry NAME          Build mirrors: general (default) or mainland.
  --platform PLATFORM      Pass --platform to build.sh, e.g. linux/amd64.
  --no-cache               Pass --no-cache to build.sh.
  --backup                 Run deploy/docker/backup.sh before deploying.
  --backup-dir PATH        Backup destination. Default: /mnt/backup/nexent
  --allow-dirty            Allow building from a dirty working tree.
  --force                  Deploy even when no image/SQL/deploy change is detected.
  --dry-run                Print the plan and commands without executing them.
  --yes, -y                Do not prompt for confirmation.
  --config                 Open the interactive deployment TUI instead of --defaults.
  --defaults               Reuse saved deployment options (default).
  -h, --help               Show this help.

Exit codes:
  0  success or nothing to do
  1  validation or build/deploy failure
  2  user aborted
USAGE
}

log() {
  printf '[release] %s\n' "$*"
}

warn() {
  printf '[release] WARN: %s\n' "$*" >&2
}

die() {
  printf '[release] ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$DRY_RUN" = false ]; then
    "$@"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

csv_contains() {
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

csv_add() {
  local list="$1" item="$2"
  if csv_contains "$list" "$item"; then
    printf '%s' "$list"
  else
    printf '%s%s%s' "$list" "${list:+,}" "$item"
  fi
}

is_known_image() {
  case "$1" in
    main|web|data-process|mcp|sandbox|sandbox-full|terminal|docs) return 0 ;;
    *) return 1 ;;
  esac
}

image_repo() {
  case "$1" in
    main) printf 'nexent/nexent' ;;
    web) printf 'nexent/nexent-web' ;;
    data-process) printf 'nexent/nexent-data-process' ;;
    mcp) printf 'nexent/nexent-mcp' ;;
    sandbox) printf 'nexent/nexent-sandbox' ;;
    sandbox-full) printf 'nexent/nexent-sandbox-full' ;;
    terminal) printf 'nexent/nexent-ubuntu-terminal' ;;
    docs) printf 'nexent/nexent-docs' ;;
    *) die "unknown image name: $1" ;;
  esac
}

image_env_var() {
  case "$1" in
    main) printf 'NEXENT_IMAGE' ;;
    web) printf 'NEXENT_WEB_IMAGE' ;;
    data-process) printf 'NEXENT_DATA_PROCESS_IMAGE' ;;
    mcp) printf 'NEXENT_MCP_DOCKER_IMAGE' ;;
    sandbox|sandbox-full) printf 'NEXENT_SANDBOX_IMAGE' ;;
    terminal) printf 'OPENSSH_SERVER_IMAGE' ;;
    docs) printf '' ;;
    *) die "unknown image name: $1" ;;
  esac
}

env_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    index($0, key "=") == 1 {
      line = $0
      sub("^" key "=", "", line)
      gsub(/^"|"$/, "", line)
      print line
      exit
    }
  ' "$file"
}

deploy_option_value() {
  local key="$1"
  [ -f "$DEPLOY_OPTIONS" ] || return 0
  awk -v key="$key" '
    index($0, key ":") == 1 {
      line = $0
      sub("^" key ":[[:space:]]*", "", line)
      gsub(/"/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$DEPLOY_OPTIONS"
}

deploy_components() {
  [ -f "$DEPLOY_OPTIONS" ] || return 0
  awk '
    BEGIN { in_list = 0; first = 1 }
    /^components:[[:space:]]*$/ { in_list = 1; next }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (!first) printf ","
      printf "%s", line
      first = 0
      next
    }
    in_list && /^[^[:space:]-]/ { exit }
    END { printf "\n" }
  ' "$DEPLOY_OPTIONS"
}

tag_is_valid() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
}

image_exists() {
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  docker image inspect "$1" >/dev/null 2>&1
}

base_ref_for() {
  local image="$1" var ref repo
  var="$(image_env_var "$image")"
  repo="$(image_repo "$image")"

  if [ -n "$var" ]; then
    ref="$(env_value "$ENV_GENERATED" "$var")"
    case "$ref" in
      *@sha256:*)
        die "digest-pinned image refs are not supported: $ref"
        ;;
      "")
        ;;
      *:*)
        case "$image" in
          sandbox-full)
            case "$ref" in
              *nexent-sandbox-full:*)
                printf '%s:%s' "${ref%:*}" "$BASE_TAG"
                return 0
                ;;
            esac
            ;;
          sandbox)
            case "$ref" in
              *nexent-sandbox:*)
                printf '%s:%s' "${ref%:*}" "$BASE_TAG"
                return 0
                ;;
            esac
            ;;
          *)
            printf '%s:%s' "${ref%:*}" "$BASE_TAG"
            return 0
            ;;
        esac
        ;;
      *)
        die "invalid image ref in $ENV_GENERATED: $ref"
        ;;
    esac
  fi

  if [ -n "$REGISTRY_PREFIX" ]; then
    printf '%s/%s:%s' "$REGISTRY_PREFIX" "$repo" "$BASE_TAG"
  else
    printf '%s:%s' "$repo" "$BASE_TAG"
  fi
}

target_ref_for() {
  local ref="$1"
  case "$ref" in
    *@sha256:*) die "digest-pinned image refs are not supported: $ref" ;;
    *:*) printf '%s:%s' "${ref%:*}" "$TAG" ;;
    *) die "invalid image reference: $ref" ;;
  esac
}

built_ref_for() {
  printf '%s:%s' "$(image_repo "$1")" "$TAG"
}

build_image() {
  local image="$1"
  local -a args

  args=(--images "$image" --version "$TAG" --load --registry "$REGISTRY")
  if [ -n "$PLATFORM" ]; then
    args+=(--platform "$PLATFORM")
  fi
  if [ "$NO_CACHE" = true ]; then
    args+=(--no-cache)
  fi

  log "Building image: $image"
  run bash "$BUILD_SCRIPT" "${args[@]}"
}

ensure_image() {
  local image="$1"
  local built_ref base_ref target

  built_ref="$(built_ref_for "$image")"
  base_ref="$(base_ref_for "$image")"
  target="$(target_ref_for "$base_ref")"

  if [ "$DRY_RUN" = true ]; then
    if csv_contains "$TO_BUILD" "$image"; then
      if [ "$built_ref" != "$target" ]; then
        log "Would retag $built_ref -> $target"
      fi
    elif [ "$target" != "$base_ref" ]; then
      log "Would retag $base_ref -> $target"
    fi
    return 0
  fi

  if csv_contains "$TO_BUILD" "$image"; then
    image_exists "$built_ref" || die "build did not produce $built_ref"
    if [ "$built_ref" != "$target" ]; then
      run docker tag "$built_ref" "$target"
    fi
    return 0
  fi

  if [ "$target" = "$base_ref" ]; then
    if ! image_exists "$target"; then
      log "Image $target is not present locally; pulling it"
      run docker pull "$target"
    fi
    return 0
  fi

  if image_exists "$target"; then
    return 0
  fi

  if ! image_exists "$base_ref"; then
    log "Base image $base_ref is not present locally; pulling it"
    run docker pull "$base_ref"
  fi
  run docker tag "$base_ref" "$target"
}

verify_container() {
  local container="$1" image="$2"
  local target actual expected

  if ! docker inspect "$container" >/dev/null 2>&1; then
    log "  [SKIP] $container is not running"
    return 0
  fi

  target="$(target_ref_for "$(base_ref_for "$image")")"
  actual="$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null || true)"
  expected="$(docker image inspect --format '{{.Id}}' "$target" 2>/dev/null || true)"

  if [ -n "$actual" ] && [ "$actual" = "$expected" ]; then
    log "  [OK] $container -> $target"
  else
    log "  [WARN] $container image mismatch"
    log "         container: ${actual:-unknown}"
    log "         expected:  ${expected:-unknown} ($target)"
  fi
}

save_state() {
  local image target image_id manifest

  mkdir -p "$STATE_DIR/releases" 2>/dev/null || {
    warn "cannot create release state directory: $STATE_DIR"
    return 0
  }

  {
    printf 'repo=%s\n' "$ROOT_DIR"
    printf 'last_commit=%s\n' "$COMMIT"
    printf 'last_tag=%s\n' "$TAG"
    printf 'last_deploy_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'last_images=%s\n' "$REQUIRED"
  } > "$STATE_FILE"

  manifest="$STATE_DIR/releases/$TAG.txt"
  {
    printf 'commit=%s\n' "$COMMIT"
    printf 'tag=%s\n' "$TAG"
    printf 'deployed_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'images=%s\n' "$REQUIRED"
  } > "$manifest"
  for image in $(printf '%s' "$REQUIRED" | tr ',' ' '); do
    target="$(target_ref_for "$(base_ref_for "$image")")"
    image_id="$(docker image inspect --format '{{.Id}}' "$target" 2>/dev/null || true)"
    printf '%s %s %s\n' "$image" "$target" "$image_id" >> "$manifest"
  done

  log "Release state:    $STATE_FILE"
  log "Release manifest: $manifest"
}

on_error() {
  local line="$1" failed_command="$2"
  printf '[release] ERROR: command failed at line %s: %s\n' "$line" "$failed_command" >&2
  if [ "$DO_DEPLOY" = true ]; then
    printf '[release] Previously deployed tag: %s\n' "${BASE_TAG:-unknown}" >&2
    printf '[release] Rollback: bash deploy.sh --defaults docker --version %s\n' "${BASE_TAG:-<tag>}" >&2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || die "--tag requires a value"
      TAG="$2"
      TAG_EXPLICIT=true
      shift 2
      ;;
    --base-tag)
      [ "$#" -ge 2 ] || die "--base-tag requires a value"
      BASE_TAG="$2"
      shift 2
      ;;
    --images)
      [ "$#" -ge 2 ] || die "--images requires a value"
      IMAGES="$2"
      shift 2
      ;;
    --all) BUILD_ALL=true; shift ;;
    --no-build) DO_BUILD=false; shift ;;
    --no-deploy) DO_DEPLOY=false; shift ;;
    --registry)
      [ "$#" -ge 2 ] || die "--registry requires a value"
      REGISTRY="$2"
      shift 2
      ;;
    --platform)
      [ "$#" -ge 2 ] || die "--platform requires a value"
      PLATFORM="$2"
      shift 2
      ;;
    --no-cache) NO_CACHE=true; shift ;;
    --backup) BACKUP=true; shift ;;
    --backup-dir)
      [ "$#" -ge 2 ] || die "--backup-dir requires a value"
      BACKUP_DIR="$2"
      shift 2
      ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --config) DEPLOY_MODE="config"; shift ;;
    --defaults) DEPLOY_MODE="defaults"; shift ;;
    --help|-h) usage; exit 0 ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        DEPLOY_EXTRA+=("$1")
        shift
      done
      ;;
    *)
      die "unknown option: $1 (use --help)"
      ;;
  esac
done

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

cd "$ROOT_DIR"

[ -f "$DEPLOY_SCRIPT" ] || die "deploy.sh not found at $DEPLOY_SCRIPT"
[ -f "$BUILD_SCRIPT" ] || die "deploy/images/build.sh not found at $BUILD_SCRIPT"
[ -f "$DEPLOY_OPTIONS" ] || die "deploy/docker/deploy.options not found; run a first deployment or create it"
[ -f "$DEPLOY_ENV" ] || die "deploy/env/.env not found; run the deployment once first"
[ -f "$VERSION_FILE" ] || die "VERSION file not found at $VERSION_FILE"

command_exists git || die "git is required"
command_exists awk || die "awk is required"
command_exists sed || die "sed is required"

case "$REGISTRY" in
  general|mainland) ;;
  *) die "unsupported --registry value: $REGISTRY (use general or mainland)" ;;
esac

if [ -n "$IMAGES" ]; then
  IMAGES="$(printf '%s' "$IMAGES" | tr -d '[:space:]')"
  for image in $(printf '%s' "$IMAGES" | tr ',' ' '); do
    is_known_image "$image" || die "unsupported image in --images: $image"
  done
fi

if [ "$DO_BUILD" = false ] && [ -n "$IMAGES" ]; then
  die "--no-build cannot be combined with --images"
fi

if [ "$BACKUP" = true ] && [ "$DO_DEPLOY" = false ]; then
  die "--backup cannot be combined with --no-deploy"
fi

if [ "$DRY_RUN" = false ]; then
  command_exists docker || die "docker is required"
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required by build.sh"
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] \
    || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 4 ]; }; then
    die "bash 4.4 or newer is required (build.sh expands empty arrays under set -u)"
  fi
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another build-and-deploy process is running (lock: $LOCK_FILE)"
  fi

  DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [ -n "$DOCKER_ROOT" ] || DOCKER_ROOT="$ROOT_DIR"
  if command_exists df; then
    AVAIL_KB="$(df -Pk "$DOCKER_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
    case "$AVAIL_KB" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$AVAIL_KB" -lt 5242880 ]; then
          die "less than 5 GiB free under $DOCKER_ROOT; free disk space before building"
        elif [ "$AVAIL_KB" -lt 20971520 ]; then
          warn "less than 20 GiB free under $DOCKER_ROOT; large images may exhaust the disk"
        fi
        ;;
    esac
  fi
  if [ -r /proc/meminfo ]; then
    MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    case "$MEM_KB" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$MEM_KB" -lt 8388608 ]; then
          warn "less than 8 GiB RAM detected; web and data-process builds may fail or be very slow"
        fi
        ;;
    esac
  fi
fi

APP_VERSION="$(sed -n '1{s/[[:space:]]*$//;p;}' "$VERSION_FILE")"
[ -n "$APP_VERSION" ] || die "VERSION file is empty"

IMAGE_SOURCE="$(deploy_option_value imageSource)"
SANDBOX_MODE="$(deploy_option_value sandboxMode)"
REGISTRY_PREFIX="$(deploy_option_value imageRegistryPrefix)"
COMPONENTS="$(deploy_components)"

case "$IMAGE_SOURCE" in
  general|mainland) ;;
  local-latest)
    die "imageSource is local-latest in deploy.options; it forces :latest and ignores --version. Change it to general or mainland."
    ;;
  "")
    warn "imageSource is missing from deploy.options; assuming general"
    IMAGE_SOURCE="general"
    ;;
  *)
    die "unsupported imageSource in deploy.options: $IMAGE_SOURCE"
    ;;
esac

case "$SANDBOX_MODE" in
  full|lightweight|disabled) ;;
  "")
    warn "sandboxMode is missing from deploy.options; assuming lightweight"
    SANDBOX_MODE="lightweight"
    ;;
  *)
    die "unsupported sandboxMode in deploy.options: $SANDBOX_MODE"
    ;;
esac

[ -n "$COMPONENTS" ] || die "components are missing from deploy.options"

DIRTY_LIST="$(git status --porcelain | grep -v -F 'scripts/build-and-deploy.sh' || true)"
DIRTY=false
if [ -n "$DIRTY_LIST" ]; then
  DIRTY=true
  if [ "$ALLOW_DIRTY" = false ]; then
    printf '%s\n' "$DIRTY_LIST" | sed -n '1,20p' >&2
    die "working tree is dirty; commit or stash changes, or pass --allow-dirty"
  fi
fi

COMMIT="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short=8 HEAD)"
BRANCH="$(git branch --show-current 2>/dev/null || true)"

if [ -z "$BASE_TAG" ]; then
  if [ -f "$ENV_GENERATED" ]; then
    WEB_REF="$(env_value "$ENV_GENERATED" NEXENT_WEB_IMAGE)"
    MAIN_REF="$(env_value "$ENV_GENERATED" NEXENT_IMAGE)"
    BASE_REF="${WEB_REF:-$MAIN_REF}"
    case "$BASE_REF" in
      *@sha256:*) die "digest-pinned image refs are not supported: $BASE_REF" ;;
      *:*) BASE_TAG="${BASE_REF##*:}" ;;
    esac
  fi
  [ -n "$BASE_TAG" ] || BASE_TAG="$APP_VERSION"
fi

tag_is_valid "$BASE_TAG" || die "invalid base tag: $BASE_TAG"

REQUIRED=""
if csv_contains "$COMPONENTS" application; then
  REQUIRED="$(csv_add "$REQUIRED" main)"
  REQUIRED="$(csv_add "$REQUIRED" web)"
  REQUIRED="$(csv_add "$REQUIRED" mcp)"
fi
if csv_contains "$COMPONENTS" data-process; then
  REQUIRED="$(csv_add "$REQUIRED" data-process)"
fi
case "$SANDBOX_MODE" in
  full) REQUIRED="$(csv_add "$REQUIRED" sandbox-full)" ;;
  lightweight) REQUIRED="$(csv_add "$REQUIRED" sandbox)" ;;
  disabled) ;;
esac
if csv_contains "$COMPONENTS" terminal; then
  REQUIRED="$(csv_add "$REQUIRED" terminal)"
fi
[ -n "$REQUIRED" ] || die "deploy.options selects no Nexent application images"

LAST_COMMIT=""
if [ -f "$STATE_FILE" ]; then
  STATE_REPO="$(env_value "$STATE_FILE" repo)"
  STATE_TAG="$(env_value "$STATE_FILE" last_tag)"
  if { [ -z "$STATE_REPO" ] || [ "$STATE_REPO" = "$ROOT_DIR" ]; } \
    && { [ -z "$STATE_TAG" ] || [ "$STATE_TAG" = "$BASE_TAG" ]; }; then
    LAST_COMMIT="$(env_value "$STATE_FILE" last_commit)"
  fi
fi

DIFF_BASE=""
if [ -n "$LAST_COMMIT" ] \
  && git cat-file -e "${LAST_COMMIT}^{commit}" 2>/dev/null \
  && git merge-base --is-ancestor "$LAST_COMMIT" HEAD 2>/dev/null; then
  DIFF_BASE="$LAST_COMMIT"
elif git rev-parse -q --verify "refs/tags/$BASE_TAG" >/dev/null 2>&1; then
  DIFF_BASE="$BASE_TAG"
fi

CHANGED=""
if [ -n "$DIFF_BASE" ]; then
  CHANGED="$(git diff --name-only "$DIFF_BASE"..HEAD)"
fi
if [ "$ALLOW_DIRTY" = true ]; then
  CHANGED="${CHANGED}
$(git diff --name-only HEAD)
$(git ls-files --others --exclude-standard)"
fi
CHANGED="$(printf '%s\n' "$CHANGED" | sed '/^[[:space:]]*$/d' | sort -u)"

build_main=false
build_web=false
build_data_process=false
build_mcp=false
build_sandbox=false
build_sandbox_full=false
build_terminal=false
build_docs=false
SQL_CHANGED=false
DEPLOY_CHANGED=false

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    frontend/*)
      build_web=true
      ;;
    backend/*)
      build_main=true
      build_data_process=true
      ;;
    sdk/*)
      build_main=true
      build_data_process=true
      build_sandbox=true
      build_sandbox_full=true
      ;;
    VERSION)
      build_main=true
      build_data_process=true
      ;;
    deploy/common/run-sql-migrations.sh|deploy/common/start-backend.sh)
      build_main=true
      build_data_process=true
      ;;
    deploy/images/dockerfiles/main/*)
      build_main=true
      ;;
    deploy/images/dockerfiles/web/*)
      build_web=true
      ;;
    deploy/images/dockerfiles/data-process/*)
      build_data_process=true
      ;;
    deploy/images/dockerfiles/mcp/*)
      build_mcp=true
      ;;
    deploy/images/dockerfiles/sandbox-full/*)
      build_sandbox_full=true
      ;;
    deploy/images/dockerfiles/sandbox/*)
      build_sandbox=true
      ;;
    deploy/images/dockerfiles/terminal/*)
      build_terminal=true
      ;;
    deploy/images/dockerfiles/docs/*|doc/*)
      build_docs=true
      ;;
    deploy/sql/*)
      SQL_CHANGED=true
      ;;
    deploy/*)
      DEPLOY_CHANGED=true
      ;;
    scripts/build-and-deploy.sh)
      ;;
    *)
      ;;
  esac
done <<EOF
$CHANGED
EOF

TO_BUILD=""
if [ "$DO_BUILD" = true ]; then
  if [ -n "$IMAGES" ]; then
    TO_BUILD="$IMAGES"
  elif [ "$BUILD_ALL" = true ] || [ -z "$DIFF_BASE" ]; then
    TO_BUILD="$REQUIRED"
  else
    if [ "$build_main" = true ] && csv_contains "$REQUIRED" main; then
      TO_BUILD="$(csv_add "$TO_BUILD" main)"
    fi
    if [ "$build_web" = true ] && csv_contains "$REQUIRED" web; then
      TO_BUILD="$(csv_add "$TO_BUILD" web)"
    fi
    if [ "$build_data_process" = true ] && csv_contains "$REQUIRED" data-process; then
      TO_BUILD="$(csv_add "$TO_BUILD" data-process)"
    fi
    if [ "$build_mcp" = true ] && csv_contains "$REQUIRED" mcp; then
      TO_BUILD="$(csv_add "$TO_BUILD" mcp)"
    fi
    if [ "$build_sandbox" = true ] && csv_contains "$REQUIRED" sandbox; then
      TO_BUILD="$(csv_add "$TO_BUILD" sandbox)"
    fi
    if [ "$build_sandbox_full" = true ] && csv_contains "$REQUIRED" sandbox-full; then
      TO_BUILD="$(csv_add "$TO_BUILD" sandbox-full)"
    fi
    if [ "$build_terminal" = true ] && csv_contains "$REQUIRED" terminal; then
      TO_BUILD="$(csv_add "$TO_BUILD" terminal)"
    fi
  fi
fi

if [ "$build_docs" = true ] && [ "$DO_BUILD" = true ] && ! csv_contains "$TO_BUILD" docs; then
  log "doc/ or the docs Dockerfile changed; docs is not part of deploy.options, so it is not deployed."
  log "Use --images docs if you also need to rebuild nexent-docs."
fi

if [ -z "$TAG" ]; then
  if [ -n "$TO_BUILD" ]; then
    DIRTY_SUFFIX=""
    [ "$DIRTY" = true ] && DIRTY_SUFFIX="-dirty"
    TAG="${APP_VERSION}-${SHORT_SHA}${DIRTY_SUFFIX}"
  else
    TAG="$BASE_TAG"
  fi
fi

tag_is_valid "$TAG" || die "invalid release tag: $TAG"

REUSE=""
for image in $(printf '%s' "$REQUIRED" | tr ',' ' '); do
  if ! csv_contains "$TO_BUILD" "$image"; then
    REUSE="$(csv_add "$REUSE" "$image")"
  fi
done

if [ -z "$TO_BUILD" ] && [ "$DO_DEPLOY" = false ]; then
  log "No image builds requested and --no-deploy was used; nothing to do."
  exit 0
fi

if [ -z "$TO_BUILD" ] && [ "$DO_DEPLOY" = true ] \
  && [ "$DEPLOY_CHANGED" = false ] && [ "$SQL_CHANGED" = false ] \
  && [ "$FORCE" = false ] && [ "$TAG_EXPLICIT" = false ]; then
  log "No image, SQL, or deployment change detected since ${DIFF_BASE:-the current tag}."
  log "Use --force to deploy anyway, or --all to rebuild every required image."
  exit 0
fi

printf '\n'
log "Release plan"
printf '  Branch:          %s\n' "${BRANCH:-detached HEAD}"
printf '  Commit:          %s%s\n' "$COMMIT" "$([ "$DIRTY" = true ] && printf ' (dirty)' || true)"
printf '  App version:     %s\n' "$APP_VERSION"
printf '  Base tag:        %s\n' "$BASE_TAG"
printf '  Target tag:      %s\n' "$TAG"
printf '  Components:      %s\n' "$COMPONENTS"
printf '  Image source:    %s\n' "$IMAGE_SOURCE"
printf '  Sandbox mode:    %s\n' "$SANDBOX_MODE"
printf '  Required images: %s\n' "$REQUIRED"
printf '  Build images:    %s\n' "${TO_BUILD:-<none>}"
printf '  Reuse/retag:     %s\n' "${REUSE:-<none>}"
if [ -n "$REUSE" ] && [ "$TAG" = "$BASE_TAG" ]; then
  printf '  Retag:           no (target tag equals base tag)\n'
fi
printf '  Deploy mode:     %s\n' "$DEPLOY_MODE"
if [ "$SQL_CHANGED" = true ]; then
  printf '  SQL migrations:  changed (back up the database before deploying)\n'
fi
if [ "$BACKUP" = true ]; then
  printf '  Backup:          %s\n' "$BACKUP_DIR"
fi
printf '\n'

if [ "$SQL_CHANGED" = true ] && [ "$BACKUP" = false ]; then
  warn "SQL files changed. Consider rerunning with --backup, or run deploy/docker/backup.sh first."
fi

if [ "$DRY_RUN" = false ] && [ "$ASSUME_YES" = false ]; then
  if [ -t 0 ]; then
    printf '[release] Continue? [y/N] '
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *) printf '[release] Aborted.\n' >&2; exit 2 ;;
    esac
  else
    die "non-interactive run requires --yes"
  fi
fi

if [ -n "$TO_BUILD" ]; then
  for image in $(printf '%s' "$TO_BUILD" | tr ',' ' '); do
    build_image "$image"
  done
fi

for image in $(printf '%s' "$TO_BUILD" | tr ',' ' '); do
  if ! csv_contains "$REQUIRED" "$image"; then
    built_ref="$(built_ref_for "$image")"
    if [ "$DRY_RUN" = false ] && ! image_exists "$built_ref"; then
      die "build did not produce $built_ref"
    fi
  fi
done

for image in $(printf '%s' "$REQUIRED" | tr ',' ' '); do
  ensure_image "$image"
done

if [ "$BACKUP" = true ]; then
  log "Running backup to $BACKUP_DIR"
  log "Stop business writes before the backup starts."
  run bash "$ROOT_DIR/deploy/docker/backup.sh" --backup-dir "$BACKUP_DIR"
fi

if [ "$DO_DEPLOY" = true ]; then
  log "Deploying tag $TAG"
  run bash "$DEPLOY_SCRIPT" "--$DEPLOY_MODE" docker --version "$TAG" \
    ${DEPLOY_EXTRA[@]+"${DEPLOY_EXTRA[@]}"}

  if [ "$DRY_RUN" = false ]; then
    log "Verifying container images"
    verify_container nexent-config main
    verify_container nexent-runtime main
    verify_container nexent-northbound main
    verify_container nexent-web web
    verify_container nexent-mcp mcp
    verify_container nexent-data-process data-process

    log "Containers in the nexent compose project"
    docker ps --filter label=com.docker.compose.project=nexent \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | sed -n '1,20p'

    save_state || warn "deployment succeeded, but release state could not be written"
  fi

  log "Release tag: $TAG"
  log "Rollback command: bash deploy.sh --defaults docker --version $BASE_TAG"
else
  log "Build and retag complete; --no-deploy was used."
  log "Deploy later with: bash deploy.sh --defaults docker --version $TAG"
  log "Release state was not updated because nothing was deployed."
fi
