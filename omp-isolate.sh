#!/usr/bin/env bash
# Convenience wrapper for running Oh My Pi with the permissive agent sandbox.
# Equivalent to:
#   BWRAP_MISE=1 BWRAP_HOME_RW="$HOME/.omp" \
#   bwrap-isolate.sh --allow-hardlinks --follow-symlinks -- omp

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LAUNCHER="$SCRIPT_DIR/bwrap-isolate.sh"

usage() {
    cat >&2 <<'EOF'
Usage:
  omp-isolate.sh [OMP ARG ...]
  omp-isolate.sh --wrapper-help

Runs `omp` through bwrap-isolate.sh with:
  BWRAP_MISE=1
  BWRAP_HOME_RW="$HOME/.omp"
  --allow-hardlinks
  --follow-symlinks (lists targets and requires confirmation before mounting)

This convenience wrapper intentionally provides a weaker filesystem boundary.
It prompts before each run when external project symlinks are present. Use
bwrap-isolate.sh directly when hard-link and symlink protections matter.
The active read-only directories are listed in the `home_ro_paths` array below;
uncomment optional paths there only when the tool is installed and needed.
Set BWRAP_HOME_RW before invoking this wrapper to override the writable config
path.
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
export BWRAP_MISE=1
export BWRAP_HOME_RW=${BWRAP_HOME_RW:-"$HOME/.omp"}

# Convenience profile: keep the active list limited to directories used by
# this machine. Every path is still mounted read-only unless it is also in
# BWRAP_HOME_RW. Uncomment additional directories when their tools are used.
home_ro_paths=(
    "$HOME/.agents"
    "$HOME/.local/bin"
    "$HOME/.cargo/bin"
    "$HOME/.bun/bin"
    "$HOME/.config/composer/vendor/bin"
    "$HOME/.local/share/pnpm/bin"
    "$HOME/.omp"
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
home_ro_value=
for path in "${home_ro_paths[@]}"; do
    home_ro_value+="${home_ro_value:+:}$path"
done
export BWRAP_HOME_RO=${BWRAP_HOME_RO:-"$home_ro_value"}

exec "$LAUNCHER" --allow-hardlinks --follow-symlinks -- omp "$@"
