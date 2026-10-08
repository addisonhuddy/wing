#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly binary="${WING_TESTKIT:-${repo_root}/zig-out/bin/wing-testkit}"
readonly input="${1:-/tmp/bench.jsonl}"
readonly prepared_input="$(mktemp "${TMPDIR:-/tmp}/wing-validator-benchmark.XXXXXX")"
trap 'rm -f "$prepared_input"' EXIT

if [[ ! -r "$input" ]]; then
  printf 'benchmark input is not readable: %s\n' "$input" >&2
  exit 1
fi

python3 - "$input" "$prepared_input" <<'PY'
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as records, open(destination, "w", encoding="utf-8") as output:
    for line in records:
        record = json.loads(line)
        record["amount"] = round(record["amount"], 2)
        output.write(json.dumps(record, separators=(",", ":"), allow_nan=False) + "\n")
PY

readonly records="$(wc -l < "$prepared_input" | tr -d ' ')"

run_benchmark() {
  local name="$1"
  local schema="$2"
  local start_ns
  local end_ns
  local elapsed_ns

  start_ns="$(date +%s%N)"
  "$binary" validate "$schema" --draft draft7 < "$prepared_input" > /dev/null
  end_ns="$(date +%s%N)"
  elapsed_ns="$((end_ns - start_ns))"
  python3 - "$name" "$records" "$elapsed_ns" <<'PY'
import sys

name = sys.argv[1]
records = int(sys.argv[2])
elapsed_ns = int(sys.argv[3])
elapsed_seconds = elapsed_ns / 1_000_000_000
print(f"{name}: {records} valid records in {elapsed_seconds:.3f}s ({records / elapsed_seconds:.0f} records/s)")
PY
}

run_benchmark object "${repo_root}/scripts/validator-benchmark-object-schema.json"
run_benchmark realistic "${repo_root}/scripts/validator-benchmark-schema.json"
