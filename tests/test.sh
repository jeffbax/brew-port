#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
utility="$repo_dir/bin/brew-port"
shfmt_bin="${SHFMT_BIN:-shfmt}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-port-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
# Entrypoints and mocks use env bash; keep subprocesses on the tested interpreter.
mkdir "$tmp_dir/bash-runtime"
ln -s "$BASH" "$tmp_dir/bash-runtime/bash"
export PATH="$tmp_dir/bash-runtime:$PATH"
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
has_candidate() {
	local expected="$1" candidate
	shift
	for candidate in "$@"; do [ "$candidate" = "$expected" ] && return 0; done
	return 1
}

(
	source "$repo_dir/bin/lib/brew-port/fallbacks.bash"
	for literal in 'puts %q(brew is optional)' 'managers = %w[brew cask mas]' 'puts %Q{outer {brew is optional} cask is optional}' 'puts %(brew is optional)' 'puts %q!brew is optional!' 'puts %q(brew \) cask is optional)' 'puts %i[brew cask mas]' 'puts %r<brew cask mas>'; do
		if bp_declaration_looks_like_package "$literal"; then fail "Literal mistaken for a package call: $literal"; fi
	done
	for declaration in 'puts %q(brew is optional); brew "missing-audit-package"' 'managers = %w[brew cask mas]; cask "missing-app"' 'puts %q!brew is optional!; mas "Missing App", id: 10002' 'puts %Q{outer {brew is optional} cask is optional}; brew "missing-audit-package"' 'puts %q(brew \) cask is optional); cask "missing-app"'; do
		bp_declaration_looks_like_package "$declaration" || fail "Package call after literal was missed: $declaration"
	done
	for declaration in 'counter = 10; counter%=2; brew "missing-audit-package"' 'counter = 10; counter %= 2; brew "missing-audit-package"'; do
		bp_declaration_looks_like_package "$declaration" || fail "Package call after modulo assignment was missed: $declaration"
	done
	for expression in '10%-2' '10%+2' '10 % -2' '10 %-2' 'counter%-2' '(10)%-2' 'values[0]%-2'; do
		bp_declaration_looks_like_package "counter = $expression; brew \"missing-audit-package\"" || fail "Package call after modulo arithmetic was missed: $expression"
	done
	bp_declaration_looks_like_package 'counter = 10%(brew "missing-audit-package")' || fail 'Package call inside a modulo operand was missed.'
	for declaration in 'counter = 10; counter %-2; brew "missing-audit-package"' 'puts "a" %(brew "missing-audit-package")' "puts 'a' %(brew \"missing-audit-package\")"; do
		bp_declaration_looks_like_package "$declaration" || fail "Package call after a modulo operand was missed: $declaration"
	done
	bp_declaration_looks_like_package 'puts %q(unfinished' || fail 'Unclosed literal candidate was silently ignored.'
	if bp_declaration_looks_like_package 'puts %q(brew "literal-only")'; then fail 'Package text in a closed literal was mistaken for a call.'; fi
)
mock_uname="$tmp_dir/uname"
mock_port="$tmp_dir/port"
mock_sudo="$tmp_dir/sudo"
mock_sysctl="$tmp_dir/sysctl"
mock_mas="$tmp_dir/mas"
mock_curl="$tmp_dir/curl"
sudo_log="$tmp_dir/sudo.log"
jq_log="$tmp_dir/jq.log"
mas_log="$tmp_dir/mas.log"
curl_log="$tmp_dir/curl.log"
active_ports="$tmp_dir/active-ports"
all_ports="$tmp_dir/all-ports"
port_info="$tmp_dir/port-info"
port_livecheck="$tmp_dir/port-livecheck"
curl_response="$tmp_dir/curl-response"
mas_installed="$tmp_dir/mas-installed"
: >"$active_ports"
: >"$all_ports"
: >"$port_info"
: >"$port_livecheck"
: >"$curl_response"
: >"$mas_installed"
export MOCK_ACTIVE_PORTS="$active_ports"
export MOCK_ALL_PORTS="$all_ports"
export MOCK_PORT_INFO="$port_info"
export MOCK_PORT_LIVECHECK="$port_livecheck"
export MOCK_CURL_RESPONSE="$curl_response"
export MOCK_MAS_INSTALLED="$mas_installed"
cat >"$mock_uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in -s) echo Darwin ;; -m) echo "${MOCK_ARCH:?}" ;; *) exit 2 ;; esac
EOF
cat >"$mock_port" <<'EOF'
#!/usr/bin/env bash
[ -z "${MOCK_PORT_LOG:-}" ] || printf '%s\n' "$*" >>"$MOCK_PORT_LOG"
if [ "$1 ${2:-} ${3:-}" = '-q echo active' ]; then
	cat "${MOCK_ACTIVE_PORTS:?}"
	exit 0
fi
if [ "$1 ${2:-} ${3:-}" = '-q echo all' ]; then
	cat "${MOCK_ALL_PORTS:?}"
	exit 0
fi
[ "${1:-}" != -b ] || shift
case "$1" in
version) exit 0 ;;
install)
	echo "port $*"
	for target in "${@:2}"; do [ "${MOCK_PORT_FAIL_TARGET:-}" != "$target" ] || exit 1; done
	;;
info) cat "${MOCK_PORT_INFO:?}" ;;
livecheck)
	if [ "${2:-}" = -v ]; then
		cat "${MOCK_PORT_LIVECHECK:?}"
	else
		sed '/seems to be up to date/d' "${MOCK_PORT_LIVECHECK:?}"
	fi
	;;
archivefetch)
	[ "${MOCK_PORT_ARCHIVE_FAIL:-}" != "${2:-}" ] || {
		printf 'Archive for %s not found, required when binary-only\n' "${2:-}" >&2
		exit 1
	}
	printf 'Fetched archive for %s\n' "${2:-}"
	;;
selfupdate|select|upgrade) echo "port $*" ;;
*) exit 2 ;;
esac
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
cat >"$mock_mas" <<'EOF'
#!/usr/bin/env bash
command="$1"
shift
[ -z "${MOCK_MAS_LOG:-}" ] || printf '%s %s\n' "$command" "$*" >>"$MOCK_MAS_LOG"
[ "${MOCK_MAS_HANG_COMMAND:-}" != "$command" ] || sleep 5
[ "${MOCK_MAS_FAIL_COMMAND:-}" != "$command" ] || { printf 'mock MAS %s failed\n' "$command" >&2; exit 1; }
case "$command" in
list)
	status=0
	for id in "$@"; do
		if grep -Fxq -- "$id" "${MOCK_MAS_INSTALLED:?}"; then
			printf '%s Mock App (1.0)\n' "$id"
		elif [ "${MOCK_MAS_PER_ID_ERRORS:-0}" = 1 ]; then
			printf 'Error: No installed apps with ADAM ID %s\n' "$id" >&2
			status=1
		fi
	done
	exit "$status"
	;;
lookup)
	[ "${1:-}" = --json ] && shift
	status=0
	for id in "$@"; do
		if [ "${MOCK_MAS_INVALID:-}" != "$id" ]; then
			printf '{"adamID":%s}\n' "$id"
		elif [ "${MOCK_MAS_PER_ID_ERRORS:-0}" = 1 ]; then
			printf 'Error: No apps found in the App Store for ADAM ID %s\n' "$id" >&2
			status=1
		fi
	done
	[ "${MOCK_MAS_LOOKUP_SERVICE_ERROR:-0}" != 1 ] || { printf 'Error: Network connection failed\n' >&2; status=1; }
	exit "$status"
	;;
install)
	[ "${MOCK_MAS_FAIL_INSTALL:-0}" != 1 ] || { echo 'mock MAS install failed' >&2; exit 1; }
	printf 'install %s\n' "$*" >>"${MAS_LOG:?}"
	printf '%s\n' "$@" >>"${MOCK_MAS_INSTALLED:?}"
	;;
*) exit 2 ;;
esac
EOF
chmod +x "$mock_mas"
cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
[ -z "${MOCK_CURL_LOG:-}" ] || printf '%s\n' "$*" >>"$MOCK_CURL_LOG"
[ "${MOCK_CURL_FAIL:-0}" != 1 ] || { printf 'mock curl failure\n' >&2; exit 1; }
cat "${MOCK_CURL_RESPONSE:?}"
EOF
chmod +x "$mock_curl"

custom_port_bin="$tmp_dir/custom-macports/bin"
mkdir -p "$custom_port_bin"
ln -s "$mock_port" "$custom_port_bin/port"
cat >"$custom_port_bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_JQ_LOG:?}"
exec /usr/bin/jq "$@"
EOF
chmod +x "$custom_port_bin/jq"

for file in "$utility" "$repo_dir"/bin/lib/brew-port/*.bash "$repo_dir"/maps/fallbacks/*.sh "$repo_dir/tests/integration.sh"; do bash -n "$file"; done
command -v "$shfmt_bin" >/dev/null || fail 'shfmt is required to run the checks.'
"$shfmt_bin" -ln bash -d "$utility" "$repo_dir"/bin/lib/brew-port/*.bash "$repo_dir"/maps/fallbacks/*.sh "$repo_dir"/completions/brew-port.bash "$repo_dir/tests/integration.sh" "$0"
[ -x "$utility" ] || fail 'brew-port must be executable.'
[ ! -e "$repo_dir/bin/macports-brewfile" ] || fail 'The old CLI must not remain.'
[ -f "$repo_dir/.agents/skills/brew-port/SKILL.md" ] || fail 'Missing agent skill.'
"$utility" map validate | grep -Fq 'Mappings are valid.'
[ "$("$utility" --version)" = "$("$utility" version)" ] || fail '--version did not match version.'
"$utility" help map explain | grep -Fq 'Usage: brew-port map explain'
"$utility" help audit | grep -Fq 'Usage: brew-port audit'
"$utility" help completion install | grep -Fq 'Usage: brew-port completion install'
"$utility" help completion uninstall | grep -Fq 'Usage: brew-port completion uninstall'
"$utility" map --help | grep -Fq 'brew-port map validate'
"$utility" completion install --help | grep -Fq 'Install completion and activate it'
if output="$("$utility" not-a-command 2>&1)"; then fail 'Unknown command unexpectedly succeeded.'; fi
contains 'Unknown command: not-a-command' "$output"
prefix_brewfile="$tmp_dir/custom-prefix.Brewfile"
printf '%s\n' 'brew "git"' >"$prefix_brewfile"
: >"$jq_log"
MOCK_ARCH=arm64 MOCK_JQ_LOG="$jq_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$custom_port_bin/port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$prefix_brewfile" >/dev/null
[ -s "$jq_log" ] || fail 'The selected MacPorts prefix jq was not used.'
printf '%s\n' git >"$all_ports"
printf '%s\n' git >"$active_ports"
: >"$jq_log"
MOCK_ARCH=arm64 MOCK_JQ_LOG="$jq_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$custom_port_bin/port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$prefix_brewfile" >/dev/null
[ -s "$jq_log" ] || fail 'Audit did not use jq from the selected MacPorts prefix.'
: >"$all_ports"
: >"$active_ports"
MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install "$prefix_brewfile" --dry-run >/dev/null
MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install -- "$prefix_brewfile" >/dev/null
linked_bin="$tmp_dir/linked-bin"
mkdir -p "$linked_bin"
ln -s "$utility" "$linked_bin/brew-port"
[ "$("$linked_bin/brew-port" version)" = "$("$utility" version)" ] || fail 'A symlinked entrypoint could not locate its libraries.'
"$utility" map init >/dev/null
[ -f "$XDG_CONFIG_HOME/brew-port/mappings.json" ] || fail 'map init did not create an override file.'
"$utility" map validate >/dev/null

brewfile="$tmp_dir/Brewfile"
printf '%s\n' \
	'brew "git"' \
	'brew "asmvik/formulae/skhd"' \
	'brew "csvkit"' \
	'brew "mas"' \
	'brew "rtk"' \
	'brew "signal-cli"' \
	'cask "1password-cli"' \
	'cask "firefox"' >"$brewfile"
: >"$sudo_log"
output="$(MOCK_ARCH=x86_64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$brewfile")"
contains "Would run: sudo $mock_port selfupdate" "$output"
contains 'Would install MacPorts ports: git skhd 1password-cli' "$output"
contains 'Would run reviewed fallback for csvkit' "$output"
contains 'Would run reviewed fallback for mas' "$output"
contains 'Would run reviewed fallback for rtk' "$output"
contains 'Would run reviewed fallback for signal-cli' "$output"
contains 'Install cask firefox manually.' "$output"
[ ! -s "$sudo_log" ] || fail 'Dry run used sudo.'

output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$brewfile")"
contains 'Would run reviewed fallback for mas' "$output"
contains 'Would run reviewed fallback for csvkit' "$output"
contains 'Would run reviewed fallback for rtk' "$output"
contains 'Would run reviewed fallback for signal-cli' "$output"
not_contains 'No verified native fallback for arm64' "$output"

if output="$(MOCK_ARCH=x86_64 MOCK_TRANSLATED=1 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_SYSCTL_BIN="$mock_sysctl" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$brewfile" 2>&1)"; then fail 'Rosetta execution unexpectedly proceeded.'; fi
contains 'brew-port cannot run under Rosetta' "$output"
not_contains 'Would run reviewed fallback' "$output"

: >"$sudo_log"
SUDO_LOG="$sudo_log" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$repo_dir/maps/fallbacks/install-csvkit.sh" >/dev/null
grep -Fqx -- "-n $mock_port install py313-csvkit" "$sudo_log" || fail 'csvkit fallback did not install the versioned MacPorts port.'
grep -Fqx -- "-n $mock_port select --set csvkit py313-csvkit" "$sudo_log" || fail 'csvkit fallback did not select the unversioned commands.'

ruby_forms_brewfile="$tmp_dir/ruby-forms.Brewfile"
printf '%s\n' "brew 'git'" 'brew("asmvik/formulae/skhd")' "cask '1password-cli'" 'cask("firefox")' >"$ruby_forms_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$ruby_forms_brewfile")"
contains 'Would install MacPorts ports: git skhd 1password-cli' "$output"
contains 'Install cask firefox manually.' "$output"

conditional_brewfile="$tmp_dir/conditional.Brewfile"
printf '%s\n' 'brew "signal-cli" if Hardware::CPU.intel?' 'if Hardware::CPU.intel?' '  brew "rtk"' 'end' >"$conditional_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$conditional_brewfile")"
contains 'brew signal-cli: Conditional Brewfile declaration is unsupported.' "$output"
contains 'brew rtk: Conditional Brewfile declaration is unsupported.' "$output"
not_contains 'Would run reviewed fallback for signal-cli' "$output"
not_contains 'Would run reviewed fallback for rtk' "$output"

escaped_quote_brewfile="$tmp_dir/escaped-quote.Brewfile"
printf '%s\n' 'brew "git", args: ["foo\"#bar"] if false' >"$escaped_quote_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$escaped_quote_brewfile")"
contains 'brew git: Conditional Brewfile declaration is unsupported.' "$output"
not_contains 'Would install MacPorts ports: git' "$output"

commented_brewfile="$tmp_dir/commented.Brewfile"
printf '%s\n' 'brew "git" # if needed' >"$commented_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$commented_brewfile")"
contains 'Would install MacPorts ports: git' "$output"
not_contains 'Conditional Brewfile declaration is unsupported.' "$output"

cask_only_brewfile="$tmp_dir/cask-only.Brewfile"
printf '%s\n' 'cask "firefox"' >"$cask_only_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$cask_only_brewfile")"
contains 'Install cask firefox manually.' "$output"

manual_map="$tmp_dir/manual-map.json"
manual_present="$tmp_dir/Present App.app"
mkdir "$manual_present"
jq -n --arg present "$manual_present" --arg missing "$tmp_dir/Missing App.app" '{version:1,mappings:[
  {kind:"cask",token:"present-app",action:"manual",detect:[$present]},
  {kind:"cask",token:"missing-app",action:"manual",detect:[$missing]}
]}' >"$manual_map"
manual_brewfile="$tmp_dir/manual.Brewfile"
printf '%s\n' 'cask "present-app"' 'cask "missing-app"' >"$manual_brewfile"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run --map "$manual_map" "$manual_brewfile")"
contains 'Already present: 1' "$output"
contains 'Install cask missing-app manually.' "$output"
not_contains 'Install cask present-app manually.' "$output"

empty_brewfile="$tmp_dir/empty.Brewfile"
: >"$empty_brewfile"
MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$empty_brewfile" >/dev/null

already_active_brewfile="$tmp_dir/already-active.Brewfile"
duplicate_active_brewfile="$tmp_dir/duplicate-active.Brewfile"
printf '%s\n' 'brew "git"' >"$already_active_brewfile"
printf '%s\n' 'brew "git"' >"$duplicate_active_brewfile"
printf '%s\n' git >"$active_ports"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install "$already_active_brewfile" "$duplicate_active_brewfile")"
contains 'Already present: 1' "$output"
contains 'Installed: 0' "$output"
[ ! -s "$sudo_log" ] || fail 'An already-satisfied plan used sudo.'

batch_brewfile="$tmp_dir/batch.Brewfile"
printf '%s\n' 'brew "git"' 'brew "tree"' >"$batch_brewfile"
: >"$active_ports"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install "$batch_brewfile")"
contains 'Installing MacPorts ports: git tree' "$output"
contains 'Installed: 2' "$output"
[ "$(grep -Fxc -- "-n $mock_port install git tree" "$sudo_log")" -eq 1 ] || fail 'Missing ports were not installed in one batch.'
: >"$active_ports"

mas_brewfile="$tmp_dir/mas.Brewfile"
printf '%s\n' 'mas "Tom'"'"'s App", id: 12345' >"$mas_brewfile"
: >"$mas_log"
PATH="$tmp_dir:$PATH" MAS_LOG="$mas_log" MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install "$mas_brewfile" >/dev/null
grep -Fqx 'install 12345' "$mas_log" || fail 'MAS installation was gated on the obsolete account subcommand.'

mixed_mas_brewfile="$tmp_dir/mixed-mas.Brewfile"
printf '%s\n' 'mas "Valid App", id: 11111' 'mas "Invalid App", id: 99999' >"$mixed_mas_brewfile"
: >"$mas_installed"
: >"$mas_log"
if output="$(PATH="$tmp_dir:$PATH" MAS_LOG="$mas_log" MOCK_MAS_INVALID=99999 MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install "$mixed_mas_brewfile" 2>&1)"; then fail 'An invalid MAS ID did not fail reconciliation.'; fi
contains 'Invalid App (99999): Mac App Store ID is unavailable.' "$output"
contains 'Result: failed' "$output"
grep -Fqx 'install 11111' "$mas_log" || fail 'The valid MAS ID was not installed in the batch.'
not_contains '99999' "$(cat "$mas_log")"

timeout_mas_brewfile="$tmp_dir/timeout-mas.Brewfile"
printf '%s\n' 'mas "Slow App", id: 22222' >"$timeout_mas_brewfile"
: >"$mas_installed"
: >"$mas_log"
output="$(PATH="$tmp_dir:$PATH" MAS_LOG="$mas_log" MOCK_MAS_HANG_COMMAND=install BREW_PORT_MAS_TIMEOUT=1 MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install "$timeout_mas_brewfile")"
contains 'Batch install timed out after 1s; returning success to the caller.' "$output"
contains 'Result: success with warnings' "$output"
[ ! -s "$mas_log" ] || fail 'A timed-out MAS batch fell back to one-by-one installation.'

audit_map_dir="$tmp_dir/audit-map"
audit_map="$audit_map_dir/mappings.json"
audit_present="$tmp_dir/Audit Present.app"
mkdir -p "$audit_map_dir/fallbacks" "$audit_present"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$audit_map_dir/fallbacks/fallback-tool.sh"
chmod +x "$audit_map_dir/fallbacks/fallback-tool.sh"
jq -n --arg present "$audit_present" --arg missing "$tmp_dir/Audit Missing.app" '{version:1,mappings:[
  {kind:"brew",token:"fallback-tool",action:"fallback",target:"fallbacks/fallback-tool.sh",architectures:["arm64"]},
  {kind:"brew",token:"wrong-arch-tool",action:"fallback",target:"fallbacks/fallback-tool.sh",architectures:["x86_64"]},
  {kind:"cask",token:"present-app",action:"manual",detect:[$present]},
  {kind:"cask",token:"missing-app",action:"manual",detect:[$missing]},
  {kind:"cask",token:"ported-app",action:"port",target:"git"},
  {kind:"cask",token:"versioned-app",action:"port",target:"git@1.2"},
  {kind:"cask",token:"variant-app",action:"port",target:"git +universal"},
  {kind:"cask",token:"disabled-variant-app",action:"port",target:"git -universal"},
  {kind:"cask",token:"multiple-variant-app",action:"port",target:"git +universal -docs"},
  {kind:"cask",token:"versioned-variant-app",action:"port",target:"git@1.2 +universal"},
  {kind:"cask",token:"inactive-variant-app",action:"port",target:"inactive-tool +universal"},
  {kind:"cask",token:"unavailable-variant-app",action:"port",target:"unavailable-tool -universal"},
  {kind:"cask",token:"skipped-app",action:"skip",note:"not needed after migration"}
]}' >"$audit_map"
audit_brewfile="$tmp_dir/audit.Brewfile"
printf '%s\n' \
	'brew "git"' \
	'brew "inactive-tool"' \
	'brew "unavailable-tool"' \
	'brew "fallback-tool"' \
	'brew "wrong-arch-tool"' \
	'cask "present-app"' \
	'cask "missing-app"' \
	'cask "unmapped-app"' \
	'cask "ported-app"' \
	'cask "versioned-app"' \
	'cask "variant-app"' \
	'cask "disabled-variant-app"' \
	'cask "multiple-variant-app"' \
	'cask "versioned-variant-app"' \
	'cask "inactive-variant-app"' \
	'cask "unavailable-variant-app"' \
	'cask "skipped-app"' \
	'mas "Installed App", id: 10001' \
	'mas "Missing App", id: 10002' \
	'mas "Invalid App", id: 10003' >"$audit_brewfile"
printf '%s\n' git inactive-tool >"$all_ports"
printf '%s\n' git >"$active_ports"
printf '%s\n' 10001 >"$mas_installed"
audit_port_log="$tmp_dir/audit-port.log"
audit_mas_log="$tmp_dir/audit-mas.log"
: >"$audit_port_log"
: >"$audit_mas_log"
: >"$sudo_log"
: >"$mas_log"
if output="$(PATH="$tmp_dir:$PATH" XDG_STATE_HOME="$tmp_dir/audit-state" MOCK_ARCH=arm64 MOCK_PORT_LOG="$audit_port_log" MOCK_MAS_LOG="$audit_mas_log" MOCK_MAS_INVALID=10003 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit --map "$audit_map" "$audit_brewfile" 2>&1)"; then fail 'Blocked audit unexpectedly succeeded.'; fi
contains 'MacPorts targets: active 7, inactive 2, unavailable 2' "$output"
contains 'Reviewed fallbacks: 1 (runtime presence not verified)' "$output"
contains 'Manual casks: detected 1, missing 1, unmapped 1' "$output"
contains 'Mac App Store apps: installed 1, missing 1, invalid 1, unknown 0' "$output"
contains 'brew inactive-tool: MacPorts port is available but inactive: inactive-tool.' "$output"
contains 'brew unavailable-tool: MacPorts port is unavailable: unavailable-tool.' "$output"
not_contains 'cask versioned-app: MacPorts port is unavailable: git@1.2.' "$output"
contains 'cask inactive-variant-app: MacPorts port is available but inactive: inactive-tool +universal.' "$output"
contains 'cask unavailable-variant-app: MacPorts port is unavailable: unavailable-tool -universal.' "$output"
contains 'brew wrong-arch-tool: No verified native fallback for arm64.' "$output"
contains 'cask missing-app: No configured detection path exists.' "$output"
contains 'cask unmapped-app: No mapping or detection path.' "$output"
contains 'Missing App (10002): Mac App Store app is not installed.' "$output"
contains 'Invalid App (10003): Mac App Store ID is unavailable.' "$output"
contains 'Result: blocked' "$output"
grep -Fqx -- '-q echo all' "$audit_port_log" || fail 'Audit did not scan the MacPorts catalog once.'
grep -Fqx -- '-q echo active' "$audit_port_log" || fail 'Audit did not scan active MacPorts ports once.'
grep -Fqx 'list 10001 10002 10003' "$audit_mas_log" || fail 'Audit did not list MAS apps in one batch.'
grep -Fqx 'lookup --json 10001 10002 10003' "$audit_mas_log" || fail 'Audit did not validate MAS IDs in one batch.'
[ ! -s "$sudo_log" ] || fail 'Audit used sudo.'
[ ! -s "$mas_log" ] || fail 'Audit invoked MAS installation.'
[ ! -e "$tmp_dir/audit-state/brew-port" ] || fail 'Audit wrote fallback state.'

partial_mas_brewfile="$tmp_dir/partial-mas.Brewfile"
printf '%s\n' 'mas "Installed App", id: 10001' 'mas "Missing App", id: 937984704' 'mas "Invalid App", id: 100000000000000' >"$partial_mas_brewfile"
if output="$(PATH="$tmp_dir:$PATH" MOCK_ARCH=arm64 MOCK_MAS_PER_ID_ERRORS=1 MOCK_MAS_INVALID=100000000000000 BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$partial_mas_brewfile" 2>&1)"; then fail 'Audit accepted missing and invalid apps from partial MAS batches.'; fi
contains 'Mac App Store apps: installed 1, missing 1, invalid 1, unknown 0' "$output"
contains 'Missing App (937984704): Mac App Store app is not installed.' "$output"
contains 'Invalid App (100000000000000): Mac App Store ID is unavailable.' "$output"
not_contains 'scan failed' "$output"
contains 'Result: blocked' "$output"

printf '%s\n' 'mas "Invalid App", id: 100000000000000' >"$partial_mas_brewfile"
if output="$(PATH="$tmp_dir:$PATH" MOCK_ARCH=arm64 MOCK_MAS_PER_ID_ERRORS=1 MOCK_MAS_INVALID=100000000000000 BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$partial_mas_brewfile" 2>&1)"; then fail 'Audit accepted an unavailable MAS ID.'; fi
contains 'Mac App Store apps: installed 0, missing 0, invalid 1, unknown 0' "$output"

if output="$(PATH="$tmp_dir:$PATH" MOCK_ARCH=arm64 MOCK_MAS_PER_ID_ERRORS=1 MOCK_MAS_INVALID=100000000000000 MOCK_MAS_LOOKUP_SERVICE_ERROR=1 BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$partial_mas_brewfile" 2>&1)"; then fail 'A service error hid an explicitly unavailable MAS ID.'; fi
contains 'Mac App Store apps: installed 0, missing 0, invalid 1, unknown 0' "$output"
contains 'Availability scan failed' "$output"
contains 'Result: blocked' "$output"

audit_options_brewfile="$tmp_dir/audit-options.Brewfile"
printf '%s\n' 'brew "llvm", args: ["with-clang"]' >"$audit_options_brewfile"
printf '%s\n' llvm >"$all_ports"
printf '%s\n' llvm >"$active_ports"
if output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$audit_options_brewfile" 2>&1)"; then fail 'Audit accepted unsupported Brewfile options.'; fi
contains 'brew llvm: Unsupported Brewfile options.' "$output"
not_contains 'MacPorts targets: active 1' "$output"
contains 'Result: blocked' "$output"

audit_warning_brewfile="$tmp_dir/audit-warning.Brewfile"
printf '%s\n' 'brew "git"' 'mas "Slow App", id: 10004' >"$audit_warning_brewfile"
printf '%s\n' git >"$all_ports"
printf '%s\n' git >"$active_ports"
printf '%s\n' 10004 >"$mas_installed"
: >"$audit_mas_log"
output="$(PATH="$tmp_dir:$PATH" MOCK_ARCH=arm64 MOCK_MAS_LOG="$audit_mas_log" MOCK_MAS_HANG_COMMAND=lookup BREW_PORT_MAS_TIMEOUT=1 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$audit_warning_brewfile")"
contains 'Availability scan timed out after 1s; App Store availability is unknown.' "$output"
contains 'Result: coverage complete with warnings' "$output"
grep -Fqx 'list 10004' "$audit_mas_log" || fail 'Audit warning path did not list MAS apps.'
grep -Fqx 'lookup --json 10004' "$audit_mas_log" || fail 'Audit warning path did not validate MAS IDs.'

audit_mas_failure_brewfile="$tmp_dir/audit-mas-failure.Brewfile"
printf '%s\n' 'brew "git"' 'mas "Lookup Failure", id: 10005' >"$audit_mas_failure_brewfile"
printf '%s\n' git >"$all_ports"
printf '%s\n' git >"$active_ports"
output="$(PATH="$tmp_dir:$PATH" MOCK_ARCH=arm64 MOCK_MAS_FAIL_COMMAND=lookup BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$audit_mas_failure_brewfile")"
contains 'Availability scan failed: mock MAS lookup failed; App Store availability is unknown.' "$output"
contains 'Result: coverage complete with warnings' "$output"

candidate_map_dir="$tmp_dir/candidate-map"
candidate_map="$candidate_map_dir/mappings.json"
candidate_present="$tmp_dir/HandBrake.app"
mkdir -p "$candidate_map_dir/fallbacks" "$candidate_present"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$candidate_map_dir/fallbacks/handbrake.sh"
chmod +x "$candidate_map_dir/fallbacks/handbrake.sh"
jq -n --arg present "$candidate_present" '{version:1,mappings:[
  {kind:"cask",token:"handbrake-app",action:"manual",detect:[$present]},
  {kind:"cask",token:"handbrake-desktop",action:"fallback",target:"fallbacks/handbrake.sh",architectures:["arm64"]},
  {kind:"cask",token:"handbrake",action:"skip"},
  {kind:"brew",token:"git",action:"skip"},
  {kind:"cask",token:"ported-app",action:"port",target:"git"}
]}' >"$candidate_map"
candidate_brewfile="$tmp_dir/candidates.Brewfile"
printf '%s\n' 'cask "handbrake-app"' 'cask "handbrake-desktop"' 'cask "handbrake"' 'cask "ported-app"' 'brew "git"' >"$candidate_brewfile"
printf '%s\n' git HandBrake HandBrakeCLI >"$all_ports"
printf '%s\n' git >"$active_ports"
printf '%s\n' \
	$'HandBrake\t0.10.0\t0\tmultimedia/HandBrake' \
	$'HandBrakeCLI\t0.10.0\t0\tmultimedia/HandBrake' >"$port_info"
printf '%s\n' \
	'HandBrake seems to have been updated (port version: 0.10.0, new version: 1.11.2)' \
	'HandBrakeCLI seems to be up to date' >"$port_livecheck"
printf '%s\n' '[{"commit":{"committer":{"date":"2024-05-12T19:50:06Z"}}}]' >"$curl_response"
: >"$audit_port_log"
: >"$curl_log"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 MOCK_PORT_LOG="$audit_port_log" MOCK_CURL_LOG="$curl_log" BREW_PORT_CURL_BIN="$mock_curl" SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit --candidates --map "$candidate_map" "$candidate_brewfile")"
contains 'MacPorts candidates: 6 suggestions for 3 casks (advisory)' "$output"
contains 'cask handbrake-app:' "$output"
contains 'cask handbrake-desktop:' "$output"
contains 'cask handbrake:' "$output"
not_contains 'cask git:' "$output"
contains '1. HandBrake @0.10.0_0' "$output"
contains 'upstream: seems to have been updated (port version: 0.10.0, new version: 1.11.2)' "$output"
contains 'upstream: seems to be up to date' "$output"
contains 'Portfile last changed: 2024-05-12' "$output"
contains 'binary archive: not checked (run with --verify-archives)' "$output"
not_contains 'cask ported-app:' "$output"
grep -Fqx -- 'livecheck -v HandBrake HandBrakeCLI' "$audit_port_log" || fail 'Candidate audit did not batch verbose MacPorts livecheck.'
[ "$(wc -l <"$curl_log")" -eq 1 ] || fail 'Candidate audit did not cache Portfile date lookups.'
not_contains '-b archivefetch' "$(cat "$audit_port_log")"
[ ! -s "$sudo_log" ] || fail 'Candidate audit without archive verification used sudo.'

: >"$audit_port_log"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 MOCK_PORT_LOG="$audit_port_log" MOCK_CURL_LOG="$curl_log" BREW_PORT_CURL_BIN="$mock_curl" SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit --candidates --verify-archives --map "$candidate_map" "$candidate_brewfile")"
contains 'binary archive: available (fetched or already cached)' "$output"
grep -Fqx -- '-b archivefetch HandBrake' "$audit_port_log" || fail 'Archive verification did not use binary-only archivefetch.'
grep -Fqx -- '-b archivefetch HandBrakeCLI' "$audit_port_log" || fail 'Archive verification did not check every candidate.'
grep -Fqx -- '-v' "$sudo_log" || fail 'Archive verification did not acquire the MacPorts sudo lease.'
grep -Fqx -- "-n $mock_port -b archivefetch HandBrake" "$sudo_log" || fail 'Archive verification did not fetch HandBrake through sudo.'
grep -Fqx -- "-n $mock_port -b archivefetch HandBrakeCLI" "$sudo_log" || fail 'Archive verification did not fetch HandBrakeCLI through sudo.'
[ "$(wc -l <"$sudo_log")" -eq 3 ] || fail 'Archive verification did not reuse one sudo lease.'
not_contains 'install ' "$(cat "$audit_port_log")"
not_contains '-b archivefetch git' "$(cat "$audit_port_log")"

: >"$audit_port_log"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 MOCK_PORT_ARCHIVE_FAIL=HandBrake MOCK_PORT_LOG="$audit_port_log" MOCK_CURL_LOG="$curl_log" BREW_PORT_CURL_BIN="$mock_curl" SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit --candidates --verify-archives --map "$candidate_map" "$candidate_brewfile")"
contains 'binary archive: unavailable for this MacPorts host' "$output"
contains 'Result: coverage complete with warnings' "$output"

output="$(MOCK_ARCH=arm64 MOCK_CURL_FAIL=1 BREW_PORT_CURL_BIN="$mock_curl" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit --candidates --map "$candidate_map" "$candidate_brewfile")"
contains 'Portfile update date for multimedia/HandBrake is unknown: mock curl failure.' "$output"
contains 'Result: coverage complete with warnings' "$output"
if output="$("$utility" audit --verify-archives "$candidate_brewfile" 2>&1)"; then fail 'Archive verification without candidates unexpectedly succeeded.'; fi
contains '--verify-archives requires --candidates.' "$output"

inline_conditional_brewfile="$tmp_dir/inline-conditional.Brewfile"
for declaration in 'if true; brew "not-installed-anywhere"; end' 'unless false; cask "missing-app"; end' 'case true; when true; mas "Missing App", id: 10002; end'; do
	printf '%s\n' "$declaration" >"$inline_conditional_brewfile"
	if output="$(MOCK_ARCH=arm64 BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$inline_conditional_brewfile" 2>&1)"; then fail 'Audit accepted an inline conditional declaration.'; fi
	contains 'Brewfile declaration: Conditional Brewfile declaration is unsupported.' "$output"
	contains 'Result: blocked' "$output"
done

inline_audit_brewfile="$tmp_dir/inline-audit.Brewfile"
for declaration in 'true && brew "missing-audit-package"' 'false || cask("missing-app")' 'true; mas "Missing App", id: 10002' '1.times { brew "missing-audit-package" }' $'1.times do\nend ; brew "missing-audit-package"' 'puts %q(brew is optional); brew "missing-audit-package"' 'counter = 10; counter%=2; brew "missing-audit-package"' 'counter = 10; counter %= 2; brew "missing-audit-package"' 'counter = 10%-2; brew "missing-audit-package"' 'counter = 10; counter %-2; brew "missing-audit-package"' 'puts "a" %(brew "missing-audit-package")'; do
	printf '%s\n' "$declaration" >"$inline_audit_brewfile"
	if output="$(MOCK_ARCH=arm64 BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$inline_audit_brewfile" 2>&1)"; then fail "Audit accepted an inline package declaration: $declaration"; fi
	contains 'Brewfile declaration: Unsupported brew, cask, or mas declaration.' "$output"
	contains 'Result: blocked' "$output"
done
printf '%s\n' '# true && brew "missing-audit-package"' 'puts "brew missing-audit-package"' 'puts %q(brew is optional)' 'managers = %w[brew cask mas]' 'tap "homebrew/cask" # cask "missing-app"' 'homebrew "ignored"' 'brew "git" # mas "Missing App", id: 10002' >"$inline_audit_brewfile"
output="$(MOCK_ARCH=arm64 BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$inline_audit_brewfile")"
contains 'MacPorts targets: active 1, inactive 0, unavailable 0' "$output"
contains 'Result: coverage complete' "$output"

malformed_audit_brewfile="$tmp_dir/malformed-audit.Brewfile"
printf '%s\n' 'mas "Malformed App", id: invalid' >"$malformed_audit_brewfile"
if output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" audit "$malformed_audit_brewfile" 2>&1)"; then fail 'Malformed audit declaration unexpectedly succeeded.'; fi
contains 'Brewfile declaration: Unsupported brew, cask, or mas declaration.' "$output"
contains 'Result: blocked' "$output"
: >"$active_ports"
: >"$all_ports"

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
 {"kind":"brew","token":"escaped-tool","action":"fallback","target":"fallbacks/escaped-tool.sh","architectures":["arm64"],"note":"must remain in this map"},
 {"kind":"brew","token":"failing-port","action":"port","target":"fails-to-install","note":"test a port failure"},
 {"kind":"brew","token":"failing-fallback","action":"fallback","target":"fallbacks/failing-fallback.sh","architectures":["arm64"],"note":"test a fallback failure"},
 {"kind":"brew","token":"mas-client","action":"fallback","target":"fallbacks/install-test-mas.sh","architectures":["arm64"],"note":"install the test MAS client first"}
]}
EOF
cat >"$map_dir/fallbacks/root-tool.sh" <<'EOF'
#!/usr/bin/env bash
"$BREW_PORT_SUDO_BIN" -n /usr/bin/true
EOF
chmod +x "$map_dir/fallbacks/root-tool.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$map_dir/fallbacks/failing-fallback.sh"
chmod +x "$map_dir/fallbacks/failing-fallback.sh"
cat >"$map_dir/fallbacks/install-test-mas.sh" <<'EOF'
#!/usr/bin/env bash
cat >"$BREW_PORT_TEST_MAS_BIN/mas" <<'MAS'
#!/usr/bin/env bash
command="$1"
shift
case "$command" in
list)
	for id in "$@"; do grep -Fxq -- "$id" "$MOCK_MAS_INSTALLED" && printf '%s Mock App (1.0)\n' "$id"; done
	true
	;;
lookup)
	[ "${1:-}" = --json ] && shift
	for id in "$@"; do printf '{"id":%s}\n' "$id"; done
	;;
install)
	printf 'install %s\n' "$*" >>"$MAS_LOG"
	printf '%s\n' "$@" >>"$MOCK_MAS_INSTALLED"
	;;
*) exit 2 ;;
esac
MAS
chmod +x "$BREW_PORT_TEST_MAS_BIN/mas"
EOF
chmod +x "$map_dir/fallbacks/install-test-mas.sh"
outside_fallback="$tmp_dir/outside-fallback.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$outside_fallback"
chmod +x "$outside_fallback"
ln -s "$outside_fallback" "$map_dir/fallbacks/escaped-tool.sh"
"$utility" map validate --map "$local_map" >/dev/null
output="$("$utility" map explain --map "$local_map" brew git)"
contains 'skip' "$output"
contains 'local override' "$output"

output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" refresh-fallbacks --dry-run --map "$local_map")"
not_contains 'Would run reviewed fallback' "$output"

ordered_mas_bin="$tmp_dir/ordered-mas-bin"
mkdir -p "$ordered_mas_bin"
ordered_mas_brewfile="$tmp_dir/ordered-mas.Brewfile"
printf '%s\n' 'mas "Ordered App", id: 54321' 'brew "mas-client"' >"$ordered_mas_brewfile"
: >"$mas_log"
PATH="$ordered_mas_bin:$PATH" MAS_LOG="$mas_log" BREW_PORT_TEST_MAS_BIN="$ordered_mas_bin" MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --map "$local_map" "$ordered_mas_brewfile" >/dev/null
grep -Fqx 'install 54321' "$mas_log" || fail 'A Brewfile MAS entry ran before its client prerequisite.'

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
if output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run --map "$local_map" "$escaped_brewfile" 2>&1)"; then fail 'Escaped fallback unexpectedly succeeded.'; fi
contains 'Fallback target escapes the map fallbacks directory: fallbacks/escaped-tool.sh' "$output"
not_contains 'Would run reviewed fallback for escaped-tool' "$output"
contains 'Result: failed' "$output"

failing_brewfile="$tmp_dir/failing.Brewfile"
printf '%s\n' 'brew "failing-port"' 'brew "failing-fallback"' >"$failing_brewfile"
if output="$(MOCK_ARCH=arm64 MOCK_PORT_FAIL_TARGET=fails-to-install SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --map "$local_map" "$failing_brewfile" 2>&1)"; then fail 'Failed package actions unexpectedly returned success.'; fi
contains 'failing-port: MacPorts install failed: fails-to-install' "$output"
contains 'failing-fallback: Fallback failed: test a fallback failure' "$output"

root_brewfile="$tmp_dir/root.Brewfile"
printf '%s\n' 'brew "git"' 'brew "root-tool"' >"$root_brewfile"
: >"$sudo_log"
output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --map "$local_map" "$root_brewfile")"
contains 'Requesting administrator access for MacPorts...' "$output"
contains 'git: local override' "$output"
[ "$(grep -Fxc -- '-v' "$sudo_log")" -eq 1 ] || fail 'Expected a single sudo lease.'
[ "$(grep -Fxc -- "-n $mock_port selfupdate" "$sudo_log")" -eq 1 ] || fail 'Selfupdate did not reuse sudo.'
[ "$(grep -Fxc -- '-n /usr/bin/true' "$sudo_log")" -eq 1 ] || fail 'fallback-root did not reuse sudo.'

output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" refresh-fallbacks --dry-run --map "$local_map")"
contains 'Would run reviewed fallback for root-tool' "$output"
not_contains 'Would run reviewed fallback for mas:' "$output"
not_contains 'Would run reviewed fallback for rtk' "$output"
not_contains 'Would run reviewed fallback for signal-cli' "$output"
not_contains 'Would run reviewed fallback for worktrunk' "$output"

invalid_inventory_state="$tmp_dir/invalid-inventory-state"
mkdir -p "$invalid_inventory_state/brew-port"
printf '%s\n' '{not valid json' >"$invalid_inventory_state/brew-port/requested-fallbacks.json"
for inventory_command in refresh-fallbacks update; do
	if output="$(XDG_STATE_HOME="$invalid_inventory_state" MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" "$inventory_command" --dry-run 2>&1)"; then fail "$inventory_command unexpectedly accepted an invalid fallback inventory."; fi
	contains "Invalid fallback inventory: $invalid_inventory_state/brew-port/requested-fallbacks.json" "$output"
done

: >"$sudo_log"
output="$(XDG_STATE_HOME="$tmp_dir/dry-state" MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" update --dry-run --map "$local_map")"
contains "Would run: sudo $mock_port upgrade outdated" "$output"
[ ! -s "$sudo_log" ] || fail 'Dry-run update used sudo.'
[ ! -e "$tmp_dir/dry-state/brew-port" ] || fail 'Dry-run update wrote fallback state.'

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
curl_args_log="$tmp_dir/curl-args.log"
cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
output_file= url=
[ -z "${MOCK_CURL_ARGS_LOG:-}" ] || printf '%s\n' "$@" >>"$MOCK_CURL_ARGS_LOG"
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
output="$(HOME="$fallback_home" XDG_STATE_HOME="$tmp_dir/state" GITHUB_TOKEN=ci-token BREW_PORT_ARCH=arm64 BREW_PORT_CURL_BIN="$mock_curl" MOCK_CURL_LOG="$curl_log" MOCK_CURL_ARGS_LOG="$curl_args_log" MOCK_RELEASE_JSON="$release_json" MOCK_RELEASE_ARCHIVE="$archive" "$repo_dir/maps/fallbacks/install-rtk.sh")"
contains 'Installed rtk release v1.2.3.' "$output"
contains 'rtk-arm64' "$("$fallback_home/.local/bin/rtk")"
grep -Fqx 'https://example.invalid/rtk/aarch64' "$curl_log" || fail 'arm64 fallback did not select the aarch64 asset.'
[ "$(grep -Fxc -- 'Authorization: Bearer ci-token' "$curl_args_log")" -eq 1 ] || fail 'fallback did not authenticate only its GitHub metadata request.'

output="$(MOCK_ARCH=arm64 SUDO_LOG="$sudo_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$mock_port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" refresh-fallbacks --dry-run)"
contains 'Would run reviewed fallback for rtk' "$output"

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
source "$repo_dir/completions/brew-port.bash"
COMP_WORDS=(brew-port map '')
COMP_CWORD=2
_brew_port
contains explain "${COMPREPLY[*]}"
COMP_WORDS=(brew-port audit '')
COMP_CWORD=2
_brew_port
contains --map "${COMPREPLY[*]}"
contains --candidates "${COMPREPLY[*]}"
contains --verify-archives "${COMPREPLY[*]}"
COMP_WORDS=(brew-port completion uninstall '')
COMP_CWORD=3
_brew_port
contains zsh "${COMPREPLY[*]}"
COMP_WORDS=(brew-port help completion '')
COMP_CWORD=3
_brew_port
contains install "${COMPREPLY[*]}"
completion_path_dir="$tmp_dir/completion-paths"
mkdir -p "$completion_path_dir"
touch "$completion_path_dir/Brewfile"
touch "$completion_path_dir/My Brewfile" "$completion_path_dir/My Mapping"
(
	cd "$completion_path_dir"
	COMP_WORDS=(brew-port install '')
	COMP_CWORD=2
	_brew_port
	contains Brewfile "${COMPREPLY[*]}"
	COMP_WORDS=(brew-port install Brewfile '')
	COMP_CWORD=3
	_brew_port
	contains Brewfile "${COMPREPLY[*]}"
	COMP_WORDS=(brew-port audit 'My ')
	COMP_CWORD=2
	_brew_port || true
	has_candidate 'My Brewfile' "${COMPREPLY[@]}" || fail 'Bash completion split an audit Brewfile path containing spaces.'
	COMP_WORDS=(brew-port install 'My ')
	COMP_CWORD=2
	_brew_port || true
	has_candidate 'My Brewfile' "${COMPREPLY[@]}" || fail 'Bash completion split a Brewfile path containing spaces.'
	COMP_WORDS=(brew-port install --map 'My ')
	COMP_CWORD=3
	_brew_port
	has_candidate 'My Mapping' "${COMPREPLY[@]}" || fail 'Bash completion split an install --map path containing spaces.'
	COMP_WORDS=(brew-port map validate --map 'My ')
	COMP_CWORD=4
	_brew_port
	has_candidate 'My Mapping' "${COMPREPLY[@]}" || fail 'Bash completion split a map validate --map path containing spaces.'
	COMP_WORDS=(brew-port map explain --map 'My ')
	COMP_CWORD=4
	_brew_port
	has_candidate 'My Mapping' "${COMPREPLY[@]}" || fail 'Bash completion split a map explain --map path containing spaces.'
)

completion_home="$tmp_dir/completion-home"
completion_data="$tmp_dir/completion-data"
mkdir -p "$completion_home" "$completion_data"
HOME="$completion_home" XDG_DATA_HOME="$completion_data" SHELL=/bin/bash "$utility" completion install >/dev/null
bash_completion="$completion_data/bash-completion/completions/brew-port"
[ -f "$bash_completion" ] || fail 'Bash completion was not installed.'
grep -Fqx '# brew-port completion (managed)' "$bash_completion" || fail 'Bash completion was not marked as managed.'
grep -Fqx '# >>> brew-port completion >>>' "$completion_home/.bashrc" || fail 'Bash completion did not update .bashrc.'
grep -Fqx '# >>> brew-port completion >>>' "$completion_home/.bash_profile" || fail 'Bash completion did not update the login startup file.'
HOME="$completion_home" XDG_DATA_HOME="$completion_data" SHELL=/bin/bash "$utility" completion install bash >/dev/null
[ "$(grep -Fxc '# >>> brew-port completion >>>' "$completion_home/.bashrc")" -eq 1 ] || fail 'Bash completion block was duplicated.'
[ "$(grep -Fxc '# >>> brew-port completion >>>' "$completion_home/.bash_profile")" -eq 1 ] || fail 'Bash login completion block was duplicated.'
HOME="$completion_home" XDG_DATA_HOME="$completion_data" SHELL=/bin/bash "$utility" completion uninstall bash >/dev/null
[ ! -e "$bash_completion" ] || fail 'Bash completion was not removed.'
[ "$(grep -Fxc '# >>> brew-port completion >>>' "$completion_home/.bashrc" || true)" -eq 0 ] || fail 'Bash completion block was not removed.'
[ "$(grep -Fxc '# >>> brew-port completion >>>' "$completion_home/.bash_profile" || true)" -eq 0 ] || fail 'Bash login completion block was not removed.'

profile_home="$tmp_dir/profile-completion-home"
profile_data="$tmp_dir/profile-completion-data"
mkdir -p "$profile_home" "$profile_data"
printf '%s\n' '# shared login profile' >"$profile_home/.profile"
HOME="$profile_home" XDG_DATA_HOME="$profile_data" "$utility" completion install bash >/dev/null
grep -Fqx 'if [ -n "${BASH_VERSION:-}" ]; then' "$profile_home/.profile" || fail '.profile completion block was not guarded for Bash.'
if command -v dash >/dev/null 2>&1; then
	if output="$(BASH_VERSION='' dash -c '. "$1"' dash "$profile_home/.profile" 2>&1)"; then :; else fail 'The guarded .profile completion block failed under dash.'; fi
	[ -z "$output" ] || fail 'The guarded .profile completion block wrote output under dash.'
fi

legacy_home="$tmp_dir/legacy-completion-home"
legacy_data="$tmp_dir/legacy-completion-data"
legacy_completion="$legacy_data/bash-completion/completions/brew-port"
mkdir -p "$(dirname "$legacy_completion")" "$legacy_home"
cat >"$legacy_completion" <<'EOF'
_brew_port() {
	local cur="${COMP_WORDS[COMP_CWORD]}" commands='install update refresh-fallbacks doctor version map completion'
	if [ "$COMP_CWORD" -eq 1 ]; then
		COMPREPLY=($(compgen -W "$commands" -- "$cur"))
		return
	fi
	case "${COMP_WORDS[1]}" in
	install | update | refresh-fallbacks) COMPREPLY=($(compgen -W '--dry-run --map --help' -- "$cur")) ;;
	map) COMPREPLY=($(compgen -W 'init validate explain' -- "$cur")) ;;
	completion) COMPREPLY=($(compgen -W 'bash fish zsh install' -- "$cur")) ;;
	esac
}
complete -F _brew_port brew-port
EOF
HOME="$legacy_home" XDG_DATA_HOME="$legacy_data" "$utility" completion install bash >/dev/null
grep -Fqx '# brew-port completion (managed)' "$legacy_completion" || fail 'Legacy Bash completion was not migrated.'
HOME="$legacy_home" XDG_DATA_HOME="$legacy_data" "$utility" completion uninstall bash >/dev/null
[ ! -e "$legacy_completion" ] || fail 'Migrated legacy Bash completion was not removed.'

legacy_zsh_home="$tmp_dir/legacy-zsh-completion-home"
legacy_zsh_data="$tmp_dir/legacy-zsh-completion-data"
legacy_zsh_dotdir="$tmp_dir/legacy-zsh-dotdir"
legacy_zsh_completion="$legacy_zsh_data/zsh/completions/_brew-port"
mkdir -p "$(dirname "$legacy_zsh_completion")" "$legacy_zsh_home" "$legacy_zsh_dotdir"
cat >"$legacy_zsh_completion" <<'EOF'
#compdef brew-port
_brew_port() {
  local -a commands
  commands=(
    'install:install Brewfile CLI declarations through MacPorts'
    'update:selfupdate and upgrade MacPorts'
    'refresh-fallbacks:refresh reviewed fallback tools'
    'doctor:report host and prerequisite status'
    'version:print version'
    'map:manage mappings'
    'completion:print or install completion'
  )
  _arguments '1:command:->command' '*::argument:->argument'
  case $state in
    command) _describe -t commands command commands ;;
    argument) case $words[2] in
      install|update|refresh-fallbacks) _arguments '--dry-run[do not change the machine]' '--map=[mapping file]:map file:_files' ;;
      map) _values 'map command' init validate explain ;;
      completion) _values 'shell' bash fish zsh install ;;
    esac ;;
  esac
}
_brew_port "$@"
EOF
HOME="$legacy_zsh_home" XDG_DATA_HOME="$legacy_zsh_data" ZDOTDIR="$legacy_zsh_dotdir" "$utility" completion install zsh >/dev/null
grep -Fqx '# brew-port completion (managed)' "$legacy_zsh_completion" || fail 'Legacy Zsh completion was not migrated.'
HOME="$legacy_zsh_home" XDG_DATA_HOME="$legacy_zsh_data" ZDOTDIR="$legacy_zsh_dotdir" "$utility" completion uninstall zsh >/dev/null
[ ! -e "$legacy_zsh_completion" ] || fail 'Migrated legacy Zsh completion was not removed.'

custom_zsh_home="$tmp_dir/custom-zsh-completion-home"
custom_zsh_data="$tmp_dir/custom-zsh-completion-data"
custom_zsh_dotdir="$tmp_dir/custom-zsh-dotdir"
custom_zsh_completion="$custom_zsh_data/zsh/completions/_brew-port"
mkdir -p "$(dirname "$custom_zsh_completion")" "$custom_zsh_home" "$custom_zsh_dotdir"
printf '%s\n' '#compdef brew-port' '_brew_port() {' '  _arguments "*:custom completion"' '}' '_brew_port "$@"' >"$custom_zsh_completion"
custom_zsh_before="$(cat "$custom_zsh_completion")"
if output="$(HOME="$custom_zsh_home" XDG_DATA_HOME="$custom_zsh_data" ZDOTDIR="$custom_zsh_dotdir" "$utility" completion install zsh 2>&1)"; then fail 'Custom Zsh completion was overwritten.'; fi
contains 'Refusing to replace non-brew-port completion' "$output"
[ "$(cat "$custom_zsh_completion")" = "$custom_zsh_before" ] || fail 'Custom Zsh completion changed during installation.'
if output="$(HOME="$custom_zsh_home" XDG_DATA_HOME="$custom_zsh_data" ZDOTDIR="$custom_zsh_dotdir" "$utility" completion uninstall zsh 2>&1)"; then fail 'Custom Zsh completion was removed.'; fi
contains 'Refusing to remove non-brew-port completion' "$output"
[ "$(cat "$custom_zsh_completion")" = "$custom_zsh_before" ] || fail 'Custom Zsh completion changed during removal.'

symlink_home="$tmp_dir/symlink-completion-home"
symlink_data="$tmp_dir/symlink-completion-data"
symlink_target="$tmp_dir/real-bashrc"
mkdir -p "$symlink_home" "$symlink_data"
printf '%s\n' '# existing bashrc' >"$symlink_target"
ln -s "$symlink_target" "$symlink_home/.bashrc"
HOME="$symlink_home" XDG_DATA_HOME="$symlink_data" "$utility" completion install bash >/dev/null
[ -L "$symlink_home/.bashrc" ] || fail 'Bash startup symlink was replaced.'
grep -Fqx '# >>> brew-port completion >>>' "$symlink_target" || fail 'Bash startup symlink target was not updated.'
HOME="$symlink_home" XDG_DATA_HOME="$symlink_data" "$utility" completion uninstall bash >/dev/null
[ -L "$symlink_home/.bashrc" ] || fail 'Bash startup symlink was replaced during removal.'
[ "$(grep -Fxc '# >>> brew-port completion >>>' "$symlink_target" || true)" -eq 0 ] || fail 'Bash startup symlink target was not cleaned up.'

zsh_dotdir="$tmp_dir/zsh-dotdir"
HOME="$completion_home" XDG_DATA_HOME="$completion_data" ZDOTDIR="$zsh_dotdir" "$utility" completion install zsh >/dev/null
grep -Fqx '# >>> brew-port completion >>>' "$zsh_dotdir/.zshrc" || fail 'Zsh completion did not update .zshrc.'
HOME="$completion_home" XDG_DATA_HOME="$completion_data" ZDOTDIR="$zsh_dotdir" "$utility" completion uninstall zsh >/dev/null
[ "$(grep -Fxc '# >>> brew-port completion >>>' "$zsh_dotdir/.zshrc" || true)" -eq 0 ] || fail 'Zsh completion block was not removed.'

malformed_home="$tmp_dir/malformed-completion-home"
malformed_data="$tmp_dir/malformed-completion-data"
mkdir -p "$malformed_home" "$malformed_data"
malformed_startup="$malformed_home/.bashrc"
printf '%s\n' '# before' '# <<< brew-port completion <<<' '# unrelated' '# >>> brew-port completion >>>' '# after' >"$malformed_startup"
malformed_startup_before="$(cat "$malformed_startup")"
if output="$(HOME="$malformed_home" XDG_DATA_HOME="$malformed_data" "$utility" completion install bash 2>&1)"; then fail 'Malformed completion block was accepted during installation.'; fi
contains 'Refusing to modify malformed brew-port completion block' "$output"
[ "$(cat "$malformed_startup")" = "$malformed_startup_before" ] || fail 'Malformed completion block changed during installation.'
malformed_completion="$malformed_data/bash-completion/completions/brew-port"
[ ! -e "$malformed_completion" ] || fail 'Malformed completion block installed a completion file.'
mkdir -p "$(dirname "$malformed_completion")"
cp "$repo_dir/completions/brew-port.bash" "$malformed_completion"
if output="$(HOME="$malformed_home" XDG_DATA_HOME="$malformed_data" "$utility" completion uninstall bash 2>&1)"; then fail 'Malformed completion block was accepted during removal.'; fi
contains 'Refusing to modify malformed brew-port completion block' "$output"
[ "$(cat "$malformed_startup")" = "$malformed_startup_before" ] || fail 'Malformed completion block changed during removal.'
[ -f "$malformed_completion" ] || fail 'Malformed completion block removed a completion file.'

if command -v fish >/dev/null 2>&1; then
	for completion_action in install uninstall; do
		fish_output="$(fish -c 'source "$argv[1]"; complete -C "brew-port completion $argv[2] "' "$repo_dir/completions/brew-port.fish" "$completion_action")"
		contains bash "$fish_output"
		contains fish "$fish_output"
		contains zsh "$fish_output"
	done
	fish_output="$(fish -c 'source "$argv[1]"; complete -C "brew-port audit -"' "$repo_dir/completions/brew-port.fish")"
	contains --map "$fish_output"
	contains --candidates "$fish_output"
	contains --verify-archives "$fish_output"
fi

mkdir -p "$(dirname "$bash_completion")"
printf '%s\n' '# user completion' >"$bash_completion"
if output="$(HOME="$completion_home" XDG_DATA_HOME="$completion_data" "$utility" completion install bash 2>&1)"; then fail 'Unmanaged completion was overwritten.'; fi
contains 'Refusing to replace non-brew-port completion' "$output"

shellcheck -s bash -x -P "$repo_dir/bin" "$utility" "$repo_dir"/maps/fallbacks/*.sh "$repo_dir/tests/integration.sh"
git diff --check
printf '%s\n' 'brew-port checks passed.'
