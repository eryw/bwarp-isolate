#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LAUNCHER="$ROOT/bwrap-isolate.sh"
WRAPPER="$ROOT/omp-isolate.sh"
TEST_ROOT=$(mktemp -d "$ROOT/.bwrap-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'test-bwrap-isolate.sh: %s\n' "$*" >&2
    exit 1
}

[[ -x $LAUNCHER ]] || fail 'launcher is not executable'
bash -n "$LAUNCHER"
"$LAUNCHER" --help >/dev/null 2>&1
for legacy_option in --home-ro --home-rw; do
    if legacy_option_error=$("$LAUNCHER" "$legacy_option" 2>&1); then
        fail "removed $legacy_option option was still accepted"
    fi
    [[ $legacy_option_error == *"unknown launcher option: $legacy_option"* ]] || \
        fail "removed $legacy_option option did not report as unknown"
done

SANDBOX_HOME="$TEST_ROOT/home"
mkdir -p "$SANDBOX_HOME/work" "$SANDBOX_HOME/.agents" "$SANDBOX_HOME/.claude" "$SANDBOX_HOME/.codex" "$SANDBOX_HOME/.gemini" "$SANDBOX_HOME/.ddev" "$SANDBOX_HOME/.config/oh-my-pi"
mkdir -p "$SANDBOX_HOME/.local/bin" "$SANDBOX_HOME/.local/lib"
mkdir -p "$SANDBOX_HOME/.omp/plugins" "$SANDBOX_HOME/go/bin"
printf 'plugin file\n' > "$SANDBOX_HOME/.omp/plugins/plugin"
printf 'selected config\n' > "$SANDBOX_HOME/.agents/config"
printf 'claude config\n' > "$SANDBOX_HOME/.claude/config"
printf 'codex config\n' > "$SANDBOX_HOME/.codex/config"
printf 'gemini config\n' > "$SANDBOX_HOME/.gemini/config"
extra_ro="$TEST_ROOT/shared-ro"
extra_rw="$TEST_ROOT/shared-rw"
mkdir -p "$extra_ro" "$extra_rw"
printf 'read only\n' > "$extra_ro/input"
outside="$TEST_ROOT/outside"
hidden_host="$TEST_ROOT/hidden-host-file"
printf 'host-only\n' > "$hidden_host"
external_source="$TEST_ROOT/external-source"
printf 'external source\n' > "$external_source"
symlink_rw="$SANDBOX_HOME/.symlink-target-root"
mkdir "$symlink_rw"
symlink_target="$symlink_rw/symlink-target"
printf 'original\n' > "$symlink_target"
ln -s "$symlink_target" "$SANDBOX_HOME/work/followed-link"
inside="$SANDBOX_HOME/work/inside"
rw_config="$SANDBOX_HOME/.config/oh-my-pi"
bad_rw_config="$SANDBOX_HOME/.config/bad-agent"
mkdir "$bad_rw_config"
mise_data="$SANDBOX_HOME/.local/share/mise"
mkdir -p "$mise_data/shims"
printf '#!/bin/sh\nprintf mise-ok\n' > "$mise_data/shims/mise-tool"
chmod +x "$mise_data/shims/mise-tool"
secret_name=".bwrap-host-secret.$$"
auto_root="$TEST_ROOT/projects"
auto_work="$auto_root/infini-shield"
auto_target="$auto_root/infini-shield-server/plans"
mkdir -p "$auto_work" "$auto_target"
ln -s "$auto_target" "$auto_work/plans"


fake_bin="$TEST_ROOT/fake-bin"
capture="$TEST_ROOT/bwrap.args"
mkdir "$fake_bin"
cat > "$fake_bin/bwrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${BWRAP_CAPTURE:?}"
EOF
chmod +x "$fake_bin/bwrap"
command -v script >/dev/null 2>&1 || fail 'script is required for confirmation tests'
run_confirmed() {
    local answer=$1 transcript=$2 command_string=$3
    printf '%s\n' "$answer" | script -qefc "$command_string" "$transcript" >/dev/null 2>&1
}

(
    cd -- "$SANDBOX_HOME/work"
    BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
        env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS \
        "$LAUNCHER" -- true
)
mapfile -d '' -t captured_args < "$capture"
require_destination() {
    local destination=$1 index
    for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
        if [[ ${captured_args[index + 2]} == "$destination" ]]; then
            return 0
        fi
    done
    fail "mount destination was not present: $destination"
}
require_no_destination() {
    local destination=$1 index
    for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
        if [[ ${captured_args[index + 2]} == "$destination" ]]; then
            fail "unexpected mount destination was present: $destination"
        fi
    done
}
require_pair() {
    local first=$1 second=$2 index
    for ((index = 0; index + 1 < ${#captured_args[@]}; index++)); do
        if [[ ${captured_args[index]} == "$first" && ${captured_args[index + 1]} == "$second" ]]; then
            return 0
        fi
    done
    fail "argument pair was not present: $first $second"
}
require_triplet() {
    local first=$1 second=$2 third=$3 index
    for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
        if [[ ${captured_args[index]} == "$first" && ${captured_args[index + 1]} == "$second" && ${captured_args[index + 2]} == "$third" ]]; then
            return 0
        fi
    done
    fail "argument triplet was not present: $first $second $third"
}
require_no_triplet() {
    local first=$1 second=$2 third=$3 index
    for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
        if [[ ${captured_args[index]} == "$first" && ${captured_args[index + 1]} == "$second" && ${captured_args[index + 2]} == "$third" ]]; then
            fail "unexpected argument triplet was present: $first $second $third"
        fi
    done
}
for home_path in "$SANDBOX_HOME/.agents" "$SANDBOX_HOME/.claude" "$SANDBOX_HOME/.codex" "$SANDBOX_HOME/.gemini"; do
    require_no_destination "$home_path"
done
require_pair --ro-bind "$SANDBOX_HOME/.local/bin"
for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
    if [[ ${captured_args[index]} == --ro-bind && ${captured_args[index + 1]} == / &&
        ${captured_args[index + 2]} == / ]]; then
        fail 'launcher still exposes the host root mount'
    fi
done
require_no_destination /var/run/docker.sock
if [[ -S /var/run/docker.sock ]]; then
    (
        cd -- "$SANDBOX_HOME/work"
        BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
            env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS \
            -u BWRAP_DOCKER_SOCKET "$LAUNCHER" --docker-socket -- true
    )
    mapfile -d '' -t captured_args < "$capture"
    require_triplet --bind /var/run/docker.sock /var/run/docker.sock
    (
        cd -- "$SANDBOX_HOME/work"
        BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
            BWRAP_DOCKER_SOCKET=1 "$LAUNCHER" -- true
    )
    mapfile -d '' -t captured_args < "$capture"
    require_triplet --bind /var/run/docker.sock /var/run/docker.sock
else
    if (
        cd -- "$SANDBOX_HOME/work"
        HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
            env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS \
            -u BWRAP_DOCKER_SOCKET "$LAUNCHER" --docker-socket -- true \
    ); then
        fail 'docker-socket mode accepted a missing Docker socket'
    fi
    docker_socket_error=$(<"$TEST_ROOT/docker-socket-error")
    [[ $docker_socket_error == *'Docker socket not found'* ]] || \
        fail 'missing Docker socket error was not actionable'
fi
(
    cd -- "$SANDBOX_HOME/work"
    CLI_SECRET=visible OTHER_SECRET=hidden BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" MISE_DATA_DIR="$mise_data" \
        BWRAP_MISE=0 BWRAP_PASSTHROUGH_ENV=OTHER_SECRET PATH="$fake_bin:/usr/bin:/bin" \
        "$LAUNCHER" --bind-ro "$SANDBOX_HOME/.claude" --bind-rw "$rw_config" --mise \
        --passthrough-env CLI_SECRET -- true
)
mapfile -d '' -t captured_args < "$capture"
require_pair --ro-bind "$SANDBOX_HOME/.claude"
require_pair --bind "$rw_config"
require_triplet --setenv CLI_SECRET visible
require_triplet --setenv MISE_DATA_DIR "$mise_data"
require_pair --ro-bind "$SANDBOX_HOME/.local/bin"
(
    cd -- "$SANDBOX_HOME/work"
    BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
        "$LAUNCHER" --bind-rw "$SANDBOX_HOME/.local/bin" -- true
)
mapfile -d '' -t captured_args < "$capture"
require_pair --bind "$SANDBOX_HOME/.local/bin"
require_no_triplet --ro-bind "$SANDBOX_HOME/.local/bin" "$SANDBOX_HOME/.local/bin"
require_no_destination "$SANDBOX_HOME/.codex"
require_no_destination "$symlink_rw"
require_no_triplet --setenv OTHER_SECRET hidden
(
    cd -- "$SANDBOX_HOME/work"
    BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
        env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS \
        "$LAUNCHER" --bind-ro "$extra_ro" --bind-rw="$extra_rw" -- true
)
mapfile -d '' -t captured_args < "$capture"
require_pair --ro-bind "$extra_ro"
require_pair --bind "$extra_rw"
(
    cd -- "$SANDBOX_HOME/work"
    BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" PATH="$fake_bin:/usr/bin:/bin" \
        env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS \
        "$LAUNCHER" --mount-root-ro -- true
)
mapfile -d '' -t captured_args < "$capture"
root_ro_bind_seen=false
for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
    if [[ ${captured_args[index]} == --ro-bind && ${captured_args[index + 1]} == / &&
        ${captured_args[index + 2]} == / ]]; then
        root_ro_bind_seen=true
    fi
done
[[ $root_ro_bind_seen == true ]] || fail 'mount-root-ro did not mount the host root read-only'
require_destination /usr/bin
require_destination /usr/lib
require_destination /etc/ld.so.cache
(
    cd -- "$SANDBOX_HOME/work"
    HOME="$SANDBOX_HOME" \
        "$LAUNCHER" --bind-ro "$SANDBOX_HOME/.agents" --bind-rw "$rw_config" \
            --mount-root-ro -- sh -ceu '
            test -f "$1"
            ! touch "$1" 2>/dev/null
        ' sh "$hidden_host"
)

ln -s / "$SANDBOX_HOME/work/root-link"
root_command=$(printf 'cd -- %q && env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS BWRAP_CAPTURE=%q HOME=%q PATH=%q %q --follow-symlinks -- true' \
    "$SANDBOX_HOME/work" "$capture" "$SANDBOX_HOME" "$fake_bin:/usr/bin:/bin" "$LAUNCHER")
root_confirmation="$TEST_ROOT/root-confirmation.log"
if ! run_confirmed y "$root_confirmation" "$root_command"; then
    fail 'follow-symlinks root-target confirmation failed'
fi
root_confirmation_text=$(<"$root_confirmation")
[[ $root_confirmation_text == *"$SANDBOX_HOME/work/root-link -> /"* ]] || \
    fail 'confirmation omitted the root symlink mapping'
mapfile -d '' -t captured_args < "$capture"
root_bind_seen=false
for ((index = 0; index + 2 < ${#captured_args[@]}; index++)); do
    if [[ ${captured_args[index]} == --bind && ${captured_args[index + 1]} == / &&
        ${captured_args[index + 2]} == / ]]; then
        root_bind_seen=true
    fi
done
[[ $root_bind_seen == true ]] || fail 'follow-symlinks did not auto-mount the host root target'
rm "$SANDBOX_HOME/work/root-link"

cancel_target="$TEST_ROOT/cancel-target"
printf 'cancel target\n' > "$cancel_target"
ln -s "$cancel_target" "$SANDBOX_HOME/work/cancel-link"
rm -f "$capture"
cancel_command=$(printf 'cd -- %q && env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS BWRAP_CAPTURE=%q HOME=%q PATH=%q %q --follow-symlinks -- true' \
    "$SANDBOX_HOME/work" "$capture" "$SANDBOX_HOME" "$fake_bin:/usr/bin:/bin" "$LAUNCHER")
cancel_confirmation="$TEST_ROOT/cancel-confirmation.log"
if run_confirmed n "$cancel_confirmation" "$cancel_command"; then
    fail 'negative symlink confirmation unexpectedly continued'
fi
[[ ! -e $capture ]] || fail 'bubblewrap executed after symlink confirmation cancellation'
cancel_confirmation_text=$(<"$cancel_confirmation")
[[ $cancel_confirmation_text == *"$SANDBOX_HOME/work/cancel-link -> $cancel_target"* ]] || \
    fail 'cancellation prompt omitted the symlink mapping'
rm "$SANDBOX_HOME/work/cancel-link"

auto_command=$(printf 'cd -- %q && env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS HOME=%q %q --follow-symlinks -- sh -ceu %q' \
    "$auto_work" "$SANDBOX_HOME" "$LAUNCHER" 'printf sibling-ok > plans/created')
auto_confirmation="$TEST_ROOT/auto-confirmation.log"
if ! run_confirmed y "$auto_confirmation" "$auto_command"; then
    fail 'follow-symlinks did not auto-mount a sibling target directory'
fi
auto_confirmation_text=$(<"$auto_confirmation")
[[ $auto_confirmation_text == *"$auto_work/plans -> $auto_target"* ]] || \
    fail 'confirmation omitted the sibling symlink mapping'
[[ $(cat "$auto_target/created") == sibling-ok ]] || \
    fail 'sibling symlink target did not receive the sandbox write'


ln -s "$SANDBOX_HOME/.agents/config" "$SANDBOX_HOME/work/ro-config-link"
follow_command=$(printf 'cd -- %q && env -u BWRAP_MISE -u BWRAP_FOLLOW_SYMLINKS HOME=%q %q --bind-ro %q --bind-rw %q --follow-symlinks -- sh -ceu %q' \
    "$SANDBOX_HOME/work" "$SANDBOX_HOME" "$LAUNCHER" "$SANDBOX_HOME/.agents" "$rw_config" 'printf followed > followed-link; printf ro-updated > ro-config-link')
follow_confirmation="$TEST_ROOT/follow-confirmation.log"
if ! run_confirmed y "$follow_confirmation" "$follow_command"; then
    cat "$follow_confirmation" >&2
    fail 'follow-symlinks mode did not run after confirmation'
fi
[[ $(cat "$symlink_target") == followed ]] || fail 'follow-symlinks mode did not make the target writable'
[[ $(cat "$SANDBOX_HOME/.agents/config") == ro-updated ]] || \
    fail 'approved symlink target remained read-only under a read-only bind'

mkdir "$TEST_ROOT/hardlink-work"
printf 'hardlink source\n' > "$TEST_ROOT/hardlink-source"
ln "$TEST_ROOT/hardlink-source" "$TEST_ROOT/hardlink-work/in-tree-link"
ln "$external_source" "$bad_rw_config/external-link"
if hardlink_error=$(
    cd -- "$TEST_ROOT/hardlink-work"
    HOME="$SANDBOX_HOME" \
        "$LAUNCHER" --bind-rw "$bad_rw_config" -- true 2>&1
); then
    fail 'sandbox accepted a writable bind containing a hard-linked file'
fi
[[ $hardlink_error == *PIXI_NO_HARD_LINKS* ]] || fail 'hardlink error omitted Pixi guidance'
[[ $hardlink_error == *package-import-method=copy* ]] || fail 'hardlink error omitted pnpm guidance'
additional_hardlink_dir="$TEST_ROOT/additional-hardlink-dir"
mkdir "$additional_hardlink_dir"
ln "$external_source" "$additional_hardlink_dir/external-link"
if additional_hardlink_error=$(
    cd -- "$TEST_ROOT/hardlink-work"
    HOME="$SANDBOX_HOME" \
        "$LAUNCHER" --bind-rw "$additional_hardlink_dir" -- true 2>&1
); then
    fail 'sandbox accepted an additional writable mount containing a hard-linked file'
fi
[[ $additional_hardlink_error == *PIXI_NO_HARD_LINKS* ]] || \
    fail 'additional writable mount hard-link rejection omitted Pixi guidance'


if (
    cd -- "$TEST_ROOT/hardlink-work"
    HOME="$SANDBOX_HOME" \
        "$LAUNCHER" --bind-ro "$SANDBOX_HOME/.agents" --bind-rw "$rw_config" \
            -- true >/dev/null 2>&1
); then
    fail 'sandbox accepted a work directory containing a hard-linked file'
fi
if ! (
    cd -- "$TEST_ROOT/hardlink-work"
    HOME="$SANDBOX_HOME" \
        "$LAUNCHER" --bind-ro "$SANDBOX_HOME/.agents" --bind-rw "$rw_config" \
            --allow-hardlinks -- true >/dev/null 2>&1
); then
    fail 'allow-hardlinks mode did not bypass hardlink validation'
fi


(
    cd -- "$SANDBOX_HOME/work"
    HOME="$SANDBOX_HOME" MISE_DATA_DIR="$mise_data" \
        BWRAP_MISE=1 \
        "$LAUNCHER" \
            --bind-ro "$SANDBOX_HOME/.agents" \
            --bind-ro "$SANDBOX_HOME/.claude" \
            --bind-ro "$SANDBOX_HOME/.codex" \
            --bind-ro "$SANDBOX_HOME/.gemini" \
            --bind-rw "$SANDBOX_HOME/.omp" \
            --bind-ro "$SANDBOX_HOME/.omp/plugins" \
            --bind-rw "$rw_config" \
            --bind-rw "$symlink_rw" \
            --bind-ro "$extra_ro" \
            --bind-rw "$extra_rw" -- sh -ceu '
            test "$PWD" = "$1"
            ! ln "$2" dynamic-link 2>/dev/null
            test -z "${SECRET_SHOULD_NOT_LEAK+x}"
            test -f "$HOME/.agents/config"
            test -f "$HOME/.claude/config"
            test -f "$HOME/.codex/config"
            test -f "$HOME/.gemini/config"
            test -f "$HOME/.omp/plugins/plugin"
            ! touch "$HOME/.omp/plugins/.write-check" 2>/dev/null
            touch "$HOME/.omp/write-check"
            test -f "$4/input"
            ! touch "$4/read-only-check" 2>/dev/null
            touch "$5/writable-check"
            ! touch "$HOME/.claude/.write-check" 2>/dev/null
            ! touch "$HOME/.codex/.write-check" 2>/dev/null
            ! touch "$HOME/.gemini/.write-check" 2>/dev/null
            if command -v python3 >/dev/null 2>&1; then
                python3 -c "import site; assert any((path.startswith(\"/usr/lib/\") or path.startswith(\"/usr/local/lib/\")) and (\"site-packages\" in path or \"dist-packages\" in path) for path in site.getsitepackages())"
            fi
            ! touch "$HOME/.agents/.bwrap-write-check" 2>/dev/null
            ! touch "$HOME/.local/bin/.bwrap-write-check" 2>/dev/null
            touch "$HOME/.config/oh-my-pi/updated"
            touch inside
            ! test -e "$3"
            ! touch ../outside 2>/dev/null
            touch "$HOME/'"$secret_name"'"
        ' sh "$SANDBOX_HOME/work" "$external_source" "$hidden_host" "$extra_ro" "$extra_rw"
)
[[ ! -e "$extra_ro/read-only-check" ]] || fail 'additional read-only directory was writable'
[[ -f "$extra_rw/writable-check" ]] || fail 'additional read-write directory did not persist changes'

[[ -f $inside ]] || fail 'sandbox could not persist a file in the current directory'
[[ -f "$rw_config/updated" ]] || fail 'additional writable bind did not persist changes'
[[ -f "$extra_rw/writable-check" ]] || fail 'additional read-write bind did not persist changes'
[[ ! -e "$extra_ro/read-only-check" ]] || fail 'additional read-only bind was writable'
[[ ! -e "$SANDBOX_HOME/.omp/plugins/.write-check" ]] || fail 'read-only bind nested in writable bind was writable'
[[ -f "$SANDBOX_HOME/.omp/write-check" ]] || fail 'writable bind parent did not persist changes'
[[ ! -e $outside ]] || fail 'sandbox modified a file outside the current directory'
[[ ! -e "$SANDBOX_HOME/$secret_name" ]] || fail 'sandbox modified the host HOME'
[[ ! -e "$SANDBOX_HOME/.local/bin/.bwrap-write-check" ]] || fail 'default local bin bind was writable'
[[ ! -e "$SANDBOX_HOME/.agents/.bwrap-write-check" ]] || fail 'read-only bind was writable'
mkdir -p "$TEST_ROOT/wrapper-work"
(
    cd -- "$TEST_ROOT/wrapper-work"
    BWRAP_CAPTURE="$capture" HOME="$SANDBOX_HOME" MISE_DATA_DIR="$mise_data" PATH="$fake_bin:/usr/bin:/bin" \
        "$WRAPPER" --bind-ro "$extra_ro" --bind-rw "$extra_rw"
)
mapfile -d '' -t captured_args < "$capture"
require_pair --ro-bind "$SANDBOX_HOME/.local/bin"
for home_path in "$SANDBOX_HOME/.agents" "$SANDBOX_HOME/.ddev" "$SANDBOX_HOME/.local/bin" "$SANDBOX_HOME/.omp/plugins"; do
    require_destination "$home_path"
done
require_pair --bind "$SANDBOX_HOME/.omp"
require_pair --ro-bind "$SANDBOX_HOME/.omp/plugins"
require_pair --ro-bind "$extra_ro"
require_pair --bind "$extra_rw"
require_no_destination "$SANDBOX_HOME/go/bin"

printf 'sandbox boundary checks passed\n'
