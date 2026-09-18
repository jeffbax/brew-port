# macports-brewfile

`macports-brewfile` installs the CLI portion of one or more Homebrew
`Brewfile`s with MacPorts. It is a private, personal utility intended for
Intel macOS machines where MacPorts is the preferred package manager.

It treats Brewfiles as declarations, not as instructions to run Homebrew:

- unlisted `brew` declarations install same-named MacPorts ports;
- `maps/default.tsv` records aliases, intentional skips, and reviewed
  fallbacks;
- fallback tools install verified upstream Intel macOS release binaries into
  `~/.local/bin`;
- a mapping can explicitly override an otherwise-valid MacPorts port with a
  manual fallback when that port is broken;
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
bin/macports-brewfile refresh-fallbacks
bin/macports-update
bin/macports-update --dry-run
```

`--dry-run` prints the port, fallback, MAS, skip, and manual-GUI actions
without running `sudo`, `port`, `mas`, downloads, or fallback scripts.

Normal runs retain MacPorts and fallback output in the terminal. At the end,
they repeat the MacPorts package notes in one `MacPorts installation notes:`
section, labelled by the command that produced each note. This makes required
post-install setup easy to review without hiding progress during installation.

Normal `install` runs `port selfupdate` to refresh the ports tree, but does
not run `port upgrade outdated`. Use `bin/macports-update` for intentional
maintenance: it runs `selfupdate`, upgrades every outdated MacPorts port, and
then refreshes the fallback tools. It stops before fallback refreshes if either
MacPorts step fails, and does not remove inactive ports.

## Fallback releases

Each normal Intel install checks GitHub Releases for the latest `rtk` and
Worktrunk Intel macOS asset. It downloads only when that release differs from
the verified local state or its installed binary is missing; unchanged releases
do not trigger a Cargo build or a binary download.

The state file is
`${XDG_STATE_HOME:-~/.local/state}/macports-brewfile/fallbacks.tsv`. It records
the release tag, asset URL, published SHA-256 digest, and installed-binary
digest. A changed digest for an already-recorded tag is rejected. If GitHub is
temporarily unavailable, an existing verified fallback is retained with a
warning; a missing fallback is reported as unresolved.

## Mapping rules

`maps/default.tsv` is tab-separated with five fields:

```text
declaration-kind  homebrew-token  action  target  note
```

`action` is `port`, `fallback`, `fallback-root`, or `skip`. Fallback targets
are scripts below `fallbacks/`; they install verified upstream release binaries into
`~/.local/bin`.

Use `fallback-root` for a reviewed fallback that needs the active sudo lease,
such as the official MAS installer package. It overrides the normal same-named
MacPorts lookup and does not produce an extra password prompt during an
`install` or `macports-update` run.
Individual package failures and intentional skips are reported at the end so
the remaining declarations can continue.

## Updating

This utility never updates itself. Pull changes explicitly, then rerun the
same `install` command (or the chezmoi bootstrap that invokes it):

```sh
git -C ~/Developer/macports-brewfile pull
```
