#!/bin/sh
set -eu

repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
utility="$repo_dir/bin/macports-brewfile"
updater="$repo_dir/bin/macports-update"
release_installer="$repo_dir/fallbacks/install-release-binary.sh"
rtk_fallback="$repo_dir/fallbacks/install-rtk.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/macports-brewfile-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup 0 HUP INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

assert_contains() {
  needle="$1"
  haystack="$2"
  printf '%s\n' "$haystack" | grep -Fq -- "$needle" || fail "Expected output to contain: $needle"
}

assert_not_contains() {
  needle="$1"
  haystack="$2"
  if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
    fail "Expected output not to contain: $needle"
  fi
}

assert_map_is_valid() {
  awk -F '\t' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 5 { exit 1 }
    $1 !~ /^(brew|cask)$/ || $2 == "" { exit 1 }
    $3 !~ /^(port|fallback|skip)$/ { exit 1 }
    $3 == "port" && ($4 == "" || $4 == "-") { exit 1 }
    $3 == "fallback" && ($4 !~ /^fallbacks\/[A-Za-z0-9._\/-]+\.sh$/ || $4 ~ /(^|\/)\.\.?($|\/)/) { exit 1 }
    $3 == "skip" && $4 != "-" { exit 1 }
    seen[$1 SUBSEP $2]++ { exit 1 }
  ' "$repo_dir/maps/default.tsv" || fail 'The default map is invalid.'
}

for file in \
  "$utility" \
  "$updater" \
  "$release_installer" \
  "$repo_dir/fallbacks/install-rtk.sh" \
  "$repo_dir/fallbacks/install-worktrunk.sh"; do
  sh -n "$file"
done

[ -x "$utility" ] || fail 'The utility is not executable.'
[ -x "$updater" ] || fail 'The updater is not executable.'
[ -x "$release_installer" ] || fail 'The release installer is not executable.'
assert_map_is_valid

brewfile="$tmp_dir/Brewfile"
printf '%s\n' \
  'brew "git"' \
  'brew "rtk"' \
  'brew "signal-cli"' \
  'cask "1password-cli"' \
  'cask "firefox"' \
  'mas "Example App", id: 123456789' >"$brewfile"

output="$("$utility" install --dry-run "$brewfile")"
assert_contains 'Would run: sudo /opt/local/bin/port selfupdate' "$output"
assert_contains 'Would install MacPorts port git (for git)' "$output"
assert_contains 'Would run reviewed fallback for rtk' "$output"
assert_contains 'signal-cli: No verified MacPorts port or reviewed fallback is available.' "$output"
assert_contains 'Would install MacPorts port 1password-cli (for 1password-cli)' "$output"
assert_contains 'Would install Mac App Store app 123456789' "$output"
assert_contains 'Install cask firefox manually in ' "$output"

mock_port="$tmp_dir/port"
mock_sudo="$tmp_dir/sudo"
sudo_log="$tmp_dir/sudo.log"
live_brewfile="$tmp_dir/Brewfile.live"

printf '%s\n' \
  'brew "git"' \
  'brew "signal-cli"' \
  'cask "1password-cli"' \
  'cask "firefox"' >"$live_brewfile"

cat >"$mock_port" <<'EOF'
#!/bin/sh
set -eu

case "$1" in
selfupdate)
  printf '%s\n' '---> Updating MacPorts base sources using rsync'
  ;;
install)
  printf '%s\n' "---> Installing $2"
  printf '%s\n' '--->  Some of the ports you installed have notes:'
  printf '%s\n' "  $2 has the following notes:"
  printf '%s\n' '    Read this example note before using the port.'
  ;;
upgrade)
  [ "$2" = outdated ] || exit 2
  printf '%s\n' '---> Upgrading outdated ports'
  if [ "${MOCK_PORT_UPGRADE_FAIL:-false}" = true ]; then
    printf '%s\n' 'Mock MacPorts upgrade failure' >&2
    exit 3
  fi
  ;;
*)
  printf '%s\n' "Unexpected port command: $*" >&2
  exit 2
  ;;
esac
EOF

cat >"$mock_sudo" <<'EOF'
#!/bin/sh
set -eu

: "${SUDO_LOG:?}"
printf '%s\n' "$*" >>"$SUDO_LOG"

case "$1" in
-v)
  exit 0
  ;;
-n)
  shift
  if [ "$1" = -v ]; then
    exit 0
  fi
  exec "$@"
  ;;
*)
  printf '%s\n' "Unexpected sudo command: $*" >&2
  exit 2
  ;;
esac
EOF
chmod +x "$mock_port" "$mock_sudo"

mock_curl="$tmp_dir/curl"
curl_log="$tmp_dir/curl.log"
release_dir="$tmp_dir/releases"
mkdir -p "$release_dir"

cat >"$mock_curl" <<'EOF'
#!/bin/sh
set -eu

: "${MOCK_CURL_LOG:?}"
: "${MOCK_RTK_RELEASE:?}"
: "${MOCK_WORKTRUNK_RELEASE:?}"
: "${MOCK_RTK_ARCHIVE:?}"
: "${MOCK_WORKTRUNK_ARCHIVE:?}"

if [ "${MOCK_CURL_MODE:-online}" = offline ]; then
  exit 22
fi

output_file=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --output)
    shift
    output_file="$1"
    ;;
  *) url="$1" ;;
  esac
  shift
done

[ -n "$output_file" ] || exit 2
printf '%s\n' "$url" >>"$MOCK_CURL_LOG"

case "$url" in
*'/repos/rtk-ai/rtk/releases/latest') cp "$MOCK_RTK_RELEASE" "$output_file" ;;
*'/repos/max-sixty/worktrunk/releases/latest') cp "$MOCK_WORKTRUNK_RELEASE" "$output_file" ;;
*'/rtk/'*) cp "$MOCK_RTK_ARCHIVE" "$output_file" ;;
*'/worktrunk/'*) cp "$MOCK_WORKTRUNK_ARCHIVE" "$output_file" ;;
*) exit 2 ;;
esac
EOF
chmod +x "$mock_curl"

make_release_archive() {
  tool_name="$1"
  binary_name="$2"
  version="$3"
  archive="$4"

  archive_root="$release_dir/$tool_name-$version"
  mkdir -p "$archive_root/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s %s"\n' "$tool_name" "$version" >"$archive_root/bin/$binary_name"
  chmod +x "$archive_root/bin/$binary_name"
  case "$archive" in
  *.tar.gz) tar -czf "$archive" -C "$archive_root" . ;;
  *.tar.xz) tar -cJf "$archive" -C "$archive_root" . ;;
  *) fail "Unsupported archive format: $archive" ;;
  esac
}

write_release_json() {
  tag="$1"
  asset_name="$2"
  asset_url="$3"
  archive="$4"
  output_file="$5"
  archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"

  printf '{"tag_name":"%s","assets":[{"name":"%s","browser_download_url":"%s","digest":"sha256:%s"}]}' \
    "$tag" "$asset_name" "$asset_url" "$archive_sha256" >"$output_file"
}

rtk_v1_archive="$release_dir/rtk-v0.49.0.tar.gz"
rtk_v2_archive="$release_dir/rtk-v0.50.0.tar.gz"
worktrunk_archive="$release_dir/worktrunk-v0.78.0.tar.xz"
make_release_archive rtk rtk 0.49.0 "$rtk_v1_archive"
make_release_archive rtk rtk 0.50.0 "$rtk_v2_archive"
make_release_archive worktrunk wt 0.78.0 "$worktrunk_archive"

rtk_release_json="$release_dir/rtk-release.json"
worktrunk_release_json="$release_dir/worktrunk-release.json"
write_release_json v0.49.0 rtk-x86_64-apple-darwin.tar.gz https://example.invalid/rtk/v0.49.0 "$rtk_v1_archive" "$rtk_release_json"
write_release_json v0.78.0 worktrunk-x86_64-apple-darwin.tar.xz https://example.invalid/worktrunk/v0.78.0 "$worktrunk_archive" "$worktrunk_release_json"

: >"$sudo_log"
output="$(SUDO_LOG="$sudo_log" \
  MACPORTS_BREWFILE_PORT_BIN="$mock_port" \
  MACPORTS_BREWFILE_SUDO_BIN="$mock_sudo" \
  "$utility" install "$live_brewfile")"

assert_contains 'Requesting administrator access for MacPorts...' "$output"
assert_contains 'MacPorts installation notes:' "$output"
assert_contains 'Read this example note before using the port.' "$output"
assert_contains "===== $mock_sudo -n $mock_port install git =====" "$output"
assert_contains 'GUI follow-up:' "$output"
assert_not_contains 'Would run:' "$output"

[ "$(grep -Fxc -- '-v' "$sudo_log")" -eq 1 ] || fail 'Expected one interactive sudo authorization.'
[ "$(grep -Fxc -- "-n $mock_port selfupdate" "$sudo_log")" -eq 1 ] || fail 'Expected selfupdate to use non-interactive sudo.'
[ "$(grep -Fxc -- "-n $mock_port install git" "$sudo_log")" -eq 1 ] || fail 'Expected port installs to use non-interactive sudo.'

: >"$sudo_log"
output="$(SUDO_LOG="$sudo_log" \
  MACPORTS_BREWFILE_PORT_BIN="$mock_port" \
  MACPORTS_BREWFILE_SUDO_BIN="$mock_sudo" \
  "$utility" install --dry-run "$live_brewfile")"
[ ! -s "$sudo_log" ] || fail 'Dry runs must not invoke sudo.'
assert_contains "Would run: sudo $mock_port selfupdate" "$output"

fallback_home="$tmp_dir/fallback-home"
fallback_state="$tmp_dir/fallback-state"
mkdir -p "$fallback_home"
: >"$curl_log"
output="$(HOME="$fallback_home" \
  XDG_STATE_HOME="$fallback_state" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v1_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$rtk_fallback")"
assert_contains 'Installed rtk release v0.49.0.' "$output"
[ -x "$fallback_home/.local/bin/rtk" ] || fail 'Expected rtk release binary to be installed.'
assert_contains 'rtk 0.49.0' "$("$fallback_home/.local/bin/rtk")"
assert_contains 'rtk	v0.49.0' "$(cat "$fallback_state/macports-brewfile/fallbacks.tsv")"
[ "$(grep -Fxc -- 'https://example.invalid/rtk/v0.49.0' "$curl_log")" -eq 1 ] || fail 'Expected one rtk asset download.'

output="$(HOME="$fallback_home" \
  XDG_STATE_HOME="$fallback_state" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v1_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$rtk_fallback")"
assert_contains 'rtk release v0.49.0 is already installed and verified.' "$output"
[ "$(grep -Fxc -- 'https://example.invalid/rtk/v0.49.0' "$curl_log")" -eq 1 ] || fail 'Unchanged fallback should not redownload its asset.'

write_release_json v0.50.0 rtk-x86_64-apple-darwin.tar.gz https://example.invalid/rtk/v0.50.0 "$rtk_v2_archive" "$rtk_release_json"
output="$(HOME="$fallback_home" \
  XDG_STATE_HOME="$fallback_state" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$rtk_fallback")"
assert_contains 'Installed rtk release v0.50.0.' "$output"
assert_contains 'rtk 0.50.0' "$("$fallback_home/.local/bin/rtk")"
assert_contains 'rtk	v0.50.0' "$(cat "$fallback_state/macports-brewfile/fallbacks.tsv")"

printf '{"tag_name":"v0.50.0","assets":[{"name":"rtk-x86_64-apple-darwin.tar.gz","browser_download_url":"https://example.invalid/rtk/v0.50.0","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]}' >"$rtk_release_json"
if output="$(HOME="$fallback_home" \
  XDG_STATE_HOME="$fallback_state" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$rtk_fallback" 2>&1)"; then
  fail 'Expected a changed digest for the same release tag to fail.'
fi
assert_contains 'published asset digest changed' "$output"
assert_contains 'rtk 0.50.0' "$("$fallback_home/.local/bin/rtk")"

output="$(HOME="$fallback_home" \
  XDG_STATE_HOME="$fallback_state" \
  MOCK_CURL_MODE=offline \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$rtk_fallback")"
assert_contains 'Warning: could not check the latest rtk release; keeping verified v0.50.0.' "$output"

rm -f "$fallback_home/.local/bin/rtk"
if output="$(HOME="$fallback_home" \
  XDG_STATE_HOME="$fallback_state" \
  MOCK_CURL_MODE=offline \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$rtk_fallback" 2>&1)"; then
  fail 'Expected a missing fallback to fail when release lookup is unavailable.'
fi
assert_contains 'Could not determine the latest verified rtk release.' "$output"

write_release_json v0.50.0 rtk-x86_64-apple-darwin.tar.gz https://example.invalid/rtk/v0.50.0 "$rtk_v2_archive" "$rtk_release_json"
update_home="$tmp_dir/update-home"
update_state="$tmp_dir/update-state"
mkdir -p "$update_home"
: >"$sudo_log"
: >"$curl_log"
output="$(HOME="$update_home" \
  XDG_STATE_HOME="$update_state" \
  SUDO_LOG="$sudo_log" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_PORT_BIN="$mock_port" \
  MACPORTS_BREWFILE_SUDO_BIN="$mock_sudo" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$updater")"
assert_contains 'Installed rtk release v0.50.0.' "$output"
assert_contains 'Installed worktrunk release v0.78.0.' "$output"
[ "$(grep -Fxc -- '-v' "$sudo_log")" -eq 1 ] || fail 'Expected one sudo authorization for the updater.'
[ "$(grep -Fxc -- "-n $mock_port selfupdate" "$sudo_log")" -eq 1 ] || fail 'Expected updater selfupdate to use non-interactive sudo.'
[ "$(grep -Fxc -- "-n $mock_port upgrade outdated" "$sudo_log")" -eq 1 ] || fail 'Expected updater to upgrade all outdated ports.'

: >"$sudo_log"
: >"$curl_log"
output="$(SUDO_LOG="$sudo_log" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MACPORTS_BREWFILE_PORT_BIN="$mock_port" \
  MACPORTS_BREWFILE_SUDO_BIN="$mock_sudo" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$updater" --dry-run)"
assert_contains "Would run: sudo $mock_port upgrade outdated" "$output"
[ ! -s "$sudo_log" ] || fail 'Updater dry runs must not invoke sudo.'
[ ! -s "$curl_log" ] || fail 'Updater dry runs must not query fallback releases.'

: >"$curl_log"
if output="$(HOME="$update_home" \
  XDG_STATE_HOME="$update_state" \
  SUDO_LOG="$sudo_log" \
  MOCK_CURL_LOG="$curl_log" \
  MOCK_RTK_RELEASE="$rtk_release_json" \
  MOCK_WORKTRUNK_RELEASE="$worktrunk_release_json" \
  MOCK_RTK_ARCHIVE="$rtk_v2_archive" \
  MOCK_WORKTRUNK_ARCHIVE="$worktrunk_archive" \
  MOCK_PORT_UPGRADE_FAIL=true \
  MACPORTS_BREWFILE_PORT_BIN="$mock_port" \
  MACPORTS_BREWFILE_SUDO_BIN="$mock_sudo" \
  MACPORTS_BREWFILE_CURL_BIN="$mock_curl" \
  "$updater" 2>&1)"; then
  fail 'Expected a failed MacPorts upgrade to stop the updater.'
fi
assert_contains 'MacPorts upgrade failed.' "$output"
[ ! -s "$curl_log" ] || fail 'Fallback refresh must not run after a MacPorts upgrade failure.'

printf '%s\n' 'macports-brewfile checks passed.'
