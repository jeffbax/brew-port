# Mappings and fallbacks

brew-port reads bundled mappings first, then `${XDG_CONFIG_HOME:-~/.config}/brew-port/mappings.json`, then each `--map FILE` in command-line order. Later entries with the same `kind` and `token` replace earlier entries.

Create a user override file with:

```sh
brew-port map init
```

Check it before use and inspect the effective result when needed:

```sh
brew-port map validate --map ./my-mappings.json
brew-port map explain --map ./my-mappings.json brew rtk
```

Options may appear before or after positional arguments. Use `--` to treat all later values as positional arguments.

The [mapping schema](../maps/mappings.schema.json) defines the supported JSON format. Actions are `port`, `skip`, `fallback`, `fallback-root`, and cask-only `manual`.

`manual` uses literal absolute or `~/` detection paths. Fallback scripts must stay below the mapping file's adjacent `fallbacks/` directory and declare every verified native architecture. brew-port does not invoke Intel fallbacks through Rosetta or substitute a different port on Apple Silicon.

Treat `fallback-root` as user-trusted privileged code: review its URLs, checksums, destination, and every sudo command before running it. Managed fallbacks can be refreshed with `brew-port refresh-fallbacks`; use `--dry-run` to preview package actions without writes, downloads, package installs, or sudo calls.

Mac App Store declarations are processed in batches. Invalid IDs and completed failures fail reconciliation; a timed-out MAS batch is reported as a warning so remaining declarations can complete. Configure its timeout with `BREW_PORT_MAS_TIMEOUT`.

## Migration audit

Use the same Brewfiles and mapping overrides before removing Homebrew:

```sh
brew-port audit --map ./my-mappings.json Brewfile
```

By default, audit makes no package changes, package downloads, sudo calls, fallback
executions, or MAS installs. It scans the local MacPorts catalog and active ports once, checks manual
cask detection paths, and validates declared MAS IDs with one bounded `mas list`
and `mas lookup --json` batch. Missing or unavailable MacPorts targets, unmapped or
undetected casks, invalid or missing MAS apps, and unsupported declarations are
blockers. MAS timeouts and service failures are warnings so callers can continue.

Audit blocks bare percent forms after whitespace-separated identifiers, such as
`counter %(...)` or `puts %(...)`, because they can be modulo expressions or
literal arguments depending on Ruby's local-variable scope. Use explicit literal
forms such as `%q(...)` or `%w[...]` for literal arguments.
Executable `#{...}` interpolation in double-quoted strings and interpolating
percent literals is also a blocker. Escaped interpolation and non-interpolating
literal forms remain literal text.

Audit validates package coverage rather than individual commands or `PATH` order.
A compatible fallback is reported as a migration path, not proof that its runtime
executable is installed.

Use `--candidates` to inspect up to three advisory, name-based MacPorts matches
for every cask without an explicit `port` mapping. brew-port reports the packaged
version, livecheck result, and latest Portfile commit date. These results never
write a mapping; create a reviewed override with `map init` and retain its `note`
before adopting a candidate. Network lookups have a bounded total budget; unknown
metadata is reported as a warning.

```sh
brew-port audit --candidates --map ./my-mappings.json Brewfile
```

Candidates describe the MacPorts host running the command. To check whether a
candidate archive actually exists for that host, add `--verify-archives`. This
uses `port -b archivefetch`, which downloads the candidate archive to the
MacPorts cache without installing or activating it. It can download large files
and requests administrator access to write that cache; it does not verify dependency
archives.

Mac App Store availability is best-effort. If the local `mas` client, App Store
network, or DNS lookup fails, audit reports the command's concise error as a
warning and leaves affected IDs unknown rather than marking them invalid.
