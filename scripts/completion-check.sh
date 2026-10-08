#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/wing"
chmod +x "$TMP/bin/wing"
export PATH="$TMP/bin:$PATH"
printf 'registries:\n  local-a:\n    schema.registry.url: http://localhost:8081\n  prod:\n    schema.registry.url: https://example.invalid\n' >"$TMP/work/wing.yaml"
cd "$TMP/work"

status=0
fail() { echo "FAIL $1" >&2; status=1; }
expect() {
    local name=$1 out=$2 needle
    shift 2
    for needle in "$@"; do
        if ! grep -qxF -- "$needle" <<<"$out"; then
            echo "--- $name completions:" >&2
            echo "$out" >&2
            fail "$name: missing '$needle'"
            return
        fi
    done
    echo "PASS $name"
}
expect_absent() {
    local name=$1 out=$2 needle
    shift 2
    for needle in "$@"; do
        if grep -qxF -- "$needle" <<<"$out"; then
            echo "--- $name completions:" >&2
            echo "$out" >&2
            fail "$name: unexpected '$needle'"
            return
        fi
    done
    echo "PASS $name"
}
expect_exact() {
    local name=$1 actual=$2 expected=$3
    if [[ "$actual" != "$expected" ]]; then
        echo "--- $name completions:" >&2
        printf '%s\n' "$actual" >&2
        fail "$name: expected '$expected'"
        return
    fi
    echo "PASS $name"
}

if command -v bash >/dev/null; then
    H="$TMP/bash-home"
    mkdir -p "$H/.local/share/bash-completion/completions"
    cp "$ROOT/completions/wing.bash" "$H/.local/share/bash-completion/completions/wing"
    out=$(HOME="$H" bash --noprofile --norc -c '
        source ~/.local/share/bash-completion/completions/wing
        complete -p wing >/dev/null || exit 1
        complete_at() {
            COMP_WORDS=("$@")
            COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
            COMP_LINE="${COMP_WORDS[*]}"
            COMP_POINT=${#COMP_LINE}
            _wing && printf "%s\n" "${COMPREPLY[@]}"
        }
        case_at() {
            printf "__CASE_%s__\n" "$1"
            shift
            complete_at "$@"
            printf "__END_CASE__\n"
        }
        case_at root-empty wing ""
        case_at root-prefix wing w
        case_at root-flags wing --
        case_at read-flags wing read --c
        case_at write-flags wing write --f
        case_at ls-flags wing ls --k
        case_at get-flags wing get --m
        case_at push-flags wing push --
        case_at push-argument wing push orders ""
        case_at colon-word wing get orders:3
        case_at rm-flags wing rm --p
        case_at registry-actions wing registry ""
        case_at registry-set wing registry set pr
        case_at at-target wing @local
        printf "__CASE_colon-trim__\n"
        COMPREPLY=("orders:3" "orders:4")
        _wing_ltrim_colon_completions "orders:3"
        printf "%s\n" "${COMPREPLY[@]}"
        printf "__END_CASE__\n"
    ') || fail "bash: completion script did not load"
    expect bash "$out" read write ls get push rm registry update --check --fit --key --meta --compat --permanent set @local-a
    case_output() {
        awk -v start="__CASE_$1__" '$0 == start { inside=1; next } $0 == "__END_CASE__" { inside=0 } inside' <<<"$out"
    }
    expect_exact "bash root command position" "$(case_output root-empty)" $'get\nls\npush\nread\nregistry\nrm\nupdate\nwrite'
    expect_exact "bash root command prefix" "$(case_output root-prefix)" write
    expect_absent "bash root non-dash" "$(case_output root-empty)" --registry --config --help
    expect "bash root dash options" "$(case_output root-flags)" --registry --config --version
    expect_absent "bash positional argument" "$(case_output push-argument)" --fit --check --registry
    expect_exact "bash colon argument" "$(case_output colon-word)" ""
    expect_exact "bash colon completion trimming" "$(case_output colon-trim)" $'3\n4'
    expect_absent "bash registry action position" "$(case_output registry-actions)" --json --registry
    expect "bash dash-prefixed options" "$(case_output push-flags)" --check --meta --compat --registry
else
    echo "SKIP bash"
fi

if command -v zsh >/dev/null; then
    H="$TMP/zsh-home"
    mkdir -p "$H/.zfunc"
    cp "$ROOT/completions/wing.zsh" "$H/.zfunc/_wing"
    cat >"$H/.zshrc" <<'EOF'
fpath=(~/.zfunc $fpath)
autoload -Uz compinit && compinit
EOF
    cat >"$TMP/zsh-driver.zsh" <<'EOF'
zmodload zsh/zpty
zmodload zsh/datetime
typeset -g buf=""
waitfor() {
    local deadline=$((EPOCHREALTIME + 10)) chunk
    while (( EPOCHREALTIME < deadline )); do
        if zpty -r -t wing_zsh chunk; then
            buf+=$chunk
            [[ $buf == ${~1} ]] && return 0
            if [[ $buf == *'abort compinit [n]? ' ]]; then
                zpty -w -n wing_zsh y
                buf=""
            fi
        else
            sleep 0.05
        fi
    done
    return 1
}
zpty -b wing_zsh zsh -i
waitfor '*[%$#] *' || exit 1
zpty -w wing_zsh 'PROMPT=""; RPROMPT=""; setopt no_beep; zstyle ":completion:*" completer _complete
__cands=()
compadd() { local -a __r; builtin compadd -O __r "$@"; __cands+=($__r) }
__comptest() { __cands=(); _main_complete; print -rl -- "<<" $__cands ">>" }
zle -C __comptest complete-word __comptest
bindkey "^I" __comptest
print READY'
waitfor '*READY*' || exit 1
for line in "$@"; do
    buf=""
    zpty -w -n wing_zsh "$line"$'\t'
    waitfor '*>>*' || exit 1
    print -r -- "$buf"
    zpty -w wing_zsh $'\x15'
done
zpty -w wing_zsh 'exit'
EOF
    raw_pos=$(HOME="$H" TERM=dumb timeout 60s zsh -f "$TMP/zsh-driver.zsh" \
        'wing ' 'wing w' 'wing push orders ' 'wing registry ' 'wing registry set pr' 'wing @local' \
        2>"$TMP/zsh-transcript") || {
        echo "--- zsh transcript:" >&2
        cat -v "$TMP/zsh-transcript" >&2
        fail "zsh: completion script did not load"
        raw_pos=""
    }
    out_pos=$(tr -d '\r' <<<"$raw_pos" | sed -n '/<</,/>>/p' | sed 's/.*<<//; s/>>.*//' | tr -d ' ' | grep -v '^$') || true
    expect zsh-position "$out_pos" get ls push read registry rm update write list set init prod @local-a
    expect_absent zsh-position "$out_pos" --registry --config --check --fit --json
    raw=$(HOME="$H" TERM=dumb timeout 60s zsh -f "$TMP/zsh-driver.zsh" \
        'wing --' 'wing push --' 'wing read --c' 2>"$TMP/zsh-transcript") || {
        echo "--- zsh transcript:" >&2
        cat -v "$TMP/zsh-transcript" >&2
        fail "zsh: option completion did not load"
        raw=""
    }
    out=$(tr -d '\r' <<<"$raw" | sed -n '/<</,/>>/p' | sed 's/.*<<//; s/>>.*//' | tr -d ' ' | grep -v '^$') || true
    expect zsh-options "$out" --check --compat --registry --version
else
    echo "SKIP zsh"
fi

if command -v fish >/dev/null; then
    H="$TMP/fish-home"
    HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c '
        mkdir -p ~/.config/fish/completions
        cp '"$ROOT"'/completions/wing.fish ~/.config/fish/completions/
    '
    out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c '
        complete -C "wing read --c"
        complete -C "wing push --compat "
        complete -C "wing registry set pr"
        complete -C "wing @local"
    ' | cut -f1)
    expect fish "$out" --check BACKWARD prod @local-a
    fish_root=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c 'complete -C "wing "' | cut -f1)
    fish_root_prefix=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c 'complete -C "wing w"' | cut -f1)
    fish_root_flags=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c 'complete -C "wing --"' | cut -f1)
    fish_push_arg=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c 'complete -C "wing push orders "' | cut -f1)
    fish_push_flags=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c 'complete -C "wing push --"' | cut -f1)
    fish_registry=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" fish -c 'complete -C "wing registry "' | cut -f1)
    expect fish-root "$fish_root" get ls push read registry rm update write
    expect_absent fish-root "$fish_root" --registry --config --help @local-a
    expect_exact fish-root-prefix "$fish_root_prefix" write
    expect fish-root-dash-options "$fish_root_flags" --registry --config --help --version
    expect_absent fish-positional "$fish_push_arg" --fit --check --registry
    expect fish-dash-options "$fish_push_flags" --check --compat --registry
    expect fish-registry-actions "$fish_registry" list set init
    expect_absent fish-registry-actions "$fish_registry" --registry --json
else
    echo "SKIP fish"
fi

exit "$status"
