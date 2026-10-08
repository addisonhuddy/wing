# bash completion for wing.

_wing_ltrim_colon_completions() {
    local cur=$1
    if declare -F __ltrim_colon_completions >/dev/null; then
        __ltrim_colon_completions "$cur"
    elif [[ "$cur" == *:* ]]; then
        local colon_prefix="${cur%%"${cur##*:}"}"
        COMPREPLY=("${COMPREPLY[@]/#"$colon_prefix"}")
    fi
}

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
        _wing_ltrim_colon_completions "$cur"
        return
    fi
    if [ "$cmd" = registry ] && [ "$sub" = set ] && [ -f wing.yaml ]; then
        names=$(awk '/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,"");sub(/:.*/,"");print}' wing.yaml | sort -u)
        COMPREPLY=($(compgen -W "$names" -- "$cur"))
        _wing_ltrim_colon_completions "$cur"
        return
    fi
    case "$prev" in
        --config | --schema-dir | --fixtures)
            COMPREPLY=($(compgen -f -- "$cur"))
            _wing_ltrim_colon_completions "$cur"
            return
            ;;
        --errors)
            COMPREPLY=($(compgen -W "json" -- "$cur"))
            _wing_ltrim_colon_completions "$cur"
            return
            ;;
        --compat)
            COMPREPLY=($(compgen -W "BACKWARD BACKWARD_TRANSITIVE FORWARD FORWARD_TRANSITIVE FULL FULL_TRANSITIVE NONE" -- "$cur"))
            _wing_ltrim_colon_completions "$cur"
            return
            ;;
        --registry)
            return
            ;;
    esac

    if [[ $cur != -* ]]; then
        case "$cmd" in
            "")
                opts="get ls push read registry rm update write"
                ;;
            registry)
                if [ -z "$sub" ]; then
                    opts="list set init"
                else
                    opts=""
                fi
                ;;
            *)
                opts=""
                ;;
        esac
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        _wing_ltrim_colon_completions "$cur"
        return
    fi

    case "$cmd" in
        "") opts="-V --version -h --help" ;;
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
    esac
    opts="$opts --registry --config --schema-dir --errors -q --quiet -v --verbose -h --help"
    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    _wing_ltrim_colon_completions "$cur"
}

complete -F _wing wing
