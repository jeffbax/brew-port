# Release checklist

Releases use semantic versioning. semantic-release derives the next version from conventional commit messages after the latest tag, while the release archive embeds that version in `BP_VERSION`. The repository keeps the runtime version field for installed CLI reporting; release version changes do not require a source commit.

## Start a release

1. Merge changes into `main` using the normal protected-branch pull request flow.
2. Use conventional commit types for release-worthy changes: `fix:` produces a patch release, `feat:` produces a minor release, and `BREAKING CHANGE:` produces a major release. Other commits do not create a release.
3. The **Release** workflow runs after the push to `main`. It runs the native macOS 15 and 26 matrix on ARM64 and Intel, then runs semantic-release on Ubuntu if every check passes.
4. semantic-release generates release notes, creates and pushes the version tag, then the GitHub plugin creates the GitHub Release and publishes the archive, `SHA256SUMS`, and `install.sh`.

The workflow does not create commits, update `main`, or require a release GitHub App, signing key, private key, repository variable, or bypass permission.

Release runs are serialized and never cancelled. Because semantic-release pushes the tag before publication, a failed run can leave an existing tag or draft release. Inspect the tag and release before retrying: verify that an existing tag points to the intended commit, and for an existing draft upload missing assets and publish it. If no draft exists, create the release for the existing tag and attach the configured assets. Do not overwrite a published release.

## Packaging and publication

The release job runs on Ubuntu and invokes `scripts/package-release.sh` with the semantic-release version. The script copies the repository into a staging directory, replaces `BP_VERSION` only in that staged copy, creates `brew-port-VERSION.tar.gz`, and writes the archive checksum. The source checkout remains unchanged.

The GitHub plugin creates a draft release, uploads the configured assets, and publishes the release after the uploads succeed. GitHub immutable releases are enabled: after publication, the associated tag and release assets cannot be changed, and GitHub automatically generates a release attestation.

The archive contains its own file checksums, installer, CLI modules, maps, fallbacks, completions, agent skill, README, and license. Generated archives and checksums stay in ignored `dist/` or temporary directories.

Versions with a prerelease suffix are published as prereleases when semantic-release is configured with a prerelease branch. The default `main` branch currently produces stable releases from the existing release line.

## Required repository setup

- Allow GitHub Actions to run workflows and use the workflow `GITHUB_TOKEN` with `contents: write`.
- Keep the `main` ruleset configured to require pull requests and the normal **Checks** matrix jobs. semantic-release runs only after the merge and does not need to bypass those rules.
- No npm project, `package.json`, signing app, or release secret is required. The workflow installs pinned semantic-release packages with `npx` on Node 24.

## Verify locally

Run the test suites under system Bash and current Bash:

```sh
/bin/bash tests/test.sh
/bin/bash tests/release.sh
bash tests/test.sh
bash tests/release.sh
```

For a local package using the checked-in runtime version, run:

```sh
bash scripts/package-release.sh
```

To preview the archive behavior used by semantic-release, provide an explicit version:

```sh
RELEASE_VERSION=0.2.0 RELEASE_TAG=v0.2.0 bash scripts/package-release.sh dist
```

The bootstrap command is:

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s --
```

It downloads `SHA256SUMS` and the archive from `releases/latest/download`, validates the archive name and SHA-256 checksum before installation, and forwards installer arguments such as `--prefix`. Download the files separately if you need to inspect the installer first. Installation is offline, uses no sudo, and requires only system Bash, curl, shasum, and tar.

CI also runs a real installation smoke test on disposable macOS 15/26 Intel and ARM64 runners with real MacPorts. It installs the packaged CLI, translates `tests/fixtures/smoke.Brewfile`, installs `tree` and the native `rtk` fallback, and checks repeat installation and fallback refresh. Additional package testing remains a manual gate: on native Intel and Apple Silicon machines, test MAS, worktrunk, and signal-cli/OpenJDK. Review privileged operations first and record release-specific results and known issues in the GitHub Release notes.
