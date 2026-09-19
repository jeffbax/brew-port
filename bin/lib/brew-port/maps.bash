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
      (.action | IN("port", "skip", "fallback", "fallback-root", "manual")) and
      ((.note // "") | type == "string") and
      (if .action == "port" then (.target | type == "string" and length > 0)
       elif .action == "skip" then ((.target // null) == null)
       elif .action == "manual" then
         (.kind == "cask" and (.target // null) == null and
          (.detect | type == "array" and length > 0 and
           all(.[]; type == "string" and test("^(~/|/)"))))
       else ((.target | type == "string" and test("^fallbacks/[A-Za-z0-9._/-]+\\.sh$") and (contains("../") | not)) and
             (.architectures | type == "array" and length > 0 and all(.[]; IN("x86_64", "arm64")))) end) and
      ((.detect? == null) or .action == "manual") and
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

# Emits action, target, JSON-encoded note, architectures JSON, and source map,
# separated by an ASCII unit separator so empty JSON fields are not collapsed by
# Bash read and multiline notes cannot split the record.
bp_lookup_mapping() {
	local kind="$1" token="$2" index map_file result
	index=$((${#BP_MAP_FILES[@]} - 1))
	while [ "$index" -ge 0 ]; do
		map_file="${BP_MAP_FILES[$index]}"
		result="$("$BP_JQ_BIN" -r --arg kind "$kind" --arg token "$token" '[.mappings[] | select(.kind == $kind and .token == $token)] | last | select(. != null) | [.action, (.target // ""), (.note // "" | @json), (.architectures // [] | @json), (.detect // [] | @json)] | join("\u001c")' "$map_file")"
		if [ -n "$result" ]; then
			printf '%s\034%s\n' "$result" "$map_file"
			return 0
		fi
		index=$((index - 1))
	done
	return 1
}

bp_decode_mapping_note() {
	printf '%s\n' "$1" | "$BP_JQ_BIN" -r .
}

bp_canonical_path() {
	local path="$1" path_dir link_target
	while [ -L "$path" ]; do
		path_dir="$(CDPATH='' cd -P -- "$(dirname -- "$path")" && pwd -P)" || return 1
		link_target="$(readlink "$path")" || return 1
		case "$link_target" in
		/*) path="$link_target" ;;
		*) path="$path_dir/$link_target" ;;
		esac
	done
	path_dir="$(CDPATH='' cd -P -- "$(dirname -- "$path")" && pwd -P)" || return 1
	printf '%s/%s\n' "$path_dir" "$(basename -- "$path")"
}

bp_mapping_fallback_path() {
	local source_map="$1" target="$2" canonical_map map_dir fallback_dir fallback_path
	canonical_map="$(bp_canonical_path "$source_map")" || return 1
	map_dir="$(dirname -- "$canonical_map")"
	fallback_dir="$(bp_canonical_path "$map_dir/fallbacks")" || return 1
	fallback_path="$(bp_canonical_path "$map_dir/$target")" || return 1
	case "$fallback_path" in
	"$fallback_dir"/*) printf '%s\n' "$fallback_path" ;;
	*) return 1 ;;
	esac
}

bp_arch_supported() {
	local architectures="$1"
	"$BP_JQ_BIN" -e --arg arch "$BP_ARCH" 'index($arch) != null' <<EOF >/dev/null
$architectures
EOF
}

bp_map_explain() {
	local kind="$1" token="$2" row action target note arches detect source
	row="$(bp_lookup_mapping "$kind" "$token" || true)"
	if [ -z "$row" ]; then
		bp_log "$kind $token: no explicit mapping; brew defaults to the same-named MacPorts port."
		return 0
	fi
	IFS=$'\034' read -r action target note arches detect source <<EOF
$row
EOF
	note="$(bp_decode_mapping_note "$note")"
	bp_log "$kind $token: $action${target:+ -> $target}"
	bp_log "Source: $source"
	[ -n "$note" ] && bp_log "Rationale: $note"
	[ "$arches" != '[]' ] && bp_log "Native architectures: $arches"
	[ "$detect" != '[]' ] && bp_log "Detected by any path: $detect"
	return 0
}
