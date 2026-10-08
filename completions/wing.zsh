#compdef wing

_wing_registry_names() {
    local -a names
    names=(${(f)"$(awk '/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,"");sub(/:.*/,"");print}' wing.yaml 2>/dev/null | sort -u)"})
    compadd -a names
}

_wing_at_targets() {
    local -a names
    names=(${(f)"$(awk '/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,"@");sub(/:.*/,"");print}' wing.yaml 2>/dev/null | sort -u)"})
    compadd -a names
}

_wing() {
    local -a global
    global=(
        '--registry[Schema Registry URL]:url:'
        '--config[read this configuration file]:file:_files'
        '--schema-dir[offline schema cache]:directory:_files -/'
        '--errors[diagnostic format]:format:(json)'
        '(-q --quiet)'{-q,--quiet}'[suppress summaries]'
        '(-v --verbose)'{-v,--verbose}'[verbose diagnostics]'
        '(-h --help)'{-h,--help}'[show help]'
    )

    case "$words[CURRENT-1]" in
        --errors)
            compadd json
            return
            ;;
        --compat)
            compadd BACKWARD BACKWARD_TRANSITIVE FORWARD FORWARD_TRANSITIVE FULL FULL_TRANSITIVE NONE
            return
            ;;
        --config | --schema-dir | --fixtures)
            _files
            return
            ;;
        --registry)
            return
            ;;
    esac

    if [[ "$words[CURRENT]" != -* ]]; then
        if [[ "$words[CURRENT]" == @* ]]; then
            _wing_at_targets
            return
        fi
        if (( CURRENT == 2 )); then
            compadd get ls push read registry rm update write
            return
        fi
        if [[ "$words[2]" == registry ]] && (( CURRENT == 3 )); then
            compadd list set init
            return
        fi
        if [[ "$words[2]" == registry && "$words[3]" == set ]] && (( CURRENT == 4 )); then
            _wing_registry_names
            return
        fi
        return
    fi

    if (( CURRENT == 2 )); then
        _arguments -s \
            '(-V --version)'{-V,--version}'[print version]' \
            '(-h --help)'{-h,--help}'[show help]' \
            '--registry[Schema Registry URL]:url:' \
            '--config[read this configuration file]:file:_files' \
            '--schema-dir[offline schema cache]:directory:_files -/' \
            '--errors[diagnostic format]:format:(json)' \
            '(-q --quiet)'{-q,--quiet}'[suppress summaries]' \
            '(-v --verbose)'{-v,--verbose}'[verbose diagnostics]'
        return
    fi

    case "$words[2]" in
        read)
            _arguments -s $global '--check[validate without changing records]' '*:registry target:_wing_at_targets'
            ;;
        write)
            _arguments -s $global '--fit[fit records to the selected schema]' '--check[validate without writing]' \
                '*:reference or target:_wing_at_targets'
            ;;
        ls)
            _arguments -s $global '--key[list key schemas]' '--json[print JSON]' '*:topic:'
            ;;
        get)
            _arguments -s $global '--meta[print registry metadata]' '--key[fetch key schema]' '1:reference:_wing_at_targets'
            ;;
        push)
            _arguments -s $global '--check[lint without registering]' '--fixtures[validate fixture directory]:directory:_files -/' \
                '--compat[temporary compatibility level]:level:(BACKWARD BACKWARD_TRANSITIVE FORWARD FORWARD_TRANSITIVE FULL FULL_TRANSITIVE NONE)' \
                '--meta[read a metadata envelope]' '--key[register a key schema]' '1:topic:'
            ;;
        rm)
            _arguments -s $global '(-y --yes)'{-y,--yes}'[delete without confirming]' '--permanent[delete permanently]' \
                '--key[delete key schema]' '1:reference:_wing_at_targets'
            ;;
        registry)
            if (( CURRENT == 3 )); then
                _arguments -s $global '1:action:(list set init)'
            elif [[ "$words[3]" == set ]] && (( CURRENT == 4 )); then
                _wing_registry_names
            else
                _arguments -s $global '--json[print JSON]'
            fi
            ;;
        update)
            _arguments -s '(-h --help)'{-h,--help}'[show help]' '1:version:'
            ;;
    esac
}

_wing "$@"
