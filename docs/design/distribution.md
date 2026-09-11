# Design: distribution & deployment (milestone D)

Status: **contract only** (phase D0) — nothing in this document changes runtime behavior. It fixes
what every later D-phase (D1–D10, see `TODO.md` "D — Distribution hardening") is built against, so
implementation does not quietly drift from what was decided. Plan: `~/.claude/plans/act-as-senior-swift-federated-willow.md`.

## Goal

Today, installing RunnerVM needs a source checkout, Swift, Go, hand-written YAML, hand-run
`launchctl`, and a root-free user layout. This milestone replaces all of that with:

```sh
curl -fsSL https://github.com/andrejvysny/RunnerVM/releases/latest/download/install.sh | sudo bash
```

on a fresh Apple Silicon Mac reachable only over SSH. The script answers a short wizard (headless
or interactive, org or repo scope, PAT, Linux on/off, macOS on/off) and leaves a working runner
host: a headless LaunchDaemon running as `_runnervm`, the GitHub PAT in an owner-only file, a
public Linux image pulled from GHCR with automatic updates, a macOS image provisioned locally from
the Cirrus Tart base with build→qualify→promote updates, a per-VM empty CI keychain, manual-only
`runnerctl upgrade`, reboot recovery, and no GUI login, Xcode, Swift, Go, or Homebrew required on
the host.

## Decisions (locked)

Confirmed during planning, 2026-08-28:

| Topic | Decision |
| --- | --- |
| macOS provisioning | Native, no Tart binary on the host: boot the read-only `image pull --format tart` import as a provisioning VM under `vmworker`, find its IP from `/var/db/dhcpd_leases` by instance MAC (`bootpd` writes unpadded octets behind a `1,` hardware type, so both sides are normalized), drive `scripts/provision-macos-tart.sh --attach` from the host, wait for the guest to halt *itself*, seal through the builder's `ImageSealing`. |
| Operator access | `runnerd` accepts uid 0 in addition to its own uid; socket stays 0600. Operators use `sudo runnerctl …`. |
| License | `LICENSE` = Apache-2.0 for RunnerVM code; `NOTICE`/`PROVENANCE.md` keep FSL attribution for Tart-derived files, unchanged. |
| Release process | Commits land per phase on `master`. Pushing, tagging `v0.2.0`, creating the GitHub release, and the first GHCR publish are operator actions, done with the operator's own `write:packages` PAT. |
| Version source of truth | `Sources/RunnerCore/Version.swift` (`RunnerVMVersion.current = "0.2.0"`); the release workflow fails if the git tag differs; the guest agent gets the same string via `-ldflags`; the pkg ships `share/runnervm/VERSION`. |
| Config keys | New nested `images.updates` and `images.managed` blocks; the existing top-level `imageUpdates` (`recycleReusable`, `denyTooOldRunner`) stays for wire compatibility and is documented as legacy. |
| Doctor | New `DoctorCheck.Status.skip`; service-mode detection (`daemon`/`agent`/`foreground`) drives the login-keychain check instead of always failing under a LaunchDaemon. |
| Maintenance VMs | `instances.purpose` (`runner`/`maintenance`) + `pinned_until`, schema v4. |
| Managed/tracked images | One table, `managed_images` (schema v4), covers both Linux registry-tag tracks and macOS managed sources. |
| macOS provisioning runs | Recorded as `image_builds` rows (`kind = 'macosProvision'`, schema v4) so build recovery, admission, `build list/log/cancel`, drain, and operation rows are reused rather than duplicated. |
| Smoke test | One client-side implementation (`Sources/HostSetup/SmokeTest.swift`) over existing RPCs, reused by `runnerctl system smoke-test`, `doctor --deep`, `setup`, and Linux/macOS candidate qualification. |
| Superseded images | `images.updates.keepPrevious` (default 1) is the explicit deletion gate: digests beyond it are deleted by the updater only when `image.prune` eligibility allows it. |
| Tart source not runnable | `ImagePullPurpose.provisioningBase` is the only pull purpose that admits an agentless macOS tart import; `instance`/`buildBase` purposes keep refusing one. |

## Package layout

The pkg installs **immutable files only** — no PAT, no YAML config, no state mutation, no VMs, no
image disks. Everything mutable (config, database, PAT, images) is created later by `runnerctl
setup`, under the service account, outside the package receipt.

```
/usr/local/bin/runnerctl
/usr/local/libexec/runnervm/runnerd
/usr/local/libexec/runnervm/vmworker
/usr/local/share/runnervm/VERSION
/usr/local/share/runnervm/Resources/            # vmworker.entitlements, hardware-model plists, ...
/usr/local/share/runnervm/recipes/              # shipped Runnerfile recipes (ubuntu-24, ...)
/usr/local/share/runnervm/guest-agent/linux-arm64/
/usr/local/share/runnervm/guest-agent/darwin-arm64/
/usr/local/share/runnervm/launchd/              # plist templates, rendered by HostSetup at setup time
/usr/local/share/runnervm/scripts/              # provisioning/qualification scripts the daemon shells out to
/usr/local/share/runnervm/notices/              # LICENSE, NOTICE, PROVENANCE.md copies
```

What the pkg must **not** do:

- write a GitHub PAT or any credential;
- write `config.yaml` or any operator-editable state;
- create, seed, or migrate the SQLite database;
- create, boot, or touch a VM;
- create or download an image disk;
- create the `_runnervm` account (that is `runnerctl setup`'s job, via `dscl`, from `HostSetup/ServiceAccountManager.swift`).

`postinstall` does exactly one thing: verify what was just installed. Every shipped Mach-O
(`runnerd`, `runnerctl`, `vmworker`, the darwin guest agent) must pass `codesign --verify --strict`;
on a signed release it must additionally satisfy a publisher requirement pinned to our team and
carry the hardened runtime; `vmworker` must carry `com.apple.security.virtualization`. It never
signs or re-signs anything — signing happens once, at build time, off the target host. See
"Signing and notarization" for the team-id templating that decides which of those checks run.

## Release artifacts and manifest

Each GitHub release (`gh release create "$TAG" dist/*`) carries:

| File | Purpose |
| --- | --- |
| `RunnerVM-macos-arm64.pkg` | the installer, `pkgbuild` root + `productbuild --distribution`, arm64 only, `allowed-os-versions` 15.0 |
| `RunnerVM-macos-arm64.pkg.sha256` | detached checksum, one line, verified by `install.sh` before `installer -pkg` runs |
| `release-manifest.json` | machine-readable pointer `install.sh`/`runnerctl upgrade` fetch first |
| `install.sh` | the bootstrap script itself, also published as the `install.sh` release asset so the curl one-liner resolves it via `/releases/latest/download/install.sh` |

`release-manifest.json` shape:

```json
{
  "version": "0.2.0",
  "architecture": "arm64",
  "minimumMacOS": "15.0",
  "package": "RunnerVM-macos-arm64.pkg",
  "sha256": "…64 hex chars…",
  "signed": false,
  "teamId": "",
  "notarized": false,
  "license": "Apache-2.0"
}
```

The key set is **constant**: `teamId` is `""` and `notarized` is `false` on an unsigned build
rather than absent, so every consumer parses one shape. `signed` means a Developer ID Installer
signature is present on the pkg (`pkgutil --check-signature` says so — not "the build was asked to
sign"), `teamId` is the Apple Team ID read back out of the shipped `vmworker`'s own signature, and
`notarized` means a notarization ticket was stapled and `stapler validate` accepted it. The
manifest is a *description* of the artifact, never the reference an installer trusts: the install
side checks the pkg itself and compares the leaf team against a compiled-in constant.

`install.sh` and `runnerctl upgrade` both read this file to decide download URLs, and both abort
before touching the host if `architecture`/`minimumMacOS` do not match, or if the fetched
`.sha256` does not match the fetched pkg.

`package` must match `^[A-Za-z0-9._-]+\.pkg$` — a plain filename, never a path: no `/`, no leading
`-` (which a shell could parse as a flag), and it must end in `.pkg`. `install.sh` (`verify_pkg_name`),
`scripts/build-package.sh` (`assert_pkg_name_valid`, checked before the manifest is written) and the
Swift `ReleaseManifest` decoder all enforce this constraint independently.

## Service account

| Attribute | Value |
| --- | --- |
| Name | `_runnervm` |
| Visibility | hidden (`IsHidden = 1`) |
| Privilege | non-admin, never added to `admin` or `staff` |
| uid / gid | first free id in the 200–400 range (the `install.sh` convention already in use) |
| Primary group | `_runnervm` — a dedicated group created alongside the user, **never** `staff` |
| Shell | `/usr/bin/false` |
| Password | `*` (no password, no interactive login) |
| Home | `<state-dir>/home`; in production that is `/Library/Application Support/RunnerVM/home` |
| Creation | `dscl` only — `dscl . -create`, `-createprop`/`-append` for `GeneratedUID`, group membership, `UserShell`, `NFSHomeDirectory`, `IsHidden`, `Password *`. No `sysadminctl`, no interactive password prompt, idempotent (re-running `setup` on an already-provisioned account verifies rather than recreates). |

This replaces the interactive `sysadminctl` step the first Mac mini deployment needed by hand
(`docs/verification.md`, "Mac mini deployment"). `ServiceAccountManager` (`Sources/HostSetup`,
phase D4) is the single implementation; `scripts/install.sh`'s source-install path is updated to
call the same `dscl` sequence rather than keep a second one.

## Operator access

- `runnerd` accepts RPC from uid 0 and from its own running uid (`allowedUIDs: [getuid(), 0]`);
  every other uid is refused at the socket.
- `runnerd.sock` stays mode 0600, owned by `_runnervm`.
- Operators run `sudo runnerctl …`. There is no separate operator account or group added to the
  daemon's allow-list — root is the operator identity, matching how `install.sh`/`setup`/`upgrade`
  already require root.

## Filesystem and permissions

| Path | Mode | Owner |
| --- | --- | --- |
| `<state-dir>` (`/Library/Application Support/RunnerVM`) | 0750 | `_runnervm:_runnervm` |
| `<state-dir>/github-token` | 0600 | `_runnervm:_runnervm` |
| `/var/run/runnervm` | 0700 | `_runnervm:_runnervm` |
| `/var/run/runnervm/runnerd.sock` | 0600 | `_runnervm:_runnervm` |

No path RunnerVM writes to at runtime is group- or world-readable. The pkg's own files under
`/usr/local/{bin,libexec,share}/runnervm` stay root:wheel, world-readable, as normal for installed
binaries — they carry no secrets.

## Default profile naming

Generated profile names: `rvm-<host6>-ubuntu-24`, `rvm-<host6>-macos-tahoe`, where `host6` is the
first 6 hex characters of `sha256(IOPlatformUUID)`.

Why: a GitHub Actions Runner Scale Set holds exactly one message session per scale-set name within
a scope (org or repo). If two hosts in the same scope run a profile with the same name, they fight
over that session — the incumbent keeps it, whoever (re)connects second gets `HTTP 409
RunnerScaleSetSessionConflictException`, and that host's runner never starts. This was observed and
documented as an open risk in `docs/status.md` ("Profile names must be unique per scope across
hosts") before this milestone existed. Deriving the name from a stable per-host identifier
(`IOPlatformUUID` never changes across reboots or reinstalls on the same Mac) makes the default
safe for two hosts in the same org without operator coordination, while staying short and
readable. An operator who wants a fixed name can still override it with `--profile-prefix`.

## Managed image sources

`images.managed[]` (config, schema v4 `managed_images` table) names a source RunnerVM keeps
up to date on the host's own behalf, distinct from a profile pointing straight at a GHCR image:

| | Directly-runnable GHCR image | Managed source (`images.managed`, `kind: macos-tart`) |
| --- | --- | --- |
| Example | `ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable` | `ghcr.io/cirruslabs/macos-tahoe-base:latest` |
| Runnable as pulled? | Yes — has a RunnerVM guest agent baked in | No — Tart export has no guest agent; `ImagePullPurpose.provisioningBase` is the only purpose that will pull it at all |
| Becomes a profile image by | pulling, then pinning the profile to the digest | a local build→qualify→promote run producing a **new**, locally-sealed image under an alias (`managed.name`) |
| Tracked by `ImageUpdateService` as | a registry tag track (`kind: registryTag`) | a Tart source track (`kind: macosTart`) |

### Build → qualify → promote (both kinds)

1. **Resolve** the upstream reference to a digest (`RunnerVMImageTransfer.inspect`, no disk
   transfer yet); for macOS, pull the Tart export under `provisioningBase`.
2. **Build/provision**: Linux — pull the candidate registry blob; macOS — clone the Tart base into
   a builder VM, drive `scripts/provision-macos-tart.sh --attach` over SSH (guest-agent install,
   `actions/runner`, seal-time SSH lockdown), through the existing `ImageBuilder` stage ladder.
3. **Qualify**: Linux — a pinned `maintenance` instance created from the *candidate* digest has to
   reach `idle` (`ImageUpdateService.smokeTest`). macOS — the qualification runs inside the
   provisioning build itself, on a **clone of what was just sealed** booted with a fresh machine
   identity: agent reachable and ready, `sw_vers`, `agent.selfTest` all-ok (CI keychain), and a TCP
   probe proving port 22 is *closed* after a cold boot, i.e. that the seal-time lockdown survived a
   reboot rather than merely having been applied once. It is a clone rather than the provisioning
   VM because that is what an ordinary instance will be. It runs inside the build because it needs
   the build's own reservation and `vmworker` plumbing, and because a candidate that fails it must
   fail the build rather than leaving a "succeeded" build nothing may use.
4. **Promote**: only on qualification success, and only through `ImageUpdateService.promote` —
   one implementation for both kinds. For `macosTart` it additionally upserts
   `image_aliases[managed.name] = digest`, which is what a macOS profile's `image:` resolves
   through; for `registryTag` the `current_image_digest` row write is the whole promotion
   (`ImageManager.promotedRecord`). The previous digest is kept as "previous," not deleted.

   A failure anywhere above leaves the alias and `current_image_digest` exactly where they were.
   The sealed-but-unqualified digest stays recorded on the `image_builds` row (`image_digest`) so
   it is inspectable with `runnerctl build show`, and the managed row records the reason; the
   candidate column is cleared, so nothing downstream can mistake it for a promotable image.

### Update invariants

- An update **never terminates a running VM**. Existing instances keep the digest they were
  created with; nothing forces them onto the new one.
- A **failed** update (download, verify, or qualification failure) never replaces the currently
  promoted image. The alias stays pointed at the last-known-good digest; the failure is recorded
  (`managed_images.last_error`, `state = failed`) and retried later.
- `images.updates.keepPrevious` (default 1) is the retention count and the **only** deletion
  trigger: digests beyond it are candidates for deletion, and only actually deleted when
  `ImageManager`'s prune eligibility (no pins, no running instance, no reservation) agrees.
- A profile pinned to an explicit `@sha256:…` digest is **never** auto-updated — the update
  service only tracks registry tags and managed-source names, never a digest a profile already
  hardcoded.

## Version source of truth

`Sources/RunnerCore/Version.swift`, `RunnerVMVersion.current`, is the single string every other
version signal derives from:

| Consumer | How it gets the version |
| --- | --- |
| `runnerctl --version` / `runnerctl version` | compiled in, prints client (and daemon, via RPC) version |
| Release workflow | asserts the pushed git tag (`v0.2.0`) equals `RunnerVMVersion.current`; fails the release build otherwise |
| Go guest agent | same string injected via `-ldflags` at `make -C GuestAgent build-linux build-darwin` time — never hand-maintained separately |
| Installed pkg | `share/runnervm/VERSION`, one line, read by `doctor`, `upgrade`, and support requests |

There is exactly one place a version bump is authored; everything else is derived or asserted
against it.

## Upgrade policy

`sudo runnerctl upgrade` is **manual only** — nothing on the host ever upgrades itself. Flow:

1. Fetch `release-manifest.json` (latest, or `--version vX` for a specific tag).
2. Compare against `RunnerVMVersion.current`; no-op if already current (unless `--check` was
   requested, which only reports and never proceeds).
3. Download pkg + `.sha256`, verify the checksum. **Any download or checksum failure aborts before
   the host is touched.**
4. Back up `config.yaml` and the SQLite database (`sqlite3 .backup`) into
   `<state-dir>/upgrades/<timestamp>/`, alongside a `versions.json` recording the before/after
   version and the schema version.
5. Drain the host (`system drain --wait`) so no job is mid-run.
6. `launchctl bootout` the daemon, `installer -pkg -target /`, `launchctl bootstrap` it back, wait
   for the socket, run `doctor`.
7. `system resume`.

Rollback is conditional, never automatic-by-default: it only fires when `doctor` fails **and** the
maximum applied `schema_migrations` row is unchanged from before the upgrade (i.e. the new version
never ran a migration). In that case, the cached previous pkg is reinstalled and the database
backup restored. If the schema advanced, migrations are one-way — RunnerVM prints the manual
restoration steps (which backup to use, which pkg to reinstall) and stops; it does not attempt to
reverse a schema migration automatically.

## Failure semantics

| Failure | Behavior |
| --- | --- |
| Manifest/pkg/checksum download failure | Aborts before any host change; host is left exactly as it was |
| Checksum mismatch | Aborts before `installer -pkg` runs; host untouched |
| pkg install failure (upgrade path) | Existing install is kept; no partial swap |
| Revoked/rotated GitHub App installation token | The next **idempotent** request sees the 401, drops the cached token once (at most once per `authRefreshInterval`, 60 s) and retries with a freshly minted one; no `config.apply` and no restart. Non-idempotent calls (`generate-jitconfig`) surface the 401 instead of repeating a runner registration |
| GitHub auth failure (`github test` after PAT write) | Daemon stays installed and running, but is not schedulable; `setup` exits non-zero with the exact permission text needed |
| Image update (Linux tag) failure | Previous image and alias untouched; `last_error` recorded, retried on the next check |
| macOS provisioning/qualification failure | Candidate is discarded or left unpromoted; the managed alias is **never** repointed at an unqualified digest |
| Guest CI keychain preparation failure | The runner process is not started at all (`startRunner` → `KEYCHAIN_UNAVAILABLE`); no job runs without a keychain |
| `runnerd` crash | `launchd` restarts it (`KeepAlive`); in-flight sessions are recovered or closed out at-most-once on the next reconcile |
| Reboot | The daemon comes back under `launchd` with no GUI login required — this is the point of running it as a LaunchDaemon under `_runnervm` |

## Signing and notarization

### What is signed

`scripts/build-package.sh` signs **four Mach-O files**, on the staged copies (a `cp`/`install` can
strip a signature, so the file that goes into the pkg is the one that must be proven signed):

| File | Code-signing identifier | Extra |
| --- | --- | --- |
| `libexec/runnervm/runnerd` | `com.runnervm.runnerd` | — |
| `bin/runnerctl` | `com.runnervm.runnerctl` | — |
| `libexec/runnervm/vmworker` | `com.runnervm.vmworker` | `Resources/vmworker.entitlements`, then a real `probe --json` |
| `share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent` | `com.runnervm.guest-agent` | — |

The darwin guest agent is signed even though nothing on the host executes it directly: the Go
linker leaves it ad-hoc signed as `Identifier=a.out`, and Apple's notary service scans **every**
Mach-O in the payload, so leaving it alone fails the whole submission. The Linux guest agent is an
ELF and is deliberately not signed. `--identifier` is explicit on all four because codesign
otherwise derives an identifier from the file name plus a per-build hash — unstable across builds,
and therefore useless to pin a `codesign -R` requirement against.

Every signature is made with `--options runtime --timestamp`, **unconditionally**, ad-hoc dev
builds included. Ad-hoc signing accepts both flags (an ad-hoc signature simply carries no
timestamp), so a developer's `build-package.sh` run exercises exactly the hardened runtime
configuration a release does; notarization requires the hardened runtime, and discovering that it
breaks a binary at release time — on a configuration nothing else ever ran — is the failure mode
this avoids.

The pkg itself is signed by `productbuild --sign` with a Developer ID **Installer** identity. That
is sufficient on its own: no `pkgbuild --sign`, no `productsign` pass.

### Notarization and stapling

A release build additionally passes `--notarize-key/--notarize-key-id/--notarize-issuer` (required
together, refused without `--installer-identity`, refused with an ad-hoc `--sign-identity -`). The
built pkg is submitted with `notarytool submit --wait --timeout 30m`; any verdict other than
`Accepted` prints `notarytool log` and fails the build. There is no fallback to publishing an
unsigned or unnotarized pkg.

`stapler staple` then embeds the ticket so a host that cannot reach Apple still gets a verdict, and
`stapler validate` confirms it. Ordering is load-bearing: **stapling rewrites the pkg**, so the
signature re-verification (`pkgutil --check-signature`, `spctl --assess --type install`), the
`sha256` and the manifest all come *after* it. A checksum taken any earlier describes a file nobody
will ever download.

Verification uses the two tools a target host actually has — `/usr/sbin/pkgutil` and
`/usr/sbin/spctl`; `notarytool` and `stapler` are Xcode-only and exist on the build machine alone.

### The trust rule on the install side

`curl` sets no quarantine attribute and `installer` performs no assessment, so nothing verifies the
publisher unless the installers do it explicitly. They do, keyed on **notarization**, not on the
manifest:

- notarized **and** the pkg's leaf team equals the compiled-in expected team → proceed silently;
- signed by a **different** team → hard failure, no override;
- signed by our team but not notarized → warn and confirm;
- unsigned → the unsigned-package warning and confirmation this project has always had.

`RUNNERVM_ALLOW_UNSIGNED=1` still exists and still means one thing only: "do not block on a missing
signature/notarization in a non-interactive install". It never permits a package signed by someone
else — that case fails with no override, because the only reason to see it is that the artifact is
not ours.

The published `sha256` protects the download against **corruption and tampering in transit** (a
truncated download, a bit-flipped mirror) — on its own it does not prove who built the package,
since anyone who can edit the release can regenerate a matching checksum. That is what the
signature and the ticket are for. Note also that `release-manifest.json`'s `teamId` is a
description, never the reference: the expected team is compiled into the installers.

### Postinstall templating

`packaging/pkg/scripts/postinstall` is a **template**. `build-package.sh` copies
`packaging/pkg/scripts` to a temporary directory, substitutes `@RUNNERVM_TEAM_ID@` with the team id
derived from the staged `vmworker`'s own signature (empty for an ad-hoc build), `chmod 0755`s the
copy and hands *that* to `pkgbuild --scripts`. The checked-in file is never modified by a build.

The substituted value decides which checks run on the target host:

- **empty** (dev/unsigned build): `codesign --verify --strict` on all four binaries plus the
  `vmworker` entitlement check — ad-hoc installs keep working;
- **a team id**: the above, plus `codesign --verify --strict -R '=anchor apple generic and
  certificate leaf[subject.OU] = "<TEAM>"'` and a hardened-runtime flag check on each of the four.

Anything else — an unsubstituted placeholder, a malformed value — fails the install rather than
falling back to the weaker branch: a silently skipped publisher check is exactly what an attacker
who repackaged the payload would want. (The team id is validated as `[A-Z0-9]{10}` when it is
derived, which is also what makes substituting it into a `sed` expression and a `codesign -R`
requirement safe.)

### Certificates

Two certificates, both created by the Account Holder: Developer ID **Application** (the four
Mach-O files) and Developer ID **Installer** (the pkg). Signatures carry an Apple timestamp, so
they stay valid after the certificate expires (5 years) — renew, and **never revoke**, or every
already-published release stops installing. See `docs/release.md`, "One-time signing setup".

`com.apple.security.virtualization` is a non-restricted entitlement: it needs no special
provisioning profile and works under the hardened runtime with a Developer ID signature.
