# macports-brewfile

`macports-brewfile` installs the CLI portion of one or more Homebrew
`Brewfile`s with MacPorts. It is a private, personal utility intended for
Intel macOS machines where MacPorts is the preferred package manager.

It treats Brewfiles as declarations, not as instructions to run Homebrew:

- unlisted `brew` declarations install same-named MacPorts ports;
- `maps/default.tsv` records aliases, intentional skips, and reviewed source
  fallbacks;
- mapped casks can install MacPorts CLI ports, while other casks are reported
  for manual installation;
- `mas` declarations are installed when the Mac App Store is signed in.

## Prerequisites

Install MacPorts at its default `/opt/local` prefix. The command asks for an
administrator password once at the start, uses that authorization only for
MacPorts operations, and refreshes it while a long run is active. It does not
extend the normal sudo timeout after the command exits. For Mac App Store
entries, sign in to the App Store first.

## Usage

```sh
bin/macports-brewfile install Brewfile.common Brewfile.common.darwin
bin/macports-brewfile install --dry-run Brewfile.common Brewfile.common.darwin
```

`--dry-run` prints the port, fallback, MAS, skip, and manual-GUI actions
without running `sudo`, `port`, `mas`, downloads, or fallback scripts.

Normal runs retain MacPorts and fallback output in the terminal. At the end,
they repeat the MacPorts package notes in one `MacPorts installation notes:`
section, labelled by the command that produced each note. This makes required
post-install setup easy to review without hiding progress during installation.

## Mapping rules

`maps/default.tsv` is tab-separated with five fields:

```text
declaration-kind  homebrew-token  action  target  note
```

`action` is `port`, `fallback`, or `skip`. Fallback targets are scripts below
`fallbacks/`; they build verified, pinned upstream source into `~/.local`.
Individual package failures and intentional skips are reported at the end so
the remaining declarations can continue.

## Updating

This utility never updates itself. Pull changes explicitly, then rerun the
same `install` command (or the chezmoi bootstrap that invokes it):

```sh
git -C ~/Developer/macports-brewfile pull
```
