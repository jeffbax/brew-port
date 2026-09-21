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
