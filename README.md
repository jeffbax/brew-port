# brew-port

`brew-port` reads CLI declarations from Homebrew Brewfiles and applies matching MacPorts actions. It is a macOS/MacPorts tool: it never installs Homebrew or chooses a package manager.

It reads `uname -m` on every invocation. Native `x86_64` and `arm64` are equally supported when MacPorts and the requested package are available. A fallback runs only when its map declares support for the live native architecture. Intel-only fallbacks are unresolved on Apple Silicon: brew-port never invokes Rosetta or silently substitutes a different port.

## Install

Install the latest published stable release directly:

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s --
```

The bootstrap downloads the latest release manifest and archive, verifies the archive's SHA-256 checksum, extracts it, and runs the packaged offline installer. `latest` means the latest published stable release; prereleases are excluded. The default prefix is `~/.local`; pass installer arguments after `--`:

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s -- --prefix "$HOME/.local"
```

To download and inspect before executing, choose a release version and verify its archive:

```sh
version='X.Y.Z' # Replace with the release version, without the leading v.
mkdir brew-port-download
cd brew-port-download
curl -fsSLO "https://github.com/jeffbax/brew-port/releases/download/v$version/brew-port-$version.tar.gz"
curl -fsSLO https://github.com/jeffbax/brew-port/releases/download/v$version/SHA256SUMS
shasum -a 256 -c SHA256SUMS
tar -xzf "brew-port-$version.tar.gz"
less "brew-port-$version/install.sh"
bash "brew-port-$version/install.sh" --prefix '/path/to/prefix'
```

Installation is offline after the archive is downloaded, uses no sudo, and requires no MacPorts or jq. It does not edit shell configuration. Add the prefix's `bin` directory to PATH yourself if necessary. GitHub CLI release and asset attestation verification is stronger than checksums alone when available.

The complete runtime lives in `PREFIX/lib/brew-port/versions/VERSION`, with a `current` symlink and an executable symlink in `PREFIX/bin`. Installing a new pinned release switches `current` and retains older versions. Reinstalling the original verified archive rolls back to that version. An existing version with modified contents or an unrelated executable is never overwritten. User mappings and managed-fallback inventory remain outside the installation.

`brew-port update` updates MacPorts packages and managed fallbacks; upgrade the CLI by installing another release archive. Optional completions are installed separately with `brew-port completion install SHELL`.

## Use

Install MacPorts for the current macOS release first. brew-port searches `/opt/local/bin/port` first, then `port` on `PATH`; set `BREW_PORT_PORT_BIN=/path/to/port` for a non-default prefix. Host facts are detected, never persisted.

JSON work needs `/opt/local/bin/jq` or `/usr/bin/jq`. If it is missing, `install`, `update`, and `refresh-fallbacks` selfupdate MacPorts and install its `jq` port under the existing sudo lease. `doctor` and `map` remain non-mutating and explain the prerequisite.

```sh
bin/brew-port install Brewfile
bin/brew-port install --dry-run --map ./my-mappings.json Brewfile
bin/brew-port update
bin/brew-port refresh-fallbacks
bin/brew-port doctor
bin/brew-port map validate --map ./my-mappings.json
bin/brew-port map explain brew rtk
```

`install` parses and deduplicates all Brewfiles first, scans active ports once, and installs missing direct ports in one batch. Reviewed fallbacks remain package-specific. The final reconciliation summary separates already-present, installed, manual, warning, and failed items. `--dry-run` makes no downloads, package installs, sudo calls, or writes. `update` additionally runs `port upgrade outdated`.

## JSON mappings

Maps layer as bundled `maps/default.json`, `${XDG_CONFIG_HOME:-~/.config}/brew-port/mappings.json`, then repeated `--map FILE` arguments from left to right. Later entries with the same `kind` and `token` replace earlier ones. The independently authored [schema](maps/mappings.schema.json) defines the format. `brew-port map init` creates a user file and its adjacent `fallbacks/` directory.

Actions are `port`, `skip`, `fallback`, `fallback-root`, and cask-only `manual`. A `manual` mapping declares literal absolute or `~/` detection paths; an existing path satisfies the cask, otherwise it appears in manual follow-up. Fallback script targets must remain below the mapping file’s `fallbacks/` directory. `fallback-root` is explicitly user-trusted code that may reuse the active sudo lease; review every URL, checksum, destination, and privileged command.

Mac App Store declarations are scanned, validated, and installed in batches. Explicitly invalid IDs and completed installation failures fail reconciliation. A hung or timed-out MAS operation is reported as a warning so the caller can continue; brew-port does not retry IDs one by one. MAS operations default to a 30-second timeout, configurable with `BREW_PORT_MAS_TIMEOUT`.

Fallback maps declare their verified architectures and bundled installers choose matching release assets. MAS uses its matching arm64 or x86_64 package. signal-cli uses its official bundle (which contains matching macOS libsignal slices) and installs MacPorts OpenJDK 25 under the active sudo lease.

## Completions

```sh
bin/brew-port completion fish
bin/brew-port completion install fish
```

Static Bash, Fish, and Zsh completions are included. Installation writes only the selected user completion file and never edits shell startup files.

## Development

Install `shfmt` (for example, `sudo port install shfmt`), then run:

```sh
shfmt -ln bash -w bin/brew-port bin/lib/brew-port/*.bash maps/fallbacks/*.sh completions/brew-port.bash tests/test.sh
shfmt -ln bash -w install.sh scripts/*.sh tests/bump-version.sh tests/release-version.sh tests/release.sh
shfmt -ln bash -w tests/integration.sh
tests/bump-version.sh
tests/release-version.sh
tests/test.sh
bash tests/release.sh
```

The test suite enforces `shfmt -d`, Bash syntax checks, and ShellCheck.

CI also runs `tests/integration.sh` on disposable macOS 15/26 Intel and ARM64 runners with real MacPorts. It installs the packaged CLI, translates `tests/fixtures/smoke.Brewfile`, installs `tree` and the native `rtk` fallback, and checks repeat installation and fallback refresh. This test installs real system packages and requires noninteractive sudo; run it on a disposable machine. The Checks workflow can also be started manually without cutting a release.

## Releases

See [the release checklist](docs/releases.md) for versioning, testing, packaging, and publication. Release-specific test results and known issues belong in GitHub Release notes.
