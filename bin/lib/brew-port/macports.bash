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
	bp_port install "$target" || bp_action_failed "$token" "MacPorts install failed: $target"
}

bp_snapshot_active_ports() {
	BP_ACTIVE_PORTS="$BP_TMP_DIR/active-ports"
	"$BP_PORT_BIN" -q echo active >"$BP_ACTIVE_PORTS" || bp_die 'Could not inspect active MacPorts ports.'
}

bp_port_is_active() {
	grep -Fxq -- "$1" "$BP_ACTIVE_PORTS"
}

bp_install_port_plan() {
	local plan="$1" missing="$BP_TMP_DIR/missing-ports" targets="$BP_TMP_DIR/missing-port-targets"
	local token target batch_failed=false
	: >"$missing"
	while IFS=$'\t' read -r token target; do
		if bp_port_is_active "$target"; then
			bp_present port
		else
			printf '%s\t%s\n' "$token" "$target" >>"$missing"
		fi
	done <"$plan"
	[ -s "$missing" ] || return 0
	awk -F '\t' '!seen[$2]++ { print $2 }' "$missing" >"$targets"
	if "$BP_DRY_RUN"; then
		bp_log "Would install MacPorts ports: $(paste -sd ' ' "$targets")"
		return 0
	fi
	bp_selfupdate
	local -a target_args=()
	while IFS= read -r target; do target_args+=("$target"); done <"$targets"
	bp_start_sudo
	bp_log "Installing MacPorts ports: ${target_args[*]}"
	bp_port install "${target_args[@]}" || batch_failed=true
	if "$batch_failed"; then bp_snapshot_active_ports; fi
	while IFS=$'\t' read -r token target; do
		if ! "$batch_failed" || bp_port_is_active "$target"; then
			if [ "$token" = "$target" ]; then bp_installed "$token"; else bp_installed "$token -> $target"; fi
		else
			bp_action_failed "$token" "MacPorts install failed: $target"
		fi
	done <"$missing"
}
