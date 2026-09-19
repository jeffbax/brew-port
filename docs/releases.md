# Release checklist

Releases use semver (`vMAJOR.MINOR.PATCH`, optionally with `-IDENTIFIER.NUMBER`) and must match `BP_VERSION` in the CLI. One source/runtime archive supports both native Intel and Apple Silicon.

## Start a release

1. Merge the intended changes into the default branch.
2. Open the **Release** workflow and choose `patch`, `minor`, `major`, or `prerelease` from the **Run workflow** dropdown.
3. The workflow computes the next version with `scripts/bump-version.sh`, changes only the `BP_VERSION` assignment, commits it as `github-actions[bot]` with `[skip ci]`, and pushes that commit to the default branch.
4. The exact commit SHA then runs the full native matrix on macOS 15 and 26, ARM64 and Intel. Each runner executes the version helper checks, the general tests, the packaged-release tests, and the real Brewfile integration test under system Bash 3.2 and current MacPorts Bash.

The version bump commit remains on the default branch if checks fail. Fix the issue, then run the same dropdown choice again. A rerun recognizes the existing computed bump and reuses its version instead of creating another bump commit. Release runs are serialized and are never cancelled.

The CI workflow uses a branch-aware concurrency key. A newer push cancels older checks for the same branch; pull requests use the head repository and head branch so forks do not collide.

## Packaging and publication

After the matrix passes, the workflow creates or reuses a draft release targeted at the exact checked commit, then uploads:

- `brew-port-VERSION.tar.gz`, with the packaged runtime and offline installer;
- `SHA256SUMS`, covering the archive; and
- `install.sh`, the dual-mode bootstrap/offline installer.

Existing draft assets are replaced with `--clobber`, which makes recovery from an upload failure retry-safe. The draft is published automatically only after all assets upload successfully. Versions with a prerelease suffix are marked as prereleases, so GitHub's `latest` download excludes them. A published release is never overwritten.

The archive contains its own file checksums, installer, CLI modules, maps, fallbacks, completions, agent skill, README, and license. Generated archives and checksums stay in ignored `dist/` or temporary directories.

## Verify locally

Run the direct helper checks and both test suites under system Bash and current Bash:

```sh
/bin/bash tests/bump-version.sh
/bin/bash tests/test.sh
/bin/bash tests/release.sh
```

The installation suite exercises bootstrap downloads with a fake curl, malformed manifests, download failures, checksum failures, argument forwarding, offline installation, repeat installation, upgrade, and rollback. It also enforces Bash syntax, ShellCheck, and shfmt for the helper and installers.

For a local package, run `bash scripts/package-release.sh`. The output directory contains the archive and its outer `SHA256SUMS`; verify them before extraction. The release workflow performs the same packaging after checking out its exact prepare SHA.

The bootstrap command is:

```sh
curl -fsSL https://github.com/jeffbax/brew-port/releases/latest/download/install.sh \
  | bash -s --
```

It downloads `SHA256SUMS` and the archive from `releases/latest/download`, validates the archive name and SHA-256 checksum before installation, and forwards installer arguments such as `--prefix`. Download the files separately if you need to inspect the installer first. Installation is offline, uses no sudo, and requires only system Bash, curl, shasum, and tar.

CI also runs a real installation smoke test on disposable macOS 15/26 Intel and ARM64 runners with real MacPorts. It installs the packaged CLI, translates `tests/fixtures/smoke.Brewfile`, installs `tree` and the native `rtk` fallback, and checks repeat installation and fallback refresh. Additional package testing remains a manual gate: on native Intel and Apple Silicon machines, test MAS, worktrunk, and signal-cli/OpenJDK. Review privileged operations first and record release-specific results and known issues in the GitHub Release notes.
