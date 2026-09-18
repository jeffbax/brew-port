#!/usr/bin/env bash
set -euo pipefail
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
case "${BREW_PORT_ARCH:?}" in
x86_64) asset_arch=x86_64 ;;
arm64) asset_arch=aarch64 ;;
*)
	echo "Unsupported worktrunk architecture: $BREW_PORT_ARCH" >&2
	exit 1
	;;
esac
exec "$script_dir/install-release-binary.sh" worktrunk max-sixty/worktrunk "worktrunk-$asset_arch-apple-darwin.tar.xz" wt
