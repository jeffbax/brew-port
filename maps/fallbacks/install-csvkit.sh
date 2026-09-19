#!/usr/bin/env bash
set -euo pipefail

port_bin="${BREW_PORT_PORT_BIN:-/opt/local/bin/port}"
sudo_bin="${BREW_PORT_SUDO_BIN:-sudo}"

[ -x "$port_bin" ] || {
	echo "MacPorts port command is required for csvkit: $port_bin" >&2
	exit 1
}

"$sudo_bin" -n "$port_bin" install py313-csvkit
"$sudo_bin" -n "$port_bin" select --set csvkit py313-csvkit
