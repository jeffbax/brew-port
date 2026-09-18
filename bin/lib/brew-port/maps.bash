bp_init_maps() {
	BP_BUNDLED_MAP="$BP_REPO_DIR/maps/default.json"
	BP_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
	BP_USER_MAP="$BP_CONFIG_HOME/brew-port/mappings.json"
	BP_MAP_FILES=("$BP_BUNDLED_MAP")
	if [ -f "$BP_USER_MAP" ]; then BP_MAP_FILES+=("$BP_USER_MAP"); fi
}

bp_add_map() {
	[ -f "$1" ] || bp_die "Mapping file does not exist: $1"
	BP_MAP_FILES+=("$1")
}

bp_validate_map_file() {
	local map_file="$1"
	"$BP_JQ_BIN" -e '
    type == "object" and .version == 1 and (.mappings | type == "array") and
    all(.mappings[];
      (type == "object") and
      (.kind | IN("brew", "cask")) and
      (.token | type == "string" and length > 0) and
      (.action | IN("port", "skip", "fallback", "fallback-root")) and
      ((.note // "") | type == "string") and
      (if .action == "port" then (.target | type == "string" and length > 0)
       elif .action == "skip" then ((.target // null) == null)
       else ((.target | type == "string" and test("^fallbacks/[A-Za-z0-9._/-]+\\.sh$") and (contains("../") | not)) and
             (.architectures | type == "array" and length > 0 and all(.[]; IN("x86_64", "arm64")))) end) and
      ((.architectures? == null) or (.architectures | type == "array" and all(.[]; type == "string"))))
  ' "$map_file" >/dev/null 2>&1 || bp_die "Invalid mapping file: $map_file"
}

bp_validate_maps() {
	local map_file
	for map_file in "${BP_MAP_FILES[@]}"; do bp_validate_map_file "$map_file"; done
}

bp_make_effective_map() {
	local inputs=() map_file
	for map_file in "${BP_MAP_FILES[@]}"; do inputs+=("$map_file"); done
	BP_EFFECTIVE_MAP="$BP_TMP_DIR/effective-mappings.json"
	"$BP_JQ_BIN" -n 'reduce inputs as $m ({version: 1, mappings: []}; reduce $m.mappings[] as $entry (.;
    .mappings |= (map(select(.kind != $entry.kind or .token != $entry.token)) + [$entry])))' "${inputs[@]}" >"$BP_EFFECTIVE_MAP"
}

# Emits action, target, note, architectures JSON, and source map, separated by
# an ASCII unit separator so empty JSON fields are not collapsed by Bash read.
bp_lookup_mapping() {
	local kind="$1" token="$2" index map_file result
	index=$((${#BP_MAP_FILES[@]} - 1))
	while [ "$index" -ge 0 ]; do
		map_file="${BP_MAP_FILES[$index]}"
		result="$("$BP_JQ_BIN" -r --arg kind "$kind" --arg token "$token" '[.mappings[] | select(.kind == $kind and .token == $token)] | last | select(. != null) | [.action, (.target // ""), (.note // ""), (.architectures // [] | @json)] | join("\u001c")' "$map_file")"
		if [ -n "$result" ]; then
			printf '%s\034%s\n' "$result" "$map_file"
			return 0
		fi
		index=$((index - 1))
	done
	return 1
}

bp_mapping_fallback_path() {
	local source_map="$1" target="$2" map_dir
	map_dir="$(CDPATH='' cd -- "$(dirname -- "$source_map")" && pwd)"
	printf '%s/%s\n' "$map_dir" "$target"
}

bp_arch_supported() {
	local architectures="$1"
	"$BP_JQ_BIN" -e --arg arch "$BP_ARCH" 'index($arch) != null' <<EOF >/dev/null
$architectures
EOF
}

bp_map_explain() {
	local kind="$1" token="$2" row action target note arches source
	row="$(bp_lookup_mapping "$kind" "$token" || true)"
	if [ -z "$row" ]; then
		bp_log "$kind $token: no explicit mapping; brew defaults to the same-named MacPorts port."
		return 0
	fi
	IFS=$'\034' read -r action target note arches source <<EOF
$row
EOF
	bp_log "$kind $token: $action${target:+ -> $target}"
	bp_log "Source: $source"
	[ -n "$note" ] && bp_log "Rationale: $note"
	[ "$arches" != '[]' ] && bp_log "Native architectures: $arches"
	return 0
}
