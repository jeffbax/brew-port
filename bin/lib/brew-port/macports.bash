BP_SUDO_BIN="${BREW_PORT_SUDO_BIN:-sudo}"
BP_SUDO_STARTED=false
BP_PORTS_UPDATED=false
BP_SUDO_REFRESH_PID=

bp_keep_sudo_alive() {
	while sleep 60; do "$BP_SUDO_BIN" -n -v || return 0; done
}

bp_start_sudo() {
	"$BP_SUDO_STARTED" && return 0
	bp_log 'Requesting administrator access for MacPorts...'
	"$BP_SUDO_BIN" -v || bp_die 'Administrator access is required for MacPorts.'
	bp_keep_sudo_alive >/dev/null 2>&1 &
	BP_SUDO_REFRESH_PID=$!
	BP_SUDO_STARTED=true
}

bp_port() { "$BP_SUDO_BIN" -n "$BP_PORT_BIN" "$@"; }

bp_selfupdate() {
	"$BP_PORTS_UPDATED" && return 0
	if "$BP_DRY_RUN"; then
		bp_log "Would run: sudo $BP_PORT_BIN selfupdate"
		return 0
	fi
	bp_start_sudo
	bp_port selfupdate || bp_die 'MacPorts selfupdate failed.'
	BP_PORTS_UPDATED=true
}

bp_ensure_jq() {
	[ -n "$BP_JQ_BIN" ] && [ -x "$BP_JQ_BIN" ] && return 0
	if "$BP_DRY_RUN"; then
		bp_log 'jq is required for mappings; dry-run will not install it.'
		return 1
	fi
	bp_selfupdate
	bp_log 'Installing MacPorts jq prerequisite...'
	bp_port install jq || bp_die 'Could not install the MacPorts jq port.'
	bp_find_jq
	[ -n "$BP_JQ_BIN" ] && [ -x "$BP_JQ_BIN" ] || bp_die 'MacPorts installed jq but no usable jq binary was found.'
}

bp_install_port() {
	local token="$1" target="$2"
	if "$BP_DRY_RUN"; then
		bp_log "Would install MacPorts port $target (for $token)"
		return 0
	fi
	bp_start_sudo
	bp_log "Installing MacPorts port $target (for $token)"
	bp_port install "$target" || bp_unresolved "$token" "MacPorts install failed: $target"
}
