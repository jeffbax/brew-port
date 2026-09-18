#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-release-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
mkdir "$tmp_dir/bash-runtime"
ln -s "$BASH" "$tmp_dir/bash-runtime/bash"
export PATH="$tmp_dir/bash-runtime:$PATH"
export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/config"
export XDG_DATA_HOME="$tmp_dir/data"
export XDG_STATE_HOME="$tmp_dir/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/brew-port" "$XDG_STATE_HOME/brew-port"
printf '%s\n' '{"version":1,"mappings":[]}' >"$XDG_CONFIG_HOME/brew-port/mappings.json"
inventory='{"version":1,"fallbacks":[{"kind":"brew","token":"rtk"}]}'
printf '%s\n' "$inventory" >"$XDG_STATE_HOME/brew-port/requested-fallbacks.json"
printf '%s\n' '# shell startup sentinel' >"$HOME/.zshrc"
fail() {
	printf '%s\n' "$*" >&2
	exit 1
}
version="$("$repo_dir/bin/brew-port" version)"
version="${version#brew-port }"
bash "$repo_dir/scripts/package-release.sh" "$tmp_dir/download" >/dev/null
(cd "$tmp_dir/download" && shasum -a 256 -c SHA256SUMS >/dev/null)
mkdir "$tmp_dir/extracted"
tar -xzf "$tmp_dir/download/brew-port-$version.tar.gz" -C "$tmp_dir/extracted"
release_dir="$tmp_dir/extracted/brew-port-$version"
mkdir "$tmp_dir/offline"
for command_name in sudo curl port jq; do
	# Literal mock body records any forbidden installer dependency.
	# shellcheck disable=SC2016
	printf '%s\n' '#!/bin/bash' 'echo "$0" >> "$OFFLINE_LOG"; exit 99' >"$tmp_dir/offline/$command_name"
	chmod +x "$tmp_dir/offline/$command_name"
done
OFFLINE_LOG="$tmp_dir/offline.log" PATH="$tmp_dir/offline:$PATH" bash "$release_dir/install.sh" >/dev/null
[ ! -e "$tmp_dir/offline.log" ] || fail 'Installer attempted a network, privilege, or package prerequisite.'
prefix="$HOME/.local"
cli="$prefix/bin/brew-port"
[ "$("$cli" version)" = "brew-port $version" ] || fail 'Installed CLI version mismatch.'
doctor_output="$("$cli" doctor)"
[[ "$doctor_output" == *Architecture:* ]] || fail 'Packaged doctor did not load runtime modules.'
"$cli" map validate >/dev/null
"$cli" completion bash | grep -Fq 'complete -F _brew_port brew-port'
"$cli" completion install fish >/dev/null
mkdir "$tmp_dir/mocks"
# These are literal mock-script bodies, not variables of this test process.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac' >"$tmp_dir/mocks/uname"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' '[ "$1" = version ] || exit 99' >"$tmp_dir/mocks/port"
printf '%s\n' '#!/bin/bash' 'exit 99' >"$tmp_dir/mocks/sudo"
chmod +x "$tmp_dir/mocks/"*
printf '%s\n' 'brew "git"' >"$tmp_dir/Brewfile"
dry_run="$(BREW_PORT_UNAME_BIN="$tmp_dir/mocks/uname" BREW_PORT_PORT_BIN="$tmp_dir/mocks/port" BREW_PORT_SUDO_BIN="$tmp_dir/mocks/sudo" "$cli" install --dry-run "$tmp_dir/Brewfile")"
[[ "$dry_run" == *git* ]] || fail 'Packaged dry-run did not translate the Brewfile.'
bash "$release_dir/install.sh" >/dev/null
custom_prefix="$tmp_dir/custom prefix"
bash "$release_dir/install.sh" --prefix "$custom_prefix" >/dev/null
[ "$("$custom_prefix/bin/brew-port" version)" = "brew-port $version" ] || fail 'Custom prefix failed.'
# A second immutable version exercises upgrading and rollback without network access.
next="$tmp_dir/next"
cp -R "$release_dir" "$next"
sed -i '' "s/^BP_VERSION=.*/BP_VERSION=999.0.0-rc.1/" "$next/bin/brew-port"
(
	cd "$next"
	# SHA256SUMS is excluded from the inputs.
	# shellcheck disable=SC2094
	find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done >SHA256SUMS
)
bash "$next/install.sh" >/dev/null
[ "$("$cli" version)" = 'brew-port 999.0.0-rc.1' ] || fail 'Upgrade did not switch versions.'
[ -d "$prefix/lib/brew-port/versions/$version" ] || fail 'Upgrade removed the previous version.'
bash "$release_dir/install.sh" >/dev/null
[ "$("$cli" version)" = "brew-port $version" ] || fail 'Rollback failed.'
[ "$(cat "$XDG_STATE_HOME/brew-port/requested-fallbacks.json")" = "$inventory" ] || fail 'Inventory changed.'
[ "$(cat "$HOME/.zshrc")" = '# shell startup sentinel' ] || fail 'Shell startup configuration changed.'
[ "$(cat "$XDG_CONFIG_HOME/brew-port/mappings.json")" = '{"version":1,"mappings":[]}' ] || fail 'Mappings changed.'
printf '\n# modified\n' >>"$prefix/lib/brew-port/versions/$version/install.sh"
if bash "$release_dir/install.sh" >/dev/null 2>&1; then fail 'Changed installed version was overwritten.'; fi
mkdir -p "$tmp_dir/conflict/bin"
printf '%s\n' 'unrelated' >"$tmp_dir/conflict/bin/brew-port"
if bash "$release_dir/install.sh" --prefix "$tmp_dir/conflict" >/dev/null 2>&1; then fail 'Unrelated executable was overwritten.'; fi
[ "$(cat "$tmp_dir/conflict/bin/brew-port")" = unrelated ] || fail 'Conflict changed.'
printf '\ncorrupt\n' >>"$release_dir/maps/default.json"
if bash "$release_dir/install.sh" --prefix "$tmp_dir/corrupt" >/dev/null 2>&1; then fail 'Corrupt release was installed.'; fi
[ ! -e "$tmp_dir/corrupt" ] || fail 'Corrupt release wrote to the installation prefix.'
printf '\ncorrupt\n' >>"$tmp_dir/download/brew-port-$version.tar.gz"
if (cd "$tmp_dir/download" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then fail 'Corrupt download passed verification.'; fi
if RELEASE_TAG=v9.9.9 bash "$repo_dir/scripts/package-release.sh" "$tmp_dir/wrong-tag" >/dev/null 2>&1; then fail 'Mismatched tag was accepted.'; fi
for file in install.sh scripts/package-release.sh tests/release.sh; do /bin/bash -n "$repo_dir/$file"; done
shfmt -ln bash -d "$repo_dir/install.sh" "$repo_dir/scripts/package-release.sh" "$repo_dir/tests/release.sh"
shellcheck -s bash "$repo_dir/install.sh" "$repo_dir/scripts/package-release.sh" "$repo_dir/tests/release.sh"
printf '%s\n' 'Release installation checks passed.'
