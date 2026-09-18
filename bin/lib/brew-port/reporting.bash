bp_report_init() {
	BP_UNRESOLVED="$BP_TMP_DIR/unresolved"
	BP_GUI="$BP_TMP_DIR/gui"
	: >"$BP_UNRESOLVED"
	: >"$BP_GUI"
}
bp_unresolved() { printf '%s\t%s\n' "$1" "$2" >>"$BP_UNRESOLVED"; }
bp_gui() { printf '%s\n' "$1" >>"$BP_GUI"; }
bp_report() {
	if [ -s "$BP_UNRESOLVED" ]; then
		bp_log 'Unresolved packages:'
		sed 's/\t/: /' "$BP_UNRESOLVED"
	fi
	if [ -s "$BP_GUI" ]; then
		bp_log 'GUI follow-up:'
		cat "$BP_GUI"
	fi
}
