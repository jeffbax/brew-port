#!/bin/sh
set -eu

[ "$#" -eq 4 ] || {
  printf '%s\n' 'Usage: install-release-binary.sh FALLBACK-ID REPOSITORY ASSET-NAME BINARY-NAME' >&2
  exit 1
}

fallback_id="$1"
repository="$2"
asset_name="$3"
binary_name="$4"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
state_dir="$state_root/macports-brewfile"
state_file="$state_dir/fallbacks.tsv"
install_dir="$HOME/.local/bin"
destination="$install_dir/$binary_name"
curl_bin="${MACPORTS_BREWFILE_CURL_BIN:-curl}"
plutil_bin="${MACPORTS_BREWFILE_PLUTIL_BIN:-/usr/bin/plutil}"
shasum_bin="${MACPORTS_BREWFILE_SHASUM_BIN:-shasum}"
tar_bin="${MACPORTS_BREWFILE_TAR_BIN:-tar}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/macports-brewfile-release.XXXXXX")"
staging_file=
state_tmp=

cleanup() {
  if [ -n "$staging_file" ]; then
    rm -f "$staging_file"
  fi
  if [ -n "$state_tmp" ]; then
    rm -f "$state_tmp"
  fi
  rm -rf "$tmp_dir"
}
trap cleanup 0 HUP INT TERM

log() {
  printf '%s\n' "$*"
}

state_field() {
  field="$1"
  awk -F '\t' -v fallback_id="$fallback_id" -v field="$field" '
    $1 == fallback_id {
      print $field
      exit
    }
  ' "$state_file"
}

is_sha256() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[[:xdigit:]]{64}$'
}

sha256_file() {
  "$shasum_bin" -a 256 "$1" | awk '{print $1}'
}

release_tag=
asset_url=
asset_sha256=

fetch_latest_release() {
  release_json="$tmp_dir/release.json"
  api_url="https://api.github.com/repos/$repository/releases/latest"

  if ! "$curl_bin" --fail --location --proto '=https' --tlsv1.2 --silent --show-error --output "$release_json" "$api_url"; then
    return 1
  fi

  release_tag="$("$plutil_bin" -extract tag_name raw "$release_json")" || return 1
  [ -n "$release_tag" ] || return 1
  asset_count="$("$plutil_bin" -extract assets raw "$release_json")" || return 1
  case "$asset_count" in
  '' | *[!0-9]*) return 1 ;;
  esac

  asset_index=0
  while [ "$asset_index" -lt "$asset_count" ]; do
    candidate_name="$("$plutil_bin" -extract "assets.$asset_index.name" raw "$release_json")" || return 1
    if [ "$candidate_name" = "$asset_name" ]; then
      asset_url="$("$plutil_bin" -extract "assets.$asset_index.browser_download_url" raw "$release_json")" || return 1
      case "$asset_url" in
      https://*) ;;
      *) return 1 ;;
      esac
      digest="$("$plutil_bin" -extract "assets.$asset_index.digest" raw "$release_json")" || return 1
      case "$digest" in
      sha256:*) asset_sha256="${digest#sha256:}" ;;
      *) return 1 ;;
      esac
      is_sha256 "$asset_sha256" || return 1
      return 0
    fi
    asset_index=$((asset_index + 1))
  done

  return 1
}

state_tag=
state_asset_name=
state_asset_sha256=
state_binary_sha256=
if [ -f "$state_file" ]; then
  state_tag="$(state_field 2)"
  state_asset_name="$(state_field 3)"
  state_asset_sha256="$(state_field 5)"
  state_binary_sha256="$(state_field 6)"
fi

if ! fetch_latest_release; then
  if [ -n "$state_tag" ] && [ -x "$destination" ] && is_sha256 "$state_binary_sha256" && [ "$(sha256_file "$destination")" = "$state_binary_sha256" ]; then
    log "Warning: could not check the latest $fallback_id release; keeping verified $state_tag."
    exit 0
  fi
  printf '%s\n' "Could not determine the latest verified $fallback_id release." >&2
  exit 1
fi

if [ "$state_tag" = "$release_tag" ] && [ -n "$state_tag" ]; then
  if [ "$state_asset_name" != "$asset_name" ] || [ "$state_asset_sha256" != "$asset_sha256" ]; then
    printf '%s\n' "Refusing $fallback_id release $release_tag: its published asset digest changed." >&2
    exit 1
  fi

  if [ -x "$destination" ] && is_sha256 "$state_binary_sha256" && [ "$(sha256_file "$destination")" = "$state_binary_sha256" ]; then
    log "$fallback_id release $release_tag is already installed and verified."
    exit 0
  fi
fi

archive="$tmp_dir/$asset_name"
extract_dir="$tmp_dir/extract"
mkdir -p "$extract_dir"
log "Installing latest $fallback_id release $release_tag..."
"$curl_bin" --fail --location --proto '=https' --tlsv1.2 --silent --show-error --output "$archive" "$asset_url"

if [ "$(sha256_file "$archive")" != "$asset_sha256" ]; then
  printf '%s\n' "Checksum verification failed for $fallback_id release $release_tag." >&2
  exit 1
fi

"$tar_bin" -xf "$archive" -C "$extract_dir"
source_binary="$(find "$extract_dir" -type f -name "$binary_name" -perm -111 -print | sed -n '1p')"
if [ -z "$source_binary" ]; then
  printf '%s\n' "Release archive for $fallback_id did not contain executable $binary_name." >&2
  exit 1
fi

umask 077
mkdir -p "$install_dir"
staging_file="$install_dir/.${binary_name}.macports-brewfile.$$"
install -m 755 "$source_binary" "$staging_file"
binary_sha256="$(sha256_file "$staging_file")"
mv -f "$staging_file" "$destination"
staging_file=

mkdir -p "$state_dir"
chmod 700 "$state_dir"
state_tmp="$(mktemp "$state_dir/fallbacks.tsv.XXXXXX")"
if [ -f "$state_file" ]; then
  awk -F '\t' -v fallback_id="$fallback_id" '$1 != fallback_id { print }' "$state_file" >"$state_tmp"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$fallback_id" "$release_tag" "$asset_name" "$asset_url" "$asset_sha256" "$binary_sha256" >>"$state_tmp"
chmod 600 "$state_tmp"
mv -f "$state_tmp" "$state_file"
state_tmp=

log "Installed $fallback_id release $release_tag."
