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

printf '%s\n' 'macports-brewfile checks passed.'
