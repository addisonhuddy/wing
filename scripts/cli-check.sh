#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=$(realpath "${1:-zig-out/bin/wing}")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$BIN" ] || { echo "run zig build first" >&2; exit 1; }
mkdir -p "$TMP/home" "$TMP/xdg" "$TMP/work"

run_case() {
    local name=$1 expected_status=$2 expected_out=$3 expected_err=$4
    shift 4
    local out="$TMP/$name.out" err="$TMP/$name.err" status
    set +e
    (cd "$TMP/work" && env -u WING_CONFIG -u WING_TARGET -u SCHEMA_REGISTRY_URL \
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
run_case missing-topic 1 empty "missing REF" get
run_case missing-name 1 empty "missing NAME" registry set
run_case update-bad-tag 1 empty "'main' is not a release tag (want e.g. v0.1.0)" update main
run_case update-extra 1 empty "unexpected argument 'v2'" update v1 v2
run_case read-stub 1 empty "not implemented yet" read
run_case write-stub 1 empty "not implemented yet" write
run_case push-stub 1 empty "not implemented yet" push
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
        file) expected="schema.registry.url from registry"; endpoint="http://127.0.0.1:2/subjects" ;;
        target) expected="schema.registry.url from registry"; endpoint="http://127.0.0.1:3/subjects" ;;
        env) expected="schema.registry.url from environment"; endpoint="http://127.0.0.1:4/subjects" ;;
        flag) expected="schema.registry.url from flag"; endpoint="http://127.0.0.1:5/subjects" ;;
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
run_case read-stub-json 1 empty '"kind":"error","command":"read"' --errors=json read

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
