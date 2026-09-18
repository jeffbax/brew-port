---
name: brew-port
description: Safely create and review brew-port JSON mapping overrides.
license: MIT
---

# brew-port mapping work

Use this skill when changing a brew-port mapping or fallback.

1. Create local overrides with `brew-port map init` or an explicit `--map` file. Preserve the package rationale in `note`.
2. Place `fallback` and `fallback-root` scripts only in that map’s `fallbacks/` directory and declare every verified native architecture. Never run an Intel fallback through Rosetta.
3. Treat `fallback-root` as privileged code. Review its URLs, checksums, destination, and every sudo command.
4. Run `brew-port map validate --map FILE`, then `brew-port install --dry-run --map FILE BREWFILE` before a real install.
5. Use `brew-port map explain KIND TOKEN` to verify precedence and retain the reason for an override.

Mappings are persistent user configuration. Do not save detected architecture, MacPorts prefix, or other host facts in them.
