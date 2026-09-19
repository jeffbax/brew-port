#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
helper="$repo_dir/scripts/bump-version.sh"

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

assert_version() {
	actual="$($helper "$1" "$2")"
	[ "$actual" = "$3" ] || fail "$1 + $2 produced $actual, expected $3"
}

assert_version 1.2.3 patch 1.2.4
assert_version 1.2.3 minor 1.3.0
assert_version 1.2.3 major 2.0.0
assert_version 1.2.3 prerelease 1.2.4-rc.1
assert_version 1.2.4-rc.1 prerelease 1.2.4-rc.2
assert_version 1.2.4-rc.1 patch 1.2.4
assert_version 1.2.4-rc.1 minor 1.3.0
assert_version 1.2.4-rc.1 major 2.0.0
assert_version 1.2.4-beta.2 prerelease 1.2.4-beta.3

for invalid_version in 1.2 1.2.3-rc 01.2.3 1.2.3+build.1; do
	if "$helper" "$invalid_version" patch >/dev/null 2>&1; then
		fail "Accepted invalid version: $invalid_version"
	fi
done

if "$helper" 1.2.3 nope >/dev/null 2>&1; then
	fail 'Accepted invalid bump type.'
fi

/bin/bash -n "$helper"
printf '%s\n' 'Version bump checks passed.'
