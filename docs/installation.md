# Installation

brew-port runs on macOS with MacPorts. Install MacPorts for the current macOS release before using brew-port; brew-port searches `/opt/local/bin/port` first, then `port` on `PATH`. Set `BREW_PORT_PORT_BIN` for a non-default MacPorts prefix.

## Stable release

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s --
```

The installer defaults to `~/.local`; pass installer arguments after `--` to use another prefix:

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s -- --prefix "$HOME/.local"
```

Add the selected prefix's `bin` directory to `PATH`, then run `brew-port doctor`.

The bootstrap downloads a release archive and `SHA256SUMS`, validates the archive before installing, and needs no sudo, MacPorts, or jq. The installed runtime is versioned below `PREFIX/lib/brew-port`; reinstalling a verified older archive switches back to that version without replacing unrelated executables.

## Inspect a release first

Download a pinned release if you prefer to inspect the installer before running it:

```sh
version='X.Y.Z'
mkdir brew-port-download && cd brew-port-download
curl -fsSLO "https://github.com/jeffbax/brew-port/releases/download/v$version/brew-port-$version.tar.gz"
curl -fsSLO https://github.com/jeffbax/brew-port/releases/download/v$version/SHA256SUMS
shasum -a 256 -c SHA256SUMS
tar -xzf "brew-port-$version.tar.gz"
less "brew-port-$version/install.sh"
bash "brew-port-$version/install.sh" --prefix '/path/to/prefix'
```

This repository uses GitHub immutable releases: after publication, the associated tag and release assets cannot be changed, and GitHub automatically generates a release attestation. See [GitHub's release verification documentation](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity) to verify releases and local assets.

## Runtime prerequisites and updates

`install`, `update`, and `refresh-fallbacks` require jq to read mappings. When jq is absent, package-changing commands selfupdate MacPorts and install its jq port under the same sudo lease. `doctor` and `map` remain non-mutating and report the missing prerequisite.

`brew-port update` selfupdates MacPorts, upgrades outdated ports, and refreshes managed fallbacks. It does not upgrade the brew-port CLI; install another verified release archive to do that.
