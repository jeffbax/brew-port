#!/bin/sh
set -eu

version=0.77.0
archive_url="https://github.com/max-sixty/worktrunk/archive/refs/tags/v${version}.tar.gz"
archive_sha256=8160f0afe8287f3aad52e6ea1de7b0cfed01ad6d3d60ecdb952db6836775eda2
port_bin="${MACPORTS_BREWFILE_PORT_BIN:-/opt/local/bin/port}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/worktrunk.XXXXXX")"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup 0 HUP INT TERM

if ! command -v cargo >/dev/null 2>&1; then
  sudo "$port_bin" install cargo
fi

archive="$tmp_dir/worktrunk.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$archive_url"
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$tmp_dir"

install -d "$HOME/.local"
cargo install --locked --path "$tmp_dir/worktrunk-$version" --root "$HOME/.local"
