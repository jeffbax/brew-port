# brew-port completion (managed)
_brew_port_append_files() {
	local candidate
	while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -f -- "$1")
}

_brew_port() {
	local cur prev command subcommand positional index
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"
	command="${COMP_WORDS[1]:-}"
	if [ "$COMP_CWORD" -eq 1 ]; then
		COMPREPLY=($(compgen -W 'install update refresh-fallbacks doctor version map completion help --help -h --version -V' -- "$cur"))
		return
	fi
	case "$command" in
	install)
		if [ "$prev" = --map ]; then
			COMPREPLY=()
			_brew_port_append_files "$cur"
		else
			COMPREPLY=($(compgen -W '--dry-run --map --help -h' -- "$cur"))
			case "$cur" in
			-*) ;;
			*) _brew_port_append_files "$cur" ;;
			esac
		fi
		;;
	update | refresh-fallbacks) COMPREPLY=($(compgen -W '--dry-run --map --help -h' -- "$cur")) ;;
	doctor | version) COMPREPLY=($(compgen -W '--help -h' -- "$cur")) ;;
	help)
		if [ "$COMP_CWORD" -eq 2 ]; then
			COMPREPLY=($(compgen -W 'install update refresh-fallbacks doctor version map completion' -- "$cur"))
		elif [ "${COMP_WORDS[2]:-}" = map ]; then
			COMPREPLY=($(compgen -W 'init validate explain' -- "$cur"))
		elif [ "${COMP_WORDS[2]:-}" = completion ]; then COMPREPLY=($(compgen -W 'install uninstall' -- "$cur")); fi
		;;
	map)
		if [ "$COMP_CWORD" -eq 2 ]; then
			COMPREPLY=($(compgen -W 'init validate explain --help -h' -- "$cur"))
			return
		fi
		subcommand="${COMP_WORDS[2]:-}"
		case "$subcommand" in
		validate)
			if [ "$prev" = --map ]; then
				COMPREPLY=()
				_brew_port_append_files "$cur"
			else
				COMPREPLY=($(compgen -W '--map --help -h' -- "$cur"))
			fi
			;;
		explain)
			if [ "$prev" = --map ]; then
				COMPREPLY=()
				_brew_port_append_files "$cur"
				return
			fi
			positional=0
			for ((index = 3; index < COMP_CWORD; index++)); do
				case "${COMP_WORDS[index]}" in --map) index=$((index + 1)) ;; --*) ;; *) positional=$((positional + 1)) ;; esac
			done
			if [ "$positional" -eq 0 ]; then COMPREPLY=($(compgen -W 'brew cask --map --help -h' -- "$cur")); else COMPREPLY=($(compgen -W '--map --help -h' -- "$cur")); fi
			;;
		init) COMPREPLY=($(compgen -W '--help -h' -- "$cur")) ;;
		esac
		;;
	completion)
		if [ "$COMP_CWORD" -eq 2 ]; then
			COMPREPLY=($(compgen -W 'bash fish zsh install uninstall --help -h' -- "$cur"))
		elif [ "${COMP_WORDS[2]:-}" = install ] || [ "${COMP_WORDS[2]:-}" = uninstall ]; then COMPREPLY=($(compgen -W 'bash fish zsh --help -h' -- "$cur")); fi
		;;
	esac
}
complete -F _brew_port brew-port
