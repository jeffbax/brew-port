# Release checklist

Tags use semver (`vMAJOR.MINOR.PATCH`, optionally with a prerelease suffix) and must match `BP_VERSION` in the CLI. One source/runtime archive supports both native Intel and Apple Silicon.

## Prepare and package

1. Set the CLI version and review the changes on a clean checkout.
2. Run `/bin/bash tests/test.sh` and `/bin/bash tests/release.sh`, then both suites with current Bash. The installation suite packages into a temporary directory and installs outside the checkout.
3. Run `RELEASE_TAG=vVERSION bash scripts/package-release.sh`, replacing `VERSION` with the CLI version. This creates `dist/brew-port-VERSION.tar.gz` and `dist/SHA256SUMS`. The archive contains its own file checksums, installer, CLI modules, maps, fallbacks, completions, agent skill, README, and license. Generated archives and checksums stay in ignored `dist/` or temporary directories.
4. Commit and push the reviewed changes, then push the matching tag. CI and the draft-release workflow run both suites under system Bash 3.2 and current Bash on macOS 15 and 26, using native ARM64 (`macos-15`, `macos-26`) and Intel (`macos-15-intel`, `macos-26-intel`) runners. All four combinations must pass before the release job uploads the explicitly packaged archive and checksums. It fails on an existing release rather than silently replacing assets.

## Verify and publish

Enable repository release immutability before publishing. Upload all assets while the release is a draft; published assets and their tag are locked, and GitHub generates a release attestation. See [GitHub's immutable-release guidance](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

Download the draft assets with an authenticated repository account and verify SHA-256 checksums before extraction. Inspect the installer and install into a temporary prefix. Check `version`, `doctor`, mapping validation, dry-run translation, completion installation, upgrade, and rollback. Release attestation verification becomes available after publication.

CI runs a real installation smoke test on all four platforms: the packaged CLI installs the MacPorts `tree` port and native `rtk` fallback, verifies both executable architectures, and checks repeated installation and fallback refresh. Additional package testing remains a manual gate: on native Intel and Apple Silicon machines, test MAS, worktrunk, and signal-cli/OpenJDK. Review privileged operations first. Record commands, environment, results, and known limitations in the release notes.

Keep the release as a draft until these checks pass. The workflow marks versions with a prerelease suffix as prereleases. Publish manually, then verify the published release and archive using `gh release verify` and `gh release verify-asset`. Store release-specific results and known issues in the GitHub Release notes, rather than adding temporary test reports to the repository.
