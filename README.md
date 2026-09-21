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

## User services

`brew-port services` is an alpha, proof-of-concept feature. Its user-service translation and lifecycle behavior are still being validated; review every definition and retain a separate recovery path. It imports a reviewed snapshot of a Homebrew/core formula's public Formulae API metadata. It never calls the `brew` CLI, `port load`, or a MacPorts-owned launchd plist. Imports only support immediate user services whose `run` command is an argument array and whose keep-alive policy is `always` or `successful_exit`.

```sh
bin/brew-port services import-homebrew [--map ./service-mappings.json] FORMULA...
bin/brew-port services list
bin/brew-port services start [--dry-run] [--map ./service-mappings.json] TOKEN...
bin/brew-port services stop [--dry-run] TOKEN...
```

Import writes a disabled, versioned snapshot to `${XDG_CONFIG_HOME:-~/.config}/brew-port/services.json`; it never starts a service. The snapshot records the Formulae API version and date, mapped MacPorts port, a MacPorts-prefix-relative executable, arguments, keep-alive policy, environment, working directory, and an empty `overrides` object. Its format is defined by [services.schema.json](maps/services.schema.json).

Only the documented `$HOMEBREW_PREFIX` and `$HOME` placeholders are translated. Homebrew's `opt/FORMULA/` executable path becomes a path below the detected MacPorts prefix; unsupported placeholders, run types, paths, and service fields are rejected. A later local override can change `executable` (still relative to the MacPorts prefix), `arguments`, `environment`, `working_directory`, `keep_alive`, `stdout_path`, or `stderr_path`.

Starting first checks for active Homebrew labels (`sh.brew.TOKEN`, `homebrew.mxcl.TOKEN`, and a metadata label when present), then installs the mapped port if necessary, verifies the translated executable, atomically validates and writes `~/Library/LaunchAgents/dev.brew-port.TOKEN.plist`, and bootstraps it in `gui/$UID`. No shell is used to execute imported commands. The default logs are `${XDG_STATE_HOME:-~/.local/state}/brew-port/services/TOKEN.log` and `TOKEN.err.log`. `stop` bootouts and removes only that `dev.brew-port.*` plist; it keeps the port and saved definition.

`services list` is read-only. It reports each imported definition in a compact section with its formula and currently mapped MacPorts port, resolved MacPorts executable (`found` or `missing`), a friendly LaunchAgent state plus raw launchd state, labeled PID and last exit code, and independent stdout/stderr status (`present`, `empty`, `missing`, or `unavailable`) with configured paths and latest non-empty lines. It does not fetch metadata, install ports, start services, or create log files.

Homebrew and MacPorts may package different versions or executable layouts. A version mismatch produces a warning; a missing translated executable blocks startup until its local `overrides.executable` is reviewed and corrected. Always inspect an import before `start`, especially arguments, environment variables, and working directory.

The bundled map currently provides reviewed port mappings for `herdr`, `atuin`, and `colima`, so no service mapping file is needed for these formulas:

```sh
bin/brew-port services import-homebrew herdr atuin colima
${PAGER:-less} "${XDG_CONFIG_HOME:-$HOME/.config}/brew-port/services.json"
bin/brew-port services start herdr atuin colima
```

The example mappings are names to review, not a claim that matching versions or paths are interchangeable. In particular, `colima`'s `start -f` creates a user-managed runtime. Import does not migrate service state or credentials. Stop the existing Homebrew service manually before starting the brew-port-owned replacement.

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

CI also runs `tests/integration.sh` on disposable macOS 15/26 Intel and ARM64 runners with real MacPorts. It installs the packaged CLI, translates `tests/fixtures/smoke.Brewfile`, installs `shfmt` from a MacPorts binary archive, and downloads the native `rtk` fallback. This test installs real system packages and requires noninteractive sudo; run it on a disposable machine. The Checks workflow can also be started manually without cutting a release.

## Releases

See [the release checklist](docs/releases.md) for versioning, testing, packaging, and publication. Release-specific test results and known issues belong in GitHub Release notes.
