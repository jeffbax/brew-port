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

Before removing Homebrew, audit the same Brewfiles and mapping overrides. By default,
this is read-only: it checks MacPorts target coverage, manual cask detection paths, and
Mac App Store IDs in batches. Resolve every blocker before removing Homebrew.

```sh
brew-port audit --map ./my-mappings.json Brewfile
```

Add `--candidates` to research name-based MacPorts suggestions for casks that
do not have an explicit `port` mapping. Suggestions are advisory: they never
create mappings or install packages. They show the packaged version, livecheck
result, and the most recent Portfile commit date. Network enrichment is bounded;
unavailable results are reported as unknown warnings.

```sh
brew-port audit --candidates --map ./my-mappings.json Brewfile
```

Candidate archive availability is unchecked by default. `--verify-archives`
uses MacPorts to download each suggested binary archive for the current host to
its cache; it does not install or activate a port, but can download large files
and requests administrator access to write the MacPorts cache. It verifies each
candidate archive, not its dependency graph.

```sh
brew-port audit --candidates --verify-archives --map ./my-mappings.json Brewfile
```

`doctor` reports brew-port prerequisites and mapping compatibility; it does not
audit Brewfile declarations or installed software. Audit is package-level only:
reviewed fallbacks are validated as migration paths, but their runtime executables
are not inferred or checked.

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
