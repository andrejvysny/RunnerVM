# Installing RunnerVM on the host Mac

> Setting up a Mac for the first time? Read **[`SETUP.md`](../SETUP.md)** instead — it walks the
> whole path from a fresh machine to a job running in a VM, including GitHub registration for an
> organization or a repository. This document is the reference behind it: every flag, the privilege
> model, and the security rationale.

Two install paths exist, both producing the same host layout underneath:

1. **The pkg + bootstrap installer** (`curl … | sudo bash`, published from the first tagged
   release) — the path in `SETUP.md` Part 1. See "Package install" below.
2. **`scripts/install.sh`**, building from source — the from-source/dev path, documented in
   [`docs/developer-setup.md`](developer-setup.md) and covered here as the flag reference.

Both end with the same service account, the same `<state-dir>`/`<runtime-dir>` layout, and the same
`runnerctl doctor`/launchd model; only *how the binaries got onto the disk* differs.

## Package install (`install.sh` bootstrap, pkg)

```sh
curl -fsSL https://github.com/andrejvysny/RunnerVM/releases/latest/download/install.sh | sudo bash
```

`scripts/bootstrap.sh`, published byte-for-byte as the `install.sh` release asset, is
self-contained: it assumes nothing beyond stock macOS tools, never clones this repo, never runs
`swift`/`go`, and never builds anything. It fetches `release-manifest.json`, downloads the pkg and
its `.sha256`, verifies the checksum, prints an unsigned-package warning to `/dev/tty` and waits for
confirmation (the pkg is not yet Developer-ID-signed — see "Unsigned phase" in
[`docs/design/distribution.md`](design/distribution.md)), runs `installer -pkg`, verifies the
install, and hands off to `runnerctl setup` on the same tty.

Any failure — a bad checksum, a network error, an install that does not verify — leaves the host
exactly as it was before the script ran; nothing partial is left behind.

Package layout (immutable files only — no PAT, no config, no database, no VM, created later by
`runnerctl setup`):

```
/usr/local/bin/runnerctl
/usr/local/libexec/runnervm/{runnerd,vmworker}
/usr/local/share/runnervm/{VERSION,Resources/,recipes/,guest-agent/,launchd/,scripts/,notices/}
```

`postinstall` does exactly one thing: verify the shipped `vmworker`'s ad-hoc signature and
entitlement. It never (re-)signs anything — signing happens once, at `scripts/build-package.sh`
time, off the target host.

Operator-facing environment variables for the bootstrap script: `RUNNERVM_VERSION` (a specific
`vX.Y.Z` instead of latest), `RUNNERVM_PKG_URL` (a `file://`/`https://` directory carrying the
manifest, pkg and checksum, overriding `RUNNERVM_VERSION` and the default release),
`RUNNERVM_ALLOW_UNSIGNED=1` (skip the unsigned-pkg confirmation, for non-interactive runs), and
`RUNNERVM_NO_SETUP=1` (stop after the pkg install; run `runnerctl setup` yourself later).

After the pkg lands, `runnerctl setup` does the account creation, config, launchd install, GitHub
token, image pull and first profiles — see "Dedicated service account" below for what it creates,
and `SETUP.md` for the wizard's questions.

## From-source install (`scripts/install.sh`)

Building the binaries yourself and installing with `scripts/install.sh` — see
[`docs/developer-setup.md`](developer-setup.md) for the full walkthrough. Read that script's
`--help` for the exact flag list.

## Prerequisites (from-source path)

- Apple Silicon Mac, macOS 15 or later (`runnerctl doctor` checks both).
- Xcode command line tools (`swift build`, `codesign`) and, for a Developer ID build,
  `CODESIGN_IDENTITY` set to a signing identity already in your keychain.
- ~50 GiB+ free disk by default (`host.reserve.disk`; lower it in config if the host is smaller —
  `runnerctl doctor` reports the actual headroom against whatever the config says).
- A GitHub PAT or App installation for the scopes you plan to run against (spec §12).

## Install

```sh
sudo scripts/install.sh --launchd daemon --config path/to/config.yaml
```

Without `sudo`, the script performs whatever it can with the invoking user's own privileges (handy
for `--prefix`/`--state-dir`/`--runtime-dir` under a writable custom location, e.g. for testing)
and prints the exact `sudo <command>` lines for everything else under **manual steps** — it never
calls `sudo` itself. Defaults: `--prefix /usr/local`, `--state-dir "/Library/Application Support/
RunnerVM"`, `--runtime-dir /var/run/runnervm`, `--user _runnervm`, `--group _runnervm`,
`--launchd none`.

What it does, in order: checks that the `_runnervm` service group and user exist with the right
`PrimaryGroupID` relationship, queuing `dscl` manual steps for whatever is missing or
wrong (see "Dedicated service account and auto-login" below); builds release binaries for
`runnerd`/`runnerctl`/`vmworker`; signs `vmworker` with `Resources/vmworker.entitlements` (ad-hoc by
default; set `CODESIGN_IDENTITY` for a Developer ID build); installs `runnerd`+`vmworker` to
`<prefix>/libexec/runnervm/` and `runnerctl` to `<prefix>/bin/`; creates `<state-dir>` (mode 0750)
with `images/`, `instances/`, `logs/`, `state/`, `cache/` subdirectories (`logs/` and
`logs/instances/` explicitly 0750) and `<runtime-dir>` (mode 0700), both owned by the service user
and group; copies `--config` to `<state-dir>/config.yaml` (mode 0640); verifies every socket path
stays under the 104-byte `sun_path` limit before writing anything; and, if `--launchd` is not
`none`, installs the chosen plist. It never runs `launchctl` — load the job yourself (the script
prints the exact command).

It also installs the in-daemon image builder's assets (`runnerctl image build`,
[docs/image-build.md](image-build.md)): the Linux guest agent its boot seed installs (built with
`make -C GuestAgent build-linux` when `GuestAgent/bin/linux-arm64/runnervm-guest-agent` is not
already there and Go is available — fails otherwise unless `--skip-guest-agent`) at
`<state-dir>/guest-agent/linux-arm64/`; the shipped `images/recipes/` at
`<state-dir>/share/recipes/` (owned `root:<group>`, not the service user — the daemon reads these
but must not be able to rewrite them); and `state/builds/`, `cache/base-images/`, `logs/builds/`,
the directories the builder itself expects (`runnerd` also creates these lazily on first run if
`install.sh` is skipped entirely).

`--group` defaults to the dedicated `_runnervm` group, never `staff`: every local macOS user
account is a member of `staff`, so a `staff`-owned state directory and log/config files would be
readable by every account on the Mac, including runner `_diag` bundles and GitHub credentials.
Passing `--group staff` is refused unless `--allow-staff-group` is also given.

Verify with `--dry-run` first; it performs no filesystem writes and prints every action, including
the fully rendered launchd plist.

For a configuration to start from, [`docs/examples/headless-mac-mini.yaml`](examples/headless-mac-mini.yaml)
is the exact file a real deployment ran, with the reasoning for each number in comments — including
the one that surprises people: instance disk reservation is `max(profile.resources.disk,
image.virtualBytes)`, so concurrency on a normal Mac is bounded by disk long before CPU or RAM.
See [`docs/examples/README.md`](examples/README.md).

## Talking to the daemon: `sudo runnerctl`, socket discovery

`runnerctl` and `runnerd` resolve the socket/state/runtime paths the same way, in order:
`--socket`/`--state-dir`/`--runtime-dir` flag > `RUNNERVM_SOCKET`/`RUNNERVM_STATE_DIR`/
`RUNNERVM_RUNTIME_DIR` environment variable > the production path (`/var/run/runnervm/runnerd.sock`)
if it exists > the development path (`/tmp/runnervm-<uid>/runnerd.sock`). `runnerd` additionally
accepts RPC from uid 0 as well as its own running uid — every other uid is refused at the socket.
Together this means a production install needs no flags and no shell alias:

```sh
sudo runnerctl status
sudo runnerctl vm list
```

`doctor` is the one exception: it deliberately works with no daemon at all, so it takes
`--state-dir`/`--config` rather than a socket.

## Installing via Homebrew

```sh
brew install andrejvysny/runnervm/runnervm
```

This builds and ad-hoc signs `runnerd`/`runnerctl`/`vmworker` and the Linux guest agent the same
way `scripts/install.sh` does on its own (same entitlements file, same `codesign` invocation), and
installs them into the Homebrew prefix (`runnerctl` on your `PATH`, `runnerd`/`vmworker` under
`libexec`, everything else under `share/runnervm`). It does **not** perform any of the steps above
that need root — Homebrew formulae must never call `sudo`. Finish with:

```sh
sudo "$(brew --prefix runnervm)/share/runnervm/scripts/install.sh" \
    --prebuilt-dir "$(brew --prefix runnervm)" \
    --launchd daemon --config path/to/config.yaml
```

`--prebuilt-dir` points `install.sh` at the already-built keg instead of running `swift build`/
`make -C GuestAgent build-linux` again; every other step (service account, state/runtime
directories, launchd job) is identical to a from-source install. Upgrades: `brew upgrade runnervm`
followed by the same `sudo ... install.sh --prebuilt-dir ...` command re-signs and re-installs the
binaries in place (see "Upgrade procedure" below).

## One host per profile name, per scope

A profile's name is the scale-set name RunnerVM registers on GitHub (`runnervm-<profile>`), and a
scale set has exactly one message session. Two hosts pointing at the same org/repo with the same
profile name therefore fight over it: the second daemon logs

```
GITHUB_CONFLICT: conflict: POST /_apis/runtime/runnerscalesets/<id>/sessions: HTTP 409
  RunnerScaleSetSessionConflictException: The actions runner scaleset runnervm-<profile>
  already has an active session.
```

and its scale set sits `closed` in `runnerctl scaleset list`. The incumbent keeps the session, so
nothing breaks while both are up — but whichever host restarts loses the session to the other, and
jobs then land on a host you did not intend. **Give each host its own profile names** (or its own
scope). Disabling a profile on the losing host is enough to stop it contending; nothing in the
daemon deletes a scale set, so removing a profile from one host's configuration leaves the other
host's scale set alone.

## Choosing a launchd variant

`scripts/install.sh --launchd agent|daemon|none`. Full trade-off and provisioning steps live in
`packaging/launchd/README.md`. Summary:

- **`daemon`** (recommended production default): a LaunchDaemon under the dedicated unprivileged
  `_runnervm` account. No GUI session, no auto-login, no FileVault compromise. Measured
  2026-08-28 (macOS 26.5.2, Apple M4 Mac mini): with no GUI login session at all — nobody logged
  in, `/dev/console` owned by `root` — `runnerd` booted every VM asked of it while the login
  keychain sat locked; `runnerctl doctor` now skips the login-keychain check entirely under a
  detected LaunchDaemon rather than reporting it as a false-negative failure. This does **not** by
  itself prove reboot recovery — that is what the qualification loop in `docs/qualification.md`
  measures, and it remains the gate before trusting a host unattended.
- **`agent`** (secondary — developer workstations, GUI sessions): a LaunchAgent in a dedicated
  auto-login user's GUI session. Choose this only when something in the job workload actually needs
  a window server; it needs an auto-login account and is incompatible with a cold FileVault boot
  recovering unattended.
- **`none`** (default of the script itself): installs nothing launchd-related; the script prints
  the manual foreground command instead. Useful for testing or for an external process supervisor.

Both plists live in `packaging/launchd/` as templates (`__TOKEN__` placeholders); `install.sh`
substitutes them and writes the result to `/Library/LaunchAgents/com.runnervm.runnerd.agent.plist`
or `/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`.

Before trusting either variant on unattended hardware, run the cold-boot/power-cut qualification
loop in `docs/qualification.md` (`scripts/qualify-host.sh`).

## Dedicated service account and auto-login

RunnerVM runs as a dedicated `_runnervm` user whose primary group is a dedicated `_runnervm`
group — **never** `staff`. Every local macOS user account, human or service, is a member of
`staff` by default; a `staff`-owned state directory would make `<state-dir>` (0750) and its
config/log files (0640) readable by every other account on the Mac, including GitHub credentials
and runner `_diag` bundles that can carry job output. `scripts/install.sh --group staff` is
refused for exactly this reason unless you pass `--allow-staff-group` and accept the exposure.

`scripts/install.sh` checks for both principals on every run (`dscl . -read`) and prints the exact
commands to run under `sudo` when either is missing — the same **manual steps** mechanism it uses
for every other privileged action. To do it by hand ahead of time, or to understand what the
script queues:

```sh
# 1. Create the hidden system group (pick a free GID in 200-400: none of
#    `dscl . -list /Groups PrimaryGroupID` should already print it).
sudo dscl . -create /Groups/_runnervm
sudo dscl . -create /Groups/_runnervm PrimaryGroupID 250
sudo dscl . -create /Groups/_runnervm RealName "RunnerVM Service"
sudo dscl . -create /Groups/_runnervm Password "*"

# 2. Create the service account with that group as its primary group.
sudo dscl . -create /Users/_runnervm
sudo dscl . -create /Users/_runnervm UserShell /usr/bin/false
sudo dscl . -create /Users/_runnervm RealName "RunnerVM Service"
sudo dscl . -create /Users/_runnervm UniqueID 250
sudo dscl . -create /Users/_runnervm PrimaryGroupID 250
sudo dscl . -create /Users/_runnervm NFSHomeDirectory "<state-dir>/home"
sudo dscl . -create /Users/_runnervm Password '*'
sudo dscl . -create /Users/_runnervm IsHidden 1
```

`dscl` only — no `sysadminctl`, no interactive password prompt, and no real home under `/Users`
(the account never logs in, so `<state-dir>/home` is enough). This is the same sequence
`ServiceAccountManager` (`Sources/HostSetup`, used by `runnerctl setup`) runs, and what
`scripts/install.sh`'s source-install path calls too — one implementation, not two. It replaces the
interactive `sysadminctl` step the first Mac mini deployment needed by hand (`docs/verification.md`,
"Mac mini deployment"). If `_runnervm` already exists with `staff` as its primary group — a host
installed before this dedicated group existed — `scripts/install.sh` detects the mismatch and
queues `sudo dscl . -create /Users/_runnervm PrimaryGroupID <gid>` to fix it in place; nothing else
about the account needs to change.

For the LaunchAgent path, also enable automatic login for `_runnervm` (System Settings → Login
Screen) and log in as that user once before relying on it, so its login keychain exists and is
unlocked going forward. `packaging/launchd/README.md` covers the LaunchDaemon keychain-provisioning
alternative. Autologin requires FileVault to be off (or the volume unlocked another way).

## Uninstall

**From-source install** (`scripts/install.sh`):

```sh
sudo scripts/install.sh --uninstall --launchd daemon
```

Removes the installed binaries and the matching launchd plist (both variants if `--launchd` is
omitted). Unload the job first (the command is printed) so nothing tries to restart the daemon
mid-uninstall.

**Pkg install**:

```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist   # or gui/<uid> for the agent variant
sudo pkgutil --forget com.runnervm.pkg
sudo rm -rf /usr/local/bin/runnerctl /usr/local/libexec/runnervm /usr/local/share/runnervm
```

`pkgutil --forget` only removes the receipt (so a later install does not think it is upgrading in
place); it does not delete files itself, so the binaries under `/usr/local/{bin,libexec,share}
/runnervm` still need the explicit `rm -rf` above.

**Either path, state is preserved deliberately**: `<state-dir>` (config, database, images, instance
disks, logs) and the runtime socket directory are left in place. Remove them by hand only if you
actually want the data gone — a reinstall of either kind picks the existing state directory back up
unchanged.

The `_runnervm` service account and group are also left in place — neither uninstall path deletes
directory service records. Remove them yourself (`sudo dscl . -delete /Users/_runnervm`,
`sudo dscl . -delete /Groups/_runnervm`) only after confirming nothing else on the host still
depends on that account owning files under `<state-dir>`.

## `runnerctl doctor`

```sh
runnerctl doctor [--state-dir <dir>] [--socket-dir <dir>] [--config <yaml>] [--output json]
                  [--service-user <name>] [--deep]
```

Every check runs locally — no daemon required, matching the general RunnerVM principle that the
CLI never depends on runnerd being up just to inspect the host. Checks (spec §104, plus host-sleep,
launchd-job and the production-hardening checks below the implementation plan adds): Apple Silicon,
macOS ≥ 15, `vmworker` present and signed with the virtualization entitlement, `vmworker probe`
succeeds and reports `virtualizationSupported`, state directory writable + APFS clone support,
socket path lengths, configuration validates (when `--config` is given), free disk vs.
`host.reserve.disk`, free memory vs. `host.reserve.memory` plus the largest configured profile/build
workload (structural shortfall fails, transient pressure from `vm_stat` warns), a GitHub credential
is present for the configured `github.auth.source` (presence only — this never makes a network
call; use `runnerctl github test` to actually verify it; for `github.auth.provider: app` this also
checks the private key file `github-app.json` points at exists and is owner-only), the in-daemon
image builder's `hdiutil` (a real `makehybrid` smoke test, once as whoever invoked `doctor` and
again noting the uid it ran under so a mismatch against the expected service account is visible),
guest agent binary (same search order as `BuildSeed.resolveAgent` — see
[docs/image-build.md](image-build.md#guest-agent-resolution)) and shipped recipe root, every local
image's manifest still points at a blob of the recorded size (`--deep` also re-hashes every blob's
sha256 — slow for large images, off by default), at least one local image carries a RunnerVM guest
agent, `<state-dir>`/`config.yaml`/`state/`/`logs/` are owned by the expected service account with
no world-readable bits (`--service-user` overrides the default `_runnervm`; a development layout
under `$HOME` expects the invoking account instead), the runtime socket directory is 0700 with 0600
sockets, host sleep is disabled (spec plan: v1 does not tolerate the host sleeping out from under a
running VM), and whether a `com.runnervm.runnerd` launchd job is loaded. When `runnerd.sock` is
reachable it also folds in a `system.status` summary. Exits 1 if any check fails; `--output json`
for automation (used by `scripts/qualify-host.sh`, which also runs `hdiutil` and a real
`image build` under the service identity itself — see `docs/qualification.md`).

## Log locations

- `<state-dir>/logs/runnerd/runnerd.log` — the daemon's JSON log. `runnerd` writes and rotates it
  itself (32MiB × 10 by default) and tees the same lines to stderr.
- `<state-dir>/logs/runnerd/stdio.log` — where both launchd plists point
  `StandardOutPath`/`StandardErrorPath`. Crash and launch output only; empty is the healthy state.
- `<state-dir>/logs/events.jsonl` — one JSON line per instance/session lifecycle transition and per
  audit event.
- `<state-dir>/logs/instances/<id>/` — per-instance `serial.log`, `worker.log`, `failure.json` and
  the `diag/` tarball pulled out of the guest before it was destroyed. Swept after
  `logging.retention.instanceLogs` (default 7d).
- `packaging/newsyslog/runnervm.conf` — optional additional rotation policy; not installed
  automatically. `runnerd` now reopens its files on `SIGHUP`, so external rotation takes effect
  immediately (`launchctl kill HUP …` — see the file).

**Full reference: [`docs/logging.md`](logging.md)** — field glossary, the `logging:` configuration
block, retention, `_diag` collection and its limits, and ready-made Vector and Fluent Bit
pipelines.

## Upgrade procedure

**Pkg install:**

```sh
runnerctl upgrade --check                              # report only; no root
sudo runnerctl upgrade [--version vX.Y.Z] [--drain-timeout 30m] [--yes]
```

Manual only — nothing on the host upgrades itself. Fetches `release-manifest.json` (latest, or the
named tag), verifies the pkg against both its detached `.sha256` and the manifest's own hash — any
failure aborts before the host is touched — backs up `config.yaml` and the database, `system drain
--wait`-equivalent (bounded by `--drain-timeout`, default 30m), swaps the package, restarts the
daemon, and runs `doctor`. `--yes`/`-y` answers every confirmation, including the unsigned-package
one. Rollback happens automatically only when `doctor` fails **and** the schema did not advance
during the upgrade — a schema change is one-way and prints manual restoration steps instead. Full
contract: [`docs/design/distribution.md`](design/distribution.md) ("Upgrade policy"). This command
landed very recently and has not been exercised on real hardware — verify against
`runnerctl upgrade --help` before relying on this section.

**From-source install:**

1. Stop new work from landing on this host before touching binaries:
   `runnerctl system drain --wait` advertises zero capacity, admits no new jobs, and blocks until
   the last active job finishes (`--timeout` bounds the wait, default 900s).
2. `sudo launchctl bootout system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`
   (or `gui/$(id -u _runnervm)` + the agent plist path for the LaunchAgent variant).
3. Re-run `scripts/install.sh` with the same flags — it overwrites the binaries and re-signs
   `vmworker` in place; state and runtime directories are untouched. Homebrew installs:
   `brew upgrade runnervm` first, then re-run the `install.sh --prebuilt-dir ...` command from
   "Installing via Homebrew" above.
4. `runnerctl doctor` to confirm the new binary is signed and `vmworker probe` still succeeds.
5. Reload the job (`launchctl bootstrap ...`, printed by `install.sh`), then `runnerctl system
   resume` to advertise capacity again.

**The SQLite schema migration is one-way.** `runnerd` migrates `<state-dir>/state/runnerd.sqlite3`
forward on startup (`Sources/Persistence/Migrations/Migrator.swift`) and never downgrades it: a
database already migrated to schema v2 (the in-daemon image builder's `image_builds`/`image_aliases`
tables, first shipped alongside `runnerctl image build`) refuses to open under an older runnerd
binary whose own `currentSchemaVersion` is still 1 (`DB_SCHEMA_VERSION_UNSUPPORTED`). Once step 3
above has run with a v2-or-later `runnerd`, rolling back to a pre-image-builder binary on the same
`<state-dir>` is not supported — restore a database backup taken before the upgrade instead. Schema
v3 (`image_builds.recovery_since`, for builds whose builder VM could not be proven dead) follows the
same rule; it is a nullable `ADD COLUMN`, so upgrading to it preserves every existing row.

## Security notes (spec §129)

- `<runtime-dir>` is mode 0700, owned by the service user; individual sockets are created mode
  0600 by `runnerd` itself (`Sources/RPC/UnixSocketListener.swift` publishes atomically via a
  `.tmp` rename so a socket is never observed group/world-accessible).
- RunnerVM never listens on TCP for internal control in v1 — only Unix-domain sockets under
  `<runtime-dir>`.
- `<state-dir>` is 0750. Every GitHub secret file is read through one owner-checked,
  symlink-rejecting reader (`SecureFile` in `Sources/GitHubControl/Credentials`) that opens the
  file, `fstat()`s the descriptor, and only then reads it — a looser mode, a symlink, a non-regular
  file, or an unexpected owner is a configuration error, not a warning, because a leaked PAT or App
  private key with `admin:org` is a host-wide compromise. Target modes, owner = service user:
  - `github-token` (when `github.auth.source: file`) — 0600.
  - `github-app.json` (when `github.auth.provider: app`) — 0640 or stricter.
  - the GitHub App private key PEM it points at — 0600.
- Run production workloads as the dedicated `_runnervm` account, never as `root` — `root` is only
  needed transiently, for `sudo scripts/install.sh` itself.
- The service account's primary group is a dedicated `_runnervm` group, never `staff`. Every local
  macOS account is a member of `staff`, so a `staff`-owned `<state-dir>` would make its 0750/0640
  contents — GitHub credentials, job logs, runner `_diag` bundles — readable by every other user on
  the Mac. `scripts/install.sh --group staff` requires `--allow-staff-group` for exactly this
  reason; see "Dedicated service account and auto-login" above.
- **`lifecycle: ephemeral` is the production default and the only isolated mode.** A reusable
  profile (`lifecycle: reusable`) keeps one guest across consecutive jobs. Between jobs the guest
  agent restores the runner's HOME from a pristine snapshot and clears `_work`, `_diag`, the
  runner's temp files and (optionally) docker state — but a job that can `sudo` can write
  anywhere else on the disk, and nothing resets that. Treat a reusable profile as single-tenant:
  every job that can land on it is trusted with whatever the previous job left behind. `config
  validate` refuses `lifecycle: reusable` with `PROFILE_REUSABLE_UNACKNOWLEDGED` until the profile
  says so explicitly:

  ```yaml
  lifecycle: reusable
  reuse:
    acknowledgeSharedHost: true   # jobs on this profile trust each other
  ```

  Even then it warns (`PROFILE_REUSABLE_SINGLE_TENANT`). Do not point a reusable profile at a
  public repository or at workflows from more than one trust domain.
