#!/usr/bin/env bash
# The official JVM archive contains both x86_64 and arm64 macOS libsignal slices.
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
port_bin="${BREW_PORT_PORT_BIN:-/opt/local/bin/port}"
sudo_bin="${BREW_PORT_SUDO_BIN:-sudo}"
launcher="$HOME/.local/bin/signal-cli-launcher"
destination="$HOME/.local/bin/signal-cli"
java_home="${BREW_PORT_SIGNAL_CLI_JAVA_HOME:-/Library/Java/JavaVirtualMachines/jdk-25-macports.jdk/Contents/Home}"

[ -x "$port_bin" ] || {
	echo "MacPorts port command is required for signal-cli: $port_bin" >&2
	exit 1
}

"$sudo_bin" -n "$port_bin" install openjdk25
"$script_dir/install-release-binary.sh" \
	signal-cli \
	AsamK/signal-cli \
	'signal-cli-{version}.tar.gz' \
	bundle \
	"$launcher" \
	signal-cli

mkdir -p "$(dirname "$destination")"
wrapper="$destination.$$"
cat >"$wrapper" <<EOF
#!/bin/sh
JAVA_HOME="$java_home"
export JAVA_HOME
exec "$launcher" "\$@"
EOF
chmod 755 "$wrapper"
mv -f "$wrapper" "$destination"
echo "Configured signal-cli to use OpenJDK 25 at $java_home."
