#!/usr/bin/env bash
# Run a command in an empty-root bubblewrap sandbox with explicit read-only
# runtime mounts and a writable current directory.
#
# Persistent host writes are limited to the directory where this script is
# started plus any paths explicitly listed in BWRAP_HOME_RW. HOME is replaced
# with an empty tmpfs; only selected paths are mounted back. Network access is
# intentionally preserved for coding agents. Environment variables are cleared
# unless explicitly allowlisted.

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}

usage() {
    cat >&2 <<'EOF'
Usage:
  bwrap-isolate.sh [OPTIONS] [--] COMMAND [ARG ...]

  --home-ro PATHS       Set BWRAP_HOME_RO (colon-separated absolute paths).
  --home-rw PATHS       Set BWRAP_HOME_RW (colon-separated absolute paths).
  --mise                Set BWRAP_MISE=1.
  --passthrough-env NAMES
                        Set BWRAP_PASSTHROUGH_ENV (colon-separated names).
  --docker-socket       Expose /var/run/docker.sock to the command.
  --allow-hardlinks     Disable hard-link boundary validation.
  --follow-symlinks     List and confirm every resolved external symlink target;
                        mount approved targets writable.
  --mount-root-ro       Mount the host root directory read-only.
  --help                Show this help.

These options weaken the filesystem boundary and should only be used for
trusted projects.

Run COMMAND inside a bubblewrap sandbox.

Defaults:
  - current directory: writable and persistent
  - root filesystem: empty except for explicit runtime mounts
  - system executables, libraries, Python packages, and common data: readable
  - HOME: empty, except selected paths
  - selected non-mise user tool directories: readable
  - /tmp and /run: private temporary filesystems
  - network: available
  - environment: cleared, with locale/terminal variables restored
  - user namespaces: required; nested user namespaces disabled

Configuration (colon-separated absolute paths under HOME):
  BWRAP_HOME_RO       Read-only home paths. If unset, defaults to:
                      ~/.local/bin
  BWRAP_HOME_RW       Existing home directories to expose writable. Empty by
                      default. These paths persist changes to the host and
                      take precedence over an identical BWRAP_HOME_RO path.
  BWRAP_MISE          Set to 1 to expose mise's data directory and shims
                      read-only, and prepend the shims to PATH.
  BWRAP_PASSTHROUGH_ENV
                      Additional environment variable names to copy into the
                      sandbox, for example:
                      BWRAP_PASSTHROUGH_ENV=OPENAI_API_KEY:TERM
  BWRAP_DOCKER_SOCKET Set to 1 to expose /var/run/docker.sock. This grants
                      the command Docker API access and effectively root-level
                      control of the Docker host.
  BWRAP_ALLOW_HARDLINKS
                      Set to 1 as an alternative to --allow-hardlinks.
  BWRAP_FOLLOW_SYMLINKS
                      Set to 1 as an alternative to --follow-symlinks.
  BWRAP_MOUNT_ROOT_RO
                      Set to 1 as an alternative to --mount-root-ro.

Examples:
  BWRAP_HOME_RW="$HOME/.omp" \
  BWRAP_HOME_RO="$HOME/.agents" \
    BWRAP_PASSTHROUGH_ENV=ANTHROPIC_API_KEY \
    ./bwrap-isolate.sh -- omp --help
BWRAP_MISE=1 ./bwrap-isolate.sh -- node --version
./bwrap-isolate.sh --mount-root-ro -- sh -c 'cat /etc/os-release'
BWRAP_DOCKER_SOCKET=1 ./bwrap-isolate.sh -- ddev describe

Security notes:
  - The sandbox does not mount the host root by default; only listed runtime
    paths are visible. Do not add broad paths such as HOME itself to BWRAP_HOME_RO.
  - --mount-root-ro is opt-in and exposes the host root filesystem read-only.
    Explicit writable mounts, including the current directory and BWRAP_HOME_RW,
    remain writable. It does not make the root filesystem writable by itself.
  - --docker-socket is intentionally unsafe: Docker API access is equivalent
    to root-level control of the Docker host. Use only with trusted projects.
  - --follow-symlinks is intentionally unsafe: before execution, every
    resolved external target is displayed as `link -> target` and requires
    interactive confirmation before it is mounted writable. A project symlink
    to `/` can therefore expose the host filesystem to the invoking user's
    existing permissions. Use only with trusted projects.
  - Network access and explicitly passed secrets remain available by design.
  - The launcher rejects work directories and writable HOME mounts containing
    hard-linked regular files; move or copy such files before retrying.
  - This is OS-level process isolation, not a VM. Do not treat it as a defense
    against a compromised kernel, bubblewrap, or privileged host services.
EOF
}

fail() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
    exit 64
}
fail_hardlink() {
    local message=$1
    printf '%s: %s\n' "$SCRIPT_NAME" "$message" >&2
    cat >&2 <<'EOF'
Hard links are blocked because an allowed writable path could otherwise modify
the same inode through a name outside the sandbox boundary.

Common package-manager fixes:
  Pixi: set PIXI_NO_HARD_LINKS=1 (or use pixi install --no-hard-links).
        Example:
        PIXI_NO_HARD_LINKS=1 BWRAP_PASSTHROUGH_ENV=PIXI_NO_HARD_LINKS \
          ./bwrap-isolate.sh -- pixi install
  pnpm: add this to the project .npmrc:
        package-import-method=copy

Keep package caches in the current project directory or explicitly expose a
trusted cache directory with BWRAP_HOME_RW. You do not need to change package
managers.
EOF
    exit 64
}

allow_hardlinks=false
follow_symlinks=false
mount_root_ro=false
docker_socket=false
while (( $# > 0 )); do
    case $1 in
        --home-ro)
            (( $# >= 2 )) || fail '--home-ro requires a value'
            export BWRAP_HOME_RO=$2
            shift 2
            ;;
        --home-ro=*)
            export BWRAP_HOME_RO=${1#*=}
            shift
            ;;
        --home-rw)
            (( $# >= 2 )) || fail '--home-rw requires a value'
            export BWRAP_HOME_RW=$2
            shift 2
            ;;
        --home-rw=*)
            export BWRAP_HOME_RW=${1#*=}
            shift
            ;;
        --mise)
            export BWRAP_MISE=1
            shift
            ;;
        --passthrough-env)
            (( $# >= 2 )) || fail '--passthrough-env requires a value'
            export BWRAP_PASSTHROUGH_ENV=$2
            shift 2
            ;;
        --passthrough-env=*)
            export BWRAP_PASSTHROUGH_ENV=${1#*=}
            shift
            ;;
        --docker-socket)
            docker_socket=true
            shift
            ;;
        --allow-hardlinks)
            allow_hardlinks=true
            shift
            ;;
        --follow-symlinks)
            follow_symlinks=true
            shift
            ;;
        --mount-root-ro)
            mount_root_ro=true
            shift
            ;;
        --)
            shift
            break
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            fail "unknown launcher option: $1"
            ;;
        *)
            break
            ;;
    esac
done

case ${BWRAP_ALLOW_HARDLINKS:-0} in
    1|true) allow_hardlinks=true ;;
esac
case ${BWRAP_FOLLOW_SYMLINKS:-0} in
    1|true) follow_symlinks=true ;;
esac
case ${BWRAP_MOUNT_ROOT_RO:-0} in
    1|true) mount_root_ro=true ;;
esac
case ${BWRAP_DOCKER_SOCKET:-0} in
    1|true) docker_socket=true ;;
    0|"") ;;
    *) fail 'BWRAP_DOCKER_SOCKET must be 1, true, or unset' ;;
esac
if [[ $allow_hardlinks == true ]]; then
    printf '%s: WARNING: hard-link validation disabled\n' "$SCRIPT_NAME" >&2
fi
if [[ $follow_symlinks == true ]]; then
    printf '%s: WARNING: follow-symlinks will list and request confirmation for every resolved target\n' "$SCRIPT_NAME" >&2
fi
if [[ $mount_root_ro == true ]]; then
    printf '%s: WARNING: mounting the host root read-only\n' "$SCRIPT_NAME" >&2
fi
if [[ $docker_socket == true ]]; then
    printf '%s: WARNING: exposing /var/run/docker.sock grants Docker host control\n' \
        "$SCRIPT_NAME" >&2
fi

(( $# > 0 )) || { usage; fail 'a command is required'; }

command -v bwrap >/dev/null 2>&1 || fail 'bwrap is not installed or not in PATH'
command -v realpath >/dev/null 2>&1 || fail 'realpath is required'
if [[ $docker_socket == true && ! -S /var/run/docker.sock ]]; then
    fail 'Docker socket not found: /var/run/docker.sock'
fi

HOME=${HOME:?HOME is not set}
HOME=$(realpath -e -- "$HOME") || fail "cannot resolve HOME: $HOME"
[[ $HOME == /* && -d $HOME ]] || fail "HOME must be an existing absolute directory: $HOME"
[[ $HOME != / && $HOME != /tmp ]] || fail "refusing unsafe HOME: $HOME"

WORKDIR=$(realpath -e -- "$PWD") || fail "cannot resolve current directory: $PWD"
[[ -d $WORKDIR && -w $WORKDIR ]] || fail "current directory is not writable: $WORKDIR"
[[ $WORKDIR != / && $WORKDIR != /tmp && $WORKDIR != /run ]] || \
    fail "refusing special or root working directory: $WORKDIR"
case "$HOME" in
    "$WORKDIR"|"$WORKDIR"/*)
        fail "working directory must not contain HOME: $WORKDIR"
        ;;
esac


command -v find >/dev/null 2>&1 || fail 'find is required for hardlink validation'

# Build the argument vector instead of using eval. All user-controlled values
# remain separate argv entries when passed to bubblewrap.
bwrap_args=(
    --unshare-all
    --share-net
    --unshare-user
    --disable-userns
    --assert-userns-disabled
)
if [[ $mount_root_ro == true ]]; then
    bwrap_args+=(--ro-bind / /)
fi
bwrap_args+=(
    --die-with-parent
    --new-session
    --tmpfs /etc
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs /run
)
if [[ $docker_socket == true ]]; then
    bwrap_args+=(--bind /var/run/docker.sock /var/run/docker.sock)
fi

add_runtime_ro_bind() {
    local path=$1 resolved_path
    [[ -e $path || -L $path ]] || return 0
    # A root bind already exposes these host symlinks. Bubblewrap cannot
    # mount over a symlink destination, while the empty-root mode needs these
    # aliases created by the explicit runtime bind.
    if [[ $mount_root_ro == true && -L $path ]]; then
        return 0
    fi
    resolved_path=$(realpath -e -- "$path" 2>/dev/null) || return 0
    bwrap_args+=(--ro-bind "$resolved_path" "$path")
}

# Without --mount-root-ro the root is intentionally empty. These are the
# minimum conventional Linux runtime trees and configuration files needed by
# the supported tools; HOME and unrelated top-level host directories remain
# absent unless the opt-in root mount is requested.
runtime_ro_paths=(
    /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/libexec /usr/share
    /usr/local/bin /usr/local/sbin /usr/local/lib /usr/local/libexec
    /usr/local/share /bin /sbin /lib /lib64
    /etc/ld.so.cache /etc/ld.so.conf /etc/ld.so.conf.d /etc/alternatives
    /etc/passwd /etc/group /etc/nsswitch.conf /etc/host.conf /etc/hosts
    /etc/resolv.conf /etc/gai.conf /etc/protocols /etc/services /etc/shells
    /etc/localtime /etc/ssl/certs /etc/ca-certificates /etc/pki /etc/php
)
for runtime_path in "${runtime_ro_paths[@]}"; do
    add_runtime_ro_bind "$runtime_path"
done

# Validate selected host paths before hiding HOME. Bubblewrap resolves bind
# sources from the host mount namespace, so they remain available as sources
# after the sandbox HOME is masked.
declare -a home_ro_paths=()
if [[ -v BWRAP_HOME_RO ]]; then
    IFS=: read -r -a home_ro_paths <<< "$BWRAP_HOME_RO"
else
    home_ro_paths=(
        "$HOME/.local/bin"
    )
fi
declare -a home_rw_paths=()
if [[ -v BWRAP_HOME_RW && -n $BWRAP_HOME_RW ]]; then
    IFS=: read -r -a home_rw_paths <<< "$BWRAP_HOME_RW"
fi
mise_enabled=false
mise_data_dir=
case ${BWRAP_MISE:-0} in
    1|true)
        mise_enabled=true
        mise_data_dir=${MISE_DATA_DIR:-"$HOME/.local/share/mise"}
        [[ $mise_data_dir == /* ]] || fail "MISE_DATA_DIR must be absolute: $mise_data_dir"
        mise_data_dir=$(realpath -e -- "$mise_data_dir" 2>/dev/null) || \
            fail "mise data directory does not exist: $mise_data_dir"
        [[ $mise_data_dir == "$HOME/"* ]] || \
            fail "mise data directory must be under HOME: $mise_data_dir"
        [[ -d "$mise_data_dir/shims" ]] || \
            fail "mise shims directory does not exist: $mise_data_dir/shims"
        home_ro_paths+=("$mise_data_dir" "$HOME/.config/mise")
        ;;
    0|"")
        ;;
    *)
        fail "BWRAP_MISE must be 1, true, or unset"
        ;;
esac

resolve_home_dirs() {
    local requested_path resolved_path
    local required=$2
    local -n output_paths=$1
    shift 2
    for requested_path in "$@"; do
        [[ -n $requested_path ]] || continue
        [[ $requested_path == /* ]] || fail "HOME mount path is not absolute: $requested_path"

        if ! resolved_path=$(realpath -e -- "$requested_path" 2>/dev/null); then
            [[ $required == true ]] || continue
            fail "HOME mount path does not exist: $requested_path"
        fi
        [[ $resolved_path != "$HOME" && $resolved_path == "$HOME/"* ]] || \
            fail "HOME mount path must resolve strictly below HOME: $requested_path"
        [[ -d $resolved_path ]] || fail "HOME mount path must be a directory: $requested_path"
        output_paths+=("$resolved_path")
    done
}

declare -a resolved_home_ro_paths=()
declare -a resolved_home_rw_paths=()
resolve_home_dirs resolved_home_ro_paths false "${home_ro_paths[@]}"
resolve_home_dirs resolved_home_rw_paths true "${home_rw_paths[@]}"

for writable_path in "${resolved_home_rw_paths[@]}"; do
    for readonly_path in "${resolved_home_ro_paths[@]}"; do
        [[ $writable_path == "$readonly_path" ]] && continue
        case "$writable_path" in
            "$readonly_path"/*)
                fail "read-only HOME path contains writable path: $writable_path"
                ;;
        esac
    done
done
for readonly_path in "${resolved_home_ro_paths[@]}"; do
    case "$WORKDIR" in
        "$readonly_path"|"$readonly_path"/*)
            fail "working directory is inside read-only HOME path: $readonly_path"
            ;;
    esac
    case "$readonly_path" in
        "$WORKDIR"|"$WORKDIR"/*)
            fail "read-only HOME path is inside working directory: $readonly_path"
            ;;
    esac
done

declare -A writable_inode_counts=()
declare -A writable_inode_links=()
declare -A writable_inode_examples=()
declare -A writable_seen_paths=()

collect_writable_inodes() {
    local root=$1
    shift
    local readonly_path device inode inode_key link_count file_path
    local -a find_args=("$root" -xdev)
    for readonly_path in "$@"; do
        case "$readonly_path" in
            "$root"/*)
                find_args+=(-path "$readonly_path" -prune -o)
                ;;
        esac
    done
    find_args+=(-type f -links +1 -printf '%D %i %n %p\0')
    while IFS=' ' read -r -d '' device inode link_count file_path; do
        [[ -n $device && -n $inode && -n $file_path ]] || continue
        [[ -v writable_seen_paths[$file_path] ]] && continue
        writable_seen_paths[$file_path]=1
        inode_key="$device:$inode"
        if [[ -v writable_inode_counts[$inode_key] ]]; then
            writable_inode_counts[$inode_key]=$((writable_inode_counts[$inode_key] + 1))
        else
            writable_inode_counts[$inode_key]=1
            writable_inode_links[$inode_key]=$link_count
            writable_inode_examples[$inode_key]=$file_path
        fi
    done < <(find "${find_args[@]}")
}

if [[ $allow_hardlinks != true ]]; then
    collect_writable_inodes "$WORKDIR"
    for writable_path in "${resolved_home_rw_paths[@]}"; do
        collect_writable_inodes "$writable_path" "${resolved_home_ro_paths[@]}"
    done
    for inode in "${!writable_inode_counts[@]}"; do
        if (( writable_inode_counts[$inode] < writable_inode_links[$inode] )); then
            fail_hardlink "writable paths contain an externally linked inode: ${writable_inode_examples[$inode]}"
        fi
    done
fi
declare -a symlink_paths=()
declare -a symlink_resolved_targets=()
declare -a symlink_targets=()
declare -A symlink_target_seen=()
if [[ $follow_symlinks == true ]]; then
    symlink_count=0
    while IFS= read -r -d '' symlink_path; do
        symlink_target=$(realpath -e -- "$symlink_path" 2>/dev/null) || continue
        case "$symlink_target" in
            "$WORKDIR"|"$WORKDIR"/*) continue ;;
        esac
        symlink_paths+=("$symlink_path")
        symlink_resolved_targets+=("$symlink_target")
        if [[ -z ${symlink_target_seen[$symlink_target]+x} ]]; then
            symlink_target_seen[$symlink_target]=1
            symlink_targets+=("$symlink_target")
            symlink_count=$((symlink_count + 1))
        fi
    done < <(find "$WORKDIR" -xdev -type l -print0)
    if (( symlink_count > 0 )); then
        printf '%s: symlink targets to mount writable:\n' "$SCRIPT_NAME" >&2
        for ((index = 0; index < ${#symlink_paths[@]}; index++)); do
            printf '  %q -> %q\n' "${symlink_paths[index]}" "${symlink_resolved_targets[index]}" >&2
        done
        if ! exec {confirmation_fd}<>/dev/tty; then
            fail 'cannot confirm symlink mounts without an interactive terminal'
        fi
        printf '%s: Continue and mount these target(s) writable? [y/N] ' \
            "$SCRIPT_NAME" >&"$confirmation_fd"
        if ! IFS= read -r confirmation <&"$confirmation_fd"; then
            exec {confirmation_fd}>&-
            fail 'could not read symlink mount confirmation'
        fi
        exec {confirmation_fd}>&-
        case $confirmation in
            y|Y|yes|YES|Yes)
                ;;
            *)
                fail 'symlink mount confirmation cancelled'
                ;;
        esac
    fi
    printf '%s: resolved %d external symlink target(s)\n' \
        "$SCRIPT_NAME" "$symlink_count" >&2
fi



# Bubblewrap creates missing destination parents for bind operations. Mount
# HOME after validating all sources so the host HOME itself remains hidden.
bwrap_args+=(--tmpfs "$HOME")

for target in "${resolved_home_rw_paths[@]}"; do
    bwrap_args+=(--bind "$target" "$target")
done



# Read-only mounts are applied after writable roots so selected protected
# subtrees can safely remain read-only inside a writable config directory.
for target in "${resolved_home_ro_paths[@]}"; do
    for writable_path in "${resolved_home_rw_paths[@]}"; do
        [[ $target == "$writable_path" ]] && continue 2
    done
    bwrap_args+=(--ro-bind "$target" "$target")
done

# Approved symlink targets come last so confirmation always grants the
# requested writable mount, including targets nested under a read-only HOME path.
for target in "${symlink_targets[@]}"; do
    bwrap_args+=(--bind "$target" "$target")
done


sandbox_path=
if [[ $mise_enabled == true ]]; then
    sandbox_path="$mise_data_dir/shims"
fi
sandbox_path+="${sandbox_path:+:}$HOME/.local/bin"
sandbox_path+="${sandbox_path:+:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
bwrap_args+=(
    --bind "$WORKDIR" "$WORKDIR"
    --chdir "$WORKDIR"
    --clearenv
    --setenv HOME "$HOME"
    --setenv PWD "$WORKDIR"
    --setenv PATH "$sandbox_path"
    --setenv TMPDIR /tmp
    --setenv XDG_CACHE_HOME /tmp/xdg-cache
    --setenv XDG_CONFIG_HOME "$HOME/.config"
    --setenv XDG_DATA_HOME /tmp/xdg-data
    --setenv XDG_STATE_HOME /tmp/xdg-state
)

if [[ $mise_enabled == true ]]; then
    bwrap_args+=(
        --setenv MISE_DATA_DIR "$mise_data_dir"
        --setenv MISE_CONFIG_DIR "$HOME/.config/mise"
    )
fi

# Keep only non-sensitive terminal and locale metadata by default. Secrets and
# credentials must be named explicitly in BWRAP_PASSTHROUGH_ENV.
for name in TERM COLORTERM LANG LC_ALL LC_CTYPE LC_MESSAGES TZ; do
    if [[ -v $name ]]; then
        bwrap_args+=(--setenv "$name" "${!name}")
    fi
done

if [[ -v BWRAP_PASSTHROUGH_ENV && -n $BWRAP_PASSTHROUGH_ENV ]]; then
    IFS=: read -r -a passthrough_names <<< "$BWRAP_PASSTHROUGH_ENV"
    for name in "${passthrough_names[@]}"; do
        [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
            fail "invalid environment variable name: $name"
        if [[ -v $name ]]; then
            bwrap_args+=(--setenv "$name" "${!name}")
        fi
    done
fi

exec bwrap "${bwrap_args[@]}" -- "$@"
