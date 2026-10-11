bp_find_mise() {
	if [ -n "${BREW_PORT_MISE_BIN:-}" ]; then
		BP_MISE_BIN="$BREW_PORT_MISE_BIN"
	elif [ -n "${BP_PORT_BIN:-}" ] && [ -x "$(dirname -- "$BP_PORT_BIN")/mise" ]; then
		BP_MISE_BIN="$(dirname -- "$BP_PORT_BIN")/mise"
	else
		BP_MISE_BIN="$(bp_command_path mise)"
	fi
}

bp_mise() (bp_exec_mise "$@")

# Timed callers already run in a child; another subshell would hide its PID on Bash 3.2.
bp_exec_mise() {
	# Never load the invoking project's config, hooks, or version requests.
	# Match mise's canonical paths even when macOS exposes /private/var as /var.
	cd -P "$BP_TMP_DIR" || return 1
	local variable
	# Project activation can leave version overrides in the inherited environment.
	while IFS= read -r variable; do
		case "$variable" in MISE_*_VERSION) unset "$variable" ;; esac
	done < <(compgen -v MISE_)
	export MISE_CEILING_PATHS="$PWD"
	# Keep the timed PID on mise itself so termination cannot orphan the command.
	exec "$BP_MISE_BIN" "$@"
}

bp_ensure_mise() {
	bp_find_mise
	[ -n "$BP_MISE_BIN" ] && [ -x "$BP_MISE_BIN" ] && return 0
	bp_log 'mise is required for the requested mise actions. Install it using either:'
	bp_log '  MacPorts: sudo port install mise'
	bp_log '  Official installer: curl -fsSL https://mise.run | sh'
	bp_log 'Make mise available on PATH or set BREW_PORT_MISE_BIN to its executable path (the official installer uses ~/.local/bin/mise), then retry the original command.'
	"$BP_DRY_RUN" && return 0
	bp_die 'Stopping: mise is unavailable.'
}

bp_mise_state() {
	local target="$1" result errors="$BP_TMP_DIR/mise-inventory.err"
	if ! result="$(bp_mise ls --global --json "$target" 2>"$errors")"; then
		# shortcut: mise reports plugin absence as text; revisit if its diagnostic changes.
		if ! grep -Fq -- "$target is not installed" "$errors"; then
			cat "$errors" >&2
			return 1
		fi
		# ls rejects missing plugins; metadata still exposes their configured versions.
		result="$(bp_mise tool "$target" --json)" || return 1
		printf '%s\n' "$result" | "$BP_JQ_BIN" -er '
      if type != "object" or (has("requested_versions") | not) then error("invalid mise tool metadata")
      elif .requested_versions == null then "absent"
      elif (.requested_versions | type) != "array" then error("invalid mise tool requests")
      elif any(.requested_versions[]; type != "string" or length == 0) then error("invalid mise tool request")
      elif (.requested_versions | length) == 0 then "absent"
      else "missing" end'
		return "$?"
	fi
	cat "$errors" >&2
	printf '%s\n' "$result" | "$BP_JQ_BIN" -er '
    if type != "array" then error("invalid mise inventory")
    elif any(.[]; type != "object" or (.installed | type != "boolean")) then error("invalid mise inventory entry")
    elif length == 0 then "absent"
    elif all(.[]; .installed == true) then "installed"
    else "missing" end'
}

bp_mise_shell_guidance() {
	local shims shell_name quoted_bin
	shims="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
	# Activation exports MISE_SHELL; shims are the alternative shell setup.
	if [ -n "${MISE_SHELL:-}" ] || [[ ":$PATH:" == *":$shims:"* ]]; then return 0; fi
	shell_name="${SHELL:-}"
	shell_name="${shell_name##*/}"
	printf -v quoted_bin '%q' "$BP_MISE_BIN"
	bp_log 'mise tools are installed independently of shell activation. To expose them in your shell:'
	case "$shell_name" in
	bash | zsh)
		bp_log "  Run now and add to ~/.${shell_name}rc:"
		bp_log "  eval \"\$($quoted_bin activate $shell_name)\""
		;;
	fish)
		bp_log '  Run now and add to ~/.config/fish/config.fish:'
		bp_log "  $quoted_bin activate fish | source"
		;;
	*) bp_log '  Follow https://mise.jdx.dev/shell-setup.html for your shell.' ;;
	esac
}

bp_install_mise() {
	local token="$1" target="$2" state
	if "$BP_DRY_RUN"; then
		bp_log "Would ensure global mise tool $target (for $token), preserving any configured version"
		return 0
	fi
	if ! state="$(bp_mise_state "$target")"; then
		bp_action_failed "$token" "Could not inspect global mise tool: $target"
		return 0
	fi
	case "$state" in
	installed) bp_present mise ;;
	missing)
		if bp_mise install "$target"; then bp_installed "$token -> $target (mise)"; else
			bp_action_failed "$token" "mise install failed: $target"
			return 0
		fi
		;;
	absent)
		if bp_mise use --global --fuzzy "$target@latest"; then bp_installed "$token -> $target (mise)"; else
			bp_action_failed "$token" "mise install failed: $target"
			return 0
		fi
		;;
	esac
	if [ "${BP_MISE_GUIDANCE_SHOWN:-false}" = false ]; then
		bp_mise_shell_guidance
		BP_MISE_GUIDANCE_SHOWN=true
	fi
}

bp_upgrade_mise() {
	local target state targets help_text
	targets="$BP_TMP_DIR/mise-update-targets"
	"$BP_JQ_BIN" -r '[.mappings[] | select(.action == "mise") | .target] | unique[]' "$BP_EFFECTIVE_MAP" >"$targets"
	[ -s "$targets" ] || return 0
	if "$BP_DRY_RUN"; then
		bp_log "Would upgrade mapped globally configured mise tools (preserving version constraints): $(paste -sd ' ' "$targets")"
		return 0
	fi
	local -a configured=()
	while IFS= read -r target; do
		if ! state="$(bp_mise_state "$target")"; then
			bp_action_failed "$target" 'Could not inspect global mise tool.'
		elif [ "$state" != absent ]; then
			configured+=("$target")
		fi
	done <"$targets"
	[ "${#configured[@]}" -gt 0 ] || return 0
	help_text="$(bp_mise upgrade --help)" || help_text=''
	if [[ "$help_text" != *'--global'* ]]; then
		bp_action_failed mise 'mise upgrade --global is required; update the MacPorts mise package before upgrading mapped tools.'
		return 0
	fi
	bp_log "Upgrading global mise tools: ${configured[*]}"
	if ! bp_mise upgrade --global "${configured[@]}"; then
		bp_action_failed mise 'mise upgrade failed.'
	fi
}
