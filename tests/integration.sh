#!/usr/bin/env bash
# Real package smoke test for disposable macOS runners, not a mocked test.
set -euo pipefail
repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
fail() {
	printf '%s\n' "$*" >&2
	exit 1
}
[ "$(uname -s)" = Darwin ] || fail 'Integration testing requires macOS.'
arch="$(uname -m)"
case "$arch" in arm64 | x86_64) ;; *) fail "Unsupported architecture: $arch" ;; esac
port_bin="${BREW_PORT_PORT_BIN:-/opt/local/bin/port}"
[ -x "$port_bin" ] || fail 'Integration testing requires a real MacPorts installation.'
port_prefix="$(dirname "$(dirname "$port_bin")")"
jq_bin="$port_prefix/bin/jq"
[ -x "$jq_bin" ] || fail 'Install MacPorts jq before running the integration test.'
sudo -n -v || fail 'Integration testing requires noninteractive sudo on a disposable runner.'
if "$port_bin" installed tree | grep -q '(active)'; then
	fail 'Expected a fresh runner without the MacPorts tree port installed.'
fi
test_root="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-integration.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
mkdir -p "$test_root/runtime" "$test_root/extracted"
ln -s "$BASH" "$test_root/runtime/bash"
export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_DATA_HOME="$test_root/data"
export XDG_STATE_HOME="$test_root/state"
export PATH="$test_root/runtime:$port_prefix/bin:$PATH"
export BREW_PORT_PORT_BIN="$port_bin"
export BREW_PORT_JQ_BIN="$jq_bin"
version="$("$repo_dir/bin/brew-port" version)"
version="${version#brew-port }"
bash "$repo_dir/scripts/package-release.sh" "$test_root/download"
(cd "$test_root/download" && shasum -a 256 -c SHA256SUMS)
tar -xzf "$test_root/download/brew-port-$version.tar.gz" -C "$test_root/extracted"
bash "$test_root/extracted/brew-port-$version/install.sh"
cli="$HOME/.local/bin/brew-port"
brewfile="$repo_dir/tests/fixtures/smoke.Brewfile"
"$cli" doctor
"$cli" install --dry-run "$brewfile"
[ ! -e "$XDG_STATE_HOME/brew-port/requested-fallbacks.json" ] || fail 'Dry-run created an inventory.'
[ ! -e "$HOME/.local/bin/rtk" ] || fail 'Dry-run installed rtk.'
if "$port_bin" installed tree | grep -q '(active)'; then fail 'Dry-run installed tree.'; fi
"$cli" install "$brewfile"
"$port_bin" installed tree | grep -q '(active)' || fail 'tree is not active in MacPorts.'
"$port_prefix/bin/tree" --version
"$HOME/.local/bin/rtk" --version
lipo "$port_prefix/bin/tree" -verify_arch "$arch"
lipo "$HOME/.local/bin/rtk" -verify_arch "$arch"
# Exercise real repeated installation and refresh of only the requested fallback.
"$cli" install "$brewfile"
"$cli" refresh-fallbacks
"$jq_bin" -e '.version == 1 and (.fallbacks | length) == 1 and .fallbacks[0] == {kind: "brew", token: "rtk"}' "$XDG_STATE_HOME/brew-port/requested-fallbacks.json" >/dev/null
"$HOME/.local/bin/rtk" --version
printf 'Real Brewfile installation passed on macOS %s (%s).\n' "$(sw_vers -productVersion)" "$arch"
