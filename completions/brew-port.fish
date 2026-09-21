# brew-port completion (managed)
complete -c brew-port -f

function __fish_brew_port_command
    set -l words (commandline -opc)
    test (count $words) -ge 2; and test "$words[2]" = "$argv[1]"
end

function __fish_brew_port_map_subcommand
    set -l words (commandline -opc)
    test (count $words) -eq 2; and test "$words[2]" = map
end

function __fish_brew_port_completion_action
    set -l words (commandline -opc)
    test (count $words) -eq 2; and test "$words[2]" = completion
end

function __fish_brew_port_completion_shell
    set -l words (commandline -opc)
    test (count $words) -eq 3; and test "$words[2]" = completion; and contains -- "$words[3]" install uninstall
end

function __fish_brew_port_help_topic
    set -l words (commandline -opc)
    test (count $words) -eq 3; and test "$words[2]" = help; and test "$words[3]" = "$argv[1]"
end

function __fish_brew_port_help
    set -l words (commandline -opc)
    test (count $words) -eq 2; and test "$words[2]" = help
end

complete -c brew-port -f -n '__fish_use_subcommand' -a 'install' -d 'Install Brewfile declarations through MacPorts'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'update' -d 'Update MacPorts and managed fallbacks'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'refresh-fallbacks' -d 'Refresh managed fallbacks'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'doctor' -d 'Report prerequisites and mapping status'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'version' -d 'Print the version'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'map' -d 'Manage mapping overrides'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'completion' -d 'Print or manage shell completion'
complete -c brew-port -f -n '__fish_use_subcommand' -a 'help' -d 'Show command help'
complete -c brew-port -s h -l help -d 'Show help'
complete -c brew-port -l version -d 'Print the version'

complete -c brew-port -n '__fish_brew_port_command install' -l dry-run -d 'Do not change the machine'
complete -c brew-port -n '__fish_brew_port_command install' -l map -r -F -d 'Mapping file'
complete -c brew-port -n '__fish_brew_port_command install' -F
complete -c brew-port -n '__fish_brew_port_command update' -l dry-run -d 'Do not change the machine'
complete -c brew-port -n '__fish_brew_port_command update' -l map -r -F -d 'Mapping file'
complete -c brew-port -n '__fish_brew_port_command refresh-fallbacks' -l dry-run -d 'Do not change the machine'
complete -c brew-port -n '__fish_brew_port_command refresh-fallbacks' -l map -r -F -d 'Mapping file'

complete -c brew-port -n '__fish_brew_port_map_subcommand' -a 'init' -d 'Create the default user mapping'
complete -c brew-port -n '__fish_brew_port_map_subcommand' -a 'validate' -d 'Validate mapping files'
complete -c brew-port -n '__fish_brew_port_map_subcommand' -a 'explain' -d 'Explain one mapping'
complete -c brew-port -n '__fish_brew_port_command map' -l map -r -F -d 'Mapping file'

complete -c brew-port -n '__fish_brew_port_help' -a 'install' -d 'Install Brewfile declarations'
complete -c brew-port -n '__fish_brew_port_help' -a 'update' -d 'Update MacPorts'
complete -c brew-port -n '__fish_brew_port_help' -a 'refresh-fallbacks' -d 'Refresh managed fallbacks'
complete -c brew-port -n '__fish_brew_port_help' -a 'doctor' -d 'Report prerequisites'
complete -c brew-port -n '__fish_brew_port_help' -a 'version' -d 'Print the version'
complete -c brew-port -n '__fish_brew_port_help' -a 'map' -d 'Manage mapping overrides'
complete -c brew-port -n '__fish_brew_port_help' -a 'completion' -d 'Manage shell completion'
complete -c brew-port -n '__fish_brew_port_help_topic map' -a 'init' -d 'Create the default user mapping'
complete -c brew-port -n '__fish_brew_port_help_topic map' -a 'validate' -d 'Validate mapping files'
complete -c brew-port -n '__fish_brew_port_help_topic map' -a 'explain' -d 'Explain one mapping'
complete -c brew-port -n '__fish_brew_port_help_topic completion' -a 'install' -d 'Install completion'
complete -c brew-port -n '__fish_brew_port_help_topic completion' -a 'uninstall' -d 'Remove completion'

complete -c brew-port -n '__fish_brew_port_completion_action' -a 'bash' -d 'Bash completion'
complete -c brew-port -n '__fish_brew_port_completion_action' -a 'fish' -d 'Fish completion'
complete -c brew-port -n '__fish_brew_port_completion_action' -a 'zsh' -d 'Zsh completion'
complete -c brew-port -n '__fish_brew_port_completion_action' -a 'install' -d 'Install completion'
complete -c brew-port -n '__fish_brew_port_completion_action' -a 'uninstall' -d 'Remove completion'
complete -c brew-port -n '__fish_brew_port_completion_shell' -f
complete -c brew-port -n '__fish_brew_port_completion_shell' -a 'bash' -d 'Bash completion'
complete -c brew-port -n '__fish_brew_port_completion_shell' -a 'fish' -d 'Fish completion'
complete -c brew-port -n '__fish_brew_port_completion_shell' -a 'zsh' -d 'Zsh completion'
