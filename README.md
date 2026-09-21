# brew-port

`brew-port` translates Homebrew Brewfile declarations into MacPorts actions on macOS. It never installs Homebrew or chooses a package manager.

## Install

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s --
```

Install MacPorts first, add the chosen installation prefix's `bin` directory to `PATH`, then check the local prerequisites:

```sh
brew-port doctor
```

## Use

Preview a Brewfile before making changes, then install it:

```sh
brew-port install Brewfile --dry-run
brew-port install Brewfile
```

Update MacPorts packages and refresh previously requested fallbacks:

```sh
brew-port update
```

Use `brew-port help`, `brew-port help map`, or `brew-port help map explain` for command-specific help.

## More documentation

- [Installation, verification, and rollback](https://github.com/jeffbax/brew-port/blob/main/docs/installation.md)
- [Mappings and reviewed fallbacks](https://github.com/jeffbax/brew-port/blob/main/docs/mappings.md)
- [Shell completion](https://github.com/jeffbax/brew-port/blob/main/docs/completions.md)
- [Development](https://github.com/jeffbax/brew-port/blob/main/docs/development.md)
- [Release checklist](https://github.com/jeffbax/brew-port/blob/main/docs/releases.md)
