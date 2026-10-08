#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WING=${WING:-"$ROOT/zig-out/bin/wing"}
KITE=${KITE:-"$HOME/repos/kite/zig-out/bin/kite"}
SR=${SCHEMA_REGISTRY_URL:-http://localhost:8081}
BROKERS=${BOOTSTRAP_SERVERS:-localhost:9092}
SR_CONTAINER=${SMOKE_SR_CONTAINER:-sr}
JAVA_BOOTSTRAP_SERVERS=${JAVA_BOOTSTRAP_SERVERS:-kafka:29092}
TRANSCRIPTS=${TRANSCRIPT_DIR:-"$HOME/wing-work/transcripts"}
mkdir -p "$TRANSCRIPTS"
TRANSCRIPT="$TRANSCRIPTS/phase3-live-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$TRANSCRIPT") 2>&1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SCHEMA_REGISTRY_URL=$SR BOOTSTRAP_SERVERS=$BROKERS
command -v jq >/dev/null
command -v docker >/dev/null
[ -x "$WING" ] || { echo "missing wing binary: $WING"; exit 1; }
[ -x "$KITE" ] || { echo "missing kite binary: $KITE"; exit 1; }
curl -fsS "$SR/subjects" >/dev/null

PREFIX="wing-live-$(date +%s)"
ORDERS="$PREFIX-orders"
LEGACY="$PREFIX-legacy"
FIT="$PREFIX-fit"
JAVA_HEADER="$PREFIX-java-header"
JAVA_PREFIX="$PREFIX-java-prefix"
MIXED="$PREFIX-mixed"
COPY="$PREFIX-copy"
DLQ="$PREFIX-dlq"
REF_BASE="$PREFIX-ref-base"
REF_ROOT="$PREFIX-ref-root"
REF_COPY="$PREFIX-ref-copy"
REF_MONEY="$PREFIX-ref-money"
REF_INVOICE="$PREFIX-ref-invoices"
SCHEMA='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string"}},"required":["id"],"additionalProperties":false}'
KEY_SCHEMA='{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],"additionalProperties":false}'
printf '%s\n' "$SCHEMA" >"$TMP/orders.schema.json"
printf '%s\n' "$KEY_SCHEMA" >"$TMP/key.schema.json"

echo "push and kite produce/read round-trip"
GUID=$(printf '%s\n' "$SCHEMA" | "$WING" push "$ORDERS")
printf '%s\n' "$SCHEMA" | "$WING" push "$LEGACY" >/dev/null
printf '%s\n' '{"topic":"'"$ORDERS"'","value":"{\"id\":1,\"name\":\"one\"}","headers":[]}' |
    "$WING" write "$ORDERS:1" | "$KITE" produce --json "$ORDERS"
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$ORDERS" |
    "$WING" read | jq -e --arg topic "$ORDERS" '.value.id == 1 and .schema.value.topic == $topic and .schema.value.version == 1' >/dev/null
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$ORDERS" |
    "$WING" read | "$WING" write 2>"$TMP/write-selection.log" | "$KITE" produce --json "$ORDERS"
grep -Fq "wing write: using ${ORDERS}-value version 1" "$TMP/write-selection.log"

echo "key schema selection and keyed round-trip"
printf '%s\n' "$KEY_SCHEMA" | "$WING" push "$ORDERS" --key
printf '%s\n' '{"topic":"'"$ORDERS"'","key":"{\"id\":1}","value":"{\"id\":2}","headers":[]}' |
    "$WING" write "$ORDERS" | "$KITE" produce --json "$ORDERS"

echo "fit from CSV-produced records"
printf '%s\n' "$SCHEMA" | "$WING" push "$FIT"
printf 'id,name\n3,three\n' >"$TMP/fit.csv"
"$KITE" produce --csv "$FIT" <"$TMP/fit.csv"
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$FIT" |
    "$WING" write --fit "$FIT" | "$KITE" produce --json "$FIT"

echo "Java serializer header and prefix formats"
for topic in "$JAVA_HEADER" "$JAVA_PREFIX"; do
    printf '%s\n' "$SCHEMA" | "$WING" push "$topic" >/dev/null
    if [ "$topic" = "$JAVA_HEADER" ]; then
        printf '%s\n' '{"id":4,"name":"java"}' | docker exec -i "$SR_CONTAINER" kafka-json-schema-console-producer \
            --bootstrap-server "$JAVA_BOOTSTRAP_SERVERS" --topic "$topic" \
            --property "schema.registry.url=http://localhost:8081" \
            --property "value.schema=$SCHEMA" \
            --property value.schema.id.serializer=io.confluent.kafka.serializers.schema.id.HeaderSchemaIdSerializer >/dev/null
    else
        printf '%s\n' '{"id":4,"name":"java"}' | docker exec -i "$SR_CONTAINER" kafka-json-schema-console-producer \
            --bootstrap-server "$JAVA_BOOTSTRAP_SERVERS" --topic "$topic" \
            --property "schema.registry.url=http://localhost:8081" \
            --property "value.schema=$SCHEMA" >/dev/null
    fi
done
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$JAVA_HEADER" | "$WING" read >/dev/null
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$JAVA_PREFIX" | "$WING" read >/dev/null
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$JAVA_PREFIX" |
    "$WING" read | "$WING" write "$ORDERS" | "$KITE" produce --json "$ORDERS"

echo "mixed topic, prefix-to-header migration, and Java consumer"
printf '%s\n' "$SCHEMA" | "$WING" push "$MIXED" >/dev/null
printf '%s\n' '{"topic":"'"$MIXED"'","value":"{\"id\":5}","headers":[]}' |
    "$WING" write "$MIXED" | "$KITE" produce --json "$MIXED"
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$JAVA_PREFIX" |
    "$KITE" produce --json "$MIXED"
"$KITE" consume --from-beginning --max 2 --idle 2s --json "$MIXED" |
    "$WING" read | "$WING" write "$ORDERS" | "$KITE" produce --json "$ORDERS"
docker exec "$SR_CONTAINER" kafka-json-schema-console-consumer --bootstrap-server "$JAVA_BOOTSTRAP_SERVERS" \
    --topic "$ORDERS" --from-beginning --max-messages 1 \
    --property schema.registry.url=http://localhost:8081 >/dev/null

echo "reference-aware --meta push, bundled get, and schema equivalence"
BASE_SCHEMA='{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://example.test/common.json","type":"object","properties":{"code":{"type":"string"}},"required":["code"]}'
ROOT_SCHEMA='{"$schema":"https://json-schema.org/draft/2020-12/schema","$ref":"https://example.test/common.json"}'
printf '%s\n' "$BASE_SCHEMA" | "$WING" push "$REF_BASE" >/dev/null
ENVELOPE=$(jq -cn --arg topic "$REF_ROOT" --arg schema "$ROOT_SCHEMA" --arg subject "${REF_BASE}-value" \
    '{topic:$topic,version:1,id:1,guid:"00000000-0000-0000-0000-000000000000",compat:"BACKWARD",schema:$schema,references:[{name:"https://example.test/common.json",subject:$subject,version:1}],metadata:null,ruleSet:null}')
printf '%s\n' "$ENVELOPE" | "$WING" push "$REF_ROOT" --meta >/dev/null
"$WING" get "$REF_ROOT" >"$TMP/bundled.schema.json"
printf '%s\n' "$ENVELOPE" | "$WING" push "$REF_COPY" --meta >"$TMP/copy.guid"
jq -r .guid <<<"$ENVELOPE" >"$TMP/original.guid"
# Compare the registry GUIDs returned by metadata lookup, not the input envelope placeholder.
"$WING" get "$REF_ROOT" --meta | jq -r .guid >"$TMP/original.guid"
"$WING" get "$REF_COPY" --meta | jq -r .guid >"$TMP/copied.guid"
cmp "$TMP/original.guid" "$TMP/copied.guid"
"$WING" get "$REF_ROOT:1" >/dev/null
printf '%s\n' '{"code":"ok"}' | "$WING" _validate "$TMP/bundled.schema.json" |
    grep -qx valid
set +e
printf '%s\n' '{"code":7}' | "$WING" _validate "$TMP/bundled.schema.json" >"$TMP/invalid.out"
invalid_status=$?
set -e
[ "$invalid_status" -eq 2 ]

echo "relative Confluent reference without root \$id"
RELATIVE_MONEY='{"$schema":"http://json-schema.org/draft-07/schema#","$id":"money.json","type":"object","properties":{"amount":{"type":"number"}},"required":["amount"]}'
RELATIVE_INVOICE='{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"price":{"$ref":"money.json#/properties/amount"}},"required":["price"]}'
printf '%s\n' "$RELATIVE_MONEY" | "$WING" push "$REF_MONEY" >/dev/null
RELATIVE_ENVELOPE=$(jq -cn --arg topic "$REF_INVOICE" --arg schema "$RELATIVE_INVOICE" --arg subject "${REF_MONEY}-value" \
    '{topic:$topic,version:1,id:1,guid:"00000000-0000-0000-0000-000000000000",compat:"BACKWARD",schema:$schema,references:[{name:"money.json",subject:$subject,version:1}],metadata:null,ruleSet:null}')
printf '%s\n' "$RELATIVE_ENVELOPE" | "$WING" push "$REF_INVOICE" --meta >/dev/null
printf '%s\n' '{"topic":"'"$REF_INVOICE"'","value":"{\"price\":12}","headers":[]}' |
    "$WING" write "$REF_INVOICE" | "$KITE" produce --json "$REF_INVOICE"
"$KITE" consume --from-beginning --max 1 --idle 2s --json "$REF_INVOICE" |
    "$WING" read | jq -e '.value.price == 12' >/dev/null
"$WING" get "$REF_INVOICE" >"$TMP/relative-bundled.schema.json"
printf '%s\n' '{"price":12}' | "$WING" _validate "$TMP/relative-bundled.schema.json" | grep -qx valid

echo "empty values and early close"
printf '%s\n' '{"topic":"'"$ORDERS"'","value":"","headers":[]}' |
    "$WING" write "$ORDERS" | "$KITE" produce --json "$ORDERS"
set +e
"$KITE" consume --from-beginning --max 3 --idle 2s --json "$ORDERS" |
    "$WING" read | head -1 >/dev/null
head_status=$?
set -e
[ "$head_status" -eq 0 ]

echo "invalid mid-stream, check/DLQ, bundled metadata, and compatibility restore"
mkdir -p "$TMP/fixtures/valid" "$TMP/fixtures/invalid"
printf '%s\n' '{"id":7}' >"$TMP/fixtures/valid/ok.json"
printf '%s\n' '{"id":"bad"}' >"$TMP/fixtures/invalid/bad.json"
printf '%s\n' "$SCHEMA" | "$WING" push "$ORDERS" --fixtures "$TMP/fixtures" --check
printf '%s\n' '{"id":8}' >"$TMP/fixtures/invalid/unexpected-valid.json"
set +e
printf '%s\n' "$SCHEMA" | "$WING" push "$ORDERS" --fixtures "$TMP/fixtures" --check >/dev/null
fixture_status=$?
set -e
[ "$fixture_status" -eq 2 ]
BREAKING_SCHEMA='{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":["id"],"additionalProperties":false}'
set +e
printf '%s\n' "$BREAKING_SCHEMA" | "$WING" push "$ORDERS" --compat BACKWARD >/dev/null 2>"$TMP/compat.err"
compat_status=$?
set -e
[ "$compat_status" -eq 2 ]
grep -Fq "wing push: not compatible with ${ORDERS}-value version 1 (BACKWARD):" "$TMP/compat.err"
grep -Fq "TYPE_CHANGED at /properties/id:" "$TMP/compat.err"
curl -sS -o /dev/null -w '%{http_code}\n' "$SR/config/${ORDERS}-value" | grep -qx 404
set +e
printf '%s\n' "$BREAKING_SCHEMA" | "$WING" --errors=json push "$ORDERS" >/dev/null 2>"$TMP/compat.json"
compat_json_status=$?
set -e
[ "$compat_json_status" -eq 2 ]
python3 - "$TMP/compat.json" "$ORDERS" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    results = [json.loads(line) for line in source if line.strip()]
assert results
errors = []
for result in results:
    assert result["command"] == "push"
    assert result["kind"] == "invalid"
    assert result["output"]["valid"] is False
    assert len(result["output"]["errors"]) == 1
    errors.extend(result["output"]["errors"])
assert any(
    error["instanceLocation"] == "/properties/id"
    and "TYPE_CHANGED" in error["error"]
    and sys.argv[2] + "-value" in error["error"]
    for error in errors
)
PY
set +e
{
    "$KITE" consume --from-beginning --max 1 --idle 2s --json "$ORDERS"
    printf '%s\n' '{"topic":"'"$ORDERS"'","value":"{}","headers":[]}'
} | "$WING" read >/dev/null
midstream_status=$?
set -e
[ "$midstream_status" -eq 2 ]
set +e
printf '%s\n' '{"topic":"'"$ORDERS"'","value":"{}","headers":[]}' |
    "$WING" read --check | "$KITE" produce --json "$DLQ"
check_status=$?
set -e
[ "$check_status" -eq 2 ]
"$WING" get "$ORDERS" --meta | "$WING" push "$COPY" --meta |
    cmp -s <(printf '%s\n' "$GUID") -
"$WING" rm "$COPY:1" -y >/dev/null

assert_deleted_subject_absent() {
    local subject=$1
    curl -fsS "$SR/subjects?deleted=true" >"$TMP/deleted-subjects.json"
    jq -e --arg subject "$subject" 'type == "array" and index($subject) == null' \
        "$TMP/deleted-subjects.json" >/dev/null || {
        echo "FAIL subject remains after permanent delete: $subject"
        return 1
    }
}

echo "permanent deletion of live and soft-deleted subjects and versions"
RM_SOFT_TOPIC="$PREFIX-rm-soft"
printf '%s\n' "$SCHEMA" | "$WING" push "$RM_SOFT_TOPIC" >/dev/null
"$WING" rm "$RM_SOFT_TOPIC" -y >/dev/null
"$WING" rm "$RM_SOFT_TOPIC" -y --permanent >/dev/null
assert_deleted_subject_absent "${RM_SOFT_TOPIC}-value"

RM_VERSION_TOPIC="$PREFIX-rm-version"
printf '%s\n' "$SCHEMA" | "$WING" push "$RM_VERSION_TOPIC" >/dev/null
"$WING" rm "$RM_VERSION_TOPIC:1" -y >/dev/null
"$WING" rm "$RM_VERSION_TOPIC:1" -y --permanent >/dev/null
assert_deleted_subject_absent "${RM_VERSION_TOPIC}-value"
versions_status=$(curl -sS -o "$TMP/deleted-versions.json" -w '%{http_code}' \
    "$SR/subjects/${RM_VERSION_TOPIC}-value/versions?deleted=true")
if [ "$versions_status" = 200 ]; then
    jq -e 'type == "array" and all(.[]; tostring != "1")' "$TMP/deleted-versions.json" >/dev/null || {
        echo "FAIL version remains after permanent delete: ${RM_VERSION_TOPIC}-value:1"
        exit 1
    }
elif [ "$versions_status" != 404 ]; then
    echo "FAIL unexpected status checking permanent version delete: $versions_status"
    exit 1
fi

RM_LIVE_TOPIC="$PREFIX-rm-live"
printf '%s\n' "$SCHEMA" | "$WING" push "$RM_LIVE_TOPIC" >/dev/null
"$WING" rm "$RM_LIVE_TOPIC" -y --permanent >/dev/null
assert_deleted_subject_absent "${RM_LIVE_TOPIC}-value"

echo "live smoke passed"
echo "transcript: $TRANSCRIPT"
