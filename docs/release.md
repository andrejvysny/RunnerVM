# Cutting a release

Automated since `.github/workflows/release.yml` (milestone D, phase D3): pushing a `vX.Y.Z` tag
builds the pkg, install-smoke-tests it on a clean `macos-15` runner, and publishes a GitHub
release. There is nothing left to do by hand beyond the version bump and the tag push. See
`docs/design/distribution.md` for the full contract (package layout, manifest shape, signing and
notarization) this workflow implements.

Signing material is a **one-time** operator setup; it is not part of cutting a release. If the
eight repository secrets/variables below are not in place yet, do "One-time signing setup" first —
`release.yml` fails closed when any of them is empty, and an unsigned pkg is never published.

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

Confirm `master` is green before tagging: `gh run list --branch master --workflow ci`. The release
must be cut from a green master. `v0.2.0` was not: it was tagged from `d742a1c`, whose Swift CI job
was red (cooperative-pool thread starvation), fixed only afterwards by `fad78a0` on `master`. Check
`gh run list --branch master --workflow ci` before every tag — do not assume the tip commit passed.

## 2. Tag and push

```sh
git tag -a v0.3.0 -m "v0.3.0"
git push origin v0.3.0
```

The tag must be `v` + `RunnerVMVersion.current` exactly. `release.yml`'s first real step re-parses
`Version.swift` and fails the run immediately, with the exact mismatch, if the pushed tag disagrees
— it never guesses or falls back to the tag.

## 3. What `release.yml` does

Triggered by `push: tags: ['v*']`, one job on `macos-15`, `timeout-minutes: 90` (notarization is a
network round-trip to Apple), `concurrency: release-${{ github.ref }}` with no cancellation — a
half-published release is worse than a slow one:

1. **Fails closed on missing signing material.** The first step after checkout aborts the run if
   any of `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`/`_PASSWORD`,
   `APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64`/`_PASSWORD`, `APPLE_NOTARY_KEY_P8_BASE64`,
   `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` (repository **secrets**) or `APPLE_TEAM_ID`
   (repository **variable**) is empty, and if `RunnerVMSigning.expectedTeamID` in
   `Sources/RunnerCore/Signing.swift` is nil/empty or disagrees with `APPLE_TEAM_ID` — that
   constant is what every install checks the pkg's leaf team against, so a mismatch would make the
   release uninstallable. An unsigned pkg is never published as a release.
2. Selects Xcode 16.4, asserts the tag matches `Version.swift`.
3. Imports both p12s into a **temporary keychain** in `$RUNNER_TEMP` (random password, no
   auto-lock, prepended to the user search list; p12 files deleted right after import), derives the
   two identities — Application via `security find-identity -v -p codesigning`, Installer via
   `security find-identity -v` *without* `-p codesigning` (installer EKU) — asserts both carry
   `(APPLE_TEAM_ID)`, and stages the notary `.p8` at mode `600`.
4. `bash scripts/build-package.sh --version "${GITHUB_REF_NAME#v}" --out dist --keychain …
   --sign-identity … --installer-identity … --notarize-key … --notarize-key-id …
   --notarize-issuer … --notarize-timeout 30m` — swift release build, Linux+macOS guest agents,
   hardened-runtime Developer ID signing of all four Mach-O files, `productbuild --sign`,
   `notarytool submit --wait`, `stapler staple`, then checksum + manifest.
5. **Verifies the artifact it is about to publish**: `pkgutil --check-signature` shows
   `Developer ID Installer: … (TEAM)` and `Notarization: … trusted`, `xcrun stapler validate`
   passes, `spctl --assess --type install -vv` reports `source=Notarized Developer ID`,
   `release-manifest.json` has `signed: true`, `notarized: true`, `teamId: <TEAM>`, and the
   shipped `.sha256` matches the shipped `.pkg`.
6. **Installs the pkg for real** (`sudo installer -pkg dist/RunnerVM-macos-arm64.pkg -target /`)
   and asserts: `runnerctl --version` reports the right version; each of `runnerctl`, `runnerd`,
   `vmworker` and `share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent` passes
   `codesign --verify --strict`, satisfies the requirement
   `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>"`, and carries the `runtime`
   flag, a `Timestamp=`, `TeamIdentifier=<TEAM>` and no `get-task-allow`; the installed `vmworker`
   carries `com.apple.security.virtualization` and `vmworker probe --json` succeeds; the darwin
   guest agent runs (`-version`); `share/runnervm/VERSION` exists. A release that fails any of
   these never reaches the "create release" step. (`vmworker probe` proves the hardened runtime
   did not break startup — not that the full VM lifecycle works under it; that evidence comes from
   hardware validation.)
7. Copies `scripts/bootstrap.sh` to `dist/install.sh` and runs it end-to-end against the local
   `dist/` **without** `RUNNERVM_ALLOW_UNSIGNED` — the real signature/notarization gate against a
   real notarized pkg.
8. `gh release create "$GITHUB_REF_NAME" dist/RunnerVM-macos-arm64.pkg
   dist/RunnerVM-macos-arm64.pkg.sha256 dist/release-manifest.json dist/install.sh --title
   "RunnerVM $TAG" --generate-notes`, plus `--prerelease` when the tag contains a `-` (so
   `v0.3.0-rc.1` never becomes `releases/latest`).
9. `if: always()` cleanup: `security delete-keychain`, `rm -f` the notary `.p8` and any p12s.

## 4. Release assets

Every release carries three files (see `docs/design/distribution.md`, "Release artifacts and
manifest", for the exact manifest shape):

| Asset | Purpose |
| --- | --- |
| `RunnerVM-macos-arm64.pkg` | the installer: `pkgbuild` root + `productbuild --distribution`, arm64 only, macOS 15.0+ |
| `RunnerVM-macos-arm64.pkg.sha256` | detached checksum (`shasum -a 256` format) |
| `release-manifest.json` | `{version, architecture, minimumMacOS, package, sha256, signed, teamId, notarized, license}` |

`install.sh` **is** a release asset: `release.yml`'s "Stage install.sh" step copies
`scripts/bootstrap.sh` to `dist/install.sh` byte-for-byte before `gh release create`, so the curl
one-liner in `docs/design/distribution.md` resolves against every tag from `v0.2.0` onward.

## One-time signing setup

Done once, by the **Account Holder** of the Apple Developer Program — only that role can create
Developer ID certificates. Everything below is operator work outside this repository; nothing in a
normal release touches it. `docs/design/distribution.md`, "Signing and notarization", says what the
resulting material is used for.

### 1. Create the two certificates

Two are needed and they are not interchangeable: **Developer ID Application** signs the four Mach-O
files inside the pkg, **Developer ID Installer** signs the pkg itself.

1. Make a certificate signing request: Keychain Access → *Certificate Assistant* → *Request a
   Certificate From a Certificate Authority…* → your Apple ID email, any common name, **Saved to
   disk** (not "Emailed to the CA"), *Let me specify key pair information* → 2048-bit RSA. This
   writes a `.certSigningRequest` and puts the private key in your login keychain — that key is the
   thing that matters; a certificate without it is useless.
2. At <https://developer.apple.com/account/resources/certificates> → **+** → *Developer ID
   Application* → upload the CSR → download the `.cer`.
3. Repeat for *Developer ID Installer* (the same CSR can be reused).
4. Double-click both `.cer` files to import them into the **login** keychain, next to the private
   key.

A team may hold only a small number of active Developer ID certificates, so do not create spares.

### 2. Export both as `.p12`

Keychain Access → *My Certificates* → select the certificate row (it must disclose a private key
underneath) → *File* → *Export Items…* → **Personal Information Exchange (.p12)** → set a strong
password. Do this for each certificate, then base64 them for GitHub Actions:

```sh
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy   # -> APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64
base64 -i DeveloperIDInstaller.p12   | tr -d '\n' | pbcopy   # -> APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64
```

`tr -d '\n'` matters: a secret with embedded newlines fails `base64 --decode` in the workflow with
a decoding error that looks nothing like the actual problem.

### 3. Create the notarization API key

App Store Connect → *Users and Access* → *Integrations* → *App Store Connect API* → the **Team
Keys** tab (not *Individual Keys*) → **+** → role **Developer**. Developer is sufficient to submit
for notarization; Admin is not needed and should not be granted.

Download the `AuthKey_<KEYID>.p8` — **it can be downloaded exactly once**. Note the *Key ID* on the
key's row and the *Issuer ID* printed above the key list (a UUID, shared by all keys in the team).

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy        # -> APPLE_NOTARY_KEY_P8_BASE64
```

### 4. Add the eight repository secrets/variables

Seven **secrets** and one **variable** (`gh secret set NAME`, `gh variable set NAME`, or the
repository settings UI). `release.yml`'s first step fails the run if any of them is empty.

| Name | Kind | Value |
| --- | --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | secret | base64 of the Application `.p12` |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | secret | its export password |
| `APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64` | secret | base64 of the Installer `.p12` |
| `APPLE_DEVELOPER_ID_INSTALLER_P12_PASSWORD` | secret | its export password |
| `APPLE_NOTARY_KEY_P8_BASE64` | secret | base64 of the `.p8` |
| `APPLE_NOTARY_KEY_ID` | secret | the Key ID (10 chars) |
| `APPLE_NOTARY_ISSUER_ID` | secret | the Issuer ID (UUID) |
| `APPLE_TEAM_ID` | **variable** | the 10-character Team ID |

The Team ID is a public value (it is in every signature), which is why it is a variable: the
workflow asserts both identities and the compiled-in expected team agree with it, and a wrong value
must be visible in the log rather than masked as `***`.

### 4b. Pin the Team ID in both installers

The publisher check is compiled into the two installers, not read from the manifest (the manifest
is attacker-editable in the same way the checksum is). Set the same 10-character Team ID in both
places and commit them together; `release.yml` refuses to run while either is empty or differs
from `APPLE_TEAM_ID`:

| Where | What |
| --- | --- |
| `Sources/RunnerCore/Signing.swift` | `RunnerVMSigning.expectedTeamID = "ABCDE12345"` (used by `runnerctl upgrade`, incl. the rollback gate) |
| `scripts/bootstrap.sh` | `RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"` (the curl `install.sh` asset) |

Until both are set the installers accept any Developer ID Installer signature and say so in their
output ("publisher team not pinned"); notarization alone carries the decision.

### 5. Dry-run locally before trusting CI

On the machine that holds the keychain, with the exact identity strings `security` reports:

```sh
security find-identity -v -p codesigning     # the Developer ID Application identity
security find-identity -v                    # the Developer ID Installer identity (no -p!)

bash scripts/build-package.sh --out /tmp/rvm-signed \
  --sign-identity "Developer ID Application: Your Name (ABCDE12345)" \
  --installer-identity "Developer ID Installer: Your Name (ABCDE12345)" \
  --notarize-key ~/AuthKey_XXXXXXXXXX.p8 \
  --notarize-key-id XXXXXXXXXX \
  --notarize-issuer 00000000-0000-0000-0000-000000000000
```

The Installer identity is invisible to `find-identity -p codesigning` — that flag filters on the
code-signing EKU, which an installer certificate does not have. Looking for it there and concluding
the certificate did not import is the classic wasted afternoon.

Expect roughly: a swift release build, then a few minutes inside `notarytool submit --wait`. When
it finishes, keep the verification output — `pkgutil --check-signature` and
`spctl --assess --type install -vv`, both before and after stapling — as fixtures for the parsers
that read them; they are the only source of Apple's exact wording.

Finally, confirm what the build recorded:

```sh
jq '{signed, notarized, teamId}' /tmp/rvm-signed/release-manifest.json
```

### 6. Renewal — and why you must never revoke

Developer ID certificates expire after five years. Every signature this project makes carries an
Apple **timestamp**, which proves the signature was made while the certificate was valid, so
already-published releases keep verifying after expiry. Renewal is therefore routine: create the
new certificate, export it, replace the two `_P12_BASE64`/`_PASSWORD` secrets. Nothing needs
rebuilding.

**Never revoke a Developer ID certificate.** Revocation is retroactive: it invalidates every
signature ever made with it, including releases people already installed and every artifact that is
still downloadable. Revoke only if the private key is actually compromised, and treat it as an
incident that requires re-releasing everything still in use. The same applies in reverse to the
notary key — rotating it is harmless, because a stapled ticket does not depend on the key that
requested it.

## Installing a release candidate

A tag containing `-` is published with `--prerelease`, so `releases/latest` never resolves to it and
the plain one-liner keeps pointing at the last stable release. Install an rc by naming the tag
twice — once in the URL the script is fetched from, once for the assets it then downloads:

```sh
curl -fsSL https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0-rc.1/install.sh \
  | sudo RUNNERVM_VERSION=v0.3.0-rc.1 bash
```

`RUNNERVM_VERSION` must carry the leading `v` (it is the tag, not the version string). A signed,
notarized rc installs with no prompt and no `RUNNERVM_ALLOW_UNSIGNED`.

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
