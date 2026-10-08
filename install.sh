#!/bin/sh
# Install the latest wing release, verifying its SHA256SUMS entry.
#
#   curl -fsSL https://raw.githubusercontent.com/addisonhuddy/wing/main/install.sh | sh
#   curl -fsSL ... | sh -s -- --bin-dir ~/.local/bin --version v0.1.0
set -eu

REPO=addisonhuddy/wing
bin_dir=${WING_BIN_DIR:-/usr/local/bin}
version=${WING_VERSION:-latest}

fail() { echo "wing: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Download a wing release binary and put it on your PATH.

Options:
  -b, --bin-dir DIR    Install into DIR (default: \$WING_BIN_DIR or /usr/local/bin).
  -v, --version VER    Release tag to install (default: \$WING_VERSION or latest).
  -h, --help           Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bin-dir) [ $# -ge 2 ] || fail "$1 requires a value"; bin_dir=$2; shift 2 ;;
        -v|--version) [ $# -ge 2 ] || fail "$1 requires a value"; version=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option '$1' (try --help)" ;;
    esac
done

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) fail "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
esac

asset=wing-$os-$arch
if [ "$version" = latest ]; then
    base=https://github.com/$REPO/releases/latest/download
else
    base=https://github.com/$REPO/releases/download/$version
fi
url=$base/$asset
sums_url=$base/SHA256SUMS

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

download_failed() {
    fail "failed to download $1; check https://github.com/$REPO/releases (pin one with --version vX.Y.Z)"
}

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$1" -O "$2"
    else
        fail "curl or wget is required"
    fi
}

echo "wing: downloading $url" >&2
fetch "$url" "$tmp/wing" || download_failed "$url"
fetch "$sums_url" "$tmp/SHA256SUMS" || download_failed "$sums_url"

expected=$(awk -v a="$asset" '$2 ~ "(^|/)" a "$" {print $1}' "$tmp/SHA256SUMS")
[ -n "$expected" ] || fail "no checksum for $asset in SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/wing" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$tmp/wing" | awk '{print $1}')
else
    fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum mismatch for $asset (expected $expected, got $actual)"

run_install() {
    if [ -d "$bin_dir" ] && [ -w "$bin_dir" ]; then
        install -m755 "$tmp/wing" "$bin_dir/wing"
    elif [ ! -e "$bin_dir" ] && [ -w "$(dirname "$bin_dir")" ]; then
        mkdir -p "$bin_dir" && install -m755 "$tmp/wing" "$bin_dir/wing"
    elif command -v sudo >/dev/null 2>&1; then
        echo "wing: $bin_dir is not writable; using sudo" >&2
        sudo mkdir -p "$bin_dir" && sudo install -m755 "$tmp/wing" "$bin_dir/wing"
    else
        fail "$bin_dir is not writable and sudo is unavailable; rerun with --bin-dir DIR"
    fi
}
run_install

echo "wing: installed $("$bin_dir/wing" --version) to $bin_dir/wing" >&2
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
        echo "wing: $bin_dir is not on your PATH. Add it with:" >&2
        case "${SHELL:-}" in
            */fish) echo "  fish_add_path $bin_dir" >&2 ;;
            *) echo "  export PATH=\"$bin_dir:\$PATH\"" >&2 ;;
        esac
        ;;
esac
