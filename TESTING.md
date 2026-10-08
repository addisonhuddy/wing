# Testing

Use Zig 0.16.0 from the repository root:

```sh
zig fmt --check src build.zig
zig build
zig build test
scripts/cli-check.sh
scripts/completion-check.sh
scripts/jsts.sh
scripts/smoke-live.sh
```

`cli-check.sh` isolates HOME, XDG configuration, and its working directory.
`jsts.sh` fetches the pinned JSON-Schema-Test-Suite revision and requires every
required test in draft-04, draft-06, draft-07, 2019-09, and 2020-12 to pass.
Optional cases are informational. The suite, differential, and benchmark scripts drive
`wing-testkit` (`zig build testkit`), a separate harness binary; the release
`wing` binary carries no hidden test commands. `completion-check.sh` exercises the shell
completion scripts in installed bash, zsh, and fish shells.

For live checks, provide a reachable Schema Registry with
`SCHEMA_REGISTRY_URL`, a Kafka broker with `BOOTSTRAP_SERVERS`, and kite on
`PATH` or in `$KITE`. `smoke-live.sh` creates uniquely named topics and stores
its transcript under `~/wing-work/transcripts` by default.

`scripts/e2e-docker.sh` starts Kafka and Schema Registry on a private Docker
network. Host ports default to 9092 and 8081; set
`WING_E2E_KAFKA_PORT` and `WING_E2E_SCHEMA_REGISTRY_PORT` when those ports are
already occupied. It removes only its own `wing-e2e-*` containers/network and
never manages containers named `kafka` or `sr`.

`scripts/check-size.sh` builds the portable x86_64-linux ReleaseSmall binary,
reports its size, and compares it with the latest release asset when present.
`scripts/differential.sh` is best-effort and reports when the Sourcemeta oracle
is unavailable.
