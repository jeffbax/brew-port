#compdef brew-port
# brew-port completion (managed)
_brew_port() {
  local -a commands
  commands=(
    'install:install Brewfile declarations through MacPorts'
    'update:update MacPorts and managed fallbacks'
    'refresh-fallbacks:refresh managed fallbacks'
    'doctor:report prerequisites and mapping status'
    'version:print version'
    'map:manage mapping overrides'
    'completion:print or manage shell completion'
    'help:show command help'
    '--help:show help'
    '-h:show help'
    '--version:print version'
    '-V:print version'
  )
  if (( CURRENT == 2 )); then
    _describe -t commands command commands
    return
  fi
  case $words[2] in
    install)
      _arguments -S '--dry-run[do not change the machine]' '--map=[mapping file]:map file:_files' '*:Brewfile:_files'
      ;;
    update|refresh-fallbacks)
      _arguments -S '--dry-run[do not change the machine]' '--map=[mapping file]:map file:_files'
      ;;
    doctor|version)
      _arguments '--help[show help]' '-h[show help]'
      ;;
    help)
      if (( CURRENT == 3 )); then _describe -t commands command commands
      elif [[ $words[3] == map ]]; then _values 'map command' init validate explain
      elif [[ $words[3] == completion ]]; then _values 'completion command' install uninstall; fi
      ;;
    map)
      if (( CURRENT == 3 )); then
        _values 'map command' 'init[create the default user mapping]' 'validate[validate mapping files]' 'explain[explain one mapping]'
      else
        case $words[3] in
          init) _arguments '--help[show help]' '-h[show help]' ;;
          validate) _arguments '--map=[mapping file]:map file:_files' '--help[show help]' '-h[show help]' ;;
          explain) _arguments -S '--map=[mapping file]:map file:_files' '--help[show help]' '-h[show help]' '1:mapping kind:(brew cask)' '2:mapping token:' ;;
        esac
      fi
      ;;
    completion)
      if (( CURRENT == 3 )); then
        _values 'completion action' bash fish zsh 'install[install completion]' 'uninstall[remove completion]'
      elif [[ $words[3] == install || $words[3] == uninstall ]]; then
        _values 'shell' bash fish zsh
      fi
      ;;
  esac
}
_brew_port "$@"
