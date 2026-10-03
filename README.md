# bwarp-isolate

`bwarp-isolate.sh` runs a command inside a Linux [bubblewrap](https://github.com/containers/bubblewrap) sandbox. The project keeps the current project directory writable while hiding the host home directory and most of the host filesystem from the command.

## Why use it?

Coding agents are useful in `yolo` mode, but an agent can make a wrong or destructive change. This launcher reduces the blast radius by making the project directory an explicit writable boundary and keeping other host paths unavailable by default.

This is process and filesystem isolation, not a virtual machine. It does not protect against a compromised kernel, bubblewrap, privileged host services, or anything intentionally exposed to the sandbox.

## Requirements

- Linux with working unprivileged user namespaces
- Bash
- `bwrap` (bubblewrap)
- `realpath` and `find`
- A writable project directory from which to run the command

Check the launcher and its dependencies with:

```sh
./bwrap-isolate.sh --help
```

## Install for your user

To make both launchers available from any project directory, copy them to the standard per-user executable directory, `~/.local/bin`:

```sh
mkdir -p "$HOME/.local/bin"
cp bwrap-isolate.sh omp-isolate.sh "$HOME/.local/bin/"
chmod 755 "$HOME/.local/bin/bwrap-isolate.sh" "$HOME/.local/bin/omp-isolate.sh"
```

Ensure that directory is on your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

For a persistent Bash configuration, add the same `export` line to `~/.bashrc`, then start a new shell or run `source ~/.bashrc`. Other shells use their corresponding startup file.

Keep both scripts in the same directory. `omp-isolate.sh` locates `bwrap-isolate.sh` beside itself. After installation, run the launcher from the project you want to isolate:

```sh
cd /path/to/my-project
omp-isolate.sh
```

If your system uses `~/bin` instead of `~/.local/bin`, replace the destination in the commands above and add `"$HOME/bin"` to `PATH` instead.

## Quick start

Run a command from the project directory you want to protect:

```sh
cd /path/to/my-project
/path/to/bwarp-isolate/bwrap-isolate.sh -- sh
```

Run a coding agent with the convenience profile:

```sh
cd /path/to/my-project
omp-isolate.sh
```

Use the minimal launcher directly when the command only needs the current project and the standard user bin directory:

```sh
./bwrap-isolate.sh -- python3 -m pytest
./bwrap-isolate.sh -- npm test
```

The `--` separates launcher options from the command. Arguments after the command are passed through unchanged.

Bind another project or shared data directory at its resolved absolute path:

```sh
./bwrap-isolate.sh --bind-ro ../shared-library --bind-rw ../generated-data -- command
```

Use repeatable `--bind-ro PATH` or `--bind-rw PATH` options. Both require existing directories; relative paths resolve from the directory where the launcher is started. Read-write mounts persist changes and are checked for hard-linked files unless hard-link validation is explicitly disabled. Conflicting binds are rejected; a read-only subtree may be nested under a read-write bind.

Changes made in the current directory persist on the host. Other host files are not writable unless explicitly exposed through `--bind-rw` or an approved external symlink.

## Oh My Pi wrapper

`omp-isolate.sh` is a convenience wrapper for Oh My Pi. It enables mise support, exposes `~/.omp` as writable configuration, allows hard links, and asks for confirmation before mounting targets of external project symlinks:

```sh
cd /path/to/my-project
/path/to/bwarp-isolate/omp-isolate.sh
/path/to/bwarp-isolate/omp-isolate.sh --help
```

The wrapper deliberately uses weaker boundary settings for compatibility. Use `bwrap-isolate.sh` directly when hard-link validation and stricter control are important.

Pass additional paths to the wrapper before the `omp` arguments:

```sh
./omp-isolate.sh --bind-ro ../shared-library --bind-rw ../generated-data -- --help
```

The wrapper bind-mounts existing Git global config files (`~/.gitconfig` and `$XDG_CONFIG_HOME/git/config`) and the conventional global attributes/ignore files under `$XDG_CONFIG_HOME/git/` read-only. When `XDG_CONFIG_HOME` is unset it defaults to `~/.config`; an explicit absolute value is preserved in the sandbox. Missing paths are skipped. Git still applies its normal config precedence, so the presence of both config files does not mean Git reads both.

The wrapper forwards additional read-only file or directory binds and read-write directory binds to `bwrap-isolate.sh`; read-write paths persist to the host.

To use a different Oh My Pi configuration directory, invoke the launcher directly with the desired `--bind-rw PATH`.

`omp-isolate.sh` enables GPG access so `omp` can sign commits with the host GPG agent. The minimal launcher keeps it disabled unless `--gpg` is passed:

```sh
./bwrap-isolate.sh --gpg -- git commit -S -m 'Signed commit'
```

`--gpg` mounts `GNUPGHOME` (or `~/.gnupg`) and the socket directory reported by `gpgconf --list-dirs socketdir` read-write, then sets `GNUPGHOME` in the sandbox. If `private-keys-v1.d` exists, it is masked from the sandbox; the host agent retains access to its own key files and can sign. The command can request signatures and modify other GPG-home files, so enable this only for trusted commands. The option requires an existing GPG home and socket directory; an explicitly configured but missing `GNUPGHOME` is an error. Git configuration and passphrase-terminal forwarding are not enabled by `--gpg`.

## Docker API access

The launcher makes standard Docker executables available through the read-only `/usr/bin` runtime mount, but it hides `/var/run/docker.sock` by default. Docker commands therefore cannot reach the host daemon unless socket access is explicitly enabled.

Enable Docker access for the convenience wrapper:

```sh
BWRAP_DOCKER_SOCKET=1 omp-isolate.sh
```

Or run Docker directly through the minimal launcher:

```sh
./bwrap-isolate.sh --docker-socket -- docker ps
```

The opt-in mounts the host Docker socket at `/var/run/docker.sock`. The option is disabled by default because Docker socket access grants effectively root-level control of the Docker host: a command with access can create privileged containers, mount arbitrary host paths, and control the daemon.

Docker configuration and credentials under `~/.docker` are not exposed automatically. If a command needs them, bind the directory read-only explicitly and review its contents first because it may contain registry credentials.

For the strongest isolation, keep Docker administration outside the sandbox and use the sandbox only for project commands that do not need daemon access.

## Launcher options

```text
--bind-ro PATH          Bind an additional existing file or directory read-only (repeatable).
--bind-rw PATH          Bind an additional existing directory read-write (repeatable).
--mise                  Set BWRAP_MISE=1.
--gpg                   Expose GPG home and agent socket for signing (opt-in).
--passthrough-env NAMES Set BWRAP_PASSTHROUGH_ENV (colon-separated names).
--docker-socket         Expose /var/run/docker.sock to the command.
--allow-hardlinks       Disable hard-link boundary validation.
--follow-symlinks       Show external symlink targets and ask before mounting them writable.
--mount-root-ro         Expose the host root filesystem read-only.
--help                  Show help.
```

The launcher masks host `HOME` with an empty tmpfs. If it exists, `~/.local/bin` is mounted read-only by default; an explicit `--bind-rw ~/.local/bin` replaces that default. Other home directories and host paths are visible only when explicitly bound. Each bind path must exist and is mounted at its resolved absolute path; relative paths resolve from the launch directory.

```sh
./bwrap-isolate.sh \
  --bind-ro "$HOME/.config/my-tool" \
  --bind-rw "$HOME/.omp" \
  --bind-ro ../shared-library \
  -- command
```

Read-write binds persist changes to the host and undergo hard-link validation. A read-only bind may be nested inside a read-write bind; the read-only mount is applied last. Binds cannot overlap the working directory, HOME itself, or each other in conflicting ways. Avoid broad paths such as `/` or all of `HOME`.

`omp-isolate.sh` defines a convenience profile in `readonly_bind_paths`. It binds selected tool and agent directories read-only, `~/.omp` read-write, and `~/.omp/plugins` read-only. Missing optional read-only profile directories are skipped.

For example, expose Docker credentials only to a command that needs them:

```sh
./bwrap-isolate.sh --bind-ro "$HOME/.docker" -- docker ps
```

### mise

Set `BWRAP_MISE=1` to expose mise's data directory and shims read-only:

```sh
BWRAP_MISE=1 ./bwrap-isolate.sh -- node --version
```

`MISE_DATA_DIR` can override the mise data directory, but it must be an existing directory under `HOME` and must contain `shims`.

### Environment variables

The sandbox clears the environment and restores only locale and terminal metadata. Pass credentials or other required variables explicitly by name:

```sh
BWRAP_PASSTHROUGH_ENV=OPENAI_API_KEY:ANTHROPIC_API_KEY \
  ./bwrap-isolate.sh -- omp
```

Environment variable names are validated. Avoid passing secrets unless the command genuinely needs them; network access remains available by design.

The environment variables and their CLI equivalents are:

- `BWRAP_MISE=1` → `--mise`
- `BWRAP_PASSTHROUGH_ENV` → `--passthrough-env NAMES`
- `BWRAP_DOCKER_SOCKET=1` → `--docker-socket`
- `BWRAP_ALLOW_HARDLINKS=1` → `--allow-hardlinks`
- `BWRAP_FOLLOW_SYMLINKS=1` → `--follow-symlinks`
- `BWRAP_MOUNT_ROOT_RO=1` → `--mount-root-ro`

## Isolation behavior

- The current directory is writable and persistent.
- The host `HOME` is replaced with an empty temporary filesystem.
- Selected runtime directories and libraries are mounted read-only so normal tools can run.
- `/tmp` and `/run` are private temporary filesystems.
- Network access is preserved for coding agents.
- Unlisted environment variables are not available.
- Hard-linked regular files are rejected in writable paths by default because they could modify an inode outside the sandbox boundary.
- External symlink targets are not followed by default. With `--follow-symlinks`, every resolved external target is shown and must be approved interactively before being mounted writable.
- The launcher requires user namespaces and disables nested user namespaces.

A writable project directory is therefore an intentional exception: an agent can modify everything inside it. Use a clean checkout, backups, or version control when the contents matter.

## Safety notes

- Do not bind broad paths such as all of `HOME`.
- Review every `--bind-ro` and `--bind-rw` path: these options expose arbitrary host directories at their absolute paths inside the sandbox, and read-write changes persist on the host.
- Treat `--follow-symlinks` as unsafe for untrusted projects. A symlink to `/` can expose the host filesystem with your existing permissions.
- `--mount-root-ro` makes the host filesystem readable. It does not make explicitly writable mounts safe.
- Secrets explicitly passed through the environment and data reachable over the network remain exposed.
- Bubblewrap does not replace backups, version control, or a VM for hostile workloads.

## Shell completion

The repository includes completion definitions for the launcher options.

### Bash

Source the Bash completion file in the current shell:

```sh
source ./completions/bwrap-isolate.bash
```

To load it automatically, source it from `~/.bashrc` or install it in your
distribution's Bash-completion directory.

### Zsh

Zsh expects completion functions in a directory on `fpath`. Install the file
under the conventional function name, then rebuild the completion cache:

```sh
mkdir -p "$HOME/.zsh/completions"
cp completions/bwrap-isolate.zsh "$HOME/.zsh/completions/_bwrap-isolate"
fpath=("$HOME/.zsh/completions" $fpath)
autoload -Uz compinit && compinit
```

The completion definitions cover every launcher CLI option, including
`--bind-ro` and `--bind-rw`.

## Tests

Run the self-contained shell test suite from this directory:

```sh
./test-bwrap-isolate.sh
```

The tests use temporary directories and a fake `bwrap` binary to verify mount construction, environment filtering, persistence of allowed writes, hard-link rejection, and symlink confirmation behavior.

## Machine-specific paths

The scripts contain no hard-coded personal home-directory paths. Host-specific locations are derived from `HOME`, `PWD`, and `MISE_DATA_DIR` at runtime.
