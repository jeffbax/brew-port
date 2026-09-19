#!/usr/bin/env bash
# Bootstrap or install a verified brew-port release archive. Bash 3.2 compatible.
set -euo pipefail

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

release_dir=''
script_source="${BASH_SOURCE[0]:-}"
if [ -n "$script_source" ] && [ -f "$script_source" ]; then
	candidate_dir="$(CDPATH='' cd -- "$(dirname -- "$script_source")" && pwd -P)"
	if [ -f "$candidate_dir/SHA256SUMS" ] && [ -x "$candidate_dir/bin/brew-port" ]; then
		release_dir="$candidate_dir"
	fi
fi

install_release() {
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
	[ -f "$release_dir/SHA256SUMS" ] || die 'Release contents are missing SHA256SUMS.'
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
}

if [ -n "$release_dir" ]; then
	install_release "$@"
	exit 0
fi

for command_name in bash curl shasum tar; do
	command -v "$command_name" >/dev/null 2>&1 || die "Required command is missing: $command_name"
done
bootstrap_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-bootstrap.XXXXXX")"
trap 'rm -rf "$bootstrap_dir"' EXIT HUP INT TERM
base_url='https://github.com/jeffbax/brew-port/releases/latest/download'
curl -fsSL "$base_url/SHA256SUMS" -o "$bootstrap_dir/SHA256SUMS" || die 'Failed to download SHA256SUMS.'
manifest_line=''
exec 3<"$bootstrap_dir/SHA256SUMS"
IFS= read -r manifest_line <&3 || [ -n "$manifest_line" ] || die 'Malformed SHA256SUMS manifest.'
if IFS= read -r extra_line <&3; then
	die "Malformed SHA256SUMS manifest: unexpected line $extra_line"
fi
exec 3<&-
IFS=' ' read -r checksum archive extra <<EOF
$manifest_line
EOF
[ -n "${checksum:-}" ] && [ -n "${archive:-}" ] && [ -z "${extra:-}" ] || die 'Malformed SHA256SUMS manifest.'
case "$checksum" in
'' | *[!0-9A-Fa-f]*) die 'Malformed SHA256SUMS checksum.' ;;
esac
[ "${#checksum}" -eq 64 ] || die 'Malformed SHA256SUMS checksum.'
[[ "$archive" =~ ^brew-port-[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?\.tar\.gz$ ]] || die 'Malformed SHA256SUMS archive name.'
curl -fsSL "$base_url/$archive" -o "$bootstrap_dir/$archive" || die 'Failed to download release archive.'
(cd "$bootstrap_dir" && shasum -a 256 -c SHA256SUMS) || die 'Release archive failed checksum verification.'
mkdir "$bootstrap_dir/extracted"
tar -xzf "$bootstrap_dir/$archive" -C "$bootstrap_dir/extracted" || die 'Release archive could not be extracted.'
release_dir="$bootstrap_dir/extracted/${archive%.tar.gz}"
[ -f "$release_dir/install.sh" ] || die 'Release archive is missing install.sh.'
bash "$release_dir/install.sh" "$@"
