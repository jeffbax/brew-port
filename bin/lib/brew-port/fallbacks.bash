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
	note="$(bp_decode_mapping_note "$note")"
	case "$action" in
	port) bp_install_port "$token" "$target" ;;
	skip) bp_unresolved "$token" "$note" ;;
	fallback | fallback-root)
		if ! bp_arch_supported "$arches"; then
			bp_unresolved "$token" "No verified native fallback for $BP_ARCH. $note"
			return 0
		fi
		if ! fallback_path="$(bp_mapping_fallback_path "$source" "$target")"; then
			bp_unresolved "$token" "Fallback target escapes the map fallbacks directory: $target"
			return 0
		fi
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

bp_parse_brewfile_declaration() {
	local line="$1" brew_or_cask_pattern mas_pattern
	BP_DECLARATION_KIND=
	BP_DECLARATION_TOKEN=
	BP_DECLARATION_TRAILING=
	brew_or_cask_pattern="^[[:space:]]*(brew|cask)[[:space:]]*(\\([[:space:]]*)?[\"']([^\"']+)[\"'][[:space:]]*\\)?(.*)$"
	mas_pattern="^[[:space:]]*mas[[:space:]]*(\\([[:space:]]*)?[\"'][^\"']+[\"'],[[:space:]]*id:[[:space:]]*([0-9]+)[[:space:]]*\\)?(.*)$"
	if [[ "$line" =~ $brew_or_cask_pattern ]]; then
		BP_DECLARATION_KIND="${BASH_REMATCH[1]}"
		BP_DECLARATION_TOKEN="${BASH_REMATCH[3]}"
		BP_DECLARATION_TRAILING="${BASH_REMATCH[4]}"
	elif [[ "$line" =~ $mas_pattern ]]; then
		BP_DECLARATION_KIND=mas
		BP_DECLARATION_TOKEN="${BASH_REMATCH[2]}"
		BP_DECLARATION_TRAILING="${BASH_REMATCH[3]}"
	else
		return 1
	fi
}

bp_declaration_is_conditional() {
	[[ "$1" =~ ^(if|unless)([[:space:]]|\() || "$1" =~ [[:space:]](if|unless)([[:space:]]|\() ]]
}

bp_run_cask() {
	local token="$1" action
	action="$(bp_lookup_mapping cask "$token" | cut -d $'\034' -f1 || true)"
	if [ -n "$action" ]; then bp_run_mapping cask "$token"; else bp_gui "Install cask $token manually in $HOME/Applications."; fi
}

bp_run_mas() {
	local token="$1"
	if "$BP_DRY_RUN"; then
		bp_log "Would install Mac App Store app $token"
	elif ! command -v mas >/dev/null 2>&1; then
		bp_gui "Mac App Store install $token requires an installed mas client."
	elif ! mas install "$token"; then bp_gui "Mac App Store install failed for id $token."; fi
}

bp_run_brewfile() {
	local brewfile="$1" line conditional_depth=0
	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^[[:space:]]*end([[:space:]]|$) ]]; then
			[ "$conditional_depth" -gt 0 ] && conditional_depth=$((conditional_depth - 1))
			continue
		fi
		if [[ "$line" =~ ^[[:space:]]*(if|unless|case)([[:space:]]|\() ]]; then
			conditional_depth=$((conditional_depth + 1))
			continue
		fi
		bp_parse_brewfile_declaration "$line" || continue
		if [ "$conditional_depth" -gt 0 ] || bp_declaration_is_conditional "$BP_DECLARATION_TRAILING"; then
			bp_unresolved "$BP_DECLARATION_KIND $BP_DECLARATION_TOKEN" 'Conditional Brewfile declaration is unsupported.'
			continue
		fi
		case "$BP_DECLARATION_KIND" in
		brew) bp_run_mapping brew "$BP_DECLARATION_TOKEN" ;;
		cask) bp_run_cask "$BP_DECLARATION_TOKEN" ;;
		mas) bp_run_mas "$BP_DECLARATION_TOKEN" ;;
		esac
	done <"$brewfile"
}

bp_refresh_fallbacks() {
	local kind token
	while IFS=$'\t' read -r kind token; do bp_run_mapping "$kind" "$token"; done < <("$BP_JQ_BIN" -r '.mappings[] | select(.action == "fallback" or .action == "fallback-root") | [.kind, .token] | @tsv' "$BP_EFFECTIVE_MAP")
}
