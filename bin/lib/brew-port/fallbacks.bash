bp_run_mapping() {
	local kind="$1" token="$2" row action target note arches source fallback_path
	row="$(bp_lookup_mapping "$kind" "$token" || true)"
	if [ -z "$row" ]; then
		[ "$kind" = brew ] && bp_install_port "$token" "$token"
		return 0
	fi
	IFS=$'\034' read -r action target note arches source <<EOF
$row
EOF
	case "$action" in
	port) bp_install_port "$token" "$target" ;;
	skip) bp_unresolved "$token" "$note" ;;
	fallback | fallback-root)
		if ! bp_arch_supported "$arches"; then
			bp_unresolved "$token" "No verified native fallback for $BP_ARCH. $note"
			return 0
		fi
		fallback_path="$(bp_mapping_fallback_path "$source" "$target")"
		if [ ! -f "$fallback_path" ]; then
			bp_unresolved "$token" "Missing fallback: $target"
			return 0
		fi
		if "$BP_DRY_RUN"; then
			bp_log "Would run reviewed fallback for $token: $note"
			return 0
		fi
		[ "$action" = fallback-root ] && bp_start_sudo
		bp_log "Running reviewed fallback for $token: $note"
		BREW_PORT_ARCH="$BP_ARCH" BREW_PORT_PORT_BIN="$BP_PORT_BIN" BREW_PORT_SUDO_BIN="$BP_SUDO_BIN" BREW_PORT_JQ_BIN="$BP_JQ_BIN" bash "$fallback_path" || bp_unresolved "$token" "Fallback failed: $note"
		;;
	esac
}

bp_extract_brew() { sed -nE 's/^[[:space:]]*brew[[:space:]]+"([^"]+)".*/\1/p' "$1"; }
bp_extract_cask() { sed -nE 's/^[[:space:]]*cask[[:space:]]+"([^"]+)".*/\1/p' "$1"; }
bp_extract_mas() { sed -nE 's/^[[:space:]]*mas[[:space:]]+"[^"]+",[[:space:]]*id:[[:space:]]*([0-9]+).*/\1/p' "$1"; }

bp_run_brewfile() {
	local brewfile="$1" token action
	while IFS= read -r token; do [ -n "$token" ] && bp_run_mapping brew "$token"; done < <(bp_extract_brew "$brewfile")
	while IFS= read -r token; do
		[ -n "$token" ] || continue
		action="$(bp_lookup_mapping cask "$token" | cut -d $'\034' -f1 || true)"
		if [ -n "$action" ]; then bp_run_mapping cask "$token"; else bp_gui "Install cask $token manually in $HOME/Applications."; fi
	done < <(bp_extract_cask "$brewfile")
	while IFS= read -r token; do
		[ -n "$token" ] || continue
		if "$BP_DRY_RUN"; then
			bp_log "Would install Mac App Store app $token"
		elif ! command -v mas >/dev/null 2>&1 || ! mas account >/dev/null 2>&1; then
			bp_gui "Mac App Store install $token requires a signed-in mas client."
		elif ! mas install "$token"; then bp_gui "Mac App Store install failed for id $token."; fi
	done < <(bp_extract_mas "$brewfile")
}

bp_refresh_fallbacks() {
	local kind token
	while IFS=$'\t' read -r kind token; do bp_run_mapping "$kind" "$token"; done < <("$BP_JQ_BIN" -r '.mappings[] | select(.action == "fallback" or .action == "fallback-root") | [.kind, .token] | @tsv' "$BP_EFFECTIVE_MAP")
}
