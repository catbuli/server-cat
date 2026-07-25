_scat_completion() {
    local current_word="${COMP_WORDS[COMP_CWORD]}"
    local command="${COMP_WORDS[1]:-}"
    local subcommand="${COMP_WORDS[2]:-}"
    local version
    local versions=()

    if [[ "$COMP_CWORD" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W 'update agent help --help -h' -- "$current_word") )
        return 0
    fi

    case "$command" in
        update)
            if [[ "$COMP_CWORD" -eq 2 ]]; then
                COMPREPLY=( $(compgen -W 'check apply rollback' -- "$current_word") )
                return 0
            fi

            if [[ "$subcommand" == "rollback" && "$COMP_CWORD" -eq 3 ]]; then
                for version in /opt/server-cat/releases/*; do
                    [[ -d "$version" ]] || continue
                    versions+=( "${version##*/}" )
                done
                COMPREPLY=( $(compgen -W "${versions[*]}" -- "$current_word") )
            fi
            ;;
        agent)
            if [[ "$COMP_CWORD" -eq 2 ]]; then
                COMPREPLY=( $(compgen -W 'check enable disable status' -- "$current_word") )
            fi
            ;;
    esac
}

complete -F _scat_completion scat server-cat
