#!/bin/sh
set -eu

repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
utility="$repo_dir/bin/macports-brewfile"
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
  "$repo_dir/fallbacks/install-rtk.sh" \
  "$repo_dir/fallbacks/install-worktrunk.sh"; do
  sh -n "$file"
done

[ -x "$utility" ] || fail 'The utility is not executable.'
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

printf '%s\n' 'macports-brewfile checks passed.'
