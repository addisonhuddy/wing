#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=$(realpath "${1:-zig-out/bin/wing}")
TMP=$(mktemp -d)
trap 'if [ -n "${TIMEOUT_SERVER_PID:-}" ]; then kill "$TIMEOUT_SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

[ -x "$BIN" ] || { echo "run zig build first" >&2; exit 1; }
mkdir -p "$TMP/home" "$TMP/xdg" "$TMP/work"

run_case() {
    local name=$1 expected_status=$2 expected_out=$3 expected_err=$4
    shift 4
    local out="$TMP/$name.out" err="$TMP/$name.err" status
    set +e
    (cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
        -u SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO -u SCHEMA_REGISTRY_BEARER_AUTH_TOKEN \
        HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" "$@" </dev/null >"$out" 2>"$err")
    status=$?
    set -e
    if [ "$status" -ne "$expected_status" ]; then
        echo "FAIL $name: exit $status (want $expected_status)"
        cat "$err"
        return 1
    fi
    if [ "$expected_out" = nonempty ] && [ ! -s "$out" ]; then
        echo "FAIL $name: stdout is empty"
        return 1
    elif [ "$expected_out" = empty ] && [ -s "$out" ]; then
        echo "FAIL $name: stdout is not empty"
        return 1
    fi
    if [ "$expected_err" = empty ] && [ -s "$err" ]; then
        echo "FAIL $name: stderr is not empty"
        cat "$err"
        return 1
    elif [ "$expected_err" != empty ] && ! grep -Fq "$expected_err" "$err"; then
        echo "FAIL $name: stderr lacks '$expected_err'"
        cat "$err"
        return 1
    fi
    echo "PASS $name"
}

run_read_input_case() {
    local name=$1 expected_status=$2 expected_out=$3 expected_err=$4 input=$5
    shift 5
    local workdir="$TMP/work"
    if [ "${1:-}" = --workdir ]; then
        workdir=$2
        shift 2
    fi
    local out="$TMP/$name.out" err="$TMP/$name.err" status
    set +e
    printf '%s\n' "$input" | (cd "$workdir" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
        -u SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO -u SCHEMA_REGISTRY_BEARER_AUTH_TOKEN \
        HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" "$@" >"$out" 2>"$err")
    status=$?
    set -e
    if [ "$status" -ne "$expected_status" ]; then
        echo "FAIL $name: exit $status (want $expected_status)"
        cat "$err"
        return 1
    fi
    if [ "$expected_out" = nonempty ] && [ ! -s "$out" ]; then
        echo "FAIL $name: stdout is empty"
        return 1
    elif [ "$expected_out" = empty ] && [ -s "$out" ]; then
        echo "FAIL $name: stdout is not empty"
        return 1
    elif [ "$expected_out" = identical ] && ! printf '%s\n' "$input" | cmp -s - "$out"; then
        echo "FAIL $name: stdout differs from input"
        cat "$out"
        return 1
    fi
    if [ "$expected_err" = empty ] && [ -s "$err" ]; then
        echo "FAIL $name: stderr is not empty"
        cat "$err"
        return 1
    elif [ "$expected_err" != empty ] && ! grep -Fq "$expected_err" "$err"; then
        echo "FAIL $name: stderr lacks '$expected_err'"
        cat "$err"
        return 1
    fi
    echo "PASS $name"
}

run_case root-help 0 nonempty empty --help
run_case root-short-help 0 nonempty empty -h
cmp -s "$TMP/root-help.out" "$TMP/root-short-help.out"
for command in read write ls get push rm registry update; do
    run_case "$command-help" 0 nonempty empty "$command" --help
    run_case "$command-short-help" 0 nonempty empty "$command" -h
    cmp -s "$TMP/$command-help.out" "$TMP/$command-short-help.out"
done
for page in "$TMP"/*-help.out; do
    awk 'length($0) > 80 { bad=1 } END { exit bad }' "$page" || {
        echo "FAIL help line exceeds 80 columns: $page"
        exit 1
    }
done

run_case no-args 1 empty "wing: missing command"
run_case no-args-help 1 empty "Try 'wing --help'"
run_case unknown-command 1 empty "unknown command 'lis'; did you mean 'ls'?" lis
run_case unknown-option 1 empty "unknown option '--jsn' (did you mean '--json'?)" ls --jsn
run_case unknown-option-write 1 empty "unknown option '--fitt' (did you mean '--fit'?)" write --fitt
run_case unknown-option-get 1 empty "unknown option '--metaa' (did you mean '--meta'?)" get --metaa
run_case unknown-option-push 1 empty "unknown option '--chek' (did you mean '--check'?)" push --chek
run_case unknown-option-registry 1 empty "unknown option '--jsn' (did you mean '--json'?)" registry --jsn
run_case legacy-ref 1 empty "'orders@3': use 'orders:3' to pin a version ('@NAME' selects a registry)" get orders@3
run_case legacy-ref-json 1 empty "'orders@3': use 'orders:3' to pin a version ('@NAME' selects a registry)" get --errors=json orders@3
run_case invalid-version 1 empty "version must be 'latest' or a positive integer" get orders:abc
run_case rm-latest-version 1 empty "version must be 'latest' or a positive integer" rm orders:latest -y
run_case legacy-ref-write 1 empty "'orders@3': use 'orders:3' to pin a version ('@NAME' selects a registry)" write orders@3
run_case invalid-version-write 1 empty "version must be 'latest' or a positive integer" write orders:abc
run_case missing-topic 1 empty "missing REF" get
run_case push-no-topic 1 empty "wing: push needs a TOPIC (use 'wing push --check' to lint offline)" push
run_case push-empty 1 empty "wing push: no schema on stdin" push --check
run_case missing-name 1 empty "missing NAME" registry set
run_case update-bad-tag 1 empty "'main' is not a release tag (want e.g. v0.1.0)" update main
run_case update-extra 1 empty "unexpected argument 'v2'" update v1 v2
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$WING_UPDATE_CAPTURE"\n' >"$TMP/fake-install.sh"
chmod +x "$TMP/fake-install.sh"
WING_INSTALLER_URL="file://$TMP/fake-install.sh" WING_UPDATE_CAPTURE="$TMP/update-args" \
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" update v9.9.9
grep -Fxq -- '--bin-dir' "$TMP/update-args" &&
    grep -Fxq -- "$(dirname "$BIN")" "$TMP/update-args" &&
    grep -Fxq -- '--version' "$TMP/update-args" &&
    grep -Fxq -- 'v9.9.9' "$TMP/update-args" || {
    echo "FAIL update: installer was not rerun for the running binary's directory"
    cat "$TMP/update-args"
    exit 1
}
echo "PASS update-installer-target"
run_case read-empty-input 0 empty "wing read: 0 read, 0 passed, 0 failed" read
run_read_input_case read-missing-id 2 nonempty "no __value_schema_id header or schema-id prefix" \
    '{"topic":"orders","value":"{}","headers":[]}' read
run_read_input_case read-check-unchanged 2 identical "no __value_schema_id header or schema-id prefix" \
    '{"topic":"orders","value":"{}","headers":[]}' read --check
run_read_input_case read-malformed-record 1 empty "expected a JSON record" '{"value":' read
run_read_input_case read-empty-value 0 nonempty "1 empty" \
    '{"topic":"orders","value":"","headers":[]}' read
run_read_input_case push-offline-check 0 empty empty '{"type":"object"}' push --check
run_read_input_case push-typo-keyword 2 empty "wing push: unknown keyword 'typ' at the root (did you mean 'type'?)" \
    '{"typ":"object"}' push --check
run_read_input_case push-compat-check-rejected 1 empty "wing push: --compat cannot be combined with --check" \
    '{"type":"object"}' push --check --compat BACKWARD
run_read_input_case write-empty-value 0 nonempty "1 written" \
    '{"value":"","headers":[{"key":"__value_schema_id","value":"stale"}]}' write
run_read_input_case write-empty-value-byte-preserved 0 identical "1 written" \
    '{"value":"","headers":[{"key":"x-trace","value":"stable"}]}' write
run_case missing-registry-json 1 empty '"kind":"error","command":"ls"' --errors=json ls
run_case command-error-json 1 empty '"kind":"error","command":"ls"' --errors=json ls --bogus

set +e
(cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" --help > /dev/full 2>"$TMP/full.err")
status=$?
set -e
[ "$status" -eq 1 ] && grep -Fq "failed writing stdout" "$TMP/full.err" || {
    echo "FAIL /dev/full write error"
    cat "$TMP/full.err"
    exit 1
}
echo "PASS /dev/full write error"

cat >"$TMP/work/wing.yaml" <<'EOF'
default: local
defaults:
  schema.registry.url: http://127.0.0.1:1
registries:
  local:
    schema.registry.url: http://127.0.0.1:2
  dev:
    schema.registry.url: http://127.0.0.1:3
EOF
cat >"$TMP/work/wing-defaults.yaml" <<'EOF'
defaults:
  schema.registry.url: http://127.0.0.1:1
EOF
for mode in file target env flag; do
    set +e
    case "$mode" in
        file) (cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL NO_PROXY='*' WING_DEBUG=1 HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" -v ls >"$TMP/$mode.out" 2>"$TMP/$mode.err") ;;
        target) (cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL NO_PROXY='*' WING_DEBUG=1 HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" -v @dev ls >"$TMP/$mode.out" 2>"$TMP/$mode.err") ;;
        env) (cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET NO_PROXY='*' WING_DEBUG=1 HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" SCHEMA_REGISTRY_URL=http://127.0.0.1:4 "$BIN" --config "$TMP/work/wing-defaults.yaml" -v ls >"$TMP/$mode.out" 2>"$TMP/$mode.err") ;;
        flag) (cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL NO_PROXY='*' WING_DEBUG=1 HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" --registry http://127.0.0.1:5 -v ls >"$TMP/$mode.out" 2>"$TMP/$mode.err") ;;
    esac
    status=$?
    set -e
    [ "$status" -eq 1 ] || { echo "FAIL config-$mode: exit $status"; exit 1; }
    case "$mode" in
        file) expected="config from ./wing.yaml"; endpoint="http://127.0.0.1:2/subjects" ;;
        target) expected="registry 'dev' (from @dev)"; endpoint="http://127.0.0.1:3/subjects" ;;
        env) expected="registry URL http://127.0.0.1:4 (from SCHEMA_REGISTRY_URL)"; endpoint="http://127.0.0.1:4/subjects" ;;
        flag) expected="registry URL http://127.0.0.1:5 (from --registry)"; endpoint="http://127.0.0.1:5/subjects" ;;
    esac
    grep -Fq "$expected" "$TMP/$mode.err" || {
        echo "FAIL config-$mode: missing '$expected'"
        cat "$TMP/$mode.err"
        exit 1
    }
    grep -Fq "WING_DEBUG request GET $endpoint" "$TMP/$mode.err" || {
        echo "FAIL config-$mode: wrong selected URL (expected $endpoint)"
        cat "$TMP/$mode.err"
        exit 1
    }
    echo "PASS config-$mode"
done

run_case bare-target 1 empty "bare '@' is not a registry name" @ ls
run_case two-targets 1 empty "@local cannot be combined with @prod" @local @prod ls
run_case read-empty-input-json 0 empty '"kind":"summary","read":0' --errors=json read

mkdir -m 700 -p "$TMP/schema-cache"
cat >"$TMP/schema-cache/11111111-1111-1111-1111-111111111111.json" <<'EOF'
{"topic":"offline","version":1,"id":7,"guid":"11111111-1111-1111-1111-111111111111","compat":"BACKWARD","schema":"{\"type\":\"object\"}","references":null,"metadata":null,"ruleSet":null,"subject":"offline-value"}
EOF
chmod 600 "$TMP/schema-cache/11111111-1111-1111-1111-111111111111.json"
cat >"$TMP/schema-cache/22222222-2222-2222-2222-222222222222.json" <<'EOF'
{"topic":"offline","version":2,"id":8,"guid":"22222222-2222-2222-2222-222222222222","compat":"BACKWARD","schema":"{\"type\":\"object\",\"required\":[\"x\"]}","references":null,"metadata":null,"ruleSet":null,"subject":"offline-value"}
EOF
cat >"$TMP/schema-cache/33333333-3333-3333-3333-333333333333.json" <<'EOF'
{"topic":"offline","version":3,"id":9,"guid":"33333333-3333-3333-3333-333333333333","compat":"BACKWARD","schema":"{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\",\"default\":7}},\"additionalProperties\":false}","references":null,"metadata":null,"ruleSet":null,"subject":"offline-value"}
EOF
cat >"$TMP/schema-cache/44444444-4444-4444-4444-444444444444.json" <<'EOF'
{"topic":"offline","version":1,"id":10,"guid":"44444444-4444-4444-4444-444444444444","compat":"BACKWARD","schema":"{\"type\":\"integer\"}","references":null,"metadata":null,"ruleSet":null,"subject":"offline-key"}
EOF
cat >"$TMP/schema-cache/55555555-5555-5555-5555-555555555555.json" <<'EOF'
{"topic":"currency","version":1,"id":11,"guid":"55555555-5555-5555-5555-555555555555","compat":"BACKWARD","schema":"{\"type\":\"object\",\"properties\":{\"currency\":{\"type\":\"string\",\"default\":\"USD\"}},\"additionalProperties\":false}","references":null,"metadata":null,"ruleSet":null,"subject":"currency-value"}
EOF
cat >"$TMP/schema-cache/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee.json" <<'EOF'
{"topic":"offline","version":4,"id":12,"guid":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","compat":"BACKWARD","schema":"{\"type\":\"object\"}","references":null,"metadata":null,"ruleSet":null,"subject":"offline-value"}
EOF
chmod 600 "$TMP/schema-cache/"*.json
mkdir -p "$TMP/cache-work"
run_read_input_case read-offline-cache-guid 0 nonempty "1 read, 1 passed, 0 failed" \
    '{"topic":"offline","value":"{}","headers":[{"key":"__value_schema_id","value":"\u0001\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011"}]}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" read
grep -Fq '"topic":"offline"' "$TMP/read-offline-cache-guid.out" || {
    echo "FAIL read-offline-cache-guid: schema metadata missing"
    cat "$TMP/read-offline-cache-guid.out"
    exit 1
}
set +e
printf '%s\n' '{"topic":"offline","value":"{}","headers":[{"key":"__value_schema_id","value":"\u0001\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011\u0011"}]}' |
    (cd "$TMP/cache-work" && env -u WING_CONFIG -u WING_TARGET \
        -u SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO -u SCHEMA_REGISTRY_BEARER_AUTH_TOKEN \
        HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
        SCHEMA_REGISTRY_URL=http://127.0.0.1:9 WING_DEBUG=1 \
        "$BIN" --schema-dir "$TMP/schema-cache" read \
        >"$TMP/read-cached-no-request.out" 2>"$TMP/read-cached-no-request.err")
status=$?
set -e
[ "$status" -eq 0 ] && ! grep -Fq "WING_DEBUG request " "$TMP/read-cached-no-request.err" || {
    echo "FAIL read-cached-no-request: cached read contacted Schema Registry"
    cat "$TMP/read-cached-no-request.err"
    exit 1
}
echo "PASS read-cached-no-request"

run_read_input_case write-offline-cache-guid 0 nonempty "1 written" \
    '{"value":"{}","headers":[{"key":"custom","value":"one"},{"key":"__value_schema_id","value":"stale"}],"schema":{"value":{"guid":"11111111-1111-1111-1111-111111111111"}}}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write
grep -Fq '"key":"__value_schema_id"' "$TMP/write-offline-cache-guid.out" &&
    grep -Fq '"key":"custom","value":"one"' "$TMP/write-offline-cache-guid.out" &&
    ! grep -Fq '"schema":' "$TMP/write-offline-cache-guid.out" || {
    echo "FAIL write-offline-cache-guid: schema header or envelope transformation is wrong"
    cat "$TMP/write-offline-cache-guid.out"
    exit 1
}
run_read_input_case get-offline-cache-guid 0 nonempty empty '{}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" get 11111111-1111-1111-1111-111111111111
grep -Fq '"type":"object"' "$TMP/get-offline-cache-guid.out" || {
    echo "FAIL get-offline-cache-guid: cached schema was not returned"
    cat "$TMP/get-offline-cache-guid.out"
    exit 1
}
run_read_input_case write-invalid 2 empty "missing required property 'x'" \
    '{"value":"{}","schema":{"value":{"guid":"22222222-2222-2222-2222-222222222222"}}}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write
run_read_input_case write-invalid-json 2 empty '"kind":"invalid"' \
    '{"topic":"offline","partition":0,"offset":17,"value":"{}","schema":{"value":{"guid":"22222222-2222-2222-2222-222222222222"}}}' \
    --workdir "$TMP/cache-work" --errors=json --schema-dir "$TMP/schema-cache" write
grep -Fq '"partition":0,"offset":17' "$TMP/write-invalid-json.err" || {
    echo "FAIL write-invalid-json: record position is missing"
    cat "$TMP/write-invalid-json.err"
    exit 1
}
grep -Fq '"instanceLocation":""' "$TMP/write-invalid-json.err" &&
    grep -Fq '"keywordLocation":"/required"' "$TMP/write-invalid-json.err" || {
    echo "FAIL write-invalid-json: locations are not plain JSON Pointers"
    cat "$TMP/write-invalid-json.err"
    exit 1
}
run_read_input_case write-summary-json 0 nonempty '"kind":"summary","read":1,"passed":1,"failed":0,"empty":0,"fit":{"coerce":0,"defaults":0,"drop-extra":0,"wrap":0},"written":1,"fitted":0' \
    '{"value":"{\"x\":1}","schema":{"value":{"guid":"22222222-2222-2222-2222-222222222222"}}}' \
    --workdir "$TMP/cache-work" --errors=json --schema-dir "$TMP/schema-cache" write
valid_write_record='{"value":"{\"x\":1}","schema":{"value":{"guid":"22222222-2222-2222-2222-222222222222"}}}'
invalid_write_record='{"value":"{}","schema":{"value":{"guid":"22222222-2222-2222-2222-222222222222"}}}'
set +e
printf '%s\n%s\n%s\n' "$valid_write_record" "$invalid_write_record" "$valid_write_record" |
    (cd "$TMP/cache-work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
        HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" --schema-dir "$TMP/schema-cache" write \
        >"$TMP/write-stop.out" 2>"$TMP/write-stop.err")
status=$?
set -e
[ "$status" -eq 2 ] && [ "$(wc -l <"$TMP/write-stop.out")" -eq 1 ] &&
    grep -Fq "1 written" "$TMP/write-stop.err" || {
    echo "FAIL write-stop-on-invalid: expected one flushed output record and exit 2"
    cat "$TMP/write-stop.out" "$TMP/write-stop.err"
    exit 1
}
echo "PASS write-stop-on-invalid"
run_read_input_case write-check-unchanged 2 identical "missing required property 'x'" \
    "$invalid_write_record" --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write --check
run_read_input_case write-check-passes 0 empty "0 fitted" \
    "$valid_write_record" --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write --check
run_read_input_case write-fit 0 nonempty "1 fitted" \
    '{"value":"{\"extra\":1}","schema":{"value":{"guid":"33333333-3333-3333-3333-333333333333"}}}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write --fit
grep -Fq '"value":{"x":7}' "$TMP/write-fit.out" || {
    echo "FAIL write-fit: fitted value is missing"
    cat "$TMP/write-fit.out"
    exit 1
}
run_read_input_case write-fit-verbose 0 nonempty "1 fitted" \
    '{"value":"{\"extra\":1}","schema":{"value":{"guid":"55555555-5555-5555-5555-555555555555"}}}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" -v write --fit
grep -Fq 'wing write: line 1: /extra removed (drop-extra)' "$TMP/write-fit-verbose.err" &&
    grep -Fq 'wing write: line 1: /currency set to "USD" (default)' "$TMP/write-fit-verbose.err" || {
    echo "FAIL write-fit-verbose: fit operations were not described correctly"
    cat "$TMP/write-fit-verbose.err"
    exit 1
}
run_read_input_case write-fit-check-unchanged 2 identical "1 fitted" \
    '{"value":"{\"extra\":1}","schema":{"value":{"guid":"33333333-3333-3333-3333-333333333333"}}}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write --fit --check
run_read_input_case write-fit-json-patch 2 identical '"kind":"fit"' \
    '{"value":"{\"extra\":1}","schema":{"value":{"guid":"33333333-3333-3333-3333-333333333333"}}}' \
    --workdir "$TMP/cache-work" --errors=json --schema-dir "$TMP/schema-cache" write --fit --check
run_read_input_case write-fit-drop-quiet 2 identical "drop-extra removed /extra from 1 records" \
    '{"value":"{\"extra\":1}","schema":{"value":{"guid":"33333333-3333-3333-3333-333333333333"}}}' \
    --workdir "$TMP/cache-work" -q --schema-dir "$TMP/schema-cache" write --fit --check
run_read_input_case write-key-offline-cache 2 identical "keys are validated because offline-key exists" \
    '{"key":"\"bad\"","value":"{}","schema":{"value":{"guid":"11111111-1111-1111-1111-111111111111"},"key":{"guid":"44444444-4444-4444-4444-444444444444"}}}' \
    --workdir "$TMP/cache-work" --schema-dir "$TMP/schema-cache" write --check
run_read_input_case write-missing-schema 1 empty \
    "wing write: line 1: no schema for this record; pass a topic (wing write TOPIC) or keep the schema field from wing read" \
    '{"value":"{}"}' write

printf '%s\n' '{"value":"{\"x\":1}","schema":{"value":{"guid":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}}}' >"$TMP/tty.input"
(
    cd "$TMP/cache-work"
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
        "$BIN" --quiet --schema-dir "$TMP/schema-cache" write <"$TMP/tty.input" \
        >"$TMP/tty-write.pipe" 2>"$TMP/tty-write.pipe.err"
)
tty_command="stty -echo; WING_COLOR=always '$BIN' --quiet --schema-dir '$TMP/schema-cache' write < '$TMP/tty.input' 2>/dev/null"
script -qc "$tty_command" /dev/null >"$TMP/tty-write.raw"
tty_command="stty -echo; WING_COLOR=always '$BIN' --quiet --schema-dir '$TMP/schema-cache' read < '$TMP/tty-write.pipe' 2>/dev/null"
script -qc "$tty_command" /dev/null >"$TMP/tty-read.raw"
(
    cd "$TMP/cache-work"
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
        "$BIN" --quiet --schema-dir "$TMP/schema-cache" read <"$TMP/tty-write.pipe" \
        >"$TMP/tty-read.pipe" 2>"$TMP/tty-read.pipe.err"
)
python3 - "$TMP/tty-write.raw" "$TMP/tty-write.stripped" "$TMP/tty-read.raw" "$TMP/tty-read.stripped" <<'PY'
import re
import sys

for source, destination in zip(sys.argv[1::2], sys.argv[2::2]):
    data = open(source, "rb").read()
    data = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data).replace(b"\r", b"")
    open(destination, "wb").write(data)
PY
cmp -s "$TMP/tty-write.stripped" "$TMP/tty-write.pipe" &&
    cmp -s "$TMP/tty-read.stripped" "$TMP/tty-read.pipe" || {
    echo "FAIL tty JSON coloring differs from piped records"
    exit 1
}
python3 - "$TMP/tty-write.pipe" <<'PY'
import sys
assert any(byte >= 0x80 for byte in open(sys.argv[1], "rb").read())
PY
echo "PASS tty JSON coloring preserves pipe bytes"

mkdir -p "$TMP/timeout-config"
python3 - "$TMP/timeout-port" >"$TMP/timeout-server.log" 2>&1 <<'PY' &
import socket
import sys
import time

server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(sys.argv[1], "w") as port_file:
    port_file.write(str(server.getsockname()[1]))
connection, _ = server.accept()
time.sleep(3)
connection.close()
server.close()
PY
TIMEOUT_SERVER_PID=$!
for _ in $(seq 1 100); do
    [ -s "$TMP/timeout-port" ] && break
    sleep 0.02
done
[ -s "$TMP/timeout-port" ] || {
    echo "FAIL registry-request-timeout: test server did not start"
    cat "$TMP/timeout-server.log"
    exit 1
}
cat >"$TMP/timeout-config/wing.properties" <<EOF
schema.registry.url=http://127.0.0.1:$(cat "$TMP/timeout-port")
schema.registry.request.timeout.ms=250
EOF
set +e
(cd "$TMP/work" && env -u WING_TARGET -u SCHEMA_REGISTRY_URL \
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
    "$BIN" --config "$TMP/timeout-config/wing.properties" ls \
    >"$TMP/registry-timeout.out" 2>"$TMP/registry-timeout.err")
status=$?
set -e
[ "$status" -eq 1 ] && grep -Fq "did not respond within 250ms" "$TMP/registry-timeout.err" || {
    echo "FAIL registry-request-timeout: exit $status or timeout diagnostic was wrong"
    cat "$TMP/registry-timeout.err"
    exit 1
}
echo "PASS registry-request-timeout"

mkdir -p "$TMP/props"
cat >"$TMP/props/wing.properties" <<'EOF'
schema.registry.url=http://127.0.0.1:7
bootstrap.servers=ignored
sasl.mechanism=ignored
unknown.registry.option=warn
EOF
set +e
(cd "$TMP/props" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
    NO_PROXY='*' WING_DEBUG=1 HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
    SCHEMA_REGISTRY_URL=http://127.0.0.1:8 "$BIN" -v ls >"$TMP/properties.out" 2>"$TMP/properties.err")
status=$?
set -e
[ "$status" -eq 1 ] || { echo "FAIL properties config: exit $status"; exit 1; }
grep -Fq "WING_DEBUG request GET http://127.0.0.1:7/subjects" "$TMP/properties.err" || {
    echo "FAIL properties config: file URL did not win over environment"
    cat "$TMP/properties.err"
    exit 1
}
grep -Fq "unknown config key 'unknown.registry.option' ignored" "$TMP/properties.err" || {
    echo "FAIL properties config: unknown key warning missing"
    cat "$TMP/properties.err"
    exit 1
}
if grep -Fq "unknown config key 'bootstrap.servers'" "$TMP/properties.err" ||
    grep -Fq "unknown config key 'sasl.mechanism'" "$TMP/properties.err"; then
    echo "FAIL properties config: Kafka keys should be ignored silently"
    cat "$TMP/properties.err"
    exit 1
fi
echo "PASS properties config precedence and Kafka keys"

mkdir -p "$TMP/debug" "$TMP/tls" "$TMP/credentials"
cat >"$TMP/debug/wing.yaml" <<'EOF'
defaults:
  schema.registry.url: http://127.0.0.1:9
  basic.auth.user.info: user:do-not-log
  http.header.X-Test: header-value
EOF
set +e
(cd "$TMP/debug" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
    NO_PROXY='*' WING_DEBUG=1 HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
    "$BIN" ls >"$TMP/debug.out" 2>"$TMP/debug.err")
status=$?
set -e
[ "$status" -eq 1 ] &&
    grep -Fq "WING_DEBUG > Authorization: [redacted]" "$TMP/debug.err" &&
    grep -Fq "WING_DEBUG > X-Test: header-value" "$TMP/debug.err" &&
    ! grep -Fq "do-not-log" "$TMP/debug.err" || {
    echo "FAIL debug header logging or Authorization redaction"
    cat "$TMP/debug.err"
    exit 1
}
echo "PASS debug header logging and Authorization redaction"

cat >"$TMP/tls/wing.yaml" <<'EOF'
defaults:
  schema.registry.url: https://registry.example.test
  schema.registry.ssl.truststore.location: trust.JKS
EOF
set +e
(cd "$TMP/tls" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" ls >"$TMP/truststore.out" 2>"$TMP/truststore.err")
status=$?
set -e
[ "$status" -eq 1 ] && grep -Fq "Java truststores (.jks/.p12) are not supported" "$TMP/truststore.err" || {
    echo "FAIL Java truststore rejection"
    cat "$TMP/truststore.err"
    exit 1
}
echo "PASS Java truststore rejection"

cat >"$TMP/credentials/wing.yaml" <<'EOF'
default: local
registries:
  local:
    schema.registry.url: https://registry.example.test
    schema.registry.ssl.insecure: true
    basic.auth.user.info: user:secret
EOF
chmod 644 "$TMP/credentials/wing.yaml"
set +e
(cd "$TMP/credentials" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
    NO_PROXY='*' HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" "$BIN" ls >"$TMP/insecure.out" 2>"$TMP/insecure.err")
status=$?
set -e
[ "$status" -eq 1 ] &&
    grep -Fq "TLS certificate verification is disabled" "$TMP/insecure.err" &&
    grep -Fq "readable by other users" "$TMP/insecure.err" || {
    echo "FAIL insecure TLS or loose-permission warning"
    cat "$TMP/insecure.err"
    exit 1
}
echo "PASS insecure TLS and loose-permission warnings"

echo "All CLI checks passed."
