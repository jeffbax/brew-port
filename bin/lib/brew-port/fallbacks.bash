bp_run_mapping() {
	local kind="$1" token="$2" row action target note arches detect source fallback_path
	row="$(bp_lookup_mapping "$kind" "$token" || true)"
	if [ -z "$row" ]; then
		[ "$kind" = brew ] && bp_install_port "$token" "$token"
		return 0
	fi
	IFS=$'\034' read -r action target note arches detect source <<EOF
$row
EOF
	note="$(bp_decode_mapping_note "$note")"
	case "$action" in
	port) bp_install_port "$token" "$target" ;;
	skip) bp_unresolved "$token" "$note" ;;
	manual) bp_run_manual_cask "$token" "$detect" ;;
	fallback | fallback-root)
		bp_record_fallback "$kind" "$token"
		if ! bp_arch_supported "$arches"; then
			bp_action_failed "$token" "No verified native fallback for $BP_ARCH. $note"
			return 0
		fi
		if ! fallback_path="$(bp_mapping_fallback_path "$source" "$target")"; then
			bp_action_failed "$token" "Fallback target escapes the map fallbacks directory: $target"
			return 0
		fi
		if [ ! -f "$fallback_path" ]; then
			bp_action_failed "$token" "Missing fallback: $target"
			return 0
		fi
		if "$BP_DRY_RUN"; then
			bp_log "Would run reviewed fallback for $token: $note"
			return 0
		fi
		[ "$action" = fallback-root ] && bp_start_sudo
		bp_log "Running reviewed fallback for $token: $note"
		if BREW_PORT_ARCH="$BP_ARCH" BREW_PORT_PORT_BIN="$BP_PORT_BIN" BREW_PORT_SUDO_BIN="$BP_SUDO_BIN" BREW_PORT_JQ_BIN="$BP_JQ_BIN" bash "$fallback_path"; then
			bp_installed "$token (reviewed fallback)"
		else
			bp_action_failed "$token" "Fallback failed: $note"
		fi
		;;
	esac
}

bp_init_fallback_inventory() {
	BP_FALLBACK_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/brew-port"
	BP_FALLBACK_INVENTORY="$BP_FALLBACK_STATE_DIR/requested-fallbacks.json"
	BP_MANAGED_FALLBACKS="$BP_FALLBACK_STATE_DIR/fallbacks.tsv"
}

bp_record_fallback() {
	local kind="$1" token="$2" temporary_inventory
	"$BP_DRY_RUN" && return 0
	mkdir -p "$BP_FALLBACK_STATE_DIR"
	chmod 700 "$BP_FALLBACK_STATE_DIR"
	temporary_inventory="$BP_FALLBACK_STATE_DIR/.requested-fallbacks.$$"
	if [ -f "$BP_FALLBACK_INVENTORY" ]; then
		if ! "$BP_JQ_BIN" --arg kind "$kind" --arg token "$token" '
      if type != "object" or .version != 1 or (.fallbacks | type != "array") then error("invalid fallback inventory")
      else .fallbacks |= (map(select(.kind != $kind or .token != $token)) + [{kind: $kind, token: $token}]) end
    ' "$BP_FALLBACK_INVENTORY" >"$temporary_inventory"; then
			rm -f "$temporary_inventory"
			bp_die "Invalid fallback inventory: $BP_FALLBACK_INVENTORY"
		fi
	else
		"$BP_JQ_BIN" -n --arg kind "$kind" --arg token "$token" '{version: 1, fallbacks: [{kind: $kind, token: $token}]}' >"$temporary_inventory"
	fi
	mv "$temporary_inventory" "$BP_FALLBACK_INVENTORY"
}

bp_fallback_inventory_entries() {
	if [ -f "$BP_FALLBACK_INVENTORY" ]; then
		"$BP_JQ_BIN" -r '
      if type != "object" or .version != 1 or (.fallbacks | type != "array") then error("invalid fallback inventory")
      else .fallbacks[] | select(.kind | type == "string") | select(.token | type == "string") | [.kind, .token] | @tsv end
		' "$BP_FALLBACK_INVENTORY" || return 1
	fi
	if [ -f "$BP_MANAGED_FALLBACKS" ]; then
		awk -F '\t' 'NF { print "brew\t" $1 }' "$BP_MANAGED_FALLBACKS" || return 1
	fi
	return 0
}

bp_strip_ruby_comment() {
	local text="$1" result= quote= escaped=false character index
	for ((index = 0; index < ${#text}; index++)); do
		character="${text:index:1}"
		if [ -n "$quote" ]; then
			if "$escaped"; then
				escaped=false
			elif [ "$character" = "\\" ]; then
				escaped=true
			elif [ "$character" = "$quote" ]; then
				quote=
			fi
		else
			case "$character" in
			"'" | '"') quote="$character" ;;
			'#') break ;;
			esac
		fi
		result+="$character"
	done
	printf '%s' "$result"
}

bp_parse_brewfile_declaration() {
	local line="$1" brew_or_cask_pattern mas_double_pattern mas_single_pattern
	BP_DECLARATION_KIND=
	BP_DECLARATION_TOKEN=
	BP_DECLARATION_NAME=
	BP_DECLARATION_TRAILING=
	brew_or_cask_pattern="^[[:space:]]*(brew|cask)[[:space:]]*(\\([[:space:]]*)?[\"']([^\"']+)[\"'][[:space:]]*\\)?(.*)$"
	mas_double_pattern='^[[:space:]]*mas[[:space:]]*(\([[:space:]]*)?"([^"]+)",[[:space:]]*id:[[:space:]]*([0-9]+)[[:space:]]*\)?(.*)$'
	mas_single_pattern="^[[:space:]]*mas[[:space:]]*(\\([[:space:]]*)?'([^']+)',[[:space:]]*id:[[:space:]]*([0-9]+)[[:space:]]*\\)?(.*)$"
	if [[ "$line" =~ $brew_or_cask_pattern ]]; then
		BP_DECLARATION_KIND="${BASH_REMATCH[1]}"
		BP_DECLARATION_TOKEN="${BASH_REMATCH[3]}"
		BP_DECLARATION_TRAILING="$(bp_strip_ruby_comment "${BASH_REMATCH[4]}")"
	elif [[ "$line" =~ $mas_double_pattern ]]; then
		BP_DECLARATION_KIND=mas
		BP_DECLARATION_NAME="${BASH_REMATCH[2]}"
		BP_DECLARATION_TOKEN="${BASH_REMATCH[3]}"
		BP_DECLARATION_TRAILING="$(bp_strip_ruby_comment "${BASH_REMATCH[4]}")"
	elif [[ "$line" =~ $mas_single_pattern ]]; then
		BP_DECLARATION_KIND=mas
		BP_DECLARATION_NAME="${BASH_REMATCH[2]}"
		BP_DECLARATION_TOKEN="${BASH_REMATCH[3]}"
		BP_DECLARATION_TRAILING="$(bp_strip_ruby_comment "${BASH_REMATCH[4]}")"
	else
		return 1
	fi
}

bp_declaration_is_conditional() {
	[[ "$1" =~ ^(if|unless)([[:space:]]|\() || "$1" =~ [[:space:]](if|unless)([[:space:]]|\() ]]
}

bp_run_manual_cask() {
	local token="$1" detect="$2" path
	if [ -n "$detect" ] && [ "$detect" != '[]' ]; then
		while IFS= read -r path; do
			# The mapping syntax uses a literal ~/ prefix; expansion is intentionally explicit.
			# shellcheck disable=SC2088
			if [[ "$path" == '~/'* ]]; then path="$HOME/${path:1}"; fi
			if [ -e "$path" ]; then
				bp_present cask
				return 0
			fi
		done < <(printf '%s\n' "$detect" | "$BP_JQ_BIN" -r '.[]')
	fi
	bp_gui "Install cask $token manually."
}

bp_run_timed() {
	local base="$1" timeout="$2" marker="$1.timeout" pid timer status elapsed
	shift 2
	rm -f "$marker"
	"$@" >"$base.out" 2>"$base.err" &
	pid=$!
	(
		elapsed=0
		while [ "$elapsed" -lt "$timeout" ]; do
			sleep 1
			kill -0 "$pid" 2>/dev/null || exit 0
			elapsed=$((elapsed + 1))
		done
		: >"$marker"
		kill -TERM "$pid" 2>/dev/null || true
	) &
	timer=$!
	if wait "$pid"; then status=0; else status=$?; fi
	kill "$timer" 2>/dev/null || true
	wait "$timer" 2>/dev/null || true
	[ ! -f "$marker" ] || return 124
	return "$status"
}

bp_plan_brewfiles() {
	local brewfile line conditional_depth
	local raw="$BP_TMP_DIR/plan-raw"
	BP_PLAN="$BP_TMP_DIR/plan"
	: >"$raw"
	for brewfile in "$@"; do
		conditional_depth=0
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
			printf '%s\t%s\t%s\n' "$BP_DECLARATION_KIND" "$BP_DECLARATION_TOKEN" "$BP_DECLARATION_NAME" >>"$raw"
		done <"$brewfile"
	done
	awk -F '\t' '!seen[$1 FS $2]++' "$raw" >"$BP_PLAN"
}

bp_prepare_execution_plan() {
	local kind token name row action target note arches detect source
	BP_PORT_PLAN="$BP_TMP_DIR/port-plan"
	BP_FALLBACK_PLAN="$BP_TMP_DIR/fallback-plan"
	BP_CASK_PLAN="$BP_TMP_DIR/cask-plan"
	BP_MAS_PLAN="$BP_TMP_DIR/mas-plan"
	: >"$BP_PORT_PLAN"
	: >"$BP_FALLBACK_PLAN"
	: >"$BP_CASK_PLAN"
	: >"$BP_MAS_PLAN"
	while IFS=$'\t' read -r kind token name; do
		case "$kind" in
		mas)
			printf '%s\t%s\n' "$token" "$name" >>"$BP_MAS_PLAN"
			continue
			;;
		esac
		row="$(bp_lookup_mapping "$kind" "$token" || true)"
		if [ -z "$row" ]; then
			if [ "$kind" = brew ]; then
				printf '%s\t%s\n' "$token" "$token" >>"$BP_PORT_PLAN"
			else
				printf '%s\t[]\n' "$token" >>"$BP_CASK_PLAN"
			fi
			continue
		fi
		IFS=$'\034' read -r action target note arches detect source <<EOF
$row
EOF
		case "$action" in
		port) printf '%s\t%s\n' "$token" "$target" >>"$BP_PORT_PLAN" ;;
		fallback | fallback-root) printf '%s\t%s\n' "$kind" "$token" >>"$BP_FALLBACK_PLAN" ;;
		manual) printf '%s\t%s\n' "$token" "$detect" >>"$BP_CASK_PLAN" ;;
		skip) bp_unresolved "$token" "$(bp_decode_mapping_note "$note")" ;;
		esac
	done <"$BP_PLAN"
}

bp_mas_label() {
	local id="$1" name
	name="$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$BP_MAS_PLAN")"
	printf '%s (%s)\n' "${name:-Mac App Store app}" "$id"
}

bp_mas_ids_from_list() {
	awk '$1 ~ /^[0-9]+$/ { print $1 }' "$1"
}

bp_reconcile_mas() {
	[ -s "$BP_MAS_PLAN" ] || return 0
	local mas_bin timeout list_base lookup_base install_base verify_base id status detail
	local all_ids="$BP_TMP_DIR/mas-all" installed_ids="$BP_TMP_DIR/mas-installed" missing_ids="$BP_TMP_DIR/mas-missing"
	local valid_ids="$BP_TMP_DIR/mas-valid" install_ids="$BP_TMP_DIR/mas-install"
	mas_bin="$(command -v mas 2>/dev/null || true)"
	if [ -z "$mas_bin" ]; then
		while IFS=$'\t' read -r id _; do bp_action_failed "$(bp_mas_label "$id")" 'mas client is unavailable.'; done <"$BP_MAS_PLAN"
		return 0
	fi
	awk -F '\t' '{ print $1 }' "$BP_MAS_PLAN" >"$all_ids"
	if "$BP_DRY_RUN"; then
		bp_log "Would reconcile Mac App Store apps: $(paste -sd ' ' "$all_ids")"
		return 0
	fi
	timeout="${BREW_PORT_MAS_TIMEOUT:-30}"
	[[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=30
	list_base="$BP_TMP_DIR/mas-list"
	local -a ids=()
	while IFS= read -r id; do ids+=("$id"); done <"$all_ids"
	if bp_run_timed "$list_base" "$timeout" "$mas_bin" list "${ids[@]}"; then
		bp_mas_ids_from_list "$list_base.out" >"$installed_ids"
	elif [ -e "$list_base.timeout" ]; then
		: >"$installed_ids"
		bp_unresolved mas "Installed-app scan timed out after ${timeout}s; attempting one batch install."
	elif grep -Fq 'No installed apps found' "$list_base.err" "$list_base.out"; then
		: >"$installed_ids"
	else
		: >"$installed_ids"
		bp_unresolved mas 'Installed-app scan failed; attempting one batch install.'
	fi
	: >"$missing_ids"
	while IFS= read -r id; do
		if grep -Fxq -- "$id" "$installed_ids"; then bp_present mas; else printf '%s\n' "$id" >>"$missing_ids"; fi
	done <"$all_ids"
	[ -s "$missing_ids" ] || return 0
	ids=()
	while IFS= read -r id; do ids+=("$id"); done <"$missing_ids"
	lookup_base="$BP_TMP_DIR/mas-lookup"
	: >"$install_ids"
	if bp_run_timed "$lookup_base" "$timeout" "$mas_bin" lookup --json "${ids[@]}"; then
		if "$BP_JQ_BIN" -r '(.id // .trackId // .adamId // empty) | tostring' "$lookup_base.out" >"$valid_ids" 2>/dev/null; then
			while IFS= read -r id; do
				if grep -Fxq -- "$id" "$valid_ids"; then
					printf '%s\n' "$id" >>"$install_ids"
				else
					bp_action_failed "$(bp_mas_label "$id")" 'Mac App Store ID is unavailable.'
				fi
			done <"$missing_ids"
		else
			cp "$missing_ids" "$install_ids"
			bp_unresolved mas 'Availability results could not be parsed; attempting one batch install.'
		fi
	elif [ -e "$lookup_base.timeout" ]; then
		cp "$missing_ids" "$install_ids"
		bp_unresolved mas "Availability scan timed out after ${timeout}s; attempting one batch install."
	else
		cp "$missing_ids" "$install_ids"
		bp_unresolved mas 'Availability scan failed; attempting one batch install.'
	fi
	[ -s "$install_ids" ] || return 0
	ids=()
	while IFS= read -r id; do ids+=("$id"); done <"$install_ids"
	install_base="$BP_TMP_DIR/mas-install"
	if bp_run_timed "$install_base" "$timeout" "$mas_bin" install "${ids[@]}"; then
		verify_base="$BP_TMP_DIR/mas-verify"
		if bp_run_timed "$verify_base" "$timeout" "$mas_bin" list "${ids[@]}"; then
			bp_mas_ids_from_list "$verify_base.out" >"$installed_ids"
			while IFS= read -r id; do
				if grep -Fxq -- "$id" "$installed_ids"; then bp_installed "$(bp_mas_label "$id")"; else bp_action_failed "$(bp_mas_label "$id")" 'Install completed but the app is still missing.'; fi
			done <"$install_ids"
		else
			while IFS= read -r id; do bp_installed "$(bp_mas_label "$id")"; done <"$install_ids"
			bp_unresolved mas 'Post-install verification timed out or failed; batch install reported success.'
		fi
	elif [ -e "$install_base.timeout" ]; then
		bp_unresolved mas "Batch install timed out after ${timeout}s; returning success to the caller."
	else
		detail="$(sed -n '1p' "$install_base.err")"
		while IFS= read -r id; do bp_action_failed "$(bp_mas_label "$id")" "${detail:-Mac App Store batch install failed.}"; done <"$install_ids"
	fi
}

bp_reconcile_brewfiles() {
	local kind token detect
	bp_plan_brewfiles "$@"
	bp_prepare_execution_plan
	if [ -s "$BP_PORT_PLAN" ]; then
		bp_snapshot_active_ports
		bp_install_port_plan "$BP_PORT_PLAN"
	fi
	if [ -s "$BP_FALLBACK_PLAN" ]; then
		bp_selfupdate
		while IFS=$'\t' read -r kind token; do bp_run_mapping "$kind" "$token"; done <"$BP_FALLBACK_PLAN"
	fi
	while IFS=$'\t' read -r token detect; do bp_run_manual_cask "$token" "$detect"; done <"$BP_CASK_PLAN"
	bp_reconcile_mas
}

bp_refresh_fallbacks() {
	local kind token row action inventory_entries unique_entries
	inventory_entries="$BP_TMP_DIR/fallback-inventory.tsv"
	unique_entries="$BP_TMP_DIR/fallback-inventory-unique.tsv"
	if ! bp_fallback_inventory_entries >"$inventory_entries"; then
		bp_die "Invalid fallback inventory: $BP_FALLBACK_INVENTORY"
	fi
	if ! awk -F '\t' '!seen[$0]++' "$inventory_entries" >"$unique_entries"; then
		bp_die 'Could not read fallback inventory.'
	fi
	while IFS=$'\t' read -r kind token; do
		row="$(bp_lookup_mapping "$kind" "$token" || true)"
		[ -n "$row" ] || continue
		action="${row%%$'\034'*}"
		case "$action" in fallback | fallback-root) bp_run_mapping "$kind" "$token" ;; esac
	done <"$unique_entries"
}
