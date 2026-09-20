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
integration_port=shfmt
# setup-macports caches /opt/local, so restore the baseline explicitly.
if "$port_bin" installed "$integration_port" | grep -q '(active)'; then
	sudo -n "$port_bin" -N uninstall "$integration_port"
fi
test_root="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-integration.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
mkdir -p "$test_root/runtime" "$test_root/extracted"
ln -s "$BASH" "$test_root/runtime/bash"
binary_port="$test_root/runtime/port"
cat >"$binary_port" <<EOF
#!/bin/bash
case "\$1" in
install) exec "$port_bin" -b "\$@" ;;
*) exec "$port_bin" "\$@" ;;
esac
EOF
chmod 755 "$binary_port"
export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_DATA_HOME="$test_root/data"
export XDG_STATE_HOME="$test_root/state"
export PATH="$test_root/runtime:$port_prefix/bin:$PATH"
# A missing archive fails immediately rather than silently compiling in CI.
export BREW_PORT_PORT_BIN="$binary_port"
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
if "$port_bin" installed "$integration_port" | grep -q '(active)'; then fail "Dry-run installed $integration_port."; fi
"$cli" install "$brewfile"
"$port_bin" installed "$integration_port" | grep -q '(active)' || fail "$integration_port is not active in MacPorts."
"$port_prefix/bin/$integration_port" --version
"$HOME/.local/bin/rtk" --version
lipo "$port_prefix/bin/$integration_port" -verify_arch "$arch"
lipo "$HOME/.local/bin/rtk" -verify_arch "$arch"
# Exercise a real repeated MacPorts installation.
"$cli" install "$brewfile"
printf 'Real Brewfile installation passed on macOS %s (%s).\n' "$(sw_vers -productVersion)" "$arch"
