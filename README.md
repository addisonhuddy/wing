# wing

![Wing and kite JSON Schema pipeline](examples/demo.gif)

**wing is a small Schema Registry CLI for JSON Schema.** It validates and
transforms Kafka JSONL records while preserving Confluent schema identity, and
is designed to compose with [kite](https://github.com/addisonhuddy/kite).

## For AI agents

- **Purpose:** fetch, validate, fit, publish, and delete JSON Schemas in
  Confluent Schema Registry; read and write kite `--json` records.
- **Data contract:** records and diagnostics use separate streams. `read` and
  `write` accept one JSON record per line; transformed records go to stdout,
  summaries and errors to stderr.
- **Exit codes:** `0` success; `1` usage, configuration, registry, or tool
  failure; `2` invalid data/schema, failed `--check`, or rejected push; `130`
  SIGINT/SIGTERM.
- **Registry:** set `SCHEMA_REGISTRY_URL`, pass `--registry URL`, or configure
  `wing.yaml`. `@NAME` selects a named registry for one command.
- **Useful commands:** `wing ls`, `wing get REF`, `wing push TOPIC`,
  `wing read`, `wing write [REF] [--fit]`, and `wing rm REF -y`.
- **Kite pipeline:** `kite consume --json TOPIC | wing read | jq ... |
  wing write TOPIC --fit | kite produce --json TOPIC`.
- **Stable contract:** see [`llms.txt`](llms.txt). Full testing guidance is in
  [`TESTING.md`](TESTING.md).

## Quickstart

Install wing, then install kite separately if it is not already on `PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/addisonhuddy/wing/main/install.sh | sh
```

### Run Kafka and Schema Registry locally with Docker

The following single-node setup uses a private Docker network so Schema
Registry can reach Kafka on its internal listener. It publishes Kafka on
`localhost:9092` and Schema Registry on `localhost:8081`.

```sh
docker network create wing-local
docker run -d --name wing-local-kafka --network wing-local \
  -p 127.0.0.1:9092:9092 \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@wing-local-kafka:9093 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LISTENERS=INTERNAL://:29092,EXTERNAL://:9092,CONTROLLER://:9093 \
  -e KAFKA_ADVERTISED_LISTENERS=INTERNAL://wing-local-kafka:29092,EXTERNAL://localhost:9092 \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT \
  -e KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  apache/kafka-native:latest
docker run -d --name wing-local-sr --network wing-local \
  -p 127.0.0.1:8081:8081 \
  -e SCHEMA_REGISTRY_HOST_NAME=wing-local-sr \
  -e SCHEMA_REGISTRY_LISTENERS=http://0.0.0.0:8081 \
  -e SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS=PLAINTEXT://wing-local-kafka:29092 \
  mirror.gcr.io/confluentinc/cp-schema-registry:8.0.0
until curl -fsS http://localhost:8081/subjects >/dev/null; do sleep 2; done
```

Set the local endpoints and choose a topic. `wing`, `kite`, and `jq` must be
available on `PATH`:

```sh
export BOOTSTRAP_SERVERS=localhost:9092
export SCHEMA_REGISTRY_URL=http://localhost:8081
TOPIC="wing-quickstart-$(date +%s)"
```

Register the schema, write the sample JSONL records, and read them back:

```sh
wing push "$TOPIC" < examples/orders.schema.json
jq -c '{value: .}' examples/orders.jsonl |
  wing write "$TOPIC" |
  kite produce --json "$TOPIC"
kite consume --from-beginning --max 2 --idle 3s --json "$TOPIC" |
  wing read |
  jq -c .value
```

`wing write` adds a Confluent GUID schema header; `wing read` resolves it,
validates each value, and emits an inline JSON object. To fit CSV-produced
records to the same schema:

```sh
FIT_TOPIC="${TOPIC}-csv"
kite produce --csv "$FIT_TOPIC" < examples/orders.csv
kite consume --from-beginning --max 2 --idle 3s --json "$FIT_TOPIC" |
  wing write --fit "$TOPIC" |
  kite produce --json "$TOPIC"
```

Remove the local containers and network when finished:

```sh
docker rm -f wing-local-sr wing-local-kafka
docker network rm wing-local
```

For source builds, use Zig 0.16.0:

```sh
zig build
./zig-out/bin/wing --version
```

After a release is published, the checksum-verifying installer can be run
with `curl -fsSL
https://raw.githubusercontent.com/addisonhuddy/wing/main/install.sh | sh`.
It installs to `/usr/local/bin` by default. Set `WING_BIN_DIR` and
`WING_VERSION`, or pass `--bin-dir DIR` and `--version TAG` to the script.

## Commands

| Command | Purpose |
| --- | --- |
| `wing read` | Resolve schema IDs and validate consumed JSONL records. |
| `wing write [REF]` | Add schema headers and validate records before producing. |
| `wing write REF --fit` | Apply schema-directed fitting, then validate. |
| `wing ls [TOPIC]` | List value subjects or versions; `--key` selects key schemas. |
| `wing get REF` | Print registered schema text; `--meta` prints its envelope. |
| `wing push [TOPIC]` | Lint and register a schema; `--check` never registers. |
| `wing rm REF -y` | Delete a subject/version; `--permanent` also hard-deletes it. |
| `wing registry list` | List configured registries. |
| `wing registry set NAME` | Select the current configured registry. |
| `wing registry init` | Interactively configure and test a registry. |
| `wing update [VERSION]` | Replace this binary with the latest or named release. |

`REF` may be a topic, a topic followed by `:VERSION` (for example
`orders:3`), a subject, or a schema GUID. `@NAME` selects a named registry;
`--key` selects the topic key schema
for `ls`, `get`, `push`, and `rm`.

### Common command examples

These commands use the `TOPIC` from Quickstart and live Schema Registry:

```sh
wing ls "$TOPIC" --json
wing get "$TOPIC" >/dev/null
wing get "$TOPIC" --meta | jq -e '.schema | type == "string"'
wing push --check --fixtures examples/fixtures < examples/orders.schema.json
cat examples/orders-key.schema.json | wing push "$TOPIC" --key
wing ls "$TOPIC" --key --json
```

Copy metadata to a second topic, then remove that temporary subject:

```sh
COPY="${TOPIC}-copy"
wing get "$TOPIC" --meta | wing push "$COPY" --meta
wing rm "$COPY:1" -y
```

For a record-only pipeline, consume a bounded number of records and preserve
their record envelope while changing the value:

```sh
kite consume --from-beginning --max 100 --idle 3s --json "$TOPIC" |
  wing read |
  jq -c '.value.total += 1' |
  wing write "$TOPIC" --fit |
  kite produce --json "$TOPIC"
```

The same pipeline can fit CSV-produced strings to the topic schema:

```sh
CSV_TOPIC="${TOPIC}-csv"
kite produce --csv "$CSV_TOPIC" < examples/orders.csv
kite consume --from-beginning --max 2 --idle 3s --json "$CSV_TOPIC" |
  wing write "$TOPIC" --fit |
  kite produce --json "$TOPIC"
```

### Command flags

| Command | Flags |
| --- | --- |
| `read` | `--check` |
| `write` | `--fit`, `--check` |
| `ls` | `--key`, `--json` |
| `get` | `--meta`, `--key` |
| `push` | `--check`, `--fixtures DIR`, `--compat LEVEL`, `--meta`, `--key` |
| `rm` | `-y`/`--yes`, `--permanent`, `--key` |
| `registry list` | `--json` |
| `update` | `VERSION` |

Global options are `@NAME`, `--registry URL`, `--config FILE`,
`--schema-dir DIR`, `--errors=json`, `-q`/`--quiet`, `-v`/`--verbose`,
`-h`/`--help`, and `-V`/`--version`. Global registry options may appear
before or after the command.

## Record contract

`read` and `write` accept kite JSON mode: one JSON object per line, with
`value` required and optional `topic`, `partition`, `offset`, `timestamp`,
`key`, `headers`, and `schema`. A malformed/non-record input line is a usage
error. Blank lines are skipped.

- A JSON string in `value` is the exact record byte sequence. An object or
  array value uses its original JSON source text.
- `read` inlines a value only when its bytes are exactly one JSON object or
  array, without surrounding whitespace. Other values remain strings.
- Schema identity is read from `__value_schema_id` and `__key_schema_id`
  headers (GUID format, `0x01` + 16 bytes; legacy format, `0x00` + 4-byte ID)
  or a Confluent payload prefix. `read` removes schema headers/prefixes from
  transformed output. It preserves other headers and record metadata.
- `--check` prints only records that fail or would change and exits `2` if
  any need attention. `write` stops at the first invalid record after flushing
  prior complete records.
- `--errors=json` emits machine-readable diagnostic envelopes on stderr.
  Validation locations are plain JSON Pointers; the root pointer is `""`.
- Per-record read/write errors, notes, and summaries use `wing read:` or
  `wing write:` prefixes. When a write record has no schema, wing suggests
  passing a topic or keeping the schema field emitted by `wing read`.
- `-q` suppresses summaries, not warnings/errors. `-v` prints configuration
  provenance and fit changes. `SIGINT`/`SIGTERM` flush the current record and
  summary, then exit `130`; closing a downstream pipe is quiet.

## Fitting with `--fit`

Fitting reuses the compiled schema plan, then validates the result:

| Rule | Change |
| --- | --- |
| `coerce` | Convert supported strings/numbers/booleans to the schema's scalar type; preserve decimal text and never coerce `null`. |
| `defaults` | Add a declared default only for a missing property of an existing object. |
| `drop-extra` | Remove properties rejected by `additionalProperties: false`. This is the lossy rule and emits a warning summary. |
| `wrap` | Wrap a scalar in an array when the array schema accepts it. |

`allOf` rules run sequentially. `anyOf`/`oneOf` branches are tried on copies;
a branch that already passes unchanged wins, otherwise a successful fitted
branch is committed. `const`/`enum` discriminators guide branch selection.
`--fit --check -v` reports changes without writing records.

## Registry configuration

wing does not read `kite.yaml`; kite does not read `wing.yaml`. Example:

```yaml
default: dev
defaults:
  schema.dir: ~/.cache/wing/schemas
registries:
  dev:
    schema.registry.url: http://localhost:8081
  prod:
    schema.registry.url: https://registry.example.invalid
    basic.auth.user.info: API_KEY:API_SECRET
```

Configuration search order is `--config FILE`, `$WING_CONFIG`, then the first
available of `./wing.yaml`, `./wing.properties`,
`$XDG_CONFIG_HOME/wing/wing.yaml`, `$XDG_CONFIG_HOME/wing/wing.properties`,
`~/.config/wing/wing.yaml`, and `~/.config/wing/wing.properties`. A missing
explicit config path is an error.

Registry selection is `@NAME`, `$WING_TARGET`, the stored current registry
(`$XDG_CONFIG_HOME/wing/current` or `~/.config/wing/current`), then YAML
`default:`. Precedence for a named registry is command-line flags, registry
keys, environment, `defaults:`, then built-ins. With no named registry, flags
override environment, file defaults, and built-ins.

| Config key | Environment variable | Purpose |
| --- | --- | --- |
| `schema.registry.url` | `SCHEMA_REGISTRY_URL` | Required URL(s), comma-separated for connection failover. |
| `basic.auth.user.info` | `SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO` | `key:secret` basic credentials. |
| `bearer.auth.token` | `SCHEMA_REGISTRY_BEARER_AUTH_TOKEN` | Bearer token authentication. |
| `schema.registry.ssl.truststore.location` | `SCHEMA_REGISTRY_SSL_TRUSTSTORE_LOCATION` | PEM CA bundle. |
| `schema.registry.ssl.insecure` | `SCHEMA_REGISTRY_SSL_INSECURE` | Disable TLS verification; emits a warning. |
| `schema.registry.request.timeout.ms` | `SCHEMA_REGISTRY_REQUEST_TIMEOUT_MS` | Registry response timeout in milliseconds; defaults to `10000`. |
| `schema.dir` | `WING_SCHEMA_DIR` | Offline schema cache directory. |
| `http.header.NAME` | — | Additional HTTP request header. |

`basic.auth.credentials.source` is accepted for Confluent config compatibility.
`HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` are honored. Kafka properties in a
`.properties` file are ignored. Use `wing -v` to see configuration origins.
Protect files containing credentials (mode `0600`); avoid committing secrets.

## Local development and distribution

The recommended development images are Apache Kafka
`apache/kafka-native:latest` and Schema Registry
`mirror.gcr.io/confluentinc/cp-schema-registry:8.0.0`. To run the isolated
test stack without touching an existing broker, use
`scripts/e2e-docker.sh`; set `WING_E2E_KAFKA_PORT` and
`WING_E2E_SCHEMA_REGISTRY_PORT` to choose host ports.

The installer verifies the selected binary against the release's
`SHA256SUMS`. Supported assets are Linux/macOS on x86_64/aarch64.
`wing update [VERSION]` runs the same installer in the directory containing
the current executable. Shell completions for bash, zsh, and fish are in
[`completions/`](completions/).

## Development checks

See [`CONTRIBUTING.md`](CONTRIBUTING.md), [`TESTING.md`](TESTING.md), and
[`SECURITY.md`](SECURITY.md). Licensed under Apache-2.0; see [`LICENSE`](LICENSE).
