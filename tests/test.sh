#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
utility="$repo_dir/bin/brew-port"
shfmt_bin="${SHFMT_BIN:-shfmt}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/config"
export XDG_DATA_HOME="$tmp_dir/data"
export XDG_STATE_HOME="$tmp_dir/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}
contains() { [[ "$2" == *"$1"* ]] || fail "Expected output to contain: $1"; }
not_contains() { [[ "$2" != *"$1"* ]] || fail "Expected output not to contain: $1"; }

mock_uname="$tmp_dir/uname"
mock_port="$tmp_dir/port"
mock_sudo="$tmp_dir/sudo"
mock_sysctl="$tmp_dir/sysctl"
sudo_log="$tmp_dir/sudo.log"
jq_log="$tmp_dir/jq.log"
cat >"$mock_uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in -s) echo Darwin ;; -m) echo "${MOCK_ARCH:?}" ;; *) exit 2 ;; esac
EOF
cat >"$mock_port" <<'EOF'
#!/usr/bin/env bash
case "$1" in version) exit 0 ;; selfupdate|install|upgrade) echo "port $*" ;; *) exit 2 ;; esac
EOF
cat >"$mock_sudo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${SUDO_LOG:?}"
case "$1" in -v) exit 0 ;; -n) shift; exec "$@" ;; *) exit 2 ;; esac
EOF
chmod +x "$mock_uname" "$mock_port" "$mock_sudo"
cat >"$mock_sysctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in '-in sysctl.proc_translated') echo "${MOCK_TRANSLATED:-0}" ;; *) exit 2 ;; esac
EOF
chmod +x "$mock_sysctl"

custom_port_bin="$tmp_dir/custom-macports/bin"
mkdir -p "$custom_port_bin"
ln -s "$mock_port" "$custom_port_bin/port"
cat >"$custom_port_bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_JQ_LOG:?}"
exec /usr/bin/jq "$@"
EOF
chmod +x "$custom_port_bin/jq"

for file in "$utility" "$repo_dir"/bin/lib/brew-port/*.bash "$repo_dir"/maps/fallbacks/*.sh; do bash -n "$file"; done
command -v "$shfmt_bin" >/dev/null || fail 'shfmt is required to run the checks.'
"$shfmt_bin" -ln bash -d "$utility" "$repo_dir"/bin/lib/brew-port/*.bash "$repo_dir"/maps/fallbacks/*.sh "$repo_dir"/completions/brew-port.bash "$0"
[ -x "$utility" ] || fail 'brew-port must be executable.'
[ ! -e "$repo_dir/bin/macports-brewfile" ] || fail 'The old CLI must not remain.'
[ -f "$repo_dir/.agents/skills/brew-port/SKILL.md" ] || fail 'Missing agent skill.'
"$utility" map validate | grep -Fq 'Mappings are valid.'
prefix_brewfile="$tmp_dir/custom-prefix.Brewfile"
printf '%s\n' 'brew "git"' >"$prefix_brewfile"
: >"$jq_log"
MOCK_ARCH=arm64 MOCK_JQ_LOG="$jq_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$custom_port_bin/port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$prefix_brewfile" >/dev/null
[ -s "$jq_log" ] || fail 'The selected MacPorts prefix jq was not used.'
linked_bin="$tmp_dir/linked-bin"
mkdir -p "$linked_bin"
ln -s "$utility" "$linked_bin/brew-port"
"$linked_bin/brew-port" version | grep -Fqx 'brew-port 0.1.0' || fail 'A symlinked entrypoint could not locate its libraries.'
"$utility" map init >/dev/null
[ -f "$XDG_CONFIG_HOME/brew-port/mappings.json" ] || fail 'map init did not create an override file.'
"$utility" map validate >/dev/null

brewfile="$tmp_dir/Brewfile"
printf '%s\n' \
	'brew "git"' \
	'brew "asmvik/formulae/skhd"' \
	'brew "mas"' \
	'brew "rtk"' \
	'brew "signal-cli"' \
	'cask "1password-cli"' \
	'cask "firefox"' >"$brewfile"
: >"$sudo_log"
output="$(MOCK_ARCH=x86_64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$brewfile")"
contains "Would run: sudo $mock_port selfupdate" "$output"
contains 'Would install MacPorts port git (for git)' "$output"
contains 'Would install MacPorts port skhd (for asmvik/formulae/skhd)' "$output"
contains 'Would install MacPorts port 1password-cli (for 1password-cli)' "$output"
contains 'Would run reviewed fallback for mas' "$output"
contains 'Would run reviewed fallback for rtk' "$output"
contains 'Would run reviewed fallback for signal-cli' "$output"
contains 'Install cask firefox manually' "$output"
[ ! -s "$sudo_log" ] || fail 'Dry run used sudo.'

output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$brewfile")"
contains 'Would run reviewed fallback for mas' "$output"
contains 'Would run reviewed fallback for rtk' "$output"
contains 'Would run reviewed fallback for signal-cli' "$output"
not_contains 'No verified native fallback for arm64' "$output"

if output="$(MOCK_ARCH=x86_64 MOCK_TRANSLATED=1 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_SYSCTL_BIN="$mock_sysctl" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$brewfile" 2>&1)"; then fail 'Rosetta execution unexpectedly proceeded.'; fi
contains 'brew-port cannot run under Rosetta' "$output"
not_contains 'Would run reviewed fallback' "$output"

ruby_forms_brewfile="$tmp_dir/ruby-forms.Brewfile"
printf '%s\n' "brew 'git'" 'brew("asmvik/formulae/skhd")' "cask '1password-cli'" 'cask("firefox")' >"$ruby_forms_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$ruby_forms_brewfile")"
contains 'Would install MacPorts port git (for git)' "$output"
contains 'Would install MacPorts port skhd (for asmvik/formulae/skhd)' "$output"
contains 'Would install MacPorts port 1password-cli (for 1password-cli)' "$output"
contains 'Install cask firefox manually' "$output"

bad_map="$tmp_dir/bad.json"
printf '%s\n' '{"version":1,"mappings":[{"kind":"brew","token":"bad","action":"fallback","target":"../escape.sh","architectures":["arm64"]}]}' >"$bad_map"
if output="$("$utility" map validate --map "$bad_map" 2>&1)"; then fail 'Invalid map passed validation.'; fi
contains 'Invalid mapping file' "$output"

map_dir="$tmp_dir/local-map"
mkdir -p "$map_dir/fallbacks"
local_map="$map_dir/mappings.json"
cat >"$local_map" <<'EOF'
{"version":1,"mappings":[
 {"kind":"brew","token":"git","action":"skip","note":"local override"},
 {"kind":"brew","token":"root-tool","action":"fallback-root","target":"fallbacks/root-tool.sh","architectures":["arm64"],"note":"local trusted test fallback"},
 {"kind":"brew","token":"multiline-tool","action":"fallback","target":"fallbacks/root-tool.sh","architectures":["arm64"],"note":"First line\nSecond line"},
 {"kind":"brew","token":"escaped-tool","action":"fallback","target":"fallbacks/escaped-tool.sh","architectures":["arm64"],"note":"must remain in this map"}
]}
EOF
cat >"$map_dir/fallbacks/root-tool.sh" <<'EOF'
#!/usr/bin/env bash
"$BREW_PORT_SUDO_BIN" -n /usr/bin/true
EOF
chmod +x "$map_dir/fallbacks/root-tool.sh"
outside_fallback="$tmp_dir/outside-fallback.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$outside_fallback"
chmod +x "$outside_fallback"
ln -s "$outside_fallback" "$map_dir/fallbacks/escaped-tool.sh"
"$utility" map validate --map "$local_map" >/dev/null
output="$("$utility" map explain brew git --map "$local_map")"
contains 'skip' "$output"
contains 'local override' "$output"

duplicate_map="$tmp_dir/duplicate-map.json"
cat >"$duplicate_map" <<'EOF'
{"version":1,"mappings":[
 {"kind":"brew","token":"duplicate-tool","action":"port","target":"wrong-port","note":"first map entry"},
 {"kind":"brew","token":"duplicate-tool","action":"skip","note":"last map entry"}
]}
EOF
"$utility" map validate --map "$duplicate_map" >/dev/null
output="$("$utility" map explain brew duplicate-tool --map "$duplicate_map")"
contains 'duplicate-tool: skip' "$output"
contains 'last map entry' "$output"
not_contains 'first map entry' "$output"

multiline_brewfile="$tmp_dir/multiline.Brewfile"
printf '%s\n' 'brew "multiline-tool"' >"$multiline_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run --map "$local_map" "$multiline_brewfile")"
contains 'Would run reviewed fallback for multiline-tool: First line' "$output"
contains 'Second line' "$output"
not_contains 'No verified native fallback for arm64' "$output"

escaped_brewfile="$tmp_dir/escaped.Brewfile"
printf '%s\n' 'brew "escaped-tool"' >"$escaped_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run --map "$local_map" "$escaped_brewfile")"
contains 'Fallback target escapes the map fallbacks directory: fallbacks/escaped-tool.sh' "$output"
not_contains 'Would run reviewed fallback for escaped-tool' "$output"

root_brewfile="$tmp_dir/root.Brewfile"
printf '%s\n' 'brew "git"' 'brew "root-tool"' >"$root_brewfile"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --map "$local_map" "$root_brewfile")"
contains 'Requesting administrator access for MacPorts...' "$output"
contains 'git: local override' "$output"
[ "$(grep -Fxc -- '-v' "$sudo_log")" -eq 1 ] || fail 'Expected a single sudo lease.'
[ "$(grep -Fxc -- "-n $mock_port selfupdate" "$sudo_log")" -eq 1 ] || fail 'Selfupdate did not reuse sudo.'
[ "$(grep -Fxc -- '-n /usr/bin/true' "$sudo_log")" -eq 1 ] || fail 'fallback-root did not reuse sudo.'

: >"$sudo_log"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" update --dry-run --map "$local_map")"
contains "Would run: sudo $mock_port upgrade outdated" "$output"
[ ! -s "$sudo_log" ] || fail 'Dry-run update used sudo.'
[ ! -e "$XDG_STATE_HOME/brew-port" ] || fail 'Dry-run update wrote fallback state.'

release_dir="$tmp_dir/release"
mkdir -p "$release_dir/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo rtk-arm64' >"$release_dir/bin/rtk"
chmod +x "$release_dir/bin/rtk"
archive="$tmp_dir/rtk-arm64.tar.gz"
tar -czf "$archive" -C "$release_dir" .
digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
release_json="$tmp_dir/release.json"
printf '{"tag_name":"v1.2.3","assets":[{"name":"rtk-aarch64-apple-darwin.tar.gz","browser_download_url":"https://example.invalid/rtk/aarch64","digest":"sha256:%s"}]}' "$digest" >"$release_json"
mock_curl="$tmp_dir/curl"
curl_log="$tmp_dir/curl.log"
cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
output_file= url=
while [ "$#" -gt 0 ]; do
  case "$1" in --output) shift; output_file="$1" ;; *) url="$1" ;; esac
  shift
done
echo "$url" >>"$MOCK_CURL_LOG"
case "$url" in
  */releases/latest) cp "$MOCK_RELEASE_JSON" "$output_file" ;;
  */aarch64) cp "$MOCK_RELEASE_ARCHIVE" "$output_file" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$mock_curl"
fallback_home="$tmp_dir/fallback-home"
output="$(HOME="$fallback_home" XDG_STATE_HOME="$tmp_dir/state" BREW_PORT_ARCH=arm64 BREW_PORT_CURL_BIN="$mock_curl" MOCK_CURL_LOG="$curl_log" MOCK_RELEASE_JSON="$release_json" MOCK_RELEASE_ARCHIVE="$archive" "$repo_dir/maps/fallbacks/install-rtk.sh")"
contains 'Installed rtk release v1.2.3.' "$output"
contains 'rtk-arm64' "$("$fallback_home/.local/bin/rtk")"
grep -Fqx 'https://example.invalid/rtk/aarch64' "$curl_log" || fail 'arm64 fallback did not select the aarch64 asset.'

signal_release_dir="$tmp_dir/signal-release"
mkdir -p "$signal_release_dir/signal-cli-1.2.3/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$JAVA_HOME"' >"$signal_release_dir/signal-cli-1.2.3/bin/signal-cli"
chmod +x "$signal_release_dir/signal-cli-1.2.3/bin/signal-cli"
signal_archive="$tmp_dir/signal-cli.tar.gz"
tar -czf "$signal_archive" -C "$signal_release_dir" .
signal_digest="$(shasum -a 256 "$signal_archive" | awk '{print $1}')"
signal_json="$tmp_dir/signal-cli.json"
printf '{"tag_name":"v1.2.3","assets":[{"name":"signal-cli-1.2.3.tar.gz","browser_download_url":"https://example.invalid/signal/aarch64","digest":"sha256:%s"}]}' "$signal_digest" >"$signal_json"
signal_home="$tmp_dir/signal-home"
: >"$sudo_log"
HOME="$signal_home" \
	XDG_STATE_HOME="$tmp_dir/signal-state" \
	MOCK_CURL_LOG="$curl_log" \
	MOCK_RELEASE_JSON="$signal_json" \
	MOCK_RELEASE_ARCHIVE="$signal_archive" \
	SUDO_LOG="$sudo_log" \
	BREW_PORT_ARCH=arm64 \
	BREW_PORT_PORT_BIN="$mock_port" \
	BREW_PORT_SUDO_BIN="$mock_sudo" \
	BREW_PORT_CURL_BIN="$mock_curl" \
	BREW_PORT_SIGNAL_CLI_JAVA_HOME=/native/openjdk25 \
	"$repo_dir/maps/fallbacks/install-signal-cli.sh" >/dev/null
contains '/native/openjdk25' "$("$signal_home/.local/bin/signal-cli")"
[ "$(grep -Fxc -- "-n $mock_port install openjdk25" "$sudo_log")" -eq 1 ] || fail 'signal-cli must provision OpenJDK 25 through the existing sudo lease.'

if output="$(BREW_PORT_JQ_BIN=/not/a/jq "$utility" map validate 2>&1)"; then fail 'map validate unexpectedly worked without jq.'; fi
contains 'jq is required' "$output"

"$utility" completion install fish >/dev/null
[ -f "$XDG_CONFIG_HOME/fish/completions/brew-port.fish" ] || fail 'Fish completion was not installed.'
"$utility" completion bash | grep -Fq 'complete -F _brew_port brew-port'

shellcheck -s bash -x -P "$repo_dir/bin" "$utility" "$repo_dir"/maps/fallbacks/*.sh
git diff --check
printf '%s\n' 'brew-port checks passed.'
