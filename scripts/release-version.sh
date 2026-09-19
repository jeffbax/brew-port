#!/usr/bin/env bash
# Resolve a new release version or a retry of a pending bump. Bash 3.2 compatible.
set -euo pipefail

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 5 ] || die "Usage: $0 CURRENT BUMP LAST_BUMP_SUBJECT LAST_BUMP_TYPE none|draft|published"
current=$1
bump=$2
last_bump_subject=$3
last_bump_type=$4
release_state=$5
expected_subject="Bump BP_VERSION to $current [skip ci]"

case "$release_state" in
none | draft | published) ;;
*) die "Unsupported release state: $release_state" ;;
esac

if [ "$release_state" = published ]; then
	exec "$(dirname -- "$0")/bump-version.sh" "$current" "$bump"
fi

if [ "$last_bump_subject" = "$expected_subject" ]; then
	[ -n "$last_bump_type" ] || die "Pending release v$current has no Release-Bump metadata."
	[ "$last_bump_type" = "$bump" ] || die "Pending release v$current requires bump '$last_bump_type', not '$bump'."
	printf '%s\n' "$current"
	exit 0
fi

[ "$release_state" != draft ] || die "Draft release v$current has no matching version bump commit."
exec "$(dirname -- "$0")/bump-version.sh" "$current" "$bump"
