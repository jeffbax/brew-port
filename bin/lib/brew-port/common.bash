# Shared Bash 3.2 helpers. This directory is private implementation detail.

bp_log() { printf '%s\n' "$*"; }
bp_die() {
	printf '%s\n' "$*" >&2
	exit 1
}

bp_command_path() {
	command -v "$1" 2>/dev/null || true
}

bp_detect_host() {
	BP_OS="$("${BREW_PORT_UNAME_BIN:-uname}" -s)"
	BP_ARCH="$("${BREW_PORT_UNAME_BIN:-uname}" -m)"
	case "$BP_ARCH" in
	x86_64 | arm64) ;;
	*) BP_ARCH=unsupported ;;
	esac
}

bp_find_port() {
	if [ -n "${BREW_PORT_PORT_BIN:-}" ]; then
		BP_PORT_BIN="$BREW_PORT_PORT_BIN"
	elif [ -x /opt/local/bin/port ]; then
		BP_PORT_BIN=/opt/local/bin/port
	else
		BP_PORT_BIN="$(bp_command_path port)"
	fi
}

bp_find_jq() {
	if [ -n "${BREW_PORT_JQ_BIN:-}" ]; then
		BP_JQ_BIN="$BREW_PORT_JQ_BIN"
	elif [ -n "${BP_PORT_BIN:-}" ] && [ -x "$(dirname -- "$BP_PORT_BIN")/jq" ]; then
		BP_JQ_BIN="$(dirname -- "$BP_PORT_BIN")/jq"
	elif [ -x /opt/local/bin/jq ]; then
		BP_JQ_BIN=/opt/local/bin/jq
	elif [ -x /usr/bin/jq ]; then
		BP_JQ_BIN=/usr/bin/jq
	else
		BP_JQ_BIN="$(bp_command_path jq)"
	fi
}

bp_require_macos() {
	[ "$BP_OS" = Darwin ] || bp_die "brew-port supports macOS only (detected $BP_OS)."
}

bp_require_port() {
	[ -n "$BP_PORT_BIN" ] && [ -x "$BP_PORT_BIN" ] || bp_die "A working MacPorts port command is required. Install MacPorts or set BREW_PORT_PORT_BIN."
	"$BP_PORT_BIN" version >/dev/null 2>&1 || bp_die "MacPorts is not usable: $BP_PORT_BIN"
}

bp_cleanup() {
	if [ -n "${BP_SUDO_REFRESH_PID:-}" ]; then
		kill "$BP_SUDO_REFRESH_PID" 2>/dev/null || true
		wait "$BP_SUDO_REFRESH_PID" 2>/dev/null || true
	fi
	[ -n "${BP_TMP_DIR:-}" ] && [ -d "$BP_TMP_DIR" ] && rm -rf "$BP_TMP_DIR"
	return 0
}
