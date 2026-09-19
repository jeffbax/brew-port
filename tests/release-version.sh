#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
resolver="$repo_dir/scripts/release-version.sh"
subject='Bump BP_VERSION to 1.2.4 [skip ci]'

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

assert_version() {
	actual="$($resolver "$1" "$2" "$3" "$4" "$5")"
	[ "$actual" = "$6" ] || fail "Resolved $actual, expected $6"
}

assert_failure() {
	if "$resolver" "$@" >/dev/null 2>&1; then
		fail 'Accepted an unsafe release retry.'
	fi
}

assert_version 1.2.3 patch '' '' none 1.2.4
assert_version 1.2.4 patch "$subject" patch none 1.2.4
assert_version 1.2.4 patch "$subject" patch draft 1.2.4
assert_version 1.2.4 minor "$subject" patch published 1.3.0
assert_failure 1.2.4 minor "$subject" patch none
assert_failure 1.2.4 patch "$subject" '' draft
assert_failure 1.2.4 patch 'Manual version change' patch draft
assert_failure 1.2.4 patch "$subject" patch invalid

printf '%s\n' 'Release version retry checks passed.'
