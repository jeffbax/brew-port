#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
release_version="${RELEASE_VERSION:-}"
if [ -n "$release_version" ]; then
	version="$release_version"
else
	version="$("$repo_dir/bin/brew-port" version)"
	version="${version#brew-port }"
fi
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
	printf 'Tag %s does not match CLI version %s\n' "$RELEASE_TAG" "$version" >&2
	exit 1
fi
output_dir="${1:-$repo_dir/dist}"
mkdir -p "$output_dir"
output_dir="$(CDPATH='' cd -- "$output_dir" && pwd -P)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT HUP INT TERM
name="brew-port-$version"
mkdir "$stage/$name"
for item in bin maps completions .agents README.md LICENSE install.sh; do
	cp -R "$repo_dir/$item" "$stage/$name/"
done
chmod +x "$stage/$name/install.sh"
if [ -n "$release_version" ]; then
	temporary="$(mktemp)"
	awk -v replacement="BP_VERSION=$version" '
		/^BP_VERSION=/ {
			count++
			if (count > 1) exit 2
			print replacement
			next
		}
		{ print }
		END { if (count != 1) exit 3 }
	' "$stage/$name/bin/brew-port" >"$temporary"
	mv "$temporary" "$stage/$name/bin/brew-port"
	chmod +x "$stage/$name/bin/brew-port"
fi
(
	cd "$stage/$name"
	# SHA256SUMS is explicitly excluded from the input file list.
	# shellcheck disable=SC2094
	find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done >SHA256SUMS
)
COPYFILE_DISABLE=1 tar -czf "$output_dir/$name.tar.gz" -C "$stage" "$name"
(cd "$output_dir" && shasum -a 256 "$name.tar.gz" >SHA256SUMS)
printf '%s\n' "$output_dir/$name.tar.gz"
