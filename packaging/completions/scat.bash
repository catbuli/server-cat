_scat_completion() {
    local current_word="${COMP_WORDS[COMP_CWORD]}"
    local command="${COMP_WORDS[1]:-}"
    local subcommand="${COMP_WORDS[2]:-}"
    if [[ "$COMP_CWORD" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W 'update doctor agent help --help -h' -- "$current_word") )
        return 0
    fi

    case "$command" in
        update)
            if [[ "$COMP_CWORD" -eq 2 ]]; then
                COMPREPLY=( $(compgen -W 'check apply' -- "$current_word") )
                return 0
            fi
            ;;
        agent)
            if [[ "$COMP_CWORD" -eq 2 ]]; then
                COMPREPLY=( $(compgen -W 'check enable disable status test-email mute unmute' -- "$current_word") )
            fi
            ;;
    esac
}

complete -F _scat_completion scat server-cat
