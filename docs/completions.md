# Shell completion

Print a completion script for a shell:

```sh
brew-port completion bash
```

Install completion for the current shell, or name `bash`, `fish`, or `zsh` explicitly:

```sh
brew-port completion install
brew-port completion install zsh
```

Fish loads its completion file automatically. Bash installation writes owned source blocks to `~/.bashrc` and the first login startup file Bash will read (`~/.bash_profile`, `~/.bash_login`, or `~/.profile`; it creates `~/.bash_profile` when none exists). Zsh installation writes an owned `fpath` and `compinit` block to `${ZDOTDIR:-$HOME}/.zshrc`. Restart the shell after installation because brew-port cannot change its parent shell session.

The installed completions cover the command tree, map subcommands, applicable options, mapping files, and Brewfile paths. They do not fetch network data.

Remove completion with:

```sh
brew-port completion uninstall
```

Uninstall removes only files and startup blocks marked as owned by brew-port. Files written by older brew-port releases are recognized and migrated on install or removed on uninstall. Installation and removal refuse to replace or delete an unrelated completion file.
