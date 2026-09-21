# Development

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

The test suite enforces Bash syntax, `shfmt -d`, and ShellCheck. CI also runs `tests/integration.sh` on disposable macOS Intel and Apple Silicon runners with real MacPorts; it installs real system packages and requires noninteractive sudo.

See the [release checklist](releases.md) for versioning, packaging, publication, and release-specific manual gates.
