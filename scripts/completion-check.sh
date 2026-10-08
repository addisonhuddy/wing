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
        complete_at wing ""
        complete_at wing w
        complete_at wing r
        complete_at wing read --c
        complete_at wing write --f
        complete_at wing ls --k
        complete_at wing get --m
        complete_at wing push --c
        complete_at wing rm --p
        complete_at wing registry s
        complete_at wing registry set pr
        complete_at wing @local
    ') || fail "bash: completion script did not load"
    expect bash "$out" read write ls get push rm registry update --check --fit --key --meta --compat --permanent set @local-a
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
    raw=$(HOME="$H" TERM=dumb timeout 60s zsh -f "$TMP/zsh-driver.zsh" \
        'wing read --c' 'wing registry set pr' 'wing @local' 2>"$TMP/zsh-transcript") || {
        echo "--- zsh transcript:" >&2
        cat -v "$TMP/zsh-transcript" >&2
        fail "zsh: completion script did not load"
        raw=""
    }
    out=$(tr -d '\r' <<<"$raw" | sed -n '/<</,/>>/p' | sed 's/.*<<//; s/>>.*//' | tr -d ' ' | grep -v '^$') || true
    expect zsh "$out" --check prod @local-a
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
else
    echo "SKIP fish"
fi

exit "$status"
