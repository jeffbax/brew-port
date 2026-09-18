#!/usr/bin/env bash
# Offline installer for a verified brew-port release archive. Bash 3.2 compatible.
set -euo pipefail
die() {
	printf '%s\n' "$*" >&2
	exit 1
}
prefix="${HOME:?}/.local"
while [ "$#" -gt 0 ]; do
	case "$1" in
	--prefix)
		[ "$#" -ge 2 ] || die '--prefix requires a path'
		prefix="$2"
		shift 2
		;;
	--help | -h)
		printf '%s\n' 'Usage: bash install.sh [--prefix PATH]'
		exit 0
		;;
	*) die "Unknown argument: $1" ;;
	esac
done
[ -n "$prefix" ] || die 'Prefix must not be empty.'
release_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
[ -f "$release_dir/SHA256SUMS" ] || die 'Install from a packaged release, not the checkout.'
(cd "$release_dir" && shasum -a 256 -c SHA256SUMS) || die 'Release contents failed checksum verification.'
version="$("$release_dir/bin/brew-port" version)"
version="${version#brew-port }"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die 'Invalid release version.'
mkdir -p "$prefix"
prefix="$(CDPATH='' cd -- "$prefix" && pwd -P)"
runtime="$prefix/lib/brew-port"
destination="$runtime/versions/$version"
executable="$prefix/bin/brew-port"
if [ -e "$executable" ] || [ -L "$executable" ]; then
	[ -L "$executable" ] && [ "$(readlink "$executable")" = "$runtime/current/bin/brew-port" ] || die "Refusing to replace unrelated executable: $executable"
fi
if [ -e "$runtime/current" ] || [ -L "$runtime/current" ]; then
	[ -L "$runtime/current" ] || die 'The current-version path is not a symlink.'
	case "$(readlink "$runtime/current")" in versions/*) ;; *) die 'The current-version symlink is not managed by brew-port.' ;; esac
fi
mkdir -p "$runtime/versions" "$prefix/bin"
stage="$(mktemp -d "$runtime/.install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cp -R "$release_dir/." "$stage/"
(cd "$stage" && shasum -a 256 -c SHA256SUMS >/dev/null) || die 'Staged contents failed checksum verification.'
if [ -e "$destination" ] || [ -L "$destination" ]; then
	if [ ! -d "$destination" ] || [ -L "$destination" ] || ! diff -r "$stage" "$destination" >/dev/null; then
		die "Version $version already exists with different contents."
	fi
else
	mv "$stage" "$destination"
	stage="$(mktemp -d "$runtime/.install.XXXXXX")"
fi
ln -s "versions/$version" "$stage/current"
mv -fh "$stage/current" "$runtime/current"
if [ ! -L "$executable" ]; then
	ln -s "$runtime/current/bin/brew-port" "$executable"
fi
printf 'Installed brew-port %s in %s\n' "$version" "$destination"
printf 'Add %s to PATH if needed.\n' "$prefix/bin"
printf 'Optional completions: brew-port completion install fish|bash|zsh\n'
