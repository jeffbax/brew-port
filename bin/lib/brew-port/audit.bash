bp_audit_init() {
	BP_AUDIT_PORT_CATALOG="$BP_TMP_DIR/audit-port-catalog"
	BP_AUDIT_ACTIVE="$BP_TMP_DIR/audit-active"
	BP_AUDIT_INACTIVE="$BP_TMP_DIR/audit-inactive"
	BP_AUDIT_UNAVAILABLE="$BP_TMP_DIR/audit-unavailable"
	BP_AUDIT_FALLBACKS="$BP_TMP_DIR/audit-fallbacks"
	BP_AUDIT_CASK_PRESENT="$BP_TMP_DIR/audit-cask-present"
	BP_AUDIT_CASK_MISSING="$BP_TMP_DIR/audit-cask-missing"
	BP_AUDIT_CASK_UNMAPPED="$BP_TMP_DIR/audit-cask-unmapped"
	BP_AUDIT_MAS_PLAN="$BP_TMP_DIR/audit-mas-plan"
	BP_AUDIT_MAS_INSTALLED="$BP_TMP_DIR/audit-mas-installed"
	BP_AUDIT_MAS_MISSING="$BP_TMP_DIR/audit-mas-missing"
	BP_AUDIT_MAS_INVALID="$BP_TMP_DIR/audit-mas-invalid"
	BP_AUDIT_MAS_UNKNOWN="$BP_TMP_DIR/audit-mas-unknown"
	BP_AUDIT_SKIPPED="$BP_TMP_DIR/audit-skipped"
	BP_AUDIT_CANDIDATE_CASKS="$BP_TMP_DIR/audit-candidate-casks"
	BP_AUDIT_CANDIDATE_PAIRS="$BP_TMP_DIR/audit-candidate-pairs"
	BP_AUDIT_CANDIDATE_NONE="$BP_TMP_DIR/audit-candidate-none"
	BP_AUDIT_CANDIDATE_PORTS="$BP_TMP_DIR/audit-candidate-ports"
	BP_AUDIT_CANDIDATE_INFO="$BP_TMP_DIR/audit-candidate-info"
	BP_AUDIT_CANDIDATE_LIVECHECK="$BP_TMP_DIR/audit-candidate-livecheck"
	BP_AUDIT_CANDIDATE_DATES="$BP_TMP_DIR/audit-candidate-dates"
	BP_AUDIT_CANDIDATE_DATE_BUDGET="$BP_TMP_DIR/audit-candidate-date-budget"
	BP_AUDIT_CANDIDATE_DATE_BUDGET_WARNED="$BP_TMP_DIR/audit-candidate-date-budget-warned"
	BP_AUDIT_CANDIDATE_ARCHIVES="$BP_TMP_DIR/audit-candidate-archives"
	BP_AUDIT_CANDIDATE_DETAILS="$BP_TMP_DIR/audit-candidate-details"
	BP_AUDIT_BLOCKERS="$BP_TMP_DIR/audit-blockers"
	BP_AUDIT_WARNINGS="$BP_TMP_DIR/audit-warnings"
	local file
	for file in "$BP_AUDIT_PORT_CATALOG" "$BP_AUDIT_ACTIVE" "$BP_AUDIT_INACTIVE" "$BP_AUDIT_UNAVAILABLE" "$BP_AUDIT_FALLBACKS" "$BP_AUDIT_CASK_PRESENT" "$BP_AUDIT_CASK_MISSING" "$BP_AUDIT_CASK_UNMAPPED" "$BP_AUDIT_MAS_PLAN" "$BP_AUDIT_MAS_INSTALLED" "$BP_AUDIT_MAS_MISSING" "$BP_AUDIT_MAS_INVALID" "$BP_AUDIT_MAS_UNKNOWN" "$BP_AUDIT_SKIPPED" "$BP_AUDIT_CANDIDATE_CASKS" "$BP_AUDIT_CANDIDATE_PAIRS" "$BP_AUDIT_CANDIDATE_NONE" "$BP_AUDIT_CANDIDATE_PORTS" "$BP_AUDIT_CANDIDATE_INFO" "$BP_AUDIT_CANDIDATE_LIVECHECK" "$BP_AUDIT_CANDIDATE_DATES" "$BP_AUDIT_CANDIDATE_DATE_BUDGET" "$BP_AUDIT_CANDIDATE_ARCHIVES" "$BP_AUDIT_CANDIDATE_DETAILS" "$BP_AUDIT_BLOCKERS" "$BP_AUDIT_WARNINGS"; do
		: >"$file"
	done
}

bp_audit_record() { printf '%s\t%s\n' "$1" "$2" >>"$3"; }
bp_audit_block() { bp_audit_record "$1" "$2" "$BP_AUDIT_BLOCKERS"; }
bp_audit_warn() { bp_audit_record "$1" "$2" "$BP_AUDIT_WARNINGS"; }

bp_audit_count() { awk 'END { print NR + 0 }' "$1"; }

bp_audit_sanitize_detail() {
	local detail
	detail="$(printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -cd '[:print:]' | awk '{$1 = $1; print; exit}')"
	if [ "${#detail}" -gt 180 ]; then detail="${detail:0:177}..."; fi
	printf '%s' "$detail"
}

bp_audit_command_detail() {
	local file line detail
	for file in "$@"; do
		[ -r "$file" ] || continue
		while IFS= read -r line || [ -n "$line" ]; do
			detail="$(bp_audit_sanitize_detail "$line")"
			if [ -n "$detail" ]; then
				printf '%s' "$detail"
				return 0
			fi
		done <"$file"
	done
	return 1
}

bp_audit_candidate_normalize() {
	printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd '[:alnum:]'
}

bp_audit_candidate_base() {
	local token="${1%@*}"
	case "$token" in
	*-app) token="${token%-app}" ;;
	*-desktop) token="${token%-desktop}" ;;
	esac
	printf '%s' "$token"
}

bp_audit_candidate_cask() {
	local token="$1" raw raw_norm base base_norm selected
	printf '%s\n' "$token" >>"$BP_AUDIT_CANDIDATE_CASKS"
	raw_norm="$(bp_audit_candidate_normalize "$token")"
	base="$(bp_audit_candidate_base "$token")"
	base_norm="$(bp_audit_candidate_normalize "$base")"
	[ -n "$base_norm" ] || return 0
	raw="$(mktemp "$BP_TMP_DIR/audit-candidate.XXXXXX")"
	awk -v raw="$raw_norm" -v base="$base_norm" '
		function normalize(value) {
			value = tolower(value)
			gsub(/[^[:alnum:]]/, "", value)
			return value
		}
		{
			port = $0
			port_norm = normalize(port)
			if (port_norm == raw) rank = 1
			else if (port_norm == base) rank = 2
			else if (index(port_norm, base) == 1) rank = 3
			else if (index(port_norm, base)) rank = 4
			else next
			print rank "\t" port_norm "\t" port
		}
	' "$BP_AUDIT_PORT_CATALOG" >"$raw"
	selected="$(mktemp "$BP_TMP_DIR/audit-candidate-selected.XXXXXX")"
	LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$raw" | awk -F '\t' -v token="$token" '!seen[$3]++ && ++count <= 3 { print token "\t" $3 "\t" count }' >"$selected"
	if [ -s "$selected" ]; then
		sed -n 'p' "$selected" >>"$BP_AUDIT_CANDIDATE_PAIRS"
	else
		printf '%s\n' "$token" >>"$BP_AUDIT_CANDIDATE_NONE"
	fi
	rm -f "$raw" "$selected"
}

bp_audit_candidate_info_value() {
	awk -F '\t' -v port="$1" -v field="$2" '$1 == port { print $field; exit }' "$BP_AUDIT_CANDIDATE_INFO"
}

bp_audit_candidate_livecheck() {
	local port="$1" detail
	detail="$(awk -v prefix="$port " 'index($0, prefix) == 1 { sub(prefix, ""); print; exit }' "$BP_AUDIT_CANDIDATE_LIVECHECK")"
	detail="$(bp_audit_sanitize_detail "$detail")"
	printf '%s' "${detail:-unknown}"
}

bp_audit_candidate_timeout() {
	local timeout="${BREW_PORT_CANDIDATE_TIMEOUT:-10}"
	[[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=10
	printf '%s' "$timeout"
}

bp_audit_candidate_portfile_date() {
	local portdir="$1" cached base date detail timeout budget started now elapsed remaining
	cached="$(awk -F '\t' -v portdir="$portdir" '$1 == portdir { print $2; exit }' "$BP_AUDIT_CANDIDATE_DATES")"
	if [ -n "$cached" ]; then
		printf '%s' "$cached"
		return 0
	fi
	if [ -z "${BP_CURL_BIN:-}" ] || [ ! -x "$BP_CURL_BIN" ]; then
		bp_audit_warn candidates "Portfile update date for $portdir is unknown: curl is unavailable."
		printf '%s\tunknown\n' "$portdir" >>"$BP_AUDIT_CANDIDATE_DATES"
		printf '%s' unknown
		return 0
	fi
	budget="${BREW_PORT_CANDIDATE_DATE_BUDGET:-15}"
	[[ "$budget" =~ ^[0-9]+$ ]] && [ "$budget" -gt 0 ] || budget=15
	if [ ! -s "$BP_AUDIT_CANDIDATE_DATE_BUDGET" ]; then date +%s >"$BP_AUDIT_CANDIDATE_DATE_BUDGET"; fi
	started="$(sed -n '1p' "$BP_AUDIT_CANDIDATE_DATE_BUDGET")"
	now="$(date +%s)"
	elapsed=$((now - started))
	remaining=$((budget - elapsed))
	if [ "$remaining" -le 0 ]; then
		if [ ! -e "$BP_AUDIT_CANDIDATE_DATE_BUDGET_WARNED" ]; then
			bp_audit_warn candidates "Portfile update lookups exceeded their ${budget}s budget; remaining dates are unknown."
			: >"$BP_AUDIT_CANDIDATE_DATE_BUDGET_WARNED"
		fi
		printf '%s\tunknown\n' "$portdir" >>"$BP_AUDIT_CANDIDATE_DATES"
		printf '%s' unknown
		return 0
	fi
	timeout="$(bp_audit_candidate_timeout)"
	[ "$timeout" -le "$remaining" ] || timeout="$remaining"
	base="$BP_TMP_DIR/audit-portfile-date-${portdir//\//_}"
	if bp_run_timed "$base" "$timeout" "$BP_CURL_BIN" -fsSL "https://api.github.com/repos/macports/macports-ports/commits?path=$portdir/Portfile&per_page=1"; then
		date="$("$BP_JQ_BIN" -r '.[0].commit.committer.date // .[0].commit.author.date // empty' "$base.out" 2>/dev/null || true)"
		date="${date%%T*}"
	else
		date=''
	fi
	if [ -z "$date" ]; then
		detail="$(bp_audit_command_detail "$base.err" "$base.out" || true)"
		bp_audit_warn candidates "Portfile update date for $portdir is unknown${detail:+: $detail}."
		date=unknown
	fi
	printf '%s\t%s\n' "$portdir" "$date" >>"$BP_AUDIT_CANDIDATE_DATES"
	printf '%s' "$date"
}

bp_audit_verify_candidate_archives() {
	[ -s "$BP_AUDIT_CANDIDATE_PORTS" ] || return 0
	bp_start_sudo
	local port base detail status
	while IFS= read -r port; do
		base="$BP_TMP_DIR/audit-candidate-archive-${port//\//_}"
		if bp_port -b archivefetch "$port" >"$base.out" 2>"$base.err"; then
			status='available (fetched or already cached)'
		else
			detail="$(bp_audit_command_detail "$base.err" "$base.out" || true)"
			if grep -Fq 'not found, required when binary-only' "$base.out" "$base.err"; then
				status='unavailable for this MacPorts host'
			else
				status="verification failed${detail:+: $detail}"
			fi
			bp_audit_warn "candidate $port" "Binary archive $status."
		fi
		printf '%s\t%s\n' "$port" "$status" >>"$BP_AUDIT_CANDIDATE_ARCHIVES"
	done <"$BP_AUDIT_CANDIDATE_PORTS"
}

bp_audit_candidate_archive_status() {
	local port="$1" status
	status="$(awk -F '\t' -v port="$port" '$1 == port { print $2; exit }' "$BP_AUDIT_CANDIDATE_ARCHIVES")"
	if [ -n "$status" ]; then
		printf '%s' "$status"
	elif "$BP_AUDIT_VERIFY_ARCHIVES"; then
		printf '%s' 'unknown'
	else
		printf '%s' 'not checked (run with --verify-archives)'
	fi
}

bp_audit_enrich_candidates() {
	[ "$BP_AUDIT_SHOW_CANDIDATES" = true ] || return 0
	[ -s "$BP_AUDIT_CANDIDATE_PAIRS" ] || return 0
	cut -f2 "$BP_AUDIT_CANDIDATE_PAIRS" | LC_ALL=C sort -u >"$BP_AUDIT_CANDIDATE_PORTS"
	local -a ports=()
	local port cask rank version revision portdir livecheck date archive timeout livecheck_base detail
	while IFS= read -r port; do ports+=("$port"); done <"$BP_AUDIT_CANDIDATE_PORTS"
	if ! "$BP_PORT_BIN" info --index --line --name --version --revision --portdir "${ports[@]}" >"$BP_AUDIT_CANDIDATE_INFO" 2>"$BP_TMP_DIR/audit-candidate-info.err"; then
		detail="$(bp_audit_command_detail "$BP_TMP_DIR/audit-candidate-info.err" || true)"
		bp_audit_warn candidates "MacPorts candidate metadata is incomplete${detail:+: $detail}."
	fi
	timeout="$(bp_audit_candidate_timeout)"
	livecheck_base="$BP_TMP_DIR/audit-candidate-livecheck"
	if bp_run_timed "$livecheck_base" "$timeout" "$BP_PORT_BIN" livecheck -v "${ports[@]}"; then
		cp "$livecheck_base.out" "$BP_AUDIT_CANDIDATE_LIVECHECK"
	else
		cp "$livecheck_base.out" "$BP_AUDIT_CANDIDATE_LIVECHECK"
		if [ -e "$livecheck_base.timeout" ]; then
			bp_audit_warn candidates "MacPorts livecheck timed out after ${timeout}s; upstream versions are incomplete."
		else
			detail="$(bp_audit_command_detail "$livecheck_base.err" "$livecheck_base.out" || true)"
			bp_audit_warn candidates "MacPorts livecheck failed; upstream versions are incomplete${detail:+: $detail}."
		fi
	fi
	if "$BP_AUDIT_VERIFY_ARCHIVES"; then bp_audit_verify_candidate_archives; fi
	while IFS=$'\t' read -r cask port rank; do
		version="$(bp_audit_candidate_info_value "$port" 2)"
		revision="$(bp_audit_candidate_info_value "$port" 3)"
		portdir="$(bp_audit_candidate_info_value "$port" 4)"
		livecheck="$(bp_audit_candidate_livecheck "$port")"
		if [ -n "$portdir" ]; then date="$(bp_audit_candidate_portfile_date "$portdir")"; else date=unknown; fi
		archive="$(bp_audit_candidate_archive_status "$port")"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cask" "$rank" "$port" "${version:-unknown}" "${revision:-unknown}" "$livecheck" "$date" "$archive" >>"$BP_AUDIT_CANDIDATE_DETAILS"
	done <"$BP_AUDIT_CANDIDATE_PAIRS"
}

bp_audit_snapshot_ports() {
	"$BP_PORT_BIN" -q echo all >"$BP_AUDIT_PORT_CATALOG" || bp_die 'Could not inspect the MacPorts catalog.'
	bp_snapshot_active_ports
}

bp_audit_port() {
	# Catalog and active snapshots contain base names, without versions or variants.
	local label="$1" target="$2" port="${2%%[@+[:space:]]*}"
	if ! grep -Fxq -- "$port" "$BP_AUDIT_PORT_CATALOG"; then
		bp_audit_record "$label" "$target" "$BP_AUDIT_UNAVAILABLE"
		bp_audit_block "$label" "MacPorts port is unavailable: $target."
	elif bp_port_is_active "$port"; then
		bp_audit_record "$label" "$target" "$BP_AUDIT_ACTIVE"
	else
		bp_audit_record "$label" "$target" "$BP_AUDIT_INACTIVE"
		bp_audit_block "$label" "MacPorts port is available but inactive: $target."
	fi
}

bp_audit_fallback() {
	local label="$1" action="$2" target="$3" arches="$4" source="$5" fallback_path
	if ! bp_arch_supported "$arches"; then
		bp_audit_block "$label" "No verified native fallback for $BP_ARCH."
		return
	fi
	if ! fallback_path="$(bp_mapping_fallback_path "$source" "$target")"; then
		bp_audit_block "$label" "Fallback target escapes the map fallbacks directory: $target."
		return
	fi
	if [ ! -f "$fallback_path" ]; then
		bp_audit_block "$label" "Fallback is missing: $target."
		return
	fi
	if ! bash -n "$fallback_path" >/dev/null 2>&1; then
		bp_audit_block "$label" "Fallback has invalid Bash syntax: $target."
		return
	fi
	bp_audit_record "$label" "$action; runtime presence not verified" "$BP_AUDIT_FALLBACKS"
}

bp_audit_manual_cask() {
	local label="$1" detect="$2" path expanded found='' candidates=''
	while IFS= read -r path; do
		expanded="$path"
		# The mapping syntax uses a literal ~/ prefix; expansion is intentionally explicit.
		# shellcheck disable=SC2088
		if [[ "$expanded" == '~/'* ]]; then expanded="$HOME/${expanded:1}"; fi
		candidates="${candidates:+$candidates, }$expanded"
		[ -e "$expanded" ] && found="$expanded"
	done < <(printf '%s\n' "$detect" | "$BP_JQ_BIN" -r '.[]')
	if [ -n "$found" ]; then
		bp_audit_record "$label" "$found" "$BP_AUDIT_CASK_PRESENT"
	else
		bp_audit_record "$label" "$candidates" "$BP_AUDIT_CASK_MISSING"
		bp_audit_block "$label" 'No configured detection path exists.'
	fi
}

bp_audit_mas_label() { printf '%s (%s)\n' "${2:-Mac App Store app}" "$1"; }

bp_audit_mas() {
	[ -s "$BP_AUDIT_MAS_PLAN" ] || return 0
	local mas_bin timeout list_base lookup_base id name label list_ok=false lookup_ok=false
	local all_ids="$BP_TMP_DIR/audit-mas-all" installed_ids="$BP_TMP_DIR/audit-mas-installed-ids" valid_ids="$BP_TMP_DIR/audit-mas-valid-ids"
	local missing_ids="$BP_TMP_DIR/audit-mas-missing-ids" invalid_ids="$BP_TMP_DIR/audit-mas-invalid-ids"
	: >"$missing_ids"
	: >"$invalid_ids"
	mas_bin="$(bp_command_path mas)"
	if [ -z "$mas_bin" ]; then
		while IFS=$'\t' read -r id name; do bp_audit_record "$(bp_audit_mas_label "$id" "$name")" 'MAS client is unavailable.' "$BP_AUDIT_MAS_UNKNOWN"; done <"$BP_AUDIT_MAS_PLAN"
		bp_audit_warn mas 'MAS client is unavailable; installed and availability states are unknown.'
		return
	fi
	awk -F '\t' '{ print $1 }' "$BP_AUDIT_MAS_PLAN" >"$all_ids"
	timeout="${BREW_PORT_MAS_TIMEOUT:-30}"
	[[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=30
	local -a ids=()
	while IFS= read -r id; do ids+=("$id"); done <"$all_ids"
	list_base="$BP_TMP_DIR/audit-mas-list"
	if bp_run_timed "$list_base" "$timeout" "$mas_bin" list "${ids[@]}"; then
		list_ok=true
	elif [ -e "$list_base.timeout" ]; then
		bp_audit_warn mas "Installed-app scan timed out after ${timeout}s; installed state is unknown."
	elif grep -Fq 'No installed apps found' "$list_base.err" "$list_base.out"; then
		list_ok=true
	else
		sed -nE 's/.*No installed apps with ADAM ID ([0-9]+).*/\1/p' "$list_base.err" >"$missing_ids"
		if [ ! -s "$missing_ids" ] || grep -Evq 'No installed apps with ADAM ID [0-9]+|^[[:space:]]*$' "$list_base.err"; then
			local detail
			detail="$(bp_audit_command_detail "$list_base.err" "$list_base.out" || true)"
			bp_audit_warn mas "Installed-app scan failed${detail:+: $detail}; installed state is unknown."
		fi
	fi
	# MAS can return useful stdout and per-ID errors in the same failed batch.
	bp_mas_ids_from_list "$list_base.out" >"$installed_ids"
	lookup_base="$BP_TMP_DIR/audit-mas-lookup"
	if bp_run_timed "$lookup_base" "$timeout" "$mas_bin" lookup --json "${ids[@]}"; then
		lookup_ok=true
	elif [ -e "$lookup_base.timeout" ]; then
		bp_audit_warn mas "Availability scan timed out after ${timeout}s; App Store availability is unknown."
	else
		sed -nE 's/.*No apps found in the App Store for ADAM ID ([0-9]+).*/\1/p' "$lookup_base.err" >"$invalid_ids"
		if [ ! -s "$invalid_ids" ] || grep -Evq 'No apps found in the App Store for ADAM ID [0-9]+|^[[:space:]]*$' "$lookup_base.err"; then
			local detail
			detail="$(bp_audit_command_detail "$lookup_base.err" "$lookup_base.out" || true)"
			bp_audit_warn mas "Availability scan failed${detail:+: $detail}; App Store availability is unknown."
		fi
	fi
	if ! "$BP_JQ_BIN" -r '(.id // .trackId // .adamID // .adamId // empty) | tostring' "$lookup_base.out" >"$valid_ids" 2>/dev/null; then
		: >"$valid_ids"
		lookup_ok=false
		bp_audit_warn mas 'Availability results could not be parsed; App Store availability is unknown.'
	fi
	while IFS=$'\t' read -r id name; do
		label="$(bp_audit_mas_label "$id" "$name")"
		if grep -Fxq -- "$id" "$invalid_ids" || { "$lookup_ok" && ! grep -Fxq -- "$id" "$valid_ids"; }; then
			bp_audit_record "$label" 'Mac App Store ID is unavailable.' "$BP_AUDIT_MAS_INVALID"
			bp_audit_block "$label" 'Mac App Store ID is unavailable.'
		elif grep -Fxq -- "$id" "$installed_ids"; then
			bp_audit_record "$label" 'installed' "$BP_AUDIT_MAS_INSTALLED"
		elif { "$lookup_ok" || grep -Fxq -- "$id" "$valid_ids"; } && { "$list_ok" || grep -Fxq -- "$id" "$missing_ids"; }; then
			bp_audit_record "$label" 'not installed' "$BP_AUDIT_MAS_MISSING"
			bp_audit_block "$label" 'Mac App Store app is not installed.'
		else
			bp_audit_record "$label" 'installed state or App Store availability is unknown.' "$BP_AUDIT_MAS_UNKNOWN"
		fi
	done <"$BP_AUDIT_MAS_PLAN"
}

bp_audit_brewfiles() {
	local kind token name row action target note arches detect source label
	bp_report_init
	bp_audit_init
	# bp_plan_brewfiles consumes this strict mode while preserving install's permissive parser.
	# shellcheck disable=SC2034
	BP_STRICT_BREWFILE_PARSING=true
	bp_plan_brewfiles "$@"
	while IFS=$'\t' read -r label note; do bp_audit_block "$label" "$note"; done <"$BP_WARNINGS"
	bp_audit_snapshot_ports
	while IFS=$'\t' read -r kind token name; do
		if [ "$kind" = mas ]; then
			bp_audit_record "$token" "$name" "$BP_AUDIT_MAS_PLAN"
			continue
		fi
		label="$kind $token"
		row="$(bp_lookup_mapping "$kind" "$token" || true)"
		if [ -z "$row" ]; then
			if [ "$kind" = brew ]; then
				bp_audit_port "$label" "$token"
			else
				if "$BP_AUDIT_SHOW_CANDIDATES"; then bp_audit_candidate_cask "$token"; fi
				bp_audit_record "$label" 'No mapping or detection path.' "$BP_AUDIT_CASK_UNMAPPED"
				bp_audit_block "$label" 'No mapping or detection path.'
			fi
			continue
		fi
		IFS=$'\034' read -r action target note arches detect source <<EOF
$row
EOF
		case "$action" in
		port) bp_audit_port "$label" "$target" ;;
		fallback | fallback-root)
			if "$BP_AUDIT_SHOW_CANDIDATES" && [ "$kind" = cask ]; then bp_audit_candidate_cask "$token"; fi
			bp_audit_fallback "$label" "$action" "$target" "$arches" "$source"
			;;
		manual)
			if "$BP_AUDIT_SHOW_CANDIDATES"; then bp_audit_candidate_cask "$token"; fi
			bp_audit_manual_cask "$label" "$detect"
			;;
		skip)
			if "$BP_AUDIT_SHOW_CANDIDATES" && [ "$kind" = cask ]; then bp_audit_candidate_cask "$token"; fi
			note="$(bp_decode_mapping_note "$note")"
			bp_audit_record "$label" "${note:-No replacement requested.}" "$BP_AUDIT_SKIPPED"
			;;
		esac
	done <"$BP_PLAN"
	bp_audit_mas
	bp_audit_enrich_candidates
}

bp_audit_print_group() {
	[ -s "$2" ] || return 0
	bp_log "$1:"
	sed 's/\t/: /; s/^/  /' "$2"
}

bp_audit_report() {
	local blockers warnings
	blockers="$(bp_audit_count "$BP_AUDIT_BLOCKERS")"
	warnings="$(bp_audit_count "$BP_AUDIT_WARNINGS")"
	bp_log 'Migration audit:'
	bp_log "MacPorts targets: active $(bp_audit_count "$BP_AUDIT_ACTIVE"), inactive $(bp_audit_count "$BP_AUDIT_INACTIVE"), unavailable $(bp_audit_count "$BP_AUDIT_UNAVAILABLE")"
	bp_log "Reviewed fallbacks: $(bp_audit_count "$BP_AUDIT_FALLBACKS") (runtime presence not verified)"
	bp_log "Manual casks: detected $(bp_audit_count "$BP_AUDIT_CASK_PRESENT"), missing $(bp_audit_count "$BP_AUDIT_CASK_MISSING"), unmapped $(bp_audit_count "$BP_AUDIT_CASK_UNMAPPED")"
	bp_log "Mac App Store apps: installed $(bp_audit_count "$BP_AUDIT_MAS_INSTALLED"), missing $(bp_audit_count "$BP_AUDIT_MAS_MISSING"), invalid $(bp_audit_count "$BP_AUDIT_MAS_INVALID"), unknown $(bp_audit_count "$BP_AUDIT_MAS_UNKNOWN")"
	if "$BP_AUDIT_SHOW_CANDIDATES"; then
		bp_log "MacPorts candidates: $(bp_audit_count "$BP_AUDIT_CANDIDATE_DETAILS") suggestions for $(bp_audit_count "$BP_AUDIT_CANDIDATE_CASKS") casks (advisory)"
		if [ -s "$BP_AUDIT_CANDIDATE_DETAILS" ] || [ -s "$BP_AUDIT_CANDIDATE_NONE" ]; then
			local cask rank port version revision livecheck date archive previous=''
			bp_log 'Candidate MacPorts ports (advisory):'
			while IFS=$'\t' read -r cask rank port version revision livecheck date archive; do
				if [ "$cask" != "$previous" ]; then
					bp_log "  cask $cask:"
					previous="$cask"
				fi
				bp_log "    $rank. $port @${version}_${revision}"
				bp_log "       upstream: $livecheck"
				bp_log "       Portfile last changed: $date"
				bp_log "       binary archive: $archive"
			done <"$BP_AUDIT_CANDIDATE_DETAILS"
			while IFS= read -r cask; do bp_log "  cask $cask: no name-based MacPorts candidate."; done <"$BP_AUDIT_CANDIDATE_NONE"
		fi
	fi
	bp_audit_print_group 'Fallback coverage' "$BP_AUDIT_FALLBACKS"
	bp_audit_print_group 'Intentionally excluded' "$BP_AUDIT_SKIPPED"
	bp_audit_print_group 'Blockers' "$BP_AUDIT_BLOCKERS"
	bp_audit_print_group 'Warnings' "$BP_AUDIT_WARNINGS"
	if [ "$blockers" -gt 0 ]; then
		bp_log 'Result: blocked'
		return 1
	fi
	if [ "$warnings" -gt 0 ]; then
		bp_log 'Result: coverage complete with warnings'
	else
		bp_log 'Result: coverage complete'
	fi
}
