# Imported Homebrew service snapshots. Only brew-port-owned user LaunchAgents are supported.

BP_CURL_BIN="${BREW_PORT_CURL_BIN:-curl}"
BP_LAUNCHCTL_BIN="${BREW_PORT_LAUNCHCTL_BIN:-launchctl}"
BP_PLUTIL_BIN="${BREW_PORT_PLUTIL_BIN:-plutil}"

bp_init_services() {
	BP_SERVICE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/brew-port"
	BP_SERVICE_FILE="$BP_SERVICE_CONFIG_DIR/services.json"
	BP_SERVICE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/brew-port/services"
}

bp_services_require_jq() {
	bp_find_jq
	[ -n "$BP_JQ_BIN" ] && [ -x "$BP_JQ_BIN" ] || bp_die 'jq is required to inspect imported services.'
}

bp_service_token_is_valid() {
	[[ "$1" =~ ^[a-z0-9][a-z0-9+_.@-]*$ ]]
}

bp_service_validate_file() {
	local service_file="$1"
	"$BP_JQ_BIN" -e '
    def safe_string:
      type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    def token: safe_string and test("^[a-z0-9][a-z0-9+_.@-]*$");
    def service_label_value: safe_string and test("^[A-Za-z0-9][A-Za-z0-9._+@-]*$");
    def relative_path:
      safe_string and test("^[A-Za-z0-9][A-Za-z0-9._+@/-]*$") and
      (split("/") | all(. != "." and . != ".."));
    def absolute_path:
      safe_string and startswith("/") and
      (split("/") | all(. != ".."));
    def keep_alive:
      type == "object" and
      ((keys | sort) == ["always"] or (keys | sort) == ["successful_exit"]) and
      (if has("always") then (.always | type == "boolean")
       else (.successful_exit | type == "boolean") end);
    def environment:
      type == "object" and all(to_entries[];
        (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.value | safe_string));
    def overrides:
      type == "object" and
      all(keys[]; IN("executable", "arguments", "keep_alive", "environment", "working_directory", "stdout_path", "stderr_path")) and
      ((has("executable") | not) or (.executable | relative_path)) and
      ((has("arguments") | not) or (.arguments | type == "array" and all(.[]; safe_string))) and
      ((has("keep_alive") | not) or (.keep_alive | keep_alive)) and
      ((has("environment") | not) or (.environment | environment)) and
      ((has("working_directory") | not) or (.working_directory == null or (.working_directory | absolute_path))) and
      ((has("stdout_path") | not) or (.stdout_path | absolute_path)) and
      ((has("stderr_path") | not) or (.stderr_path | absolute_path));
    type == "object" and
    all(keys[]; IN("$schema", "version", "services")) and
    .version == 1 and (.services | type == "array") and
    ([.services[].token] | length == (unique | length)) and
    all(.services[];
      type == "object" and
      all(keys[]; IN("token", "formula", "source", "port", "executable", "arguments", "keep_alive", "environment", "working_directory", "homebrew_label", "overrides")) and
      (.token | token) and (.formula | token) and (.port | token) and
      (.source | type == "object" and (keys | sort) == ["generated_date", "version"] and (.version | safe_string) and (.generated_date | safe_string)) and
      (.executable | relative_path) and
      (.arguments | type == "array" and all(.[]; safe_string)) and
      (.keep_alive | keep_alive) and
      (.environment | environment) and
      (.working_directory == null or (.working_directory | absolute_path)) and
      ((has("homebrew_label") | not) or (.homebrew_label | service_label_value)) and
      (.overrides | overrides))
  ' "$service_file" >/dev/null 2>&1 || bp_die "Invalid service definition file: $service_file"
}

bp_services_validate() {
	[ -f "$BP_SERVICE_FILE" ] || return 0
	bp_service_validate_file "$BP_SERVICE_FILE"
}

bp_service_require_definition() {
	local token="$1"
	bp_service_token_is_valid "$token" || bp_die "Invalid service token: $token"
	[ -f "$BP_SERVICE_FILE" ] || bp_die "No imported services file: $BP_SERVICE_FILE"
	bp_services_validate
	"$BP_JQ_BIN" -e --arg token "$token" '.services[] | select(.token == $token)' "$BP_SERVICE_FILE" >/dev/null || bp_die "No imported service: $token"
}

bp_service_mapping_port() {
	local formula="$1" saved_port="${2:-}" row action target
	row="$(bp_lookup_mapping brew "$formula" || true)"
	if [ -z "$row" ]; then
		[ -n "$saved_port" ] && {
			printf '%s\n' "$saved_port"
			return 0
		}
		printf '%s\n' "$formula"
		return 0
	fi
	action="${row%%$'\034'*}"
	row="${row#*$'\034'}"
	target="${row%%$'\034'*}"
	[ "$action" = port ] || bp_die "Service formula $formula requires a MacPorts port mapping."
	bp_service_token_is_valid "$target" || bp_die "Service formula $formula has an invalid MacPorts port mapping: $target"
	printf '%s\n' "$target"
}

bp_service_macports_prefix() {
	local port_dir
	port_dir="$(dirname -- "$BP_PORT_BIN")"
	(CDPATH='' cd -- "$port_dir/.." && pwd -P)
}

bp_service_import_options() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--map)
			[ "$#" -ge 2 ] || bp_die '--map requires a file'
			bp_add_map "$2"
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		--*) bp_die "Unknown option: $1" ;;
		*)
			BP_REMAINING=("$@")
			return 0
			;;
		esac
	done
	BP_REMAINING=()
}

bp_service_start_options() {
	BP_DRY_RUN=false
	parse_common_options "$@"
}

bp_service_stop_options() {
	BP_DRY_RUN=false
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--dry-run)
			BP_DRY_RUN=true
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		--*) bp_die "Unknown option: $1" ;;
		*)
			BP_REMAINING=("$@")
			return 0
			;;
		esac
	done
	BP_REMAINING=()
}

bp_service_write_import() {
	local definition="$1" temporary
	mkdir -p "$BP_SERVICE_CONFIG_DIR"
	chmod 700 "$BP_SERVICE_CONFIG_DIR"
	temporary="$(mktemp "$BP_SERVICE_CONFIG_DIR/.services.XXXXXX")"
	if [ -f "$BP_SERVICE_FILE" ]; then
		"$BP_JQ_BIN" --slurpfile definition "$definition" '.services += $definition' "$BP_SERVICE_FILE" >"$temporary"
	else
		"$BP_JQ_BIN" -n --slurpfile definition "$definition" '{"$schema": "https://github.com/jeffbax/brew-port/schema/services.schema.json", version: 1, services: $definition}' >"$temporary"
	fi
	if ! bp_service_validate_file "$temporary"; then
		rm -f "$temporary"
		return 1
	fi
	chmod 600 "$temporary"
	mv "$temporary" "$BP_SERVICE_FILE"
}

bp_service_import_formula() {
	local formula="$1" port metadata definition executable_prefix
	bp_service_token_is_valid "$formula" || bp_die "Homebrew/core formula names must be unqualified lowercase tokens: $formula"
	if [ -f "$BP_SERVICE_FILE" ] && "$BP_JQ_BIN" -e --arg formula "$formula" '.services[] | select(.formula == $formula)' "$BP_SERVICE_FILE" >/dev/null; then
		bp_die "Service already imported: $formula. Edit $BP_SERVICE_FILE to change its local overrides."
	fi
	port="$(bp_service_mapping_port "$formula")"
	metadata="$BP_TMP_DIR/service-$formula.json"
	if ! "$BP_CURL_BIN" --fail --silent --show-error --location --output "$metadata" "https://formulae.brew.sh/api/formula/$formula.json"; then
		bp_die "Could not fetch Homebrew formula metadata for $formula."
	fi
	executable_prefix="\$HOMEBREW_PREFIX/opt/$formula/"
	definition="$BP_TMP_DIR/service-$formula.definition.json"
	if ! "$BP_JQ_BIN" -e --arg formula "$formula" --arg port "$port" --arg executable_prefix "$executable_prefix" --arg macports_prefix "$(bp_service_macports_prefix)" --arg home "$HOME" '
      def safe_string:
        type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
      def placeholder_end:
        . == "" or (.[0:1] | test("[^A-Za-z0-9_]"));
      def supported_variables:
        split("$")[1:] | all(.[];
          if startswith("HOMEBREW_PREFIX") then (ltrimstr("HOMEBREW_PREFIX") | placeholder_end)
          elif startswith("HOME") then (ltrimstr("HOME") | placeholder_end)
          else false end);
      def translated:
        gsub("\\$HOMEBREW_PREFIX"; $macports_prefix) | gsub("\\$HOME"; $home);
      def service_label:
        if has("label") then .label elif has("name") then .name else null end;
      . as $formula_metadata |
      (.service? | type == "object") and
      (.tap == "homebrew/core") and (.full_name == $formula) and
      (.versions.stable | safe_string) and (.generated_date | safe_string) and
      (.service | all(keys[]; IN("run", "run_type", "keep_alive", "environment_variables", "working_dir", "log_path", "error_log_path", "name", "label"))) and
      (.service.run | type == "array" and length > 0 and all(.[]; safe_string and supported_variables)) and
      (.service.run_type == "immediate") and
      (.service.keep_alive | type == "object" and ((keys | sort) == ["always"] or (keys | sort) == ["successful_exit"]) and
        (if has("always") then (.always | type == "boolean") else (.successful_exit | type == "boolean") end)) and
      ((.service.environment_variables? == null) or (.service.environment_variables | type == "object" and all(to_entries[];
        (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.value | safe_string and supported_variables)))) and
      ((.service.working_dir? == null) or (.service.working_dir | safe_string and supported_variables)) and
      ((.service.log_path? == null) or (.service.log_path | safe_string and supported_variables)) and
      ((.service.error_log_path? == null) or (.service.error_log_path | safe_string and supported_variables)) and
      ((.service | service_label) == null or ((.service | service_label) | safe_string and test("^[A-Za-z0-9][A-Za-z0-9._+@-]*$"))) and
      (.service.run[0] | startswith($executable_prefix) and supported_variables and
        (ltrimstr($executable_prefix) | test("^[A-Za-z0-9][A-Za-z0-9._+@/-]*$") and (split("/") | all(. != "." and . != ".."))))
      | if . then
          {
            token: $formula,
            formula: $formula,
            source: {version: $formula_metadata.versions.stable, generated_date: $formula_metadata.generated_date},
            port: $port,
            executable: ($formula_metadata.service.run[0] | ltrimstr($executable_prefix)),
            arguments: [$formula_metadata.service.run[1:][] | translated],
            keep_alive: $formula_metadata.service.keep_alive,
            environment: (($formula_metadata.service.environment_variables // {}) | with_entries(.value |= translated)),
            working_directory: (if $formula_metadata.service.working_dir? == null then null else ($formula_metadata.service.working_dir | translated | if startswith("//") then ltrimstr("/") else . end) end),
            overrides: {}
          } + (if ($formula_metadata.service | service_label) == null then {} else {homebrew_label: ($formula_metadata.service | service_label)} end)
        else error("unsupported service metadata") end
    ' "$metadata" >"$definition" 2>/dev/null; then
		bp_die "Unsupported or malformed Homebrew service metadata for $formula."
	fi
	bp_service_write_import "$definition"
	bp_log "Imported disabled service definition for $formula. Review $BP_SERVICE_FILE before starting it."
}

bp_services_import() {
	bp_service_import_options "$@"
	[ "${#BP_REMAINING[@]}" -gt 0 ] || bp_die 'At least one Homebrew/core formula is required.'
	bp_detect_host
	bp_require_macos
	bp_require_native_execution
	bp_find_port
	bp_require_port
	bp_services_require_jq
	bp_validate_maps
	bp_services_validate
	local formula
	for formula in "${BP_REMAINING[@]}"; do bp_service_import_formula "$formula"; done
}

bp_service_list_options() {
	[ "$#" -eq 0 ] || {
		case "$1" in
		--help | -h)
			usage
			exit 0
			;;
		esac
		bp_die 'services list does not accept options.'
	}
}

bp_service_log_report() {
	local stream="$1" path="$2" line
	local -r log_tail_lines=100
	if [ ! -f "$path" ]; then
		printf '  %s: missing — path: %s\n' "$stream" "$path"
		return 0
	fi
	# List is a status command, so do not scan unrotated service logs in full.
	if ! line="$(LC_ALL=C tail -n "$log_tail_lines" "$path" 2>/dev/null | LC_ALL=C awk '
		length($0) > 0 { line = $0; found = 1 }
		END {
			if (found) {
				# Log content is untrusted terminal input; replace control bytes safely.
				gsub(/[[:cntrl:]\200-\237]/, "?", line)
				print line
			}
		}' 2>/dev/null)"; then
		printf '  %s: unavailable — path: %s\n' "$stream" "$path"
		return 0
	fi
	if [ -n "$line" ]; then
		printf '  %s: present — path: %s — last line: %s\n' "$stream" "$path" "$line"
	else
		printf '  %s: empty — path: %s\n' "$stream" "$path"
	fi
}

bp_services_list() {
	bp_service_list_options "$@"
	[ -f "$BP_SERVICE_FILE" ] || {
		bp_log 'No imported services.'
		return 0
	}
	bp_detect_host
	bp_find_port
	bp_services_require_jq
	bp_validate_maps
	bp_services_validate
	local prefix=/opt/local port_dir
	if [ -n "$BP_PORT_BIN" ]; then
		port_dir="$(dirname -- "$BP_PORT_BIN")"
		if [ -d "$port_dir/.." ]; then prefix="$(CDPATH='' cd -- "$port_dir/.." && pwd -P)"; fi
	fi
	local launchctl_available=true
	if [ ! -x "$BP_LAUNCHCTL_BIN" ] && ! command -v "$BP_LAUNCHCTL_BIN" >/dev/null 2>&1; then launchctl_available=false; fi
	local token formula port executable_relative executable stdout_path stderr_path service_row
	local keep_alive_key keep_alive_value launchd_state pid last_exit friendly_state launchctl_output gui_output label restarts
	while IFS= read -r token; do
		service_row="$("$BP_JQ_BIN" -r --arg token "$token" '
      .services[] | select(.token == $token) |
      (if .overrides | has("keep_alive") then .overrides.keep_alive else .keep_alive end) as $keep_alive |
      ($keep_alive | keys[0]) as $keep_alive_key |
      [
        .formula,
        .port,
        (.overrides.executable // .executable),
        (.overrides.stdout_path // "-"),
        (.overrides.stderr_path // "-"),
        $keep_alive_key,
        ($keep_alive[$keep_alive_key] | tostring)
      ] | @tsv
    ' "$BP_SERVICE_FILE")"
		IFS=$'	' read -r formula port executable_relative stdout_path stderr_path keep_alive_key keep_alive_value <<<"$service_row"
		port="$(bp_service_mapping_port "$formula" "$port")"
		[ "$stdout_path" = '-' ] && stdout_path="$BP_SERVICE_STATE_DIR/$token.log"
		[ "$stderr_path" = '-' ] && stderr_path="$BP_SERVICE_STATE_DIR/$token.err.log"
		executable="$prefix/$executable_relative"
		if [ -x "$executable" ]; then executable="found $executable"; else executable="missing $executable"; fi
		pid='unknown'
		last_exit='unknown'
		launchd_state='unknown'
		friendly_state='launchctl unavailable'
		label="dev.brew-port.$token"
		if [ "$launchctl_available" = true ]; then
			if launchctl_output="$("$BP_LAUNCHCTL_BIN" print "gui/$UID/$label" 2>/dev/null)"; then
				launchd_state="$(printf '%s\n' "$launchctl_output" | sed -n 's/^[[:space:]]*state = //p' | head -1)"
				pid="$(printf '%s\n' "$launchctl_output" | sed -n 's/^[[:space:]]*pid = //p' | head -1)"
				last_exit="$(printf '%s\n' "$launchctl_output" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
				[ -n "$launchd_state" ] || launchd_state='loaded'
				[[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid='none'
				[ -n "$last_exit" ] || last_exit='none'
				if [ "$pid" != 'none' ]; then
					friendly_state='running'
				elif [ "$last_exit" = none ]; then
					[ "$launchd_state" = exited ] && friendly_state='stopped' || friendly_state='scheduled'
				else
					# KeepAlive determines whether launchd will run an exited job again.
					restarts=false
					case "$keep_alive_key:$keep_alive_value" in
					always:true) restarts=true ;;
					successful_exit:true)
						[ "$last_exit" = 0 ] && restarts=true
						;;
					successful_exit:false)
						[ "$last_exit" != 0 ] && restarts=true
						;;
					esac
					"$restarts" && friendly_state='restarting' || friendly_state='stopped'
				fi
			elif gui_output="$("$BP_LAUNCHCTL_BIN" print "gui/$UID" 2>/dev/null)"; then
				: "$gui_output"
				friendly_state='stopped'
				launchd_state='not loaded'
				pid='none'
				last_exit='none'
			else
				friendly_state='no GUI session'
				launchd_state='no GUI session'
			fi
		fi
		printf '%s: %s\n' "$token" "$friendly_state"
		printf '  formula: %s\n' "$formula"
		printf '  port: %s\n' "$port"
		printf '  executable: %s\n' "$executable"
		printf '  pid: %s\n' "$pid"
		printf '  last exit: %s\n' "$last_exit"
		printf '  launchd: "%s"\n' "$launchd_state"
		bp_service_log_report stderr "$stderr_path"
		bp_service_log_report stdout "$stdout_path"
		printf '\n'
	done < <("$BP_JQ_BIN" -r '.services[].token' "$BP_SERVICE_FILE")
}

bp_service_definition_value() {
	local token="$1" field="$2"
	"$BP_JQ_BIN" -r --arg token "$token" --arg field "$field" '
    .services[] | select(.token == $token) as $service |
    if $field == "port" then $service.port
    elif $field == "formula" then $service.formula
    elif $field == "source_version" then $service.source.version
    elif $field == "homebrew_label" then ($service.homebrew_label // "")
    else empty end
  ' "$BP_SERVICE_FILE"
}

bp_service_effective_definition() {
	local token="$1" output="$2"
	"$BP_JQ_BIN" -e --arg token "$token" '
    .services[] | select(.token == $token) as $service | $service.overrides as $overrides |
    {
      executable: (if $overrides | has("executable") then $overrides.executable else $service.executable end),
      arguments: (if $overrides | has("arguments") then $overrides.arguments else $service.arguments end),
      keep_alive: (if $overrides | has("keep_alive") then $overrides.keep_alive else $service.keep_alive end),
      environment: (if $overrides | has("environment") then $overrides.environment else $service.environment end),
      working_directory: (if $overrides | has("working_directory") then $overrides.working_directory else $service.working_directory end),
      stdout_path: ($overrides.stdout_path // null),
      stderr_path: ($overrides.stderr_path // null)
    }
  ' "$BP_SERVICE_FILE" >"$output"
}

bp_service_homebrew_is_active() {
	local token="$1" explicit_label="$2" label
	for label in "sh.brew.$token" "homebrew.mxcl.$token" "$explicit_label"; do
		[ -n "$label" ] || continue
		if "$BP_LAUNCHCTL_BIN" print "gui/$UID/$label" >/dev/null 2>&1; then
			bp_die "Homebrew service $label is active. Stop it manually before starting brew-port service $token."
		fi
	done
}

bp_service_port_is_active() {
	local port="$1" active_ports="$BP_TMP_DIR/service-active-ports"
	"$BP_PORT_BIN" -q echo active >"$active_ports" || bp_die 'Could not inspect active MacPorts ports.'
	grep -Fxq -- "$port" "$active_ports"
}

bp_service_install_port_if_needed() {
	local token="$1" port="$2"
	if bp_service_port_is_active "$port"; then return 0; fi
	if "$BP_DRY_RUN"; then
		bp_log "Would install MacPorts port $port (for service $token)"
		return 0
	fi
	bp_start_sudo
	bp_log "Installing MacPorts port $port (for service $token)"
	bp_port install "$port" || bp_die "MacPorts install failed for service $token: $port"
}

bp_service_warn_version_mismatch() {
	local formula="$1" port="$2" source_version="$3" port_version
	port_version="$("$BP_PORT_BIN" -q info --version "$port" 2>/dev/null || true)"
	port_version="${port_version%%$'\n'*}"
	if [ -n "$port_version" ] && [ "$port_version" != "$source_version" ]; then
		bp_log "Warning: Homebrew $formula is $source_version; MacPorts $port is $port_version. Review version-sensitive service arguments."
	fi
}

bp_service_xml_escape() {
	local value="$1" character
	local index=0

	while [ "$index" -lt "${#value}" ]; do
		character="${value:index:1}"
		case "$character" in
		'&') printf '%s' '&amp;' ;;
		'<') printf '%s' '&lt;' ;;
		'>') printf '%s' '&gt;' ;;
		'"') printf '%s' '&quot;' ;;
		"'") printf '%s' '&apos;' ;;
		*) printf '%s' "$character" ;;
		esac
		index=$((index + 1))
	done
}

bp_service_prepare_plist() {
	local token="$1" effective="$2" target="$3" stdout_path="$4" stderr_path="$5" prefix="$6" temporary="$7" executable argument key value working_directory
	local keep_alive_key keep_alive_value
	executable="$prefix/$("$BP_JQ_BIN" -r '.executable' "$effective")"
	working_directory="$("$BP_JQ_BIN" -r '.working_directory // empty' "$effective")"
	keep_alive_key="$("$BP_JQ_BIN" -r '.keep_alive | keys[0]' "$effective")"
	keep_alive_value="$("$BP_JQ_BIN" -r ".keep_alive[\"$keep_alive_key\"]" "$effective")"
	{
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
		printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
		printf '%s\n' '<plist version="1.0"><dict>'
		printf '<key>Label</key><string>dev.brew-port.%s</string>\n' "$(bp_service_xml_escape "$token")"
		printf '%s\n' '<key>ProgramArguments</key><array>'
		printf '<string>%s</string>\n' "$(bp_service_xml_escape "$executable")"
		while IFS= read -r argument; do printf '<string>%s</string>\n' "$(bp_service_xml_escape "$argument")"; done < <("$BP_JQ_BIN" -r '.arguments[]' "$effective")
		printf '%s\n' '</array>'
		# Imported services only support Homebrew's immediate run type.
		printf '%s\n' '<key>RunAtLoad</key><true/>'
		if [ "$keep_alive_key" = always ]; then
			[ "$keep_alive_value" = true ] && printf '%s\n' '<key>KeepAlive</key><true/>' || printf '%s\n' '<key>KeepAlive</key><false/>'
		else
			printf '%s\n' '<key>KeepAlive</key><dict>'
			[ "$keep_alive_value" = true ] && printf '%s\n' '<key>SuccessfulExit</key><true/>' || printf '%s\n' '<key>SuccessfulExit</key><false/>'
			printf '%s\n' '</dict>'
		fi
		if [ "$("$BP_JQ_BIN" '.environment | length' "$effective")" -gt 0 ]; then
			printf '%s\n' '<key>EnvironmentVariables</key><dict>'
			# NUL delimiters avoid jq's textual escaping of literal backslashes.
			while IFS= read -r -d '' key && IFS= read -r -d '' value; do
				printf '<key>%s</key><string>%s</string>\n' "$(bp_service_xml_escape "$key")" "$(bp_service_xml_escape "$value")"
			done < <("$BP_JQ_BIN" -jr '.environment | to_entries | sort_by(.key)[] | .key, "\u0000", .value, "\u0000"' "$effective")
			printf '%s\n' '</dict>'
		fi
		[ -z "$working_directory" ] || printf '<key>WorkingDirectory</key><string>%s</string>\n' "$(bp_service_xml_escape "$working_directory")"
		printf '<key>StandardOutPath</key><string>%s</string>\n' "$(bp_service_xml_escape "$stdout_path")"
		printf '<key>StandardErrorPath</key><string>%s</string>\n' "$(bp_service_xml_escape "$stderr_path")"
		printf '%s\n' '</dict></plist>'
	} >"$temporary"
	if ! "$BP_PLUTIL_BIN" -lint "$temporary" >/dev/null; then
		rm -f "$temporary"
		bp_die "Generated plist is invalid: $target"
	fi
}

bp_service_restore_previous_plist() {
	local token="$1" target="$2" backup="$3" was_loaded="$4"
	if ! mv "$backup" "$target"; then
		bp_die "Could not restore the prior plist for brew-port service $token: $target"
	fi
	if "$was_loaded" && ! "$BP_LAUNCHCTL_BIN" bootstrap "gui/$UID" "$target"; then
		bp_die "Could not restore the prior job for brew-port service $token: $target"
	fi
}

bp_service_start_one() {
	local token="$1" formula saved_port port source_version homebrew_label effective prefix executable target label stdout_path stderr_path replacement backup was_loaded
	bp_service_require_definition "$token"
	formula="$(bp_service_definition_value "$token" formula)"
	saved_port="$(bp_service_definition_value "$token" port)"
	source_version="$(bp_service_definition_value "$token" source_version)"
	homebrew_label="$(bp_service_definition_value "$token" homebrew_label)"
	port="$(bp_service_mapping_port "$formula" "$saved_port")"
	bp_service_homebrew_is_active "$token" "$homebrew_label"
	bp_service_install_port_if_needed "$token" "$port"
	prefix="$(bp_service_macports_prefix)"
	effective="$BP_TMP_DIR/service-$token-effective.json"
	bp_service_effective_definition "$token" "$effective"
	executable="$prefix/$("$BP_JQ_BIN" -r '.executable' "$effective")"
	target="$HOME/Library/LaunchAgents/dev.brew-port.$token.plist"
	label="dev.brew-port.$token"
	stdout_path="$("$BP_JQ_BIN" -r '.stdout_path // empty' "$effective")"
	stderr_path="$("$BP_JQ_BIN" -r '.stderr_path // empty' "$effective")"
	[ -n "$stdout_path" ] || stdout_path="$BP_SERVICE_STATE_DIR/$token.log"
	[ -n "$stderr_path" ] || stderr_path="$BP_SERVICE_STATE_DIR/$token.err.log"
	if "$BP_DRY_RUN"; then
		if bp_service_port_is_active "$port" && [ ! -x "$executable" ]; then
			bp_die "MacPorts executable is missing for service $token: $executable. Set overrides.executable in $BP_SERVICE_FILE after review."
		fi
		bp_log "Would verify MacPorts executable: $executable"
		bp_log "Would write and bootstrap: $target"
		return 0
	fi
	[ -x "$executable" ] || bp_die "MacPorts executable is missing for service $token: $executable. Set overrides.executable in $BP_SERVICE_FILE after review."
	bp_service_warn_version_mismatch "$formula" "$port" "$source_version"
	mkdir -p "$(dirname -- "$target")" "$BP_SERVICE_STATE_DIR"
	chmod 700 "$BP_SERVICE_STATE_DIR"
	# Validate the replacement before disrupting a running service.
	replacement="$(mktemp "$(dirname -- "$target")/.${token}.XXXXXX")"
	bp_service_prepare_plist "$token" "$effective" "$target" "$stdout_path" "$stderr_path" "$prefix" "$replacement"
	backup=
	if [ -e "$target" ] || [ -L "$target" ]; then
		# Keep the prior plist until its replacement has bootstrapped.
		backup="$(mktemp "$(dirname -- "$target")/.${token}.backup.XXXXXX")"
		if ! cp "$target" "$backup"; then
			rm -f "$replacement" "$backup"
			bp_die "Could not preserve the prior plist for brew-port service $token: $target"
		fi
	fi
	was_loaded=false
	# A loaded job keeps its previous plist configuration until it is unloaded.
	if "$BP_LAUNCHCTL_BIN" print "gui/$UID/$label" >/dev/null 2>&1; then
		was_loaded=true
	fi
	if "$was_loaded" && ! "$BP_LAUNCHCTL_BIN" bootout "gui/$UID" "$target"; then
		rm -f "$replacement" "$backup"
		bp_die "Could not reload brew-port service $token. The existing job and plist remain in place at $target."
	fi
	if ! mv "$replacement" "$target"; then
		rm -f "$replacement"
		if [ -n "$backup" ]; then
			bp_service_restore_previous_plist "$token" "$target" "$backup" "$was_loaded"
			bp_die "Could not replace the plist for brew-port service $token. The prior configuration was restored."
		fi
		bp_die "Could not replace the plist for brew-port service $token."
	fi
	if ! "$BP_LAUNCHCTL_BIN" bootstrap "gui/$UID" "$target"; then
		if [ -n "$backup" ]; then
			bp_service_restore_previous_plist "$token" "$target" "$backup" "$was_loaded"
			bp_die "Could not bootstrap brew-port service $token. The prior configuration was restored."
		fi
		bp_die "Could not bootstrap brew-port service $token. The plist remains at $target."
	fi
	[ -z "$backup" ] || rm -f "$backup"
	bp_log "Started brew-port service $token."
}

bp_services_start() {
	bp_service_start_options "$@"
	[ "${#BP_REMAINING[@]}" -gt 0 ] || bp_die 'At least one imported service token is required.'
	bp_detect_host
	bp_require_macos
	bp_require_native_execution
	bp_find_port
	bp_require_port
	bp_services_require_jq
	bp_validate_maps
	bp_services_validate
	local token
	for token in "${BP_REMAINING[@]}"; do bp_service_start_one "$token"; done
}

bp_service_stop_one() {
	local token="$1" target="$HOME/Library/LaunchAgents/dev.brew-port.$1.plist" label="dev.brew-port.$1"
	bp_service_require_definition "$token"
	if "$BP_DRY_RUN"; then
		bp_log "Would bootout and remove: $target"
		return 0
	fi
	if [ -e "$target" ] || [ -L "$target" ]; then
		# A failed bootout is harmless only after its brew-port label is unloaded.
		if ! "$BP_LAUNCHCTL_BIN" bootout "gui/$UID" "$target" >/dev/null 2>&1 && "$BP_LAUNCHCTL_BIN" print "gui/$UID/$label" >/dev/null 2>&1; then
			bp_die "Could not boot out brew-port service $token. The plist remains at $target."
		fi
		rm -f "$target"
		bp_log "Stopped brew-port service $token."
	else
		bp_log "No brew-port plist to stop for $token."
	fi
}

bp_services_stop() {
	bp_service_stop_options "$@"
	[ "${#BP_REMAINING[@]}" -gt 0 ] || bp_die 'At least one imported service token is required.'
	bp_detect_host
	bp_require_macos
	bp_services_require_jq
	bp_services_validate
	local token
	for token in "${BP_REMAINING[@]}"; do bp_service_stop_one "$token"; done
}
