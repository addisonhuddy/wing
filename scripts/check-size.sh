#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "$#" -gt 0 ]; then
    BIN=$1
else
    zig build -Dtarget=x86_64-linux -p "$TMP/portable"
    BIN="$TMP/portable/bin/wing"
fi
[ -f "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 1; }
size=$(stat -c%s "$BIN" 2>/dev/null || stat -f%z "$BIN")
echo "$BIN (x86_64-linux ReleaseSmall): $size bytes"

url=https://github.com/addisonhuddy/wing/releases/latest/download/wing-linux-x86_64
code=$(curl -sSL --max-time 30 -o "$TMP/latest" -w '%{http_code}' "$url") || {
    echo "failed to check latest release size at $url" >&2
    exit 1
}
if [ "$code" = 404 ]; then
    echo "skip: no latest wing-linux-x86_64 release asset"
    exit 0
fi
[ "$code" = 200 ] || { echo "failed to fetch latest asset (HTTP $code)" >&2; exit 1; }

latest=$(stat -c%s "$TMP/latest" 2>/dev/null || stat -f%z "$TMP/latest")
limit=$((latest * 3 / 2))
echo "latest release: $latest bytes; 150% limit: $limit bytes"
if (( size * 2 > latest * 3 )); then
    echo "FAIL: $size bytes exceeds 150% of latest release ($latest bytes)" >&2
    exit 1
fi
echo "ok: within 150% of latest release"
