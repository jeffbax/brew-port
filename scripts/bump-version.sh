#!/usr/bin/env bash
# Compute the next brew-port release version. Bash 3.2 compatible.
set -euo pipefail

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] || die "Usage: $0 VERSION patch|minor|major|prerelease"
current=$1
bump=$2

if [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+)\.([0-9]+))?$ ]]; then
	major=${BASH_REMATCH[1]}
	minor=${BASH_REMATCH[2]}
	patch=${BASH_REMATCH[3]}
	identifier=${BASH_REMATCH[5]:-}
	prerelease_number=${BASH_REMATCH[6]:-}
else
	die "Unsupported version: $current (expected MAJOR.MINOR.PATCH[-IDENTIFIER.NUMBER])"
fi

for numeric in "$major" "$minor" "$patch" "$prerelease_number"; do
	[ -z "$numeric" ] && continue
	case "$numeric" in
	0 | [1-9]*) ;;
	*) die "Unsupported version: $current (numeric components must not have leading zeroes)" ;;
	esac
done

case "$bump" in
patch)
	if [ -n "$identifier" ]; then
		printf '%s.%s.%s\n' "$major" "$minor" "$patch"
	else
		printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
	fi
	;;
minor)
	printf '%s.%s.0\n' "$major" "$((minor + 1))"
	;;
major)
	printf '%s.0.0\n' "$((major + 1))"
	;;
prerelease)
	if [ -n "$identifier" ]; then
		printf '%s.%s.%s-%s.%s\n' "$major" "$minor" "$patch" "$identifier" "$((prerelease_number + 1))"
	else
		printf '%s.%s.%s-rc.1\n' "$major" "$minor" "$((patch + 1))"
	fi
	;;
*)
	die "Unsupported bump type: $bump (choose patch, minor, major, or prerelease)"
	;;
esac
