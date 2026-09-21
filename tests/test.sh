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
xml_metacharacters=$'a&b\\path<>"\''
xml_escaped='a&amp;b\path&lt;&gt;&quot;&apos;'
xml_escaped_actual="$(/bin/bash -c 'source "$1"; bp_service_xml_escape "$2"' -- "$repo_dir/bin/lib/brew-port/services.bash" "$xml_metacharacters")"
[ "$xml_escaped_actual" = "$xml_escaped" ] || fail 'System Bash XML escaping changed a service value.'

mock_uname="$tmp_dir/uname"
mock_port="$tmp_dir/port"
mock_sudo="$tmp_dir/sudo"
mock_sysctl="$tmp_dir/sysctl"
mock_mas="$tmp_dir/mas"
mock_brew="$tmp_dir/brew"
mock_curl="$tmp_dir/curl"
mock_launchctl="$tmp_dir/launchctl"
mock_plutil="$tmp_dir/plutil"
sudo_log="$tmp_dir/sudo.log"
jq_log="$tmp_dir/jq.log"
mas_log="$tmp_dir/mas.log"
curl_log="$tmp_dir/curl.log"
brew_log="$tmp_dir/brew.log"
launchctl_log="$tmp_dir/launchctl.log"
active_ports="$tmp_dir/active-ports"
mas_installed="$tmp_dir/mas-installed"
: >"$active_ports"
: >"$mas_installed"
export MOCK_ACTIVE_PORTS="$active_ports"
export MOCK_MAS_INSTALLED="$mas_installed"
export MOCK_JQ_LOG="$jq_log"
cat >"$mock_uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in -s) echo Darwin ;; -m) echo "${MOCK_ARCH:?}" ;; *) exit 2 ;; esac
EOF
cat >"$mock_port" <<'EOF'
#!/usr/bin/env bash
if [ "$1 ${2:-} ${3:-}" = '-q echo active' ]; then
	cat "${MOCK_ACTIVE_PORTS:?}"
	exit 0
fi
case "$1" in
version) exit 0 ;;
install)
	echo "port $*"
	for target in "${@:2}"; do
		[ "${MOCK_PORT_FAIL_TARGET:-}" != "$target" ] || exit 1
		if [ "${MOCK_PORT_INSTALL_ACTIVE:-0}" = 1 ]; then
			printf '%s\n' "$target" >>"${MOCK_ACTIVE_PORTS:?}"
			mkdir -p "${MOCK_MACPORTS_PREFIX:?}/bin"
			printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${MOCK_MACPORTS_PREFIX:?}/bin/$target"
			chmod +x "${MOCK_MACPORTS_PREFIX:?}/bin/$target"
		fi
	done
	;;
selfupdate|select|upgrade) echo "port $*" ;;
-q)
	[ "${2:-} ${3:-}" = 'info --version' ] && { printf '%s\n' "${MOCK_PORT_VERSION:-}"; exit 0; }
	exit 2
    ;;
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
[ "${MOCK_MAS_HANG_COMMAND:-}" != "$command" ] || sleep 5
case "$command" in
list)
	for id in "$@"; do grep -Fxq -- "$id" "${MOCK_MAS_INSTALLED:?}" && printf '%s Mock App (1.0)\n' "$id"; done
	true
	;;
lookup)
	[ "${1:-}" = --json ] && shift
	for id in "$@"; do [ "${MOCK_MAS_INVALID:-}" = "$id" ] || printf '{"id":%s}\n' "$id"; done
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
cat >"$mock_brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_BREW_LOG:?}"
exit 99
EOF
cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
output_file= url=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--output)
		shift
		output_file="$1"
		;;
	*) url="$1" ;;
	esac
	shift
done
printf '%s\n' "$url" >>"${MOCK_CURL_LOG:?}"
[ "${MOCK_CURL_HTTP_FAIL:-0}" != 1 ] || exit 22
formula="${url##*/}"
formula="${formula%.json}"
cp "${MOCK_FORMULAE_DIR:?}/$formula.json" "$output_file"
EOF
cat >"$mock_launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_LAUNCHCTL_LOG:?}"
case "$1" in
print)
	case "$2" in
	gui/*/*)
		label="${2##*/}"
		[ "${MOCK_GUI_SESSION:-1}" = 1 ] || exit 1
		case "$label" in
		dev.brew-port.herdr)
			if grep -Fxq -- "$label" "${MOCK_HOMEBREW_LABELS:?}"; then
				printf '%s\n' 'state = running' 'pid = 4242' 'last exit code = 0'
				exit 0
			fi
			exit 1
			;;
		dev.brew-port.restarting-service)
			printf '%s\n' 'state = spawn scheduled' "last exit code = ${MOCK_RESTARTING_SERVICE_EXIT:-1}"
			exit 0
			;;
		dev.brew-port.colima)
			printf '%s\n' 'state = waiting' 'last exit code = 0'
			exit 0
			;;
		dev.brew-port.atuin)
			printf '%s\n' 'state = exited' 'last exit code = 1'
			exit 0
			;;
		*)
			if grep -Fxq -- "$label" "${MOCK_HOMEBREW_LABELS:?}"; then
				printf '%s\n' 'state = running' 'pid = 4242' 'last exit code = 0'
				exit 0
			fi
			exit 1
			;;
		esac
		;;
	gui/*)
		[ "${MOCK_GUI_SESSION:-1}" = 1 ]
		;;
	*) exit 2 ;;
	esac
	;;
bootstrap)
	[ "${MOCK_LAUNCHCTL_FAIL:-0}" != 1 ] || exit 1
	if [ "${MOCK_LAUNCHCTL_FAIL_ONCE:-0}" = 1 ] && [ ! -e "${MOCK_LAUNCHCTL_FAIL_ONCE_STATE:?}" ]; then
		: >"${MOCK_LAUNCHCTL_FAIL_ONCE_STATE:?}"
		exit 1
	fi
	label="${3##*/}"
	label="${label%.plist}"
	grep -Fxq -- "$label" "${MOCK_HOMEBREW_LABELS:?}" && exit 1
	printf '%s\n' "$label" >>"${MOCK_HOMEBREW_LABELS:?}"
	;;
bootout)
	[ "${MOCK_LAUNCHCTL_BOOTOUT_FAIL:-0}" != 1 ] || exit 1
	label="${3##*/}"
	label="${label%.plist}"
	grep -Fxv -- "$label" "${MOCK_HOMEBREW_LABELS:?}" >"${MOCK_HOMEBREW_LABELS:?}.next" || true
	mv "${MOCK_HOMEBREW_LABELS:?}.next" "${MOCK_HOMEBREW_LABELS:?}"
	;;
*) exit 2 ;;
esac
EOF
cat >"$mock_plutil" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -lint ] || exit 2
[ "${MOCK_PLUTIL_FAIL:-0}" != 1 ] || exit 1
grep -Fq '<plist version="1.0">' "$2"
EOF
chmod +x "$mock_brew" "$mock_curl" "$mock_launchctl" "$mock_plutil"

custom_port_bin="$tmp_dir/custom-macports/bin"
mkdir -p "$custom_port_bin"
custom_port_prefix="$(CDPATH='' cd -- "$custom_port_bin/.." && pwd -P)"
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
grep -Fqx "complete -c brew-port -n '__fish_seen_subcommand_from start stop' -l dry-run" "$repo_dir/completions/brew-port.fish" || fail 'Fish completion did not scope --dry-run to services start and stop.'
grep -Fqx "complete -c brew-port -n '__fish_seen_subcommand_from import-homebrew start' -l map -r" "$repo_dir/completions/brew-port.fish" || fail 'Fish completion did not scope --map to services import-homebrew and start.'
"$utility" map validate | grep -Fq 'Mappings are valid.'
prefix_brewfile="$tmp_dir/custom-prefix.Brewfile"
printf '%s\n' 'brew "git"' >"$prefix_brewfile"
: >"$jq_log"
MOCK_ARCH=arm64 MOCK_JQ_LOG="$jq_log" BREW_PORT_UNAME_BIN="$mock_uname" BREW_PORT_PORT_BIN="$custom_port_bin/port" BREW_PORT_SUDO_BIN="$mock_sudo" "$utility" install --dry-run "$prefix_brewfile" >/dev/null
[ -s "$jq_log" ] || fail 'The selected MacPorts prefix jq was not used.'
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
output="$("$utility" map explain brew git --map "$local_map")"
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

output="$($utility services list)"
contains 'No imported services.' "$output"

formulae_dir="$tmp_dir/formulae"
mkdir "$formulae_dir"
cat >"$formulae_dir/herdr.json" <<'EOF'
{"name":"herdr","full_name":"herdr","tap":"homebrew/core","versions":{"stable":"0.9.1"},"generated_date":"2026-09-19","service":{"run":["$HOMEBREW_PREFIX/opt/herdr/bin/herdr","server"],"run_type":"immediate","keep_alive":{"always":true},"label":"org.example.herdr","log_path":"$HOMEBREW_PREFIX/var/log/herdr.log","error_log_path":"$HOMEBREW_PREFIX/var/log/herdr.log"}}
EOF
cat >"$formulae_dir/restarting-service.json" <<'EOF'
{"name":"restarting-service","full_name":"restarting-service","tap":"homebrew/core","versions":{"stable":"1.0.0"},"generated_date":"2026-09-19","service":{"run":["$HOMEBREW_PREFIX/opt/restarting-service/bin/restarting-service"],"run_type":"immediate","keep_alive":{"successful_exit":false},"log_path":"$HOMEBREW_PREFIX/var/log/restarting-service.log","error_log_path":"$HOMEBREW_PREFIX/var/log/restarting-service.log"}}
EOF
cat >"$formulae_dir/atuin.json" <<'EOF'
{"name":"atuin","full_name":"atuin","tap":"homebrew/core","versions":{"stable":"18.22.0"},"generated_date":"2026-09-11","service":{"run":["$HOMEBREW_PREFIX/opt/atuin/bin/atuin","daemon","start"],"run_type":"immediate","keep_alive":{"always":true},"log_path":"$HOMEBREW_PREFIX/var/log/atuin.log","error_log_path":"$HOMEBREW_PREFIX/var/log/atuin.log"}}
EOF
cat >"$formulae_dir/colima.json" <<'EOF'
{"name":"colima","full_name":"colima","tap":"homebrew/core","versions":{"stable":"0.10.3"},"generated_date":"2026-09-18","service":{"run":["$HOMEBREW_PREFIX/opt/colima/bin/colima","start","-f"],"run_type":"immediate","keep_alive":{"successful_exit":true},"environment_variables":{"PATH":"$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin"},"working_dir":"/$HOME","log_path":"$HOMEBREW_PREFIX/var/log/colima.log","error_log_path":"$HOMEBREW_PREFIX/var/log/colima.log"}}
EOF
cat >"$formulae_dir/no-service.json" <<'EOF'
{"name":"no-service","full_name":"no-service","tap":"homebrew/core","versions":{"stable":"1.0"},"generated_date":"2026-09-19"}
EOF
printf '%s\n' '{not json' >"$formulae_dir/malformed.json"
cat >"$formulae_dir/unsupported.json" <<'EOF'
{"name":"unsupported","full_name":"unsupported","tap":"homebrew/core","versions":{"stable":"1.0"},"generated_date":"2026-09-19","service":{"run":["$HOMEBREW_PREFIX/opt/unsupported/bin/unsupported"],"run_type":"interval","keep_alive":{"always":true}}}
EOF
cat >"$formulae_dir/placeholder.json" <<'EOF'
{"name":"placeholder","full_name":"placeholder","tap":"homebrew/core","versions":{"stable":"1.0"},"generated_date":"2026-09-19","service":{"run":["$HOMEBREW_PREFIX/opt/placeholder/bin/placeholder","$UNSUPPORTED"],"run_type":"immediate","keep_alive":{"always":true}}}
EOF
service_map="$tmp_dir/services-map.json"
cat >"$service_map" <<'EOF'
{"version":1,"mappings":[
 {"kind":"brew","token":"herdr","action":"port","target":"herdr"},
 {"kind":"brew","token":"restarting-service","action":"port","target":"restarting-service"},
 {"kind":"brew","token":"atuin","action":"port","target":"atuin"},
 {"kind":"brew","token":"colima","action":"port","target":"colima"}
]}
EOF
homebrew_labels="$tmp_dir/homebrew-labels"
: >"$homebrew_labels"
: >"$curl_log"
: >"$brew_log"
service_import_env=(
	MOCK_ARCH=arm64
	MOCK_BREW_LOG="$brew_log"
	MOCK_CURL_LOG="$curl_log"
	MOCK_FORMULAE_DIR="$formulae_dir"
	PATH="$tmp_dir:$PATH"
	BREW_PORT_CURL_BIN="$mock_curl"
	BREW_PORT_UNAME_BIN="$mock_uname"
	BREW_PORT_PORT_BIN="$custom_port_bin/port"
	BREW_PORT_SUDO_BIN="$mock_sudo"
)
output="$(env "${service_import_env[@]}" "$utility" services import-homebrew --map "$service_map" herdr restarting-service atuin colima)"
contains 'Imported disabled service definition for herdr.' "$output"
service_file="$XDG_CONFIG_HOME/brew-port/services.json"
[ -f "$service_file" ] || fail 'Service import did not create services.json.'
"$custom_port_bin/jq" -e '
  .version == 1 and (.services | length == 4) and
  ([.services[].formula] | sort == ["atuin", "colima", "herdr", "restarting-service"]) and
  (.services[] | select(.formula == "herdr") | .executable == "bin/herdr" and .arguments == ["server"] and .keep_alive == {always: true}) and
  (.services[] | select(.formula == "restarting-service") | .keep_alive == {successful_exit: false}) and
  (.services[] | select(.formula == "atuin") | .arguments == ["daemon", "start"]) and
  (.services[] | select(.formula == "colima") |
    .environment.PATH == "'"$custom_port_prefix"'/bin:'"$custom_port_prefix"'/sbin:/usr/bin:/bin:/usr/sbin:/sbin" and
    .working_directory == "'"$HOME"'")
' "$service_file" >/dev/null || fail 'Imported service translation was incorrect.'
[ "$(wc -l <"$curl_log" | tr -d ' ')" = 4 ] || fail 'Formulae metadata was not fetched exactly once per import.'
[ ! -s "$brew_log" ] || fail 'Service import invoked the Homebrew CLI.'
if output="$(env "${service_import_env[@]}" "$utility" services import-homebrew herdr 2>&1)"; then fail 'Existing imported service was refreshed unexpectedly.'; fi
contains 'Service already imported: herdr.' "$output"
if output="$(env "${service_import_env[@]}" "$utility" services import-homebrew no-service 2>&1)"; then fail 'Formula without a service was imported.'; fi
contains 'Unsupported or malformed Homebrew service metadata for no-service.' "$output"
if output="$(env "${service_import_env[@]}" "$utility" services import-homebrew malformed 2>&1)"; then fail 'Malformed Formulae JSON was imported.'; fi
contains 'Unsupported or malformed Homebrew service metadata for malformed.' "$output"
if output="$(env MOCK_CURL_HTTP_FAIL=1 "${service_import_env[@]}" "$utility" services import-homebrew missing 2>&1)"; then fail 'Formulae HTTP failure was accepted.'; fi
contains 'Could not fetch Homebrew formula metadata for missing.' "$output"
if output="$(env "${service_import_env[@]}" "$utility" services import-homebrew unsupported 2>&1)"; then fail 'Unsupported run type was imported.'; fi
contains 'Unsupported or malformed Homebrew service metadata for unsupported.' "$output"
if output="$(env "${service_import_env[@]}" "$utility" services import-homebrew placeholder 2>&1)"; then fail 'Unsupported placeholder was imported.'; fi
contains 'Unsupported or malformed Homebrew service metadata for placeholder.' "$output"
if output="$(env "${service_import_env[@]}" "$utility" services import-homebrew homebrew/core/herdr 2>&1)"; then fail 'Tap-qualified formula was imported.'; fi
contains 'Homebrew/core formula names must be unqualified lowercase tokens' "$output"

service_start_env=(
	MOCK_ARCH=arm64
	MOCK_ACTIVE_PORTS="$active_ports"
	MOCK_MACPORTS_PREFIX="$custom_port_prefix"
	MOCK_HOMEBREW_LABELS="$homebrew_labels"
	MOCK_LAUNCHCTL_LOG="$launchctl_log"
	SUDO_LOG="$sudo_log"
	BREW_PORT_UNAME_BIN="$mock_uname"
	BREW_PORT_PORT_BIN="$custom_port_bin/port"
	BREW_PORT_SUDO_BIN="$mock_sudo"
	BREW_PORT_LAUNCHCTL_BIN="$mock_launchctl"
	BREW_PORT_PLUTIL_BIN="$mock_plutil"
)
: >"$active_ports"
: >"$sudo_log"
: >"$launchctl_log"
output="$(env MOCK_PORT_INSTALL_ACTIVE=1 MOCK_PORT_VERSION=0.9.0 "${service_start_env[@]}" "$utility" services start --map "$service_map" herdr)"
contains 'Warning: Homebrew herdr is 0.9.1; MacPorts herdr is 0.9.0.' "$output"
contains 'Started brew-port service herdr.' "$output"
herdr_plist="$HOME/Library/LaunchAgents/dev.brew-port.herdr.plist"
[ -f "$herdr_plist" ] || fail 'Service start did not write the owned LaunchAgent.'
grep -Fq "<string>$custom_port_prefix/bin/herdr</string>" "$herdr_plist" || fail 'Plist did not use the MacPorts executable.'
grep -Fq '<string>server</string>' "$herdr_plist" || fail 'Plist omitted imported arguments.'
grep -Fq '<key>RunAtLoad</key><true/>' "$herdr_plist" || fail 'Immediate service plist did not run at load.'
grep -Fq "<string>$XDG_STATE_HOME/brew-port/services/herdr.log</string>" "$herdr_plist" || fail 'Plist did not use the brew-port state log path.'
grep -Fqx -- "-n $custom_port_bin/port install herdr" "$sudo_log" || fail 'Service start did not install its mapped port.'
grep -Fqx "bootstrap gui/$UID $herdr_plist" "$launchctl_log" || fail 'Service bootstrap did not follow plist creation.'
printf '%s\n' 'herdr started' >"$XDG_STATE_HOME/brew-port/services/herdr.log"
printf '%s\n' old $'bad\033[2J\233Kfile descriptor' '' >"$XDG_STATE_HOME/brew-port/services/restarting-service.err.log"
: >"$XDG_STATE_HOME/brew-port/services/atuin.err.log"
: >"$XDG_STATE_HOME/brew-port/services/colima.log"
service_file_temporary="$tmp_dir/services-list-overrides.json"
"$custom_port_bin/jq" '
  .services |= map(if .token == "atuin" then .overrides.keep_alive = {always: false} else . end)
' "$service_file" >"$service_file_temporary"
mv "$service_file_temporary" "$service_file"
cat >"$XDG_CONFIG_HOME/brew-port/mappings.json" <<'EOF'
{"version":1,"mappings":[
 {"kind":"brew","token":"restarting-service","action":"port","target":"alternate-restarting-service"}
]}
EOF
tail_mock_dir="$tmp_dir/tail-mock"
tail_log="$tmp_dir/tail.log"
tail_bin="$(command -v tail)"
mkdir "$tail_mock_dir"
cat >"$tail_mock_dir/tail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_TAIL_LOG:?}"
exec "${MOCK_TAIL_BIN:?}" "$@"
EOF
chmod +x "$tail_mock_dir/tail"
list_files_before="$(find "$XDG_STATE_HOME" -type f | LC_ALL=C sort)"
curl_count_before="$(wc -l <"$curl_log" | tr -d ' ')"
sudo_log_before="$(cat "$sudo_log")"
: >"$launchctl_log"
: >"$jq_log"
list_output="$(env PATH="$tail_mock_dir:$tmp_dir/bash-runtime:/usr/bin:/bin" MOCK_TAIL_LOG="$tail_log" MOCK_TAIL_BIN="$tail_bin" "${service_start_env[@]}" "$utility" services list)"
[ -s "$jq_log" ] || fail 'Service list did not use the selected MacPorts prefix jq.'
not_contains 'TOKEN  FORMULA  PORT  CLI  STATE  PID  EXIT  LOG  LAST' "$list_output"
contains 'herdr: running' "$list_output"
contains "executable: found $custom_port_prefix/bin/herdr" "$list_output"
contains 'pid: 4242' "$list_output"
contains 'last exit: 0' "$list_output"
contains 'herdr started' "$list_output"
contains 'restarting-service: restarting' "$list_output"
contains 'port: alternate-restarting-service' "$list_output"
contains "executable: missing $custom_port_prefix/bin/restarting-service" "$list_output"
contains 'pid: none' "$list_output"
contains 'last exit: 1' "$list_output"
contains 'launchd: "spawn scheduled"' "$list_output"
contains 'stderr: present' "$list_output"
contains 'last line: bad?[2J?Kfile descriptor' "$list_output"
not_contains $'\033' "$list_output"
not_contains $'\233' "$list_output"
contains "stdout: missing — path: $XDG_STATE_HOME/brew-port/services/restarting-service.log" "$list_output"
contains 'atuin: stopped' "$list_output"
contains 'stderr: empty' "$list_output"
contains 'colima: restarting' "$list_output"
contains 'stdout: empty' "$list_output"
grep -Fqx -- "-n 100 $XDG_STATE_HOME/brew-port/services/restarting-service.err.log" "$tail_log" || fail 'Service list did not bound log inspection.'
list_files_after="$(find "$XDG_STATE_HOME" -type f | LC_ALL=C sort)"
[ "$list_files_before" = "$list_files_after" ] || fail 'Service list created or removed a persistent file.'
[ "$curl_count_before" = "$(wc -l <"$curl_log" | tr -d ' ')" ] || fail 'Service list fetched metadata.'
[ "$sudo_log_before" = "$(cat "$sudo_log")" ] || fail 'Service list invoked a privileged MacPorts action.'
not_contains 'bootstrap' "$(cat "$launchctl_log")"
not_contains 'bootout' "$(cat "$launchctl_log")"
[ ! -e "$XDG_STATE_HOME/brew-port/services/restarting-service.log" ] || fail 'Service list created a missing stdout log.'

list_output="$(env PATH="$tmp_dir/bash-runtime:/usr/bin:/bin" MOCK_RESTARTING_SERVICE_EXIT=0 "${service_start_env[@]}" "$utility" services list)"
contains 'restarting-service: stopped' "$list_output"

unavailable_awk_dir="$tmp_dir/unavailable-awk"
mkdir -p "$unavailable_awk_dir"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$unavailable_awk_dir/awk"
chmod +x "$unavailable_awk_dir/awk"
list_output="$(env PATH="$unavailable_awk_dir:$tmp_dir/bash-runtime:/usr/bin:/bin" "${service_start_env[@]}" "$utility" services list)"
contains "stderr: unavailable — path: $XDG_STATE_HOME/brew-port/services/restarting-service.err.log" "$list_output"

list_output="$(env MOCK_GUI_SESSION=0 "${service_start_env[@]}" "$utility" services list)"
contains 'herdr: no GUI session' "$list_output"
contains 'launchd: "no GUI session"' "$list_output"

: >"$launchctl_log"
list_output="$(env "${service_start_env[@]}" BREW_PORT_LAUNCHCTL_BIN="$tmp_dir/missing-launchctl" "$utility" services list)"
contains 'herdr: launchctl unavailable' "$list_output"
contains 'pid: unknown' "$list_output"
[ ! -s "$launchctl_log" ] || fail 'Service list queried launchctl after it was unavailable.'

service_file_temporary="$tmp_dir/services-herdr-update.json"
"$custom_port_bin/jq" '
  .services |= map(if .token == "herdr" then .overrides.arguments = ["server", "--updated"] else . end)
' "$service_file" >"$service_file_temporary"
mv "$service_file_temporary" "$service_file"
: >"$launchctl_log"
output="$(env "${service_start_env[@]}" "$utility" services start --map "$service_map" herdr)"
contains 'Started brew-port service herdr.' "$output"
grep -Fqx "bootout gui/$UID $herdr_plist" "$launchctl_log" || fail 'Repeated service start did not boot out the prior job.'
grep -Fqx "bootstrap gui/$UID $herdr_plist" "$launchctl_log" || fail 'Repeated service start did not bootstrap the replacement job.'
grep -Fq '<string>--updated</string>' "$herdr_plist" || fail 'Reloaded service plist did not use the updated configuration.'

"$custom_port_bin/jq" '
  .services |= map(if .token == "herdr" then .overrides.arguments = ["server", "--not-loaded"] else . end)
' "$service_file" >"$service_file_temporary"
mv "$service_file_temporary" "$service_file"

: >"$launchctl_log"
if output="$(env MOCK_PLUTIL_FAIL=1 "${service_start_env[@]}" "$utility" services start --map "$service_map" herdr 2>&1)"; then fail 'Invalid replacement plist was accepted.'; fi
contains "Generated plist is invalid: $herdr_plist" "$output"
not_contains 'bootout' "$(cat "$launchctl_log")"
grep -Fq '<string>--updated</string>' "$herdr_plist" || fail 'Invalid replacement plist replaced the active plist.'
grep -Fxq dev.brew-port.herdr "$homebrew_labels" || fail 'Invalid replacement plist unloaded the active service.'

: >"$launchctl_log"
launchctl_fail_once="$tmp_dir/launchctl-fail-once"
if output="$(env MOCK_LAUNCHCTL_FAIL_ONCE=1 MOCK_LAUNCHCTL_FAIL_ONCE_STATE="$launchctl_fail_once" "${service_start_env[@]}" "$utility" services start --map "$service_map" herdr 2>&1)"; then fail 'Replacement bootstrap failure was accepted.'; fi
contains 'Could not bootstrap brew-port service herdr. The prior configuration was restored.' "$output"
grep -Fq '<string>--updated</string>' "$herdr_plist" || fail 'Bootstrap failure did not restore the prior plist.'
not_contains '<string>--not-loaded</string>' "$(cat "$herdr_plist")"
grep -Fxq dev.brew-port.herdr "$homebrew_labels" || fail 'Bootstrap failure did not restore the prior service.'

if output="$(env MOCK_LAUNCHCTL_BOOTOUT_FAIL=1 "${service_start_env[@]}" "$utility" services start --map "$service_map" herdr 2>&1)"; then fail 'Repeated service start accepted a failed reload.'; fi
contains "Could not reload brew-port service herdr. The existing job and plist remain in place at $herdr_plist." "$output"
grep -Fq '<string>--updated</string>' "$herdr_plist" || fail 'Failed service reload replaced its active plist.'
not_contains '<string>--not-loaded</string>' "$(cat "$herdr_plist")"

: >"$active_ports"
: >"$sudo_log"
: >"$launchctl_log"
colima_plist="$HOME/Library/LaunchAgents/dev.brew-port.colima.plist"
output="$(env "${service_start_env[@]}" "$utility" services start --dry-run --map "$service_map" colima)"
contains 'Would install MacPorts port colima (for service colima)' "$output"
contains 'Would write and bootstrap' "$output"
[ ! -e "$colima_plist" ] || fail 'Dry-run wrote a service plist.'
[ ! -s "$sudo_log" ] || fail 'Dry-run service start used sudo.'
not_contains 'bootstrap' "$(cat "$launchctl_log")"

printf '%s\n' sh.brew.atuin >"$homebrew_labels"
if output="$(env "${service_start_env[@]}" "$utility" services start --dry-run --map "$service_map" atuin 2>&1)"; then fail 'Active Homebrew service was not rejected.'; fi
contains 'Homebrew service sh.brew.atuin is active.' "$output"
printf '%s\n' homebrew.mxcl.atuin >"$homebrew_labels"
if output="$(env "${service_start_env[@]}" "$utility" services start --dry-run --map "$service_map" atuin 2>&1)"; then fail 'Legacy Homebrew service label was not rejected.'; fi
contains 'Homebrew service homebrew.mxcl.atuin is active.' "$output"
printf '%s\n' org.example.herdr >"$homebrew_labels"
if output="$(env "${service_start_env[@]}" "$utility" services start --dry-run --map "$service_map" herdr 2>&1)"; then fail 'Explicit Homebrew service label was not rejected.'; fi
contains 'Homebrew service org.example.herdr is active.' "$output"
: >"$homebrew_labels"

override_working_directory="$tmp_dir/service-working-directory"
mkdir "$override_working_directory"
mkdir -p "$custom_port_prefix/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$custom_port_prefix/bin/atuin-local"
chmod +x "$custom_port_prefix/bin/atuin-local"
service_file_temporary="$tmp_dir/services-with-overrides.json"
"$custom_port_bin/jq" --arg workdir "$override_working_directory" --arg xml_environment "$xml_metacharacters" '
  .services |= map(if .token == "atuin" then .overrides = {
    executable: "bin/atuin-local",
    arguments: ["daemon", "start", "--verbose"],
    keep_alive: {successful_exit: false},
    environment: {ATUIN_LOG: $xml_environment},
    working_directory: $workdir,
    stdout_path: "/tmp/atuin-out.log",
    stderr_path: "/tmp/atuin-err.log"
  } else . end)
' "$service_file" >"$service_file_temporary"
mv "$service_file_temporary" "$service_file"
printf '%s\n' atuin >"$active_ports"
atuin_plist="$HOME/Library/LaunchAgents/dev.brew-port.atuin.plist"
env "${service_start_env[@]}" "$utility" services start --map "$service_map" atuin >/dev/null
grep -Fq "<string>$custom_port_prefix/bin/atuin-local</string>" "$atuin_plist" || fail 'Executable override was ignored.'
grep -Fq '<string>--verbose</string>' "$atuin_plist" || fail 'Argument override was ignored.'
grep -Fq "<key>ATUIN_LOG</key><string>$xml_escaped</string>" "$atuin_plist" || fail 'Environment override was not preserved and XML escaped.'
grep -Fq "<string>$override_working_directory</string>" "$atuin_plist" || fail 'Working-directory override was ignored.'
grep -Fq '<key>SuccessfulExit</key><false/>' "$atuin_plist" || fail 'Keep-alive override was ignored.'
grep -Fq '<string>/tmp/atuin-out.log</string>' "$atuin_plist" || fail 'Log-path override was ignored.'

printf '%s\n' colima >"$active_ports"
mkdir -p "$custom_port_prefix/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$custom_port_prefix/bin/colima"
chmod +x "$custom_port_prefix/bin/colima"
printf '%s\n' 'old plist must survive invalid validation' >"$colima_plist"
if output="$(env MOCK_PLUTIL_FAIL=1 "${service_start_env[@]}" "$utility" services start --map "$service_map" colima 2>&1)"; then fail 'Invalid plist was accepted.'; fi
contains "Generated plist is invalid: $colima_plist" "$output"
grep -Fqx 'old plist must survive invalid validation' "$colima_plist" || fail 'Invalid plist replaced an existing plist.'

homebrew_plist="$HOME/Library/LaunchAgents/homebrew.mxcl.herdr.plist"
printf '%s\n' 'Homebrew-owned plist' >"$homebrew_plist"
: >"$launchctl_log"
env "${service_start_env[@]}" "$utility" services stop herdr >/dev/null
[ ! -e "$herdr_plist" ] || fail 'Service stop did not remove the owned plist.'
[ -f "$homebrew_plist" ] || fail 'Service stop touched a Homebrew-owned plist.'
"$custom_port_bin/jq" -e '.services[] | select(.token == "herdr")' "$service_file" >/dev/null || fail 'Service stop removed its saved definition.'
grep -Fqx "bootout gui/$UID $herdr_plist" "$launchctl_log" || fail 'Service stop did not boot out the owned plist.'

printf '%s\n' 'loaded plist must survive failed bootout' >"$herdr_plist"
printf '%s\n' dev.brew-port.herdr >"$homebrew_labels"
if output="$(env MOCK_LAUNCHCTL_BOOTOUT_FAIL=1 "${service_start_env[@]}" "$utility" services stop herdr 2>&1)"; then fail 'Loaded service was accepted after bootout failed.'; fi
contains "Could not boot out brew-port service herdr. The plist remains at $herdr_plist." "$output"
[ -f "$herdr_plist" ] || fail 'Failed bootout removed the loaded service plist.'

: >"$homebrew_labels"
env MOCK_LAUNCHCTL_BOOTOUT_FAIL=1 "${service_start_env[@]}" "$utility" services stop herdr >/dev/null
[ ! -e "$herdr_plist" ] || fail 'Unloaded service plist was not removed after failed bootout.'

printf '%s\n' 'dry-run plist' >"$herdr_plist"
env "${service_start_env[@]}" "$utility" services stop --dry-run herdr >/dev/null
[ -f "$herdr_plist" ] || fail 'Dry-run service stop removed a plist.'

printf '%s\n' '{"version":1,"services":[{"token":"bad"}]}' >"$service_file"
if output="$(env "${service_start_env[@]}" "$utility" services stop --dry-run herdr 2>&1)"; then fail 'Malformed service definitions were accepted.'; fi
contains "Invalid service definition file: $service_file" "$output"

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

shellcheck -s bash -x -P "$repo_dir/bin" "$utility" "$repo_dir"/maps/fallbacks/*.sh "$repo_dir/tests/integration.sh"
git diff --check
printf '%s\n' 'brew-port checks passed.'
