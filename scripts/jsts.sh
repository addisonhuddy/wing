#!/usr/bin/env bash
set -euo pipefail

readonly commit="5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}/wing"
suite_dir="${WING_JSTS_DIR:-}"

if [[ -z "$suite_dir" && -d /tmp/JSON-Schema-Test-Suite/.git ]]; then
  suite_dir=/tmp/JSON-Schema-Test-Suite
fi
if [[ -z "$suite_dir" ]]; then
  suite_dir="${cache_root}/JSON-Schema-Test-Suite"
fi

if [[ ! -d "$suite_dir/.git" ]]; then
  mkdir -p "$(dirname "$suite_dir")"
  git clone https://github.com/json-schema-org/JSON-Schema-Test-Suite.git "$suite_dir"
fi
if [[ "$(git -C "$suite_dir" rev-parse HEAD)" != "$commit" ]]; then
  git -C "$suite_dir" fetch --depth 1 origin "$commit"
  git -C "$suite_dir" checkout --detach "$commit"
fi

cd "$repo_root"
zig build -Doptimize=ReleaseSmall
binary="$repo_root/zig-out/bin/wing"
for draft in draft4 draft6 draft7 draft2019-09 draft2020-12; do
  "$binary" _jsts "$suite_dir/tests/$draft" --draft "$draft"
done
