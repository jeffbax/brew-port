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
mkdir "$tmp_dir/bootstrap" "$tmp_dir/bootstrap-bin"
cp "$repo_dir/install.sh" "$tmp_dir/bootstrap/install.sh"
chmod +x "$tmp_dir/bootstrap/install.sh"
cat >"$tmp_dir/bootstrap-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${MOCK_CURL_FAIL:-0}" = 1 ] && exit 22
output=''
url=''
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o)
		output="$2"
		shift 2
		;;
	*)
		url="$1"
		shift
		;;
	esac
done
[ -n "$output" ] || exit 2
case "$url" in
*/SHA256SUMS) cp "$MOCK_MANIFEST" "$output" ;;
*/brew-port-*.tar.gz) cp "$MOCK_ARCHIVE" "$output" ;;
*) exit 2 ;;
esac
EOF
chmod +x "$tmp_dir/bootstrap-bin/curl"
bootstrap_prefix="$tmp_dir/bootstrap prefix"
PATH="$tmp_dir/bootstrap-bin:$PATH" MOCK_MANIFEST="$tmp_dir/download/SHA256SUMS" MOCK_ARCHIVE="$tmp_dir/download/brew-port-$version.tar.gz" bash "$tmp_dir/bootstrap/install.sh" --prefix "$bootstrap_prefix" >/dev/null
[ "$("$bootstrap_prefix/bin/brew-port" version)" = "brew-port $version" ] || fail 'Bootstrap installer did not forward --prefix.'
mkdir "$tmp_dir/piped-bootstrap"
cp "$tmp_dir/download/SHA256SUMS" "$tmp_dir/piped-bootstrap/SHA256SUMS"
piped_prefix="$tmp_dir/piped bootstrap prefix"
(
	cd "$tmp_dir/piped-bootstrap"
	PATH="$tmp_dir/bootstrap-bin:$PATH" MOCK_MANIFEST="$tmp_dir/download/SHA256SUMS" MOCK_ARCHIVE="$tmp_dir/download/brew-port-$version.tar.gz" bash -s -- --prefix "$piped_prefix" <"$tmp_dir/bootstrap/install.sh" >/dev/null
)
[ "$("$piped_prefix/bin/brew-port" version)" = "brew-port $version" ] || fail 'Piped bootstrap treated its caller directory as a release.'
printf '%s\n' 'not a checksum manifest' >"$tmp_dir/bad-manifest"
if PATH="$tmp_dir/bootstrap-bin:$PATH" MOCK_MANIFEST="$tmp_dir/bad-manifest" MOCK_ARCHIVE="$tmp_dir/download/brew-port-$version.tar.gz" bash "$tmp_dir/bootstrap/install.sh" --prefix "$tmp_dir/malformed" >/dev/null 2>&1; then
	fail 'Malformed bootstrap manifest was accepted.'
fi
[ ! -e "$tmp_dir/malformed" ] || fail 'Malformed bootstrap manifest wrote to the installation prefix.'
cp "$tmp_dir/download/brew-port-$version.tar.gz" "$tmp_dir/corrupt-download.tar.gz"
printf '\ncorrupt\n' >>"$tmp_dir/corrupt-download.tar.gz"
if PATH="$tmp_dir/bootstrap-bin:$PATH" MOCK_MANIFEST="$tmp_dir/download/SHA256SUMS" MOCK_ARCHIVE="$tmp_dir/corrupt-download.tar.gz" bash "$tmp_dir/bootstrap/install.sh" --prefix "$tmp_dir/checksum-failure" >/dev/null 2>&1; then
	fail 'Bootstrap checksum failure was accepted.'
fi
[ ! -e "$tmp_dir/checksum-failure" ] || fail 'Checksum failure wrote to the installation prefix.'
if PATH="$tmp_dir/bootstrap-bin:$PATH" MOCK_CURL_FAIL=1 MOCK_MANIFEST="$tmp_dir/download/SHA256SUMS" MOCK_ARCHIVE="$tmp_dir/download/brew-port-$version.tar.gz" bash "$tmp_dir/bootstrap/install.sh" --prefix "$tmp_dir/download-failure" >/dev/null 2>&1; then
	fail 'Bootstrap download failure was accepted.'
fi
[ ! -e "$tmp_dir/download-failure" ] || fail 'Download failure wrote to the installation prefix.'
mkdir "$tmp_dir/extracted"
tar -xzf "$tmp_dir/download/brew-port-$version.tar.gz" -C "$tmp_dir/extracted"
release_dir="$tmp_dir/extracted/brew-port-$version"
[ -f "$release_dir/README.md" ] || fail 'Release archive omitted the README.'
grep -Fq 'https://github.com/jeffbax/brew-port/blob/main/docs/installation.md' "$release_dir/README.md" || fail 'Packaged README does not link to repository documentation.'
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
printf '%s\n' '#!/bin/bash' 'if [ "$1" = version ]; then exit 0; fi' 'if [ "$1 ${2:-} ${3:-}" = "-q echo active" ]; then exit 0; fi' 'exit 99' >"$tmp_dir/mocks/port"
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
for file in install.sh scripts/bump-version.sh scripts/package-release.sh scripts/release-version.sh tests/bump-version.sh tests/release-version.sh tests/release.sh; do /bin/bash -n "$repo_dir/$file"; done
shfmt -ln bash -d "$repo_dir/install.sh" "$repo_dir/scripts/bump-version.sh" "$repo_dir/scripts/package-release.sh" "$repo_dir/scripts/release-version.sh" "$repo_dir/tests/bump-version.sh" "$repo_dir/tests/release-version.sh" "$repo_dir/tests/release.sh"
shellcheck -s bash "$repo_dir/install.sh" "$repo_dir/scripts/bump-version.sh" "$repo_dir/scripts/package-release.sh" "$repo_dir/scripts/release-version.sh" "$repo_dir/tests/bump-version.sh" "$repo_dir/tests/release-version.sh" "$repo_dir/tests/release.sh"
printf '%s\n' 'Release installation checks passed.'
