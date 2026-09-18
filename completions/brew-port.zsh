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
