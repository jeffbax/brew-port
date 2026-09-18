#!/bin/sh
set -eu

version=0.49.0
archive_url="https://github.com/rtk-ai/rtk/archive/refs/tags/v${version}.tar.gz"
archive_sha256=74b226ab00b8698d5084402893c76d93189493bd332b99d0b1e681d1ef860eb8
port_bin="${MACPORTS_BREWFILE_PORT_BIN:-/opt/local/bin/port}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rtk.XXXXXX")"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup 0 HUP INT TERM

if ! command -v cargo >/dev/null 2>&1; then
  sudo "$port_bin" install cargo
fi

archive="$tmp_dir/rtk.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$archive_url"
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$tmp_dir"

install -d "$HOME/.local"
cargo install --locked --path "$tmp_dir/rtk-$version" --root "$HOME/.local"
