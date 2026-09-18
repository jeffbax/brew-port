#!/usr/bin/env bash
set -euo pipefail
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
destination="${BREW_PORT_MAS_DESTINATION:-/usr/local/bin/mas}"
case "${BREW_PORT_ARCH:?}" in
x86_64 | arm64) asset_arch="$BREW_PORT_ARCH" ;;
*)
	echo "Unsupported MAS architecture: $BREW_PORT_ARCH" >&2
	exit 1
	;;
esac
exec "$script_dir/install-release-binary.sh" mas mas-cli/mas "mas-{version}-$asset_arch.pkg" package "$destination"
