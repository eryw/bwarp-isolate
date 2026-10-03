#!/usr/bin/env bash
# Convenience wrapper for running Claude Code with the permissive agent sandbox.
# Equivalent to:
#   bwrap-isolate.sh --gpg --docker-socket --allow-hardlinks --follow-symlinks \
#     --bind-rw "$HOME/.claude" --bind-rw "$HOME/.claude.json" -- claude

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LAUNCHER="$SCRIPT_DIR/bwrap-isolate.sh"

usage() {
    cat >&2 <<'EOF'
Usage:
  claude-isolate.sh [MOUNT OPTION ...] [CLAUDE ARG ...]
  claude-isolate.sh --wrapper-help

  --bind-ro PATH  Expose an additional existing file or directory read-only.
  --bind-rw PATH  Expose an additional existing file or directory read-write.

Runs `claude` through bwrap-isolate.sh with:
  --gpg (exposes the GPG home and agent socket; masks private key files)
  --bind-rw "$HOME/.claude"
  --bind-rw "$HOME/.claude.json" (created with mode 0600 if missing)
  --allow-hardlinks
  --follow-symlinks (lists targets and requires confirmation before mounting)

This convenience wrapper intentionally provides a weaker filesystem boundary.
It prompts before each run when external project symlinks are present. Use
bwrap-isolate.sh directly when hard-link and symlink protections matter.
Additional file/directory bind options are passed to bwrap-isolate.sh before `claude`.
The active read-only paths, including Git config, attributes, and ignore files, are listed in
readonly_bind_paths; missing paths are skipped. Uncomment optional paths there only when needed.
This wrapper exposes the host Docker API socket on every run. This grants
root-equivalent control of the Docker host; use bwrap-isolate.sh for default-deny.
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
git_config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
    [[ $XDG_CONFIG_HOME == /* ]] || {
        printf '%s: XDG_CONFIG_HOME must be an absolute path: %s\n' "${0##*/}" "$XDG_CONFIG_HOME" >&2
        exit 64
    }
    git_config_home=$(realpath -m -- "$XDG_CONFIG_HOME") || {
        printf '%s: cannot resolve XDG_CONFIG_HOME: %s\n' "${0##*/}" "$XDG_CONFIG_HOME" >&2
        exit 64
    }
    XDG_CONFIG_HOME=$git_config_home
    export XDG_CONFIG_HOME
    case ":${BWRAP_PASSTHROUGH_ENV:-}:" in
        *:XDG_CONFIG_HOME:*) ;;
        *) export BWRAP_PASSTHROUGH_ENV="${BWRAP_PASSTHROUGH_ENV:+${BWRAP_PASSTHROUGH_ENV}:}XDG_CONFIG_HOME" ;;
    esac
fi

# Convenience profile: only existing selected paths are mounted read-only.
readonly_bind_paths=(
    "$HOME/.gitconfig"
    "$git_config_home/git/config"
    "$git_config_home/git/attributes"
    "$git_config_home/git/ignore"
    "$HOME/.local/share/claude"
    "$HOME/.ddev"
    "$HOME/.cargo/bin"
    "$HOME/.bun/bin"
    "$HOME/.config/composer/vendor/bin"
    "$HOME/.local/share/pnpm/bin"
)
declare -a profile_ro_args=()
for path in "${readonly_bind_paths[@]}"; do
    [[ -d $path || -f $path ]] || continue
    profile_ro_args+=(--bind-ro "$path")
done

claude_state_file="$HOME/.claude.json"
if [[ -L $claude_state_file ]]; then
    printf '%s: refusing symbolic-link Claude state file: %s\n' "${0##*/}" "$claude_state_file" >&2
    exit 64
fi
if [[ ! -e $claude_state_file ]]; then
    if ! (umask 077; set -o noclobber; : > "$claude_state_file") 2>/dev/null && \
        [[ ! -f $claude_state_file || -L $claude_state_file ]]; then
        printf '%s: cannot create Claude state file: %s\n' "${0##*/}" "$claude_state_file" >&2
        exit 64
    fi
fi
[[ -f $claude_state_file && ! -L $claude_state_file ]] || {
    printf '%s: Claude state path is not a regular file: %s\n' "${0##*/}" "$claude_state_file" >&2
    exit 64
}
declare -a claude_rw_args=(--bind-rw "$HOME/.claude" --bind-rw "$claude_state_file")

exec "$LAUNCHER" --gpg --docker-socket --allow-hardlinks --follow-symlinks \
    "${claude_rw_args[@]}" "${profile_ro_args[@]}" \
    "${additional_mount_args[@]}" -- claude "$@"
