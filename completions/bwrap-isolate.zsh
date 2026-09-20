#compdef bwrap-isolate.sh bwrap-isolate

_bwrap_isolate() {
    _arguments -s \
        '--home-ro[read-only HOME paths]:paths:_files -/' \
        '--home-rw[writable HOME paths]:paths:_files -/' \
        '--mise[enable mise support]' \
        '--passthrough-env[environment variable names]:names:' \
        '--allow-hardlinks[disable hard-link validation]' \
        '--follow-symlinks[confirm external symlink targets]' \
        '--mount-root-ro[mount the host root read-only]' \
        '(-h --help)'{-h,--help}'[show help]' \
        '1:command:_command_names' \
        '*:arguments:_message "argument"'
}

_bwrap-isolate "$@"
