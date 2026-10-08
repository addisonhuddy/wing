#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly binary="${WING_BIN:-${repo_root}/zig-out/bin/wing}"
readonly schema_file="${repo_root}/scripts/validator-benchmark-schema.json"
readonly records="${1:-100000}"

start_ns="$(date +%s%N)"
python3 - "$records" <<'PY' | "$binary" _validate "$schema_file" --draft draft7 >/dev/null
import json
import sys

count = int(sys.argv[1])
payload = "x" * 780
for index in range(count):
    record = {
        "id": index,
        "createdAt": "2026-10-01T12:00:00Z",
        "amount": 12.34,
        "customer": {"id": f"C{index % 10000000:07d}", "country": "US"},
        "tags": ["orders", "validated"],
        "payload": payload,
    }
    print(json.dumps(record, separators=(",", ":")))
PY
end_ns="$(date +%s%N)"
elapsed_ns="$((end_ns - start_ns))"
python3 - "$records" "$elapsed_ns" <<'PY'
import sys

records = int(sys.argv[1])
elapsed_ns = int(sys.argv[2])
elapsed_seconds = elapsed_ns / 1_000_000_000
print(f"{records} records in {elapsed_seconds:.3f}s ({records / elapsed_seconds:.0f} records/s)")
PY
