# Cutting a release

Automated since `.github/workflows/release.yml` (milestone D, phase D3): pushing a `vX.Y.Z` tag
builds the pkg, install-smoke-tests it on a clean `macos-15` runner, and publishes a GitHub
release. There is nothing left to do by hand beyond the version bump and the tag push. See
`docs/design/distribution.md` for the full contract (package layout, manifest shape, the unsigned
phase) this workflow implements.

## 1. Bump the version

`Sources/RunnerCore/Version.swift`'s `RunnerVMVersion.current` is the single source of truth for
every version string in the project (`runnerctl --version`, `runnerctl version`, the guest agent's
`-ldflags`-injected string, `share/runnervm/VERSION` in the pkg). Edit it, commit, land on
`master`:

```swift
public enum RunnerVMVersion {
  public static let current = "0.3.0"
}
```

```sh
git add Sources/RunnerCore/Version.swift
git commit -m "release: bump to 0.3.0"
git push origin master
```

Confirm `master` is green before tagging: `gh run list --branch master --workflow ci`.

## 2. Tag and push

```sh
git tag -a v0.3.0 -m "v0.3.0"
git push origin v0.3.0
```

The tag must be `v` + `RunnerVMVersion.current` exactly. `release.yml`'s first real step re-parses
`Version.swift` and fails the run immediately, with the exact mismatch, if the pushed tag disagrees
— it never guesses or falls back to the tag.

## 3. What `release.yml` does

Triggered by `push: tags: ['v*']`, one job on `macos-15`:

1. Selects Xcode 16.4, asserts the tag matches `Version.swift`.
2. `bash scripts/build-package.sh --version "${GITHUB_REF_NAME#v}" --out dist` — swift release
   build, Linux+macOS guest agents, ad-hoc-signed `vmworker`, staged payload root, `pkgbuild` +
   `productbuild`.
3. **Installs the pkg for real** (`sudo installer -pkg dist/RunnerVM-macos-arm64.pkg -target /`)
   and asserts: `runnerctl --version` reports the right version, the installed `vmworker` verifies
   and carries `com.apple.security.virtualization`, `vmworker probe --json` succeeds,
   `share/runnervm/VERSION` exists, and the shipped `.sha256` matches the shipped `.pkg`. A release
   that fails any of these never reaches the "create release" step.
4. `gh release create "$GITHUB_REF_NAME" dist/RunnerVM-macos-arm64.pkg
   dist/RunnerVM-macos-arm64.pkg.sha256 dist/release-manifest.json --title "RunnerVM $TAG"
   --generate-notes`.

## 4. Release assets

Every release carries three files (see `docs/design/distribution.md`, "Release artifacts and
manifest", for the exact manifest shape):

| Asset | Purpose |
| --- | --- |
| `RunnerVM-macos-arm64.pkg` | the installer: `pkgbuild` root + `productbuild --distribution`, arm64 only, macOS 15.0+ |
| `RunnerVM-macos-arm64.pkg.sha256` | detached checksum (`shasum -a 256` format) |
| `release-manifest.json` | `{version, architecture, minimumMacOS, package, sha256, signed, license}` |

`install.sh` is **not yet a release asset** — it does not exist until milestone D phase D4
(`scripts/bootstrap.sh`, published as `install.sh`). Until then, the curl one-liner in
`docs/design/distribution.md` does not resolve; installing from a tag means downloading
`RunnerVM-macos-arm64.pkg` from the release page (or `gh release download`) and running `sudo
installer -pkg RunnerVM-macos-arm64.pkg -target /` by hand.

## The pkg is unsigned

`release-manifest.json` always carries `"signed": false` unless `scripts/build-package.sh` was run
with `--installer-identity` (a Developer ID Installer certificate) — `release.yml` never passes
one, so every automated release is unsigned. `vmworker` inside the pkg is still ad-hoc signed with
the virtualization entitlement (`build-package.sh`'s default `--sign-identity -`); the pkg wrapper
around it is not. The published `.sha256` protects the download against corruption and tampering
in transit, not against an untrusted publisher — see `docs/design/distribution.md`, "Unsigned
phase", for exactly what this does and does not prove, and what a later Developer ID
signing/notarization milestone changes. `install.sh` (once it exists, phase D4) prints an explicit
unsigned-package warning and requires confirmation before installing.

## Homebrew tap (optional, secondary)

The `andrejvysny/homebrew-runnervm` tap is not wired into `release.yml` and stays a manual,
optional step for anyone who prefers `brew install` over the pkg:

1. Resolve the commit the tag points to (the tap formula pins this, not a tarball checksum):
   ```sh
   git rev-parse v0.3.0
   ```
2. In `andrejvysny/homebrew-runnervm`, edit `Formula/runnervm.rb`:
   - `tag: "v0.3.0"`
   - `revision: "<sha from step 1>"`
3. Sanity-check the formula against the new tag before pushing it:
   ```sh
   brew install --build-from-source ./Formula/runnervm.rb
   brew test runnervm
   brew audit --strict --online runnervm
   ```
4. Commit and push the tap. `brew install andrejvysny/runnervm/runnervm` (or `brew upgrade`) now
   resolves the new version for everyone who uses the tap.

## Version scheme

Semver, starting at `0.x` while `runnerd`'s wire/schema versions and the milestone list in
`TODO.md` are still moving — see `docs/status.md` for what's actually load-bearing at any given
point. Bump to `1.0.0` once the open M8/S3/S5/S7/D-milestone items in `TODO.md` are resolved or
explicitly deferred and live GitHub verification covers the supported feature surface, not before.
