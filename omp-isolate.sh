#!/usr/bin/env bash
# Convenience wrapper for running Oh My Pi with the permissive agent sandbox.
# Equivalent to:
#   bwrap-isolate.sh --allow-hardlinks --follow-symlinks \
#     --bind-rw "$HOME/.omp" --bind-ro "$HOME/.agents" -- omp

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LAUNCHER="$SCRIPT_DIR/bwrap-isolate.sh"

usage() {
    cat >&2 <<'EOF'
Usage:
  omp-isolate.sh [MOUNT OPTION ...] [OMP ARG ...]
  omp-isolate.sh --wrapper-help

  --bind-ro PATH  Expose an additional existing directory read-only.
  --bind-rw PATH  Expose an additional existing directory read-write.

Runs `omp` through bwrap-isolate.sh with:
  --bind-rw "$HOME/.omp"
  --allow-hardlinks
  --follow-symlinks (lists targets and requires confirmation before mounting)

This convenience wrapper intentionally provides a weaker filesystem boundary.
It prompts before each run when external project symlinks are present. Use
bwrap-isolate.sh directly when hard-link and symlink protections matter.
Additional directory options are passed to bwrap-isolate.sh before `omp`.
The active read-only directories are listed in the `readonly_bind_paths` array;
uncomment optional paths there only when the tool is installed and needed.
Set BWRAP_DOCKER_SOCKET=1 to expose the host Docker API socket. This grants
root-equivalent control of the Docker host and is disabled by default.

EOF
}

if [[ ${1-} == --wrapper-help ]]; then
    usage
    exit 0
fi

[[ -x $LAUNCHER ]] || {
    printf '%s: launcher is not executable: %s\n' "${0##*/}" "$LAUNCHER" >&2
    exit 64
}
declare -a additional_mount_args=()
while (( $# > 0 )); do
    case $1 in
        --bind-ro|--bind-rw)
            (( $# >= 2 )) || {
                printf '%s: %s requires a path\n' "${0##*/}" "$1" >&2
                exit 64
            }
            additional_mount_args+=("$1" "$2")
            shift 2
            ;;
        --bind-ro=*|--bind-rw=*)
            additional_mount_args+=("$1")
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done
export BWRAP_MISE=1

# Convenience profile: only existing selected paths are mounted read-only.
readonly_bind_paths=(
    "$HOME/.agents"
    "$HOME/.ddev"
    "$HOME/.cargo/bin"
    "$HOME/.bun/bin"
    "$HOME/.config/composer/vendor/bin"
    "$HOME/.local/share/pnpm/bin"
    "$HOME/.omp/plugins"

    # Common optional language/tool directories:
    # "$HOME/.claude"
    # "$HOME/.codex"
    # "$HOME/.gemini"
    # "$HOME/go/bin"
    # "$HOME/.deno/bin"
    # "$HOME/.dotnet/tools"
    # "$HOME/.npm-global/bin"
    # "$HOME/.volta/bin"
    # "$HOME/.yarn/bin"
    # "$HOME/.asdf/bin"
    # "$HOME/.asdf/shims"
    # "$HOME/.pyenv/bin"
    # "$HOME/.pyenv/shims"
    # "$HOME/.rbenv/bin"
    # "$HOME/.rbenv/shims"
    # "$HOME/.rvm/bin"
    # "$HOME/.ghcup/bin"
    # "$HOME/.juliaup/bin"
    # "$HOME/.pub-cache/bin"
    # "$HOME/.mix/escripts"
)
declare -a profile_ro_args=()
for path in "${readonly_bind_paths[@]}"; do
    [[ -d $path ]] || continue
    profile_ro_args+=(--bind-ro "$path")
done

exec "$LAUNCHER" --docker-socket --allow-hardlinks --follow-symlinks \
    --bind-rw "$HOME/.omp" "${profile_ro_args[@]}" \
    "${additional_mount_args[@]}" -- omp "$@"
