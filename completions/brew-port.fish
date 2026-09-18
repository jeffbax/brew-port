complete -c brew-port -f -n '__fish_use_subcommand' -a 'install update refresh-fallbacks doctor version map completion'
complete -c brew-port -n '__fish_seen_subcommand_from install update refresh-fallbacks' -l dry-run
complete -c brew-port -n '__fish_seen_subcommand_from install update refresh-fallbacks' -l map -r
complete -c brew-port -n '__fish_seen_subcommand_from map' -a 'init validate explain'
complete -c brew-port -n '__fish_seen_subcommand_from completion' -a 'bash fish zsh install'
