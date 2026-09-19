bp_report_init() {
	BP_WARNINGS="$BP_TMP_DIR/warnings"
	BP_MANUAL="$BP_TMP_DIR/manual"
	BP_FAILED="$BP_TMP_DIR/failed"
	BP_INSTALLED="$BP_TMP_DIR/installed"
	BP_PRESENT_COUNT=0
	BP_PRESENT_PORTS=0
	BP_PRESENT_CASKS=0
	BP_PRESENT_MAS=0
	: >"$BP_WARNINGS"
	: >"$BP_MANUAL"
	: >"$BP_FAILED"
	: >"$BP_INSTALLED"
}
bp_unresolved() { printf '%s\t%s\n' "$1" "$2" >>"$BP_WARNINGS"; }
bp_action_failed() {
	printf '%s\t%s\n' "$1" "$2" >>"$BP_FAILED"
}
bp_gui() { printf '%s\n' "$1" >>"$BP_MANUAL"; }
bp_present() {
	BP_PRESENT_COUNT=$((BP_PRESENT_COUNT + 1))
	case "${1:-}" in
	port) BP_PRESENT_PORTS=$((BP_PRESENT_PORTS + 1)) ;;
	cask) BP_PRESENT_CASKS=$((BP_PRESENT_CASKS + 1)) ;;
	mas) BP_PRESENT_MAS=$((BP_PRESENT_MAS + 1)) ;;
	esac
}
bp_installed() { printf '%s\n' "$1" >>"$BP_INSTALLED"; }
bp_report() {
	local installed_count
	installed_count="$(awk 'END { print NR + 0 }' "$BP_INSTALLED")"
	bp_log 'Package reconciliation:'
	bp_log "Already present: $BP_PRESENT_COUNT (MacPorts: $BP_PRESENT_PORTS, casks: $BP_PRESENT_CASKS, MAS: $BP_PRESENT_MAS)"
	bp_log "Installed: $installed_count"
	if [ -s "$BP_INSTALLED" ]; then
		sed 's/^/  /' "$BP_INSTALLED"
	fi
	if [ -s "$BP_MANUAL" ]; then
		bp_log 'Manual follow-up:'
		sed 's/^/  /' "$BP_MANUAL"
	fi
	if [ -s "$BP_WARNINGS" ]; then
		bp_log 'Warnings:'
		sed 's/\t/: /; s/^/  /' "$BP_WARNINGS"
	fi
	if [ -s "$BP_FAILED" ]; then
		bp_log 'Failed:'
		sed 's/\t/: /; s/^/  /' "$BP_FAILED"
		bp_log 'Result: failed'
		return 1
	fi
	if [ -s "$BP_WARNINGS" ] || [ -s "$BP_MANUAL" ]; then
		bp_log 'Result: success with warnings'
	else
		bp_log 'Result: success'
	fi
}
