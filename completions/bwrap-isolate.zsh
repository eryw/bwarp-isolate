#compdef bwrap-isolate.sh bwrap-isolate

_bwrap_isolate() {
    _arguments -s \
        '--bind-ro[bind an additional file or directory read-only]:path:_files' \
        '--bind-rw[bind an additional directory read-write]:path:_files -/' \
        '--mise[enable mise support]' \
        '--gpg[expose GPG home and agent socket for signing]' \
        '--passthrough-env[environment variable names]:names:' \
        '--allow-hardlinks[disable hard-link validation]' \
        '--follow-symlinks[confirm external symlink targets]' \
        '--mount-root-ro[mount the host root read-only]' \
        '(-h --help)'{-h,--help}'[show help]' \
        '1:command:_command_names' \
        '*:arguments:_message "argument"'
}

_bwrap-isolate "$@"
