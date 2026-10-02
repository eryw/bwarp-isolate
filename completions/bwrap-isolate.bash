# Bash completion for bwrap-isolate.sh and bwrap-isolate.

_bwrap_isolate_complete() {
    local current previous index
    local -a options

    COMPREPLY=()
    current=${COMP_WORDS[COMP_CWORD]}
    previous=${COMP_WORDS[COMP_CWORD - 1]:-}

    for ((index = 1; index < COMP_CWORD; index++)); do
        [[ ${COMP_WORDS[index]} == -- ]] && return 0
    done

    case $previous in
        --bind-ro|--bind-rw)
            COMPREPLY=( $(compgen -d -- "$current") )
            return 0
            ;;
        --passthrough-env)
            COMPREPLY=( $(compgen -A variable -- "$current") )
            return 0
            ;;
    esac

    options=(
        --bind-ro
        --bind-rw
        --mise
        --passthrough-env
        --allow-hardlinks
        --follow-symlinks
        --mount-root-ro
        --help
    )
    if [[ $current == -* ]]; then
        COMPREPLY=( $(compgen -W "${options[*]}" -- "$current") )
    fi
}

complete -F _bwrap_isolate_complete bwrap-isolate.sh bwrap-isolate
