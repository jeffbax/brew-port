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

The [mapping schema](../maps/mappings.schema.json) defines the supported JSON format. Actions are `port`, `mise`, `skip`, `fallback`, `fallback-root`, and cask-only `manual`.

`manual` uses literal absolute or `~/` detection paths. Fallback scripts must stay below the mapping file's adjacent `fallbacks/` directory and declare every verified native architecture. brew-port does not invoke Intel fallbacks through Rosetta or substitute a different port on Apple Silicon.

Treat `fallback-root` as user-trusted privileged code: review its URLs, checksums, destination, and every sudo command before running it. Managed fallbacks can be refreshed with `brew-port refresh-fallbacks`; use `--dry-run` to preview package actions without writes, downloads, package installs, or sudo calls.

Mac App Store declarations are processed in batches. Invalid IDs and completed failures fail reconciliation; a timed-out MAS batch is reported as a warning so remaining declarations can complete. Configure its timeout with `BREW_PORT_MAS_TIMEOUT`.

## Mise-managed CLI tools

Use `mise` for a Brewfile CLI declaration that should be installed through mise instead of MacPorts. For example, save this override and pass it with `--map`:

```json
{
  "version": 1,
  "mappings": [
    {
      "kind": "brew",
      "token": "ripgrep",
      "action": "mise",
      "target": "ripgrep",
      "note": "Manage this CLI globally through mise."
    }
  ]
}
```

`target` is a mise registry name or backend-qualified tool identifier, such as `github:owner/repo` or `npm:@scope/package`. Version suffixes, tool options, whitespace, and command flags are not supported in mappings; configure version constraints in mise's global configuration instead.

`brew-port install` preserves existing global version requests and installs any missing requested versions. Newly configured tools use `latest`. Install mise yourself through MacPorts or the [official installer](https://mise.jdx.dev/installing-mise.html). When mise is required but unavailable, real install/update runs halt before package reconciliation with installation and retry instructions; dry-run prints the instructions and continues. `BREW_PORT_MISE_BIN` overrides discovery; otherwise brew-port checks beside the selected `port` executable before searching PATH. Mise tool installation runs as your user, without sudo.

`brew-port update` upgrades only effective mapped targets already configured globally, respecting their version constraints. It does not add unconfigured targets or upgrade unrelated mise tools. Global upgrades require a mise version supporting `upgrade --global`; older versions produce an actionable failure. Project configuration is excluded from brew-port's mise commands. `refresh-fallbacks` remains limited to recorded fallbacks.

Installation can finish without mise shell activation: brew-port invokes mise by its discovered path and uses `mise exec` for a mise-mapped `mas` client. To run tools directly in your terminal, use [mise shell setup](https://mise.jdx.dev/shell-setup.html). When neither the activation marker nor the default/configured data directory's shims appear in the environment, installation and `doctor` print shell-specific activation guidance. Startup files are not edited, and brew-port cannot change its parent shell's PATH. This check is advisory; it cannot verify that activation is saved for future terminals.

Switching a mapping does not remove an existing MacPorts or fallback installation. Review PATH precedence if an older binary still runs. Bundled mappings retain their current actions.
