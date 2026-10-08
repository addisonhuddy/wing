<div align="center">
<pre>
                       __
                 __.--~  )
           __.--~  __.--~
     __.--~  __.--~  __)
   &lt;~  __.--~  __.--~
    ~-~  __.--~  __)
      ~-~  __.--~
        ~-~ __)
          ~~
</pre>

<h1>wing</h1>

<p>
  <a href="https://github.com/addisonhuddy/wing/actions/workflows/ci.yml"><img src="https://github.com/addisonhuddy/wing/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/addisonhuddy/wing/actions/workflows/release.yml"><img src="https://github.com/addisonhuddy/wing/actions/workflows/release.yml/badge.svg" alt="Release"></a>
  <a href="https://github.com/addisonhuddy/wing/releases/latest"><img src="https://img.shields.io/github/v/release/addisonhuddy/wing?sort=semver&display_name=tag&label=version" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/addisonhuddy/wing" alt="License"></a>
</p>

<p>
  <strong>wing is a tiny Confluent Schema Registry CLI for JSON Schema, built to fly with kite.</strong><br>
  One Zig binary, no JVM. JSONL in, JSONL out. Exit 2 when data fails.
</p>
</div>

**What is wing?** wing validates, fits, reads, writes, and manages JSON
Schemas in Confluent Schema Registry. It composes with
[kite](https://github.com/addisonhuddy/kite): kite moves Kafka records, while
wing validates and transforms them in a stream.

**Use wing when** a shell, CI job, or AI agent needs to lint or publish JSON
Schemas, validate Kafka records, or adapt records to a schema between
`kite consume` and `kite produce`.

**Do not use wing when** you need Avro or Protobuf; use
`RecordNameStrategy` or `TopicRecordNameStrategy`; need remote `$ref` fetching;
need an in-process application serializer; or need consumer groups, Kafka
administration, or offset commits. Use an application client for serializers
and [kite](https://github.com/addisonhuddy/kite) for Kafka record movement.

## Quickstart

![10-second demo: push a schema, write and read records through kite, fit CSV records](examples/demo.gif)

You need Kafka at `localhost:9092` and Schema Registry at `localhost:8081`
(e.g. the Docker ones in
[Run Kafka and Schema Registry locally with Docker](#run-kafka-and-schema-registry-locally-with-docker)),
[kite](https://github.com/addisonhuddy/kite) v0.4.0 or later, and
[`jq`](https://jqlang.github.io/jq/) for the last line only. Use a fresh topic
name so the output is exactly one record.

```sh
curl -fsSL https://raw.githubusercontent.com/addisonhuddy/wing/main/install.sh | sh
export SCHEMA_REGISTRY_URL=http://localhost:8081 BOOTSTRAP_SERVERS=localhost:9092
echo '{"type":"object","properties":{"id":{"type":"integer"}}}' | wing push events  # register a schema
echo '{"id":1}' | wing write events | kite produce --json events       # validate, add schema header, produce
kite consume -B -n 1 --idle 3s --json events | wing read | jq -c .value  # prints: {"id":1}
```

`wing write` adds the Confluent schema header; `wing read` resolves it and
validates again. Records go to stdout and diagnostics to stderr, so `jq` only
sees data. A record that does not match exits 2 and nothing is produced:

```sh
echo '{"id":"one"}' | wing write events | kite produce --json events
# wing write: line 1: /id: expected integer, got string [/properties/id/type]
```

No Kafka? Check a schema and its fixtures offline:

```sh
wing push --check --fixtures examples/fixtures < examples/orders.schema.json
# wing push: ok
echo '{"type":"objet"}' | wing push --check; echo "exit $?"
# wing push: schema metaschema error at /properties/type/anyOf/0/$ref -> /definitions/simpleTypes/enum: value "objet" is not in enum; did you mean "object"?
# exit 2
```

More recipes are in [Examples](#examples).

## Why wing

- **One small binary.** No JVM, daemon, or runtime dependency.
- **Unix pipelines.** JSONL records compose with kite and ordinary tools;
  stdout is stable data and stderr is diagnostics.
- **Strict writes, useful reads.** Writes validate before producing; reads
  preserve records and attach schema/validation metadata.
- **Schema-directed fitting.** `--fit` supports `coerce`, `defaults`,
  `drop-extra`, and `wrap`, selects `anyOf`/`oneOf` branches, then validates
  the result. `-v` explains every change.
- **Confluent wire-compatible.** Writes use the GUID header (`0x01` plus 16
  bytes); reads also accept the legacy `0x00` plus 4-byte ID payload prefix.
  Interoperability is tested with Confluent's Java JSON Schema serializer.
- **Offline schema cache.** `--schema-dir` caches schemas; reads make zero
  Registry requests when every referenced GUID is cached.
- **Validator correctness.** All required cases pass in the official JSON
  Schema Test Suite: draft-04 **618**, draft-06 **841**, draft-07 **929**,
  2019-09 **1261**, and 2020-12 **1301**. Differential tests agreed with
  Sourcemeta's validator on **133/133** bundled schemas.

## For AI agents

[`llms.txt`](llms.txt) is the stable machine-readable contract: commands,
REF syntax, the record format, streams, and exit codes. `wing --help` and
`wing COMMAND --help` list every flag. See [`TESTING.md`](TESTING.md) for
test guidance.

## Install

Install the latest release (Linux/macOS, x86_64/aarch64); the script verifies
the asset against `SHA256SUMS`:

```sh
curl -fsSL https://raw.githubusercontent.com/addisonhuddy/wing/main/install.sh | sh
```

The installer defaults to `/usr/local/bin`. Set `WING_BIN_DIR` and
`WING_VERSION`, or pass `--bin-dir DIR` and `--version TAG` to the script.
`wing update [VERSION]` installs the selected release next to the running
binary.

Build from source with Zig 0.16.0:

```sh
zig build
./zig-out/bin/wing -V
```

Shell completions are in [`completions/`](completions/). Clone the repository
first; the installer downloads only the binary.

**Bash** (or source it from `~/.bashrc`):

```sh
mkdir -p ~/.local/share/bash-completion/completions
cp completions/wing.bash ~/.local/share/bash-completion/completions/wing
```

**Zsh** (the function file must be named `_wing` and be on `fpath` before
`compinit`):

```sh
mkdir -p ~/.zfunc
cp completions/wing.zsh ~/.zfunc/_wing
# Add to ~/.zshrc before compinit:
fpath=(~/.zfunc $fpath)
autoload -Uz compinit && compinit
```

**Fish:**

```fish
set -q __fish_config_dir; or set __fish_config_dir ~/.config/fish
mkdir -p $__fish_config_dir/completions
cp completions/wing.fish $__fish_config_dir/completions/
```

## Command reference

Run `wing --help` for the command list and `wing COMMAND --help` for flags
and examples. Global options: `--registry URL`, `--config FILE`,
`--schema-dir DIR`, `--errors=json`, `-q`, `-v`, `-h`, and `-V`. Add `@NAME`
to a command to select a configured Registry.

## Examples

These recipes use a configured Schema Registry and kite on `PATH`.

### Lint a schema and its fixtures offline

Validates `valid/` and `invalid/` fixtures without registering.

```sh
wing push --check --fixtures examples/fixtures < examples/orders.schema.json
```

### Check backward compatibility

Register a base schema, then check backward compatibility.

```sh
wing push orders-compat --compat BACKWARD < examples/orders.schema.json
# exits 2 and prints the incompatible paths
jq '.properties.order_id.type = "string"' examples/orders.schema.json |
  wing push orders-compat
```

### Publish a key schema

`--key` addresses the `<topic>-key` subject.

```sh
wing push orders --key < examples/orders-key.schema.json
```

### Pin a version and inspect metadata

Pin a schema version, then inspect its metadata envelope.

```sh
wing get orders:1
wing get orders --meta | jq '{topic,version,guid}'
```

### Copy a schema to another topic

Copy schema metadata (including references) to another topic.

```sh
wing get orders --meta | wing push orders-copy --meta
```

### Validate consumed records

Consume and validate records, keeping only each decoded value.

```sh
kite consume --from-beginning --max 2 --idle 3s --json orders |
  wing read |
  jq -c .value
```

### Filter saved records with jq, decode later

Save raw records now. filter with jq and decode later (the schema header survives jq).

```sh
kite consume --from-beginning --max 2 --idle 3s --json orders > orders.jsonl
jq -c 'select(.offset == 1)' orders.jsonl | wing read
```

### Route failed records to a dead-letter topic

Route failed records from orders-bad into a dead-letter topic.

```sh
kite consume --from-beginning --max 1 --idle 3s --json orders-bad |
  wing read --check |
  kite produce --json orders-dlq
```

### Fit CSV records to a schema

CSV fields arrive as strings. `--fit` coerces them and applies currency's default.

```sh
kite produce --csv orders-csv < examples/orders.csv
kite consume --from-beginning --max 2 --idle 3s --json orders-csv |
  wing write orders --fit |
  kite produce --json orders
```

### Edit records with jq and re-validate

Keep a jq edit in the record pipeline. write validates the changed value.

```sh
kite consume --from-beginning --max 2 --idle 3s --json orders |
  wing read |
  jq -c '.value.total += 1' |
  wing write orders --fit |
  kite produce --json orders
```

### Read records from Confluent's Java serializer

Records from Confluent's Java JSON Schema serializer (legacy 0x00 prefix or GUID header) read the same way.

```sh
kite consume --from-beginning --max 1 --idle 3s --json legacy-orders | wing read
```

### Register a schema with a reference

Register a relative reference. get bundles the referenced schema.

```sh
wing push money < examples/money.schema.json
wing push invoice --meta < examples/invoice.meta.json
wing get invoice
```

### Read offline from the schema cache

Later reads with every GUID cached make no Registry requests.

```sh
kite consume --from-beginning --max 2 --idle 3s --json orders > batch.jsonl
wing read --schema-dir ~/.cache/wing/schemas < batch.jsonl
```

### List subjects on another registry

Requires prod to be configured in wing.yaml (see Multiple registries).

```sh
wing ls @prod
```

### Structured diagnostics with --errors=json

Pipe structured schema diagnostics from stderr into jq.

```sh
jq '{tpye: "object"}' examples/orders.schema.json |
  wing push --check --errors=json 2>&1 >/dev/null |
  jq -c .
```

### Remove a schema version

Create then remove version 2. `rm` requires `-y` in a non-interactive pipeline.

```sh
wing push orders-versions < examples/orders.schema.json >/dev/null
jq '.description = "temporary README example version"' examples/orders.schema.json |
  wing push orders-versions >/dev/null
wing rm orders-versions:2 -y
```

## REF syntax

For `get` and `write`, a REF can be a topic, a topic plus version
(`TOPIC:VERSION` or `TOPIC:latest`), an explicit subject, or a schema GUID.
`rm` accepts a subject or `SUBJECT:VERSION` with a positive integer version.
`ls` accepts a topic. `@NAME` selects a named Registry and is never a version
separator; `orders@3` exits with a migration hint to use `orders:3`.
Context-qualified subjects such as `:.ctx:orders-value` pass through as
subjects; a final positive integer after `:` pins a version.

## Record contract

`read` accepts kite `--json`: one JSON object per line, with `value` or
`value_b64` and optional `topic`, `partition`, `offset`, `timestamp`, `key`,
`headers`, and `schema`. `write` requires a JSON `value`; when a REF is
given, a JSON object or array line without a `value` (or `value_b64`) member
is taken as the record value and written in a kite envelope. A line whose
object has a `value` member is always read as an envelope, so wrap values of
schemas with a top-level `value` property as `{"value": ...}`. Blank lines are
skipped.

- A JSON string in `value` is the exact record byte sequence. An object or
  array value uses its original JSON source text.
- `read` decodes top-level `key_b64` / `value_b64` and array-header
  `value_b64` fields before handling payload prefixes and schema IDs; decoded
  top-level fields do not pass through unchanged.
- `read` inlines a value only when its bytes are exactly one JSON object or
  array. Other values remain strings. It preserves record metadata and
  non-schema headers.
- Schema identity comes from `__value_schema_id` / `__key_schema_id` headers
  (GUID format: `0x01` plus 16 bytes; legacy format: `0x00` plus a 4-byte ID)
  or a Confluent payload prefix. `read` removes schema headers/prefixes from
  transformed output and adds schema metadata under `.schema`.
- Header identity remains intact through `jq` anywhere in the pipeline; this
  requires kite v0.4.0 or later with `--json` `_b64` support. Base64 header
  values are decoded before schema IDs are parsed.
- `wing write --check` validates without adding a header. `wing read --check`
  emits only failed or changed records. Both return `2` when a record needs
  attention; pipe read-check output to a DLQ producer.
- `--errors=json` requests structured diagnostic lines on stderr. Validation
  locations are plain JSON Pointers; the root is `""`.
- Per-record read/write errors, notes, and summaries start with
  `wing read:` or `wing write:`. Without an incoming schema field, write
  suggests passing a topic or preserving the schema field emitted by `read`.
- `-q` suppresses summaries, not warnings/errors. `-v` prints configuration
  provenance and fit changes. `SIGINT`/`SIGTERM` flush the current record and
  summary, then exit `130`; a closed downstream pipe is quiet.

## Fitting with `--fit`

Fitting applies schema-directed changes and validates the result:

| Rule | Behavior |
| --- | --- |
| `coerce` | Convert supported strings, numbers, and booleans to the schema's scalar type; preserve decimal text and never coerce `null`. |
| `defaults` | Add a declared default only for a missing property on an existing object. |
| `drop-extra` | Remove properties rejected by `additionalProperties: false`; this lossy rule is reported. |
| `wrap` | Wrap a scalar in an array when the array schema accepts it. |

`allOf` rules run sequentially. `anyOf` and `oneOf` branches are tried on
copies; an already-valid branch wins, otherwise a successful fitted branch
is committed. `const` and `enum` discriminators guide branch selection.
`wing write --fit --check -v` reports changes without writing records.

## Configuration

wing reads its own `wing.yaml` / `wing.properties`; it does not read `kite.yaml`.
Configuration-file search order is `--config FILE`, `$WING_CONFIG`, then the
first available of `./wing.yaml`, `./wing.properties`,
`$XDG_CONFIG_HOME/wing/wing.yaml`, `$XDG_CONFIG_HOME/wing/wing.properties`,
`~/.config/wing/wing.yaml`, and `~/.config/wing/wing.properties`.

### Multiple registries

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

Select a registry per command with `@NAME` (`wing ls @prod`), set the
environment default with `WING_TARGET`, persist the current selection with
`wing registry set NAME`, or create/test configuration interactively with
`wing registry init`. `wing registry list` shows configured registries.
Selection precedence is `@NAME`, `WING_TARGET`, the stored current registry,
then YAML `default:`. For a selected registry, command-line settings override
registry keys, environment, `defaults:`, and built-ins. Without a named
registry, command-line settings override environment, file defaults, and
built-ins.

| Config key | Environment | Purpose |
| --- | --- | --- |
| `schema.registry.url` | `SCHEMA_REGISTRY_URL` | Registry URL(s), comma-separated for connection failover. |
| `basic.auth.user.info` | `SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO` | Basic credentials as `key:secret`. |
| `bearer.auth.token` | `SCHEMA_REGISTRY_BEARER_AUTH_TOKEN` | Bearer authentication token. |
| `schema.registry.ssl.truststore.location` | `SCHEMA_REGISTRY_SSL_TRUSTSTORE_LOCATION` | PEM CA bundle. |
| `schema.registry.ssl.insecure` | `SCHEMA_REGISTRY_SSL_INSECURE` | Disable TLS verification; emits a warning. |
| `schema.registry.request.timeout.ms` | `SCHEMA_REGISTRY_REQUEST_TIMEOUT_MS` | Registry response timeout in milliseconds; default `10000`. |
| `schema.dir` | `WING_SCHEMA_DIR` | Offline schema cache directory. |
| `http.header.NAME` | — | Additional HTTP request header. |

`basic.auth.credentials.source` is accepted for Confluent config compatibility.
`HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` are honored. Kafka properties in
`.properties` files are ignored. Use `wing -v` to see configuration origins.
Protect credential files (mode `0600`) and do not commit secrets.

## Output streams and exit codes

- **stdout:** schemas/metadata requested from `get`, JSONL records from `read`
  and `write`, and the new GUID from `push`.
- **stderr:** diagnostics, warnings, fit explanations, summaries, and progress.
- **Exit `0`:** success; **`1`:** usage, configuration, Registry, or tool
  failure; **`2`:** invalid record/schema, failed check, or compatibility
  rejection; **`130`:** SIGINT/SIGTERM after flushing.

## Run Kafka and Schema Registry locally with Docker

The Quickstart needs Docker, `curl`, and a free local `9092` and `8081` port.
Kafka's internal listener is on the private Docker network so Schema Registry
can reach it; the external listener is advertised as `localhost:9092`.

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

Check or remove only these containers and their network:

```sh
docker ps --filter name=wing-local
docker logs wing-local-sr
docker rm -f wing-local-sr wing-local-kafka
docker network rm wing-local
```

## Troubleshooting

- **`wing write: line 1: no schema for this record; pass a topic (wing write TOPIC) or keep the schema field from wing read`:** provide a topic or retain the schema field from `wing read`.
- **`wing get: 'orders@3': use 'orders:3' to pin a version ('@NAME' selects a registry)`:** use `:` for a version; `@` is reserved for registry selection.
- **`Schema Registry at URL did not respond within 10s`:** the default response timeout is ten seconds; set `schema.registry.request.timeout.ms` or `SCHEMA_REGISTRY_REQUEST_TIMEOUT_MS`. This bounds the response wait, not DNS/TCP connect: Zig 0.16 `std.http` does not expose a usable connect timeout, so unreachable connects use the operating system timeout.
- **`wing push: not compatible with orders-value version 1 (BACKWARD)`:** the Registry rejected the candidate schema; inspect the following path/reason lines, then choose a compatible schema or intentionally change the subject's compatibility policy.
- **`connection refused by localhost:8081`:** start Schema Registry and confirm its host port and Kafka bootstrap listener match the Docker setup.

## Development and testing

```sh
zig fmt --check src build.zig
zig build
zig build test
scripts/cli-check.sh
scripts/completion-check.sh
scripts/jsts.sh
scripts/smoke-live.sh
scripts/e2e-docker.sh
scripts/differential.sh # optional Sourcemeta comparison
```

The default build is stripped `ReleaseSmall`. Releases are cut by pushing a
`v*` tag; the workflow cross-compiles Linux and macOS binaries and publishes
them with `SHA256SUMS`. See [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`TESTING.md`](TESTING.md) for contributor and test details.

## License

wing is licensed under the [Apache License 2.0](LICENSE).
