_brew_port() {
	local cur="${COMP_WORDS[COMP_CWORD]}" commands='install update refresh-fallbacks doctor version map services completion'
	if [ "$COMP_CWORD" -eq 1 ]; then
		COMPREPLY=($(compgen -W "$commands" -- "$cur"))
		return
	fi
	case "${COMP_WORDS[1]}" in
	install | update | refresh-fallbacks) COMPREPLY=($(compgen -W '--dry-run --map --help' -- "$cur")) ;;
	map) COMPREPLY=($(compgen -W 'init validate explain' -- "$cur")) ;;
	services) COMPREPLY=($(compgen -W 'import-homebrew list start stop' -- "$cur")) ;;
	completion) COMPREPLY=($(compgen -W 'bash fish zsh install' -- "$cur")) ;;
	esac
}
complete -F _brew_port brew-port
