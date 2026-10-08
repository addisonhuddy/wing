# bash completion for wing.

_wing() {
    local cur prev word cmd sub opts names
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    cmd=""
    sub=""
    for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
        case "$word" in
            read | write | ls | get | push | rm | registry | update) cmd=$word ;;
            list | set | init) sub=$word ;;
        esac
    done

    if [[ $cur == @* ]] && [ -f wing.yaml ]; then
        names=$(awk '/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,"@");sub(/:.*/,"");print}' wing.yaml | sort -u)
        COMPREPLY=($(compgen -W "$names" -- "$cur"))
        return
    fi
    if [ "$cmd" = registry ] && [ "$sub" = set ] && [ -f wing.yaml ]; then
        names=$(awk '/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,"");sub(/:.*/,"");print}' wing.yaml | sort -u)
        COMPREPLY=($(compgen -W "$names" -- "$cur"))
        return
    fi
    case "$prev" in
        --config | --schema-dir | --fixtures)
            COMPREPLY=($(compgen -f -- "$cur"))
            return
            ;;
        --errors)
            COMPREPLY=($(compgen -W "json" -- "$cur"))
            return
            ;;
        --compat)
            COMPREPLY=($(compgen -W "BACKWARD BACKWARD_TRANSITIVE FORWARD FORWARD_TRANSITIVE FULL FULL_TRANSITIVE NONE" -- "$cur"))
            return
            ;;
        --registry)
            return
            ;;
    esac

    case "$cmd" in
        read) opts="--check" ;;
        write) opts="--fit --check" ;;
        ls) opts="--key --json" ;;
        get) opts="--meta --key" ;;
        push) opts="--check --fixtures --compat --meta --key" ;;
        rm) opts="-y --yes --permanent --key" ;;
        registry)
            if [ -z "$sub" ]; then
                opts="list set init --json"
            else
                opts="--json"
            fi
            ;;
        update) opts="" ;;
        *)
            opts="read write ls get push rm registry update -V --version"
            ;;
    esac
    opts="$opts --registry --config --schema-dir --errors -q --quiet -v --verbose -h --help"
    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
}

complete -F _wing wing
