#!/usr/bin/env bash
# Install a checksum-published GitHub release asset. Called only by reviewed maps.
set -euo pipefail

if [ "$#" -ne 4 ] && [ "$#" -ne 5 ] && [ "$#" -ne 6 ]; then
	echo 'Usage: install-release-binary.sh ID OWNER/REPO ASSET BINARY' >&2
	echo '       install-release-binary.sh ID OWNER/REPO ASSET package DESTINATION' >&2
	echo '       install-release-binary.sh ID OWNER/REPO ASSET bundle DESTINATION BINARY' >&2
	exit 1
fi
fallback_id="$1"
repository="$2"
asset_template="$3"
delivery=binary
if [ "$#" -eq 4 ]; then
	binary_name="$4"
	destination="$HOME/.local/bin/$binary_name"
elif [ "$#" -eq 5 ]; then
	delivery=package
	destination="$5"
	binary_name="$(basename "$destination")"
else
	delivery=bundle
	destination="$5"
	binary_name="$6"
fi

jq_bin="${BREW_PORT_JQ_BIN:-}"
if [ -z "$jq_bin" ]; then
	[ -x /opt/local/bin/jq ] && jq_bin=/opt/local/bin/jq || jq_bin=/usr/bin/jq
fi
[ -x "$jq_bin" ] || {
	echo 'A usable jq is required for fallback release metadata.' >&2
	exit 1
}
curl_bin="${BREW_PORT_CURL_BIN:-curl}"
github_token="${GITHUB_TOKEN:-}"
sudo_bin="${BREW_PORT_SUDO_BIN:-sudo}"
installer_bin="${BREW_PORT_INSTALLER_BIN:-/usr/sbin/installer}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
state_dir="$state_root/brew-port"
state_file="$state_dir/fallbacks.tsv"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-release.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
valid_sha() { [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]; }
state_value() { [ -f "$state_file" ] && awk -F '\t' -v key="$fallback_id" -v col="$1" '$1 == key { print $col; exit }' "$state_file"; }

release_json="$tmp_dir/release.json"
api_curl_args=(--fail --location --proto '=https' --tlsv1.2 --silent --show-error)
# CI supplies its short-lived token to avoid unauthenticated API rate limits.
if [ -n "$github_token" ]; then api_curl_args+=(--header "Authorization: Bearer $github_token"); fi
if ! "$curl_bin" "${api_curl_args[@]}" --output "$release_json" "https://api.github.com/repos/$repository/releases/latest"; then
	existing_tag="$(state_value 2 || true)"
	existing_hash="$(state_value 6 || true)"
	if [ -n "$existing_tag" ] && [ -x "$destination" ] && valid_sha "$existing_hash" && [ "$(sha256 "$destination")" = "$existing_hash" ]; then
		echo "Warning: could not check the latest $fallback_id release; keeping verified $existing_tag."
		exit 0
	fi
	echo "Could not determine the latest verified $fallback_id release." >&2
	exit 1
fi
tag="$("$jq_bin" -er '.tag_name' "$release_json")"
version="${tag#v}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || {
	echo "Refusing unsafe $fallback_id release tag: $tag" >&2
	exit 1
}
asset_name="${asset_template//\{version\}/$version}"
# shellcheck disable=SC2016 # jq programs intentionally use literal $name.
asset_url="$("$jq_bin" -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"
# shellcheck disable=SC2016 # jq programs intentionally use literal $name.
asset_hash="$("$jq_bin" -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .digest | select(startswith("sha256:")) | ltrimstr("sha256:")' "$release_json")"
valid_sha "$asset_hash" || {
	echo "Release metadata has no SHA-256 digest for $asset_name." >&2
	exit 1
}

old_tag="$(state_value 2 || true)"
old_name="$(state_value 3 || true)"
old_hash="$(state_value 5 || true)"
old_binary="$(state_value 6 || true)"
if [ "$old_tag" = "$tag" ] && [ -n "$old_tag" ]; then
	[ "$old_name" = "$asset_name" ] && [ "$old_hash" = "$asset_hash" ] || {
		echo "Refusing $fallback_id release $tag: its published asset digest changed." >&2
		exit 1
	}
	if [ -x "$destination" ] && valid_sha "$old_binary" && [ "$(sha256 "$destination")" = "$old_binary" ]; then
		echo "$fallback_id release $tag is already installed and verified."
		exit 0
	fi
fi
if [ "$delivery" = package ] && [ -x "$destination" ] && { [ "$("$destination" version 2>/dev/null || true)" = "$version" ] || [ "$("$destination" version 2>/dev/null || true)" = "$tag" ]; }; then
	echo "$fallback_id release $tag is already available at $destination."
	exit 0
fi

archive="$tmp_dir/$asset_name"
echo "Installing latest $fallback_id release $tag..."
"$curl_bin" --fail --location --proto '=https' --tlsv1.2 --silent --show-error --output "$archive" "$asset_url"
[ "$(sha256 "$archive")" = "$asset_hash" ] || {
	echo "Checksum verification failed for $fallback_id release $tag." >&2
	exit 1
}
if [ "$delivery" = binary ]; then
	extract="$tmp_dir/extract"
	mkdir -p "$extract"
	tar -xf "$archive" -C "$extract"
	source_binary="$(find "$extract" -type f -name "$binary_name" -perm -111 -print | sed -n '1p')"
	[ -n "$source_binary" ] || {
		echo "Release archive for $fallback_id did not contain executable $binary_name." >&2
		exit 1
	}
	mkdir -p "$(dirname "$destination")"
	install -m 755 "$source_binary" "$destination"
elif [ "$delivery" = bundle ]; then
	extract="$tmp_dir/extract"
	mkdir -p "$extract"
	tar -xf "$archive" -C "$extract"
	source_binary="$(find "$extract" -type f -path "*/bin/$binary_name" -perm -111 -print | sed -n '1p')"
	[ -n "$source_binary" ] || {
		echo "Release archive for $fallback_id did not contain executable bin/$binary_name." >&2
		exit 1
	}
	source_root="$(dirname "$(dirname "$source_binary")")"
	bundle_root="${XDG_DATA_HOME:-$HOME/.local/share}/brew-port/fallbacks/$fallback_id"
	mkdir -p "$bundle_root" "$(dirname "$destination")"
	staged_bundle="$bundle_root/.${tag}.$$"
	rm -rf "${staged_bundle:?}"
	mv "$source_root" "$staged_bundle"
	rm -rf "${bundle_root:?}/${tag:?}"
	mv "$staged_bundle" "$bundle_root/$tag"
	ln -sfn "$bundle_root/$tag/bin/$binary_name" "$destination"
else
	"$sudo_bin" -n "$installer_bin" -pkg "$archive" -target /
	[ -x "$destination" ] || {
		echo "Package for $fallback_id did not install executable $destination." >&2
		exit 1
	}
fi
binary_hash="$(sha256 "$destination")"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
temp_state="$state_dir/fallbacks.tsv.$$"
[ -f "$state_file" ] && awk -F '\t' -v key="$fallback_id" '$1 != key' "$state_file" >"$temp_state" || : >"$temp_state"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$fallback_id" "$tag" "$asset_name" "$asset_url" "$asset_hash" "$binary_hash" >>"$temp_state"
mv "$temp_state" "$state_file"
echo "Installed $fallback_id release $tag."
