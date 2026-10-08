#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

WING_TESTKIT=${WING_TESTKIT:-"$PWD/zig-out/bin/wing-testkit"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ORACLE=${JSONSCHEMA:-}
if [ -z "$ORACLE" ] && command -v npm >/dev/null 2>&1; then
    if npm install --prefix "$TMP/npm" --no-audit --no-fund @sourcemeta/jsonschema; then
        ORACLE="$TMP/npm/node_modules/.bin/jsonschema"
    fi
fi
if [ -z "$ORACLE" ] && command -v jsonschema >/dev/null 2>&1; then
    ORACLE=$(command -v jsonschema)
fi
if [ -z "$ORACLE" ] || [ ! -x "$ORACLE" ]; then
    echo "SKIP: Sourcemeta jsonschema CLI is unavailable (tried PATH and npm @sourcemeta/jsonschema)"
    exit 0
fi
[ -x "$WING_TESTKIT" ] || zig build testkit

cat >"$TMP/schema.json" <<'EOF'
{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}
EOF
printf '{}\n' >"$TMP/instance.json"
MODE=
if "$ORACLE" validate --resolve src/schema/meta "$TMP/schema.json" "$TMP/instance.json" >/dev/null 2>&1; then
    MODE=positional
elif "$ORACLE" validate --resolve src/schema/meta --schema "$TMP/schema.json" --instance "$TMP/instance.json" >/dev/null 2>&1; then
    MODE=flags
else
    echo "SKIP: Sourcemeta jsonschema CLI does not expose a recognized validate interface ($ORACLE)"
    "$ORACLE" --help >&2 || true
    exit 0
fi

oracle_valid() {
    if [ "$MODE" = positional ]; then
        "$ORACLE" validate --resolve src/schema/meta "$1" "$2" >/dev/null 2>&1
    else
        "$ORACLE" validate --resolve src/schema/meta --schema "$1" --instance "$2" >/dev/null 2>&1
    fi
}

instances=(
    '{}'
    'true'
    'null'
    '"text"'
    '[]'
    '{"type":1}'
    '{"type":"object","required":["id"]}'
)
compared=0
mismatches=0
for schema in src/schema/meta/*.json; do
    for instance in "${instances[@]}"; do
        printf '%s\n' "$instance" >"$TMP/instance.json"
        set +e
        "$WING_TESTKIT" validate "$schema" <"$TMP/instance.json" >/dev/null 2>&1
        wing_status=$?
        oracle_valid "$schema" "$TMP/instance.json"
        oracle_status=$?
        set -e
        wing_valid=0
        oracle_is_valid=0
        [ "$wing_status" -eq 0 ] && wing_valid=1
        [ "$oracle_status" -eq 0 ] && oracle_is_valid=1
        compared=$((compared + 1))
        if [ "$wing_valid" -ne "$oracle_is_valid" ]; then
            mismatches=$((mismatches + 1))
            printf 'DIFF %s instance=%s wing=%s sourcemeta=%s\n' \
                "$schema" "$instance" "$wing_valid" "$oracle_is_valid"
        fi
    done
done
echo "differential: $((compared - mismatches))/$compared agree; $mismatches mismatches"
[ "$mismatches" -eq 0 ]
