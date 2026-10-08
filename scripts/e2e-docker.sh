#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

KAFKA_IMAGE=${WING_E2E_KAFKA_IMAGE:-apache/kafka:4.0.0}
SR_IMAGE=${WING_E2E_SR_IMAGE:-mirror.gcr.io/confluentinc/cp-schema-registry:8.0.0}
KAFKA_PORT=${WING_E2E_KAFKA_PORT:-9092}
SR_PORT=${WING_E2E_SCHEMA_REGISTRY_PORT:-8081}
TIMEOUT=${WING_E2E_TIMEOUT:-180}
KAFKA_NAME=wing-e2e-kafka
SR_NAME=wing-e2e-sr
NETWORK=wing-e2e-net
WING=${WING:-"$PWD/zig-out/bin/wing"}
TMP=$(mktemp -d)
TRANSCRIPTS=${TRANSCRIPT_DIR:-"$HOME/wing-work/transcripts"}
mkdir -p "$TRANSCRIPTS"
TRANSCRIPT="$TRANSCRIPTS/phase4-e2e-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$TRANSCRIPT") 2>&1
status=1

cleanup() {
    if [ "$status" -ne 0 ]; then
        echo "== Schema Registry logs =="
        docker logs --tail 200 "$SR_NAME" 2>/dev/null || true
        echo "== Kafka logs =="
        docker logs --tail 200 "$KAFKA_NAME" 2>/dev/null || true
    fi
    docker rm -f "$SR_NAME" "$KAFKA_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL $1" >&2; exit 1; }

[ -x "$WING" ] || zig build
[ -x "$WING" ] || fail "missing wing binary: $WING"
if [ -n "${KITE:-}" ]; then
    if [ -x "$KITE" ]; then
        KITE_BIN=$KITE
    else
        KITE_BIN=$(command -v "$KITE") || fail "KITE is not executable: $KITE"
    fi
else
    mkdir -p "$TMP/kite-bin"
    curl -fsSL https://raw.githubusercontent.com/addisonhuddy/kite/main/install.sh -o "$TMP/kite-install.sh"
    sh "$TMP/kite-install.sh" --bin-dir "$TMP/kite-bin"
    KITE_BIN="$TMP/kite-bin/kite"
fi
[ -x "$KITE_BIN" ] || fail "missing kite binary: $KITE_BIN"

echo "== pull Kafka and Schema Registry images =="
docker pull "$KAFKA_IMAGE" >/dev/null
docker pull "$SR_IMAGE" >/dev/null
docker rm -f "$SR_NAME" "$KAFKA_NAME" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

docker run -d --name "$KAFKA_NAME" --network "$NETWORK" --network-alias kafka \
    -p "127.0.0.1:$KAFKA_PORT:29092" \
    -e KAFKA_NODE_ID=1 \
    -e KAFKA_PROCESS_ROLES=broker,controller \
    -e KAFKA_LISTENERS=INTERNAL://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:29092 \
    -e "KAFKA_ADVERTISED_LISTENERS=INTERNAL://kafka:9092,EXTERNAL://127.0.0.1:$KAFKA_PORT" \
    -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=INTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT,EXTERNAL:PLAINTEXT \
    -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
    -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:9093 \
    -e KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL \
    -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
    -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
    -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
    -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
    -e KAFKA_NUM_PARTITIONS=1 \
    -e CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qk "$KAFKA_IMAGE" >/dev/null

docker run -d --name "$SR_NAME" --network "$NETWORK" \
    -p "127.0.0.1:$SR_PORT:8081" \
    -e SCHEMA_REGISTRY_HOST_NAME=sr \
    -e SCHEMA_REGISTRY_LISTENERS=http://0.0.0.0:8081 \
    -e SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS=PLAINTEXT://kafka:9092 \
    -e SCHEMA_REGISTRY_KAFKASTORE_TOPIC_REPLICATION_FACTOR=1 \
    "$SR_IMAGE" >/dev/null

echo "== wait for Kafka and Schema Registry =="
deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
    if docker exec "$KAFKA_NAME" /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka:9092 --list >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
[ "$SECONDS" -lt "$deadline" ] || fail "Kafka readiness timed out after ${TIMEOUT}s"
while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS "http://127.0.0.1:$SR_PORT/subjects" >/dev/null; then
        break
    fi
    sleep 2
done
[ "$SECONDS" -lt "$deadline" ] || fail "Schema Registry readiness timed out after ${TIMEOUT}s"

export WING KITE="$KITE_BIN"
export SCHEMA_REGISTRY_URL="http://127.0.0.1:$SR_PORT"
export BOOTSTRAP_SERVERS="127.0.0.1:$KAFKA_PORT"
export SMOKE_SR_CONTAINER="$SR_NAME" JAVA_BOOTSTRAP_SERVERS=kafka:9092
export TRANSCRIPT_DIR="$TRANSCRIPTS"

echo "== smoke-live.sh =="
scripts/smoke-live.sh

TOPIC="wing-e2e-wire-$(date +%s)-$RANDOM"
SCHEMA='{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],"additionalProperties":false}'
GUID=$(printf '%s\n' "$SCHEMA" | "$WING" push "$TOPIC")

echo "== header byte preservation =="
for form in raw escaped; do
    python3 - "$TOPIC" "$GUID" "$form" >"$TMP/$form.jsonl" <<'PY'
import json
import sys

topic, guid, form = sys.argv[1:]
header = b"\x01" + bytes.fromhex(guid.replace("-", ""))
payload = (
    b'{"topic":' + json.dumps(topic).encode() +
    b',"value":"{\\"id\\":1}","headers":[{"key":"__value_schema_id","value":"'
)
encoded = bytearray()
for byte in header:
    if byte == 34:
        encoded.extend(b'\\"')
    elif byte == 92:
        encoded.extend(b"\\\\")
    elif byte < 32 or (form == "escaped" and byte >= 128):
        encoded.extend(b"\\u%04x" % byte)
    else:
        encoded.append(byte)
sys.stdout.buffer.write(payload + encoded + b'"}]}\n')
PY
    if [ "$form" = raw ]; then
        "$WING" read <"$TMP/$form.jsonl" | jq -e --arg guid "$GUID" '.schema.value.guid == $guid' >/dev/null \
            || fail "raw header did not resolve"
        "$WING" write "$TOPIC:1" <"$TMP/$form.jsonl" >"$TMP/$form.out"
python3 - "$GUID" "$TMP/$form.out" <<'PY'
import base64
import json
import sys

header = b"\x01" + bytes.fromhex(sys.argv[1].replace("-", ""))
output = open(sys.argv[2], "rb").read()
record = json.loads(output)
schema_header = next(item for item in record["headers"] if item["key"] == "__value_schema_id")
if schema_header.get("value_b64") != base64.b64encode(header).decode():
    raise SystemExit("schema header was not emitted as standard base64")
if any(byte >= 128 for byte in output):
    raise SystemExit("schema header output was not ASCII-safe")
PY
    else
        set +e
        "$WING" read <"$TMP/$form.jsonl" >/dev/null 2>"$TMP/$form.err"
        escaped_status=$?
        set -e
        [ "$escaped_status" -eq 2 ] &&
            grep -Fq 'corrupt __value_schema_id header' "$TMP/$form.err" &&
            grep -Fq 'upgrade kite so it emits value_b64' "$TMP/$form.err" \
            || fail "escaped high-byte header was not rejected"
    fi
done

echo "== schema header survives jq between wing and kite =="
printf '%s\n' '{"value":{"id":1},"headers":[]}' |
    "$WING" write "$TOPIC" | "$KITE_BIN" produce --json "$TOPIC"
"$KITE_BIN" consume --from-beginning --max 1 --idle 3s --json "$TOPIC" |
    jq -c . | "$WING" read |
    jq -s -e --arg guid "$GUID" 'length == 1 and .[0].schema.value.guid == $guid and .[0].value.id == 1' >/dev/null \
    || fail "schema identity did not survive consume | jq | wing read"

echo "== tombstones and empty values through kite =="
EMPTY_TOPIC="wing-e2e-empty-$(date +%s)-$RANDOM"
printf '%s\n' '{"type":"string"}' | "$WING" push "$EMPTY_TOPIC" --key >/dev/null
EMPTY_KEY_ID=$(curl -fsS "$SCHEMA_REGISTRY_URL/subjects/${EMPTY_TOPIC}-key/versions/latest" | jq -r .id)
printf '%s\n' '{"value":"","headers":[]}' | "$WING" write | "$KITE_BIN" produce --json "$EMPTY_TOPIC"
python3 - "$EMPTY_KEY_ID" <<'PY' | docker exec -i "$KAFKA_NAME" \
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka:9092 \
    --topic "$EMPTY_TOPIC" --property parse.key=true \
    --property parse.headers=true --property null.marker=__NULL__
import sys

schema_id = int(sys.argv[1])
header = b"\x00" + schema_id.to_bytes(4, "big")
sys.stdout.buffer.write(b'__key_schema_id:' + header + b'\t"tombstone"\t__NULL__\n')
PY
"$KITE_BIN" consume --from-beginning --max 2 --idle 3s --json "$EMPTY_TOPIC" |
    "$WING" read | jq -s -e 'length == 2 and all(.[]; .value == "")' >/dev/null \
    || fail "empty value/tombstone round trip"

echo "== early close =="
set +e
"$KITE_BIN" consume --from-beginning --max 100 --idle 3s --json "$EMPTY_TOPIC" |
    "$WING" read | head -n 1 >/dev/null
head_status=${PIPESTATUS[1]}
set -e
[ "$head_status" -eq 0 ] || fail "wing read exited $head_status after head closed the pipe"

echo "== SIGINT flush and exit status =="
mkfifo "$TMP/signal.in"
"$WING" write "$TOPIC" <"$TMP/signal.in" >"$TMP/signal.out" 2>"$TMP/signal.err" &
wing_pid=$!
python3 -u - "$TOPIC" >"$TMP/signal.in" <<'PY' &
import json
import sys
import time

topic = sys.argv[1]
while True:
    print(json.dumps({"topic": topic, "value": '{"id":1}', "headers": []}), flush=True)
    time.sleep(0.05)
PY
producer_pid=$!
sleep 1
kill -INT "$wing_pid"
set +e
wait "$wing_pid"
signal_status=$?
set -e
kill "$producer_pid" 2>/dev/null || true
wait "$producer_pid" 2>/dev/null || true
[ "$signal_status" -eq 130 ] || fail "SIGINT returned $signal_status, expected 130"
[ -s "$TMP/signal.out" ] && grep -Eq 'wing write: [1-9][0-9]* written' "$TMP/signal.err" \
    || fail "SIGINT did not flush output and summary"

echo "== write stops at first invalid record under pipefail =="
set +e
printf '%s\n' '{"value":"{\"id\":1}","headers":[]}' '{"value":"{\"id\":\"bad\"}","headers":[]}' '{"value":"{\"id\":2}","headers":[]}' |
    "$WING" write "$TOPIC" >"$TMP/stop.out" 2>"$TMP/stop.err"
stop_status=$?
set -e
[ "$stop_status" -eq 2 ] && [ "$(wc -l <"$TMP/stop.out")" -eq 1 ] \
    || fail "write did not stop after flushing one valid record (status $stop_status)"

status=0
echo "ok: Docker E2E passed on localhost:$KAFKA_PORT and localhost:$SR_PORT"
echo "transcript: $TRANSCRIPT"
