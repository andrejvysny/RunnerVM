# Changelog

Dates are when the work landed on `master`; see `docs/verification.md` for what was proven live.

## Unreleased — v0.3.0 (in progress)

Hardening from the pre-release review (`PLAN.md`). Everything here is unit/integration-tested;
the hardware matrix runs before the tag.

- The reconciler now reaps `failed`, `interrupted` and `stopped` instances of every lifecycle once
  `diagnostics.failedInstanceRetention` has passed — previously only ephemeral ones were reaped,
  so a reusable VM that was stopped or never reached `idle` held its cpu, memory, disk
  reservation, image pin and directory until the daemon was restarted. Maintenance instances
  inside their pin, and rows a delete or restart is already walking down, are untouched. The
  sweep commits against the state it judged (compare-and-swap), never against a row that moved.
- Rows stuck in `deleting` (a worker that never released its lock) are retried once per
  `deletingRetryGrace` (5 min) by a background task that never stalls the reconcile tick;
  `runnervm_instance_delete_retries_total{profile}` counts them. Scheduler cancel failures are
  counted in `runnervm_instance_cancel_failures_total{profile,code}` and logged with backoff
  instead of every 10 seconds. Image rows abandoned in `pulling` are invalidated.
- New `ProcessSpawn` runner for every host subprocess (`hdiutil`, `tar`, the macOS provisioning
  script, `vmworker probe`, setup/upgrade commands): `posix_spawn` with a private process group,
  default signal dispositions (runnerd ignores SIGTERM and used to pass that on), process-group
  SIGTERM→SIGKILL escalation, and a deadline-bounded pipe drain — a helper whose grandchild holds
  the pipe can no longer hang a build forever. `BUILD_TOOL_TIMEOUT` names a killed tool; the
  provisioning script gets `RVM_PROVISION_TIMEOUT` below the build timeout, an explicit
  environment and `--out`; an orphaned provisioning process group is terminated by build recovery
  after a daemon crash. `vmworker probe` is re-tried on the maintenance tick while degraded.
- A revoked or rotated GitHub App installation token self-heals: a 401 on an idempotent request
  drops the cached credential once per minute and retries once.
- Session recovery can no longer terminalize a live session whose registration is mid-JIT, nor act
  on a stale snapshot: `register` owns its row from before the insert until the observer exists,
  and recovery re-reads every row before deciding.
- `vmworker` unlinks its sockets on every exit path (including a VZ start failure) and reports
  exit 79 when the guest could not be force-stopped and 80 when the host is at the macOS
  guest ceiling (was 75, indistinguishable from a held lock). `worker.shutdown`'s `drain` and
  `stop` are documented as identical; `agentBootId` is dropped from the protocol document.
- `timeouts.gracefulShutdown` is now enforced on every runnerd-driven teardown instead of a
  hardcoded 30 s: `worker.shutdown`, the guest's `agent.stopRunner`, and — through the new
  `vmworker run --graceful-ms` option — the shutdowns a worker starts by itself (hard deadline,
  orphan idle, SIGTERM). The `agent.stopRunner` call now gets its own deadline of the grace plus
  15 s, so a window longer than 30 s is no longer cancelled into a SIGKILL at 30 s. The wait for
  the worker's lock to drop scales with the grace and is capped at 120 s, and the scheduler's
  cancellations run as tracked detached tasks so a long grace cannot stall the reconcile tick.
  A profile above 10 min is flagged `PROFILE_TIMEOUT_GRACEFUL_SHUTDOWN_LONG`; image builds are not
  profile-owned and keep their fixed 120 s.
- `install.sh` (bootstrap) refuses a manifest package name that is not a plain `<name>.pkg`
  filename; `APFSClone.freeSpace` logs once when the volume is unreadable instead of silently
  reporting 0.
- `timeouts.jitGeneration` is enforced: `generate-jitconfig` is now bounded on both the REST and
  the scale-set path, and expiry closes the session as `jitFailed` with
  `GITHUB_JIT_GENERATION_TIMEOUT` and hands the VM straight back instead of retaining it. A
  registration GitHub made anyway — the config arrived after the deadline, or its answer was lost —
  is found by id or by runner name, written to the session row and removed, so a failed DELETE is
  still retried by the maintenance loop. The default is raised **30s -> 2m**, which covers a
  credential mint plus a few 429/503 retries — deliberately not the whole `RetryPolicy.github`
  ladder, because giving up earlier and letting the scheduler's hold-down set the retry cadence is
  the point; `PROFILE_TIMEOUT_JIT_GENERATION_SHORT` warns below 60s. A session hand-off that fails
  with any `GITHUB_*` code now holds the profile down like a failed VM start, so a GitHub outage
  can no longer turn standing demand into a create/destroy loop. The scale-set token exchange is now cancellable per waiter (it used to be awaited as
  `Task.value`, which ignores cancellation), while the exchange itself keeps running for the other
  callers that share it. A scale-set runner lookup by name is re-filtered for an exact match, as
  the REST one already was.
- `timeouts.imagePull` is enforced, per caller: the deadline covers resolving the reference and
  waiting for the image inside `instance.create`, and expiry answers `IMAGE_PULL_TIMEOUT` with the
  planning pin released and no instance row left behind — while the transfer everyone on that
  digest shares keeps running, so the next create is served from the store instead of downloading
  the image again. A caller waiting on someone else's transfer is told what that transfer actually
  failed with (`REGISTRY_AUTH`, `IMAGE_INSUFFICIENT_DISK_SPACE`, …) rather than a flattened
  `IMAGE_PULL_FAILED`. `image.pull` and `runnerctl image pull` stay unbounded. The default is
  raised **30m -> 60m** (a real image is ~2.9 GiB compressed and ~16 GiB of content to hash, and
  `images.prefetch` is off by default, so the first `vm create` pays for the whole transfer);
  `PROFILE_TIMEOUT_IMAGE_PULL_SHORT` warns below 60s.
- `timeouts.vmBoot` is enforced: the clock starts at `cloning` and bounds the whole window up to
  the guest reporting itself running. The clone and the worker spawn are checked against it as they
  finish (`clonefile(2)` has no cancellation point, so an overrun can only be reported afterwards),
  and the rest — which outlives the `instance.create` RPC, still returning at `startingVM` — is
  watched by a tracked background task per instance. Expiry fails the row with `VM_BOOT_TIMEOUT`,
  names the phase that overran in `failure.json`, and shuts the worker down while keeping the
  directory for diagnostics; a `running` event that lands first wins the row and leaves no failure
  record, metric or shutdown behind. The watch is rebuilt on the first reconcile tick after a daemon
  restart — from the row's `started_at`, so a restart cannot hand the same boot a fresh budget —
  after asking the re-adopted worker what state it sees, which finishes a guest that came up while
  runnerd was away instead of failing it. `InstanceManager.fail` now commits the state first and
  writes the failure record, metric and log line only when that compare-and-swap lands (it used to
  write the record before checking, and to report a failure whose transition had been rejected).
  `PROFILE_TIMEOUT_VM_BOOT_SHORT` warns below 30s, and `PROFILE_TIMEOUT_AGENT_READY_SHORT` warns
  when a macOS profile allows under 2m for `agentReady` — Virtualization reports a macOS guest
  running before macOS has booted, so that first boot is bounded by `agentReady`, not `vmBoot`.

## 2026-09-02 — v0.2.1 patch

- `fad78a0`: fixed the cooperative-pool thread starvation that made `v0.2.0`'s CI (`d742a1c`) red —
  blocking probes/subprocess calls were parking cooperative-pool threads.
- `runnerd` startup-failure classification and backoff, using sysexits codes (69, 72, 75, 78) to
  decide retry vs. give up; new `RUNNERVM_STARTUP_BACKOFF` and `RUNNERVM_SUPERVISED` env vars.
- `install.sh` now creates `<state>/logs/runnerd`, the launchd stdio directory — its absence on a
  real host made launchd fail to spawn `runnerd` 70,547 times, reported as exit 78.
- launchd plists: `ThrottleInterval` 30, agent `ExitTimeOut` 60; `HostProbe` bounded by 60 s.
- `doctor` reports launchd `runs`/`last exit code`, a missing stdio directory, and a stale
  `ThrottleInterval`.
- `publish-images.yml`'s cron trigger removed (dispatch only) until a publisher host exists —
  a cron run would otherwise queue forever with no `runnervm-publisher` runner registered.
- Guest agent Go module path is `github.com/andrejvysny/RunnerVM/GuestAgent` (was the placeholder
  `github.com/runnervm/guest-agent`); binary name, version injection and behavior unchanged.
- Licensing stated explicitly: README "License and provenance", `NOTICE` lists the actions/scaleset
  MIT port and every third-party dependency's license, `PROVENANCE.md` audit record re-verified
  19/19 Tart-derived and 7/7 scaleset-ported headers.
- The 8 stale `.claude/worktrees/` agent clones and their branches were deleted (local only).

## 2026-08-28 — Distribution hardening (milestone D)

Closes the distribution milestone (`docs/design/distribution.md`, `TODO.md` "D — Distribution
hardening"): a fresh Apple Silicon Mac becomes a working runner host from one `curl … | sudo bash`.
Every item below is unit/integration-tested only at the time it landed. **Nothing published to
GHCR yet** — the operator matrix (fresh-Mac install, reboot loop, upgrade, managed macOS
provisioning, keychain e2e, first publish) is still open. Track it in `docs/status.md` "Open
verification". `v0.2.0` was tagged from `d742a1c` with a red CI (Swift job failing on
cooperative-pool thread starvation), fixed afterwards by `fad78a0` on `master` — see the v0.2.1
section above.

- **Repository renamed** to `andrejvysny/RunnerVM`, `LICENSE` is now Apache-2.0 for RunnerVM code
  (FSL attribution for ported Tart files unchanged in `NOTICE`/`PROVENANCE.md`), and
  `RunnerVMVersion.current = "0.2.0"` (`Sources/RunnerCore/Version.swift`) becomes the one place a
  version is authored — `runnerctl --version` prints it offline, the release workflow asserts the
  git tag matches it, and the pkg ships it as `share/runnervm/VERSION`.
- **Socket auto-discovery.** `runnerctl`/`runnerd` resolve `--socket`/`--state-dir`/`--runtime-dir`
  as flag > `RUNNERVM_SOCKET`/`RUNNERVM_STATE_DIR`/`RUNNERVM_RUNTIME_DIR` > the production path if
  it exists > the development path — no more spelling `--socket` on every call against a real
  install. `runnerd` now also accepts RPC from uid 0, so `sudo runnerctl …` works against a daemon
  running as `_runnervm`.
- **`doctor` grows a service-mode-aware model.** A new `skip` status, LaunchDaemon/LaunchAgent/
  foreground detection, the login-keychain check now skipped (not failed) under a detected
  LaunchDaemon and warned elsewhere, FileVault and reboot-persistence checks, and `--deep` running
  the shared smoke test end to end.
- **Prebuilt pkg and release automation.** `scripts/build-package.sh` lays out
  `/usr/local/{bin,libexec/runnervm,share/runnervm/...}`; `.github/workflows/release.yml` is
  tag-gated (the tag must equal `RunnerVMVersion.current`), runs an install smoke test, and creates
  a `gh release` carrying the pkg, its sha256, `release-manifest.json` and `install.sh`.
  `scripts/bootstrap.sh` (published as the `install.sh` release asset) is the curl one-liner: it
  verifies the download, installs, and hands off to `runnerctl setup` on `/dev/tty`
  (`RUNNERVM_VERSION`/`RUNNERVM_PKG_URL`/`RUNNERVM_ALLOW_UNSIGNED`/`RUNNERVM_NO_SETUP`).
- **`runnerctl setup`** is the wizard behind that handoff: daemon deployment by default, org/repo
  scope, a PAT read without echo, a sizing recommendation, `rvm-<host6>-*` generated profile names
  (so two hosts in one GitHub scope cannot collide on a scale-set session), profiles applied only
  after images are pulled or provisioned, and a finish that runs `doctor` plus a smoke test and
  prints a single-scale-set-label `runs-on` sample. Creates the hidden `_runnervm` account
  `dscl`-only (shell `/usr/bin/false`, home under the state directory — no `sysadminctl`).
  `--dry-run`/`--non-interactive` supported.
- **Maintenance instances.** `vm create --pinned --ttl [--image]` makes a resource-visible,
  demand-invisible instance that scale-to-zero never cancels; `runnerctl system smoke-test` wraps
  the same client-side check the wizard and image qualification use; `scripts/qualify-macos-image.sh`
  now pins its instance, fixing H2 (an ephemeral qualification instance could be scaled away by the
  scheduler before the guest agent ever connected).
- **Automatic image updates.** `images.updates {enabled, interval, jitter, keepPrevious,
  smokeTest}` re-resolves every tracked registry tag or managed source on an interval, pulls and
  qualifies the candidate (boot-to-idle), and only then promotes it atomically. An update never
  terminates a running VM, a failed update never replaces the current image, `keepPrevious` is the
  only deletion gate, and a digest-pinned profile is never tracked. Operator surface: `runnerctl
  image update check|run|status`, plus an `Updates` block in `status`.
- **Native managed macOS provisioning.** `images.managed [{name, kind: macos-tart, source,
  autoUpdate, resources}]` lets the daemon pull the Cirrus Tart base read-only, boot it under
  `vmworker` itself (no Tart binary, no Homebrew on the host), find its IP by MAC from
  `/var/db/dhcpd_leases`, and drive `scripts/provision-macos-tart.sh --attach` over SSH — payload
  manifest, seal-time lockdown, a refusal to seal without harden proof and a graceful shutdown, and
  a cold-boot qualification of a fresh-identity clone before promoting via alias. Macos images are
  still never published.
- **Per-VM macOS CI keychain**, in the Go guest agent: a fresh, empty, unlocked
  `runnervm-ci.keychain` per session, exposed to the runner as `RUNNERVM_CI_KEYCHAIN`/
  `RUNNERVM_CI_KEYCHAIN_PASSWORD`, fail-closed (`KEYCHAIN_UNAVAILABLE`) if it cannot be built, and
  deleted on exit. `agent.selfTest` proves the import-then-codesign chain actually works
  (`Proto/guest_agent.md`).
- **`sudo runnerctl upgrade` (D10).** Manual-only, per `docs/design/distribution.md` ("Upgrade
  policy"): `--check` reports the installed vs. released version with no root; otherwise it
  verifies the pkg against its detached checksum and the manifest's own hash, backs up
  `config.yaml` and the database, drains the host (`--drain-timeout`, default 30m), swaps the
  package, restarts the daemon, and runs `doctor` — with auto-rollback only when `doctor` fails and
  the schema did not advance. Landed very close to this entry; not yet exercised on real hardware.
- **`publish-images.yml`**, self-hosted (`runnervm-publisher`), monthly. The first publish of
  `ubuntu-24-base:stable` to GHCR is an operator step (login, dispatch or wait for the schedule,
  make the package public, connect it to the repo) and has not been run.

## 2026-08-28 — pull-only deployment: `image inspect --remote`, `images.prefetch`, published images

A host that pulls its images should not have to build any. Three gaps stood between that and the
existing OCI transport, which has been live-verified against GHCR since 2026-08-27.

**Sizing before pulling.** A profile's `resources.disk` is measured against the image's virtual
size — a macOS profile must match it exactly (`VM_MACOS_DISK_RESIZE_UNSUPPORTED`), a Linux one must
be at least it — and a 16–50 GiB download is a bad way to learn that number. `image.inspectRemote`
(`runnerctl image inspect --remote <ref>`) reads the manifest and the two config blobs and stops:
no disk transfer, no row, no staging directory. It reports the `@sha256:…` to pin, the virtual size
in bytes as well as units, the compressed transfer size, the guest-agent and Docker capabilities,
and a macOS image's `minimumCPUCount`/`minimumMemoryBytes`. Unlike `instance.create` it *describes*
an agentless image rather than refusing it — `guestAgent: false` is the answer to the question that
was asked. Its tag resolution seeds the same cache `image.pull` reads, so the pull that usually
follows does not repeat the round trip.

**`images.prefetch`.** Off by default. With it on, every configured profile's registry image is
pulled at `config apply` and at daemon start, instead of inside the first `instance.create` that
needs it — which is what otherwise makes the first job after a config change wait for a
multi-gigabyte download and look like a runner failure. The sweep is detached from `config apply`,
sequential, and goes through the existing pull gate (`host.limits.concurrentImagePulls`, the
free-space check against `host.reserve.disk`). Nothing in it is fatal: an unreachable registry or a
credential not stored yet is logged and stepped over, the other profiles are still prefetched, and
the reconcile tick retries.

**Publishing.** `scripts/publish-images.sh` wraps `runnerctl image push` with the checks that are
advisory for a local image and refusals for a published one: not `ready`, no guest agent, a macOS
image that kept the Tart base's `admin`/`admin` over SSH, a `-dirty` guest-agent build, an
`actions/runner` already graded `stale`/`tooOld`. Each refusal names the flag that overrides it.
The SSH check is macOS-only on purpose: on Linux `capabilities.ssh: true` means socket-activated
`sshd` with no keys and no password auth, which is every shipped recipe.
`docs/published-images.md` is the catalogue; `SETUP.md` §8 now leads with pulling and treats
building as the customization path.

macOS images are deliberately not published: a RunnerVM macOS image is a provisioned copy of
Apple's macOS, and Apple's SLA grants the right to run macOS VMs on Apple hardware, not to
redistribute macOS. Each host builds its own from `ghcr.io/cirruslabs/macos-tahoe-base:latest`
with `scripts/provision-macos-tart.sh`, as before.

## 2026-08-28 — `host.overcommit.disk`

Admission reserves `max(profile.resources.disk, image.virtualBytes)` — the guest disk's **apparent**
size — while an instance disk is an APFS clone of the image that starts at nearly zero additional
bytes and only grows as the job writes. For Linux the gap is nil (a 16 GiB image really is 16 GiB).
For macOS it is large and permanent: the Tart-derived image is 50 GB apparent against 30.6 GiB
allocated, and the exact-size rule forbids a profile asking for less. Measured on the development
Mac, a full macOS job left free disk unchanged at 83 GiB — the reservation was the only thing that
could not fit.

`host.overcommit.disk` is the opt-in, alongside the `cpu` and `memory` ratios that already existed.
It scales the post-floor disk budget; the floor is subtracted first, deliberately, because the
reserve is the space macOS and the daemon's own logs need. Default 1.0 keeps admission fail-closed
against a guest that really does write every block, and `config validate` warns whenever it is
raised (`HOST_DISK_OVERCOMMIT_ENABLED`).

`runnerctl status` grows a `Disk overcommit` row **only when the ratio is not 1.0** — a host
admitting more disk than it has should not require reading the configuration file to discover, and
a row reading "1.0x" on every host would train the eye to skip it.

`CapacitySummary.diskOvercommit` decodes leniently, so a payload from a daemon that predates the
field still parses as "no overcommit".

## 2026-08-28 — first headless deployment (Mac mini)

Deploying onto a Mac with no GUI login session — the configuration the LaunchDaemon variant and
any unattended host actually run in — found five defects that the development Mac could not.
Evidence, host layout and the full list of what was and was not tested:
`docs/verification.md` "Mac mini deployment".

- **Free space read as 0 in any session without a login window, so the daemon advertised
  `capacity=0` and never scheduled a VM.** `APFSClone.freeSpace` used only
  `volumeAvailableCapacityForImportantUsageKey`; that figure is produced by a per-login-session
  service and is 0 where there is none — measured on macOS 26.5.2 as 0 against 70 GiB of real free
  space, while the same host's `volumeAvailableCapacity` was correct. The daemon came up in
  permanent `critical` disk pressure. It now falls back to `volumeAvailableCapacityKey`, which
  undercounts purgeable space — the safe direction for an admission check — and
  `runnerctl doctor` reads the same function instead of the volume keys a second time, so
  doctor's "Disk headroom" line and the daemon's own accounting can no longer disagree.
- **The in-daemon image builder never received the applied configuration**, so the whole `build:`
  block was ignored and `host.reserve.disk` stayed at its 50 GiB default: every build on a host
  configured for a smaller floor was refused with `IMAGE_INSUFFICIENT_DISK_SPACE`.
  `updateConfiguration` is now part of `ImageBuildService` and is called wherever `images`,
  `instances`, `gateway` and `orchestrator` are updated. It has no default implementation on
  purpose: a protocol-extension no-op outranks the actor's own method at a concrete call site, and
  the version that had one silently disabled the build harness's own configuration.
- **`scripts/provision-macos-tart.sh` could never verify its staged payload over password SSH.**
  The H1 payload check compared raw `ssh` output, and without `--ssh-key` that output carries the
  pty's own `password:` prompt, so the comparison failed with all four digests visibly identical.
  Only digest lines are compared now.
- **`runnerctl status` always claimed "Scale sets: 0 healthy"** — `Mapping.github` hardcoded the
  figure — while `scaleset list` reported the same scale set `ready`/`open`/`ok`. It is now
  counted over the rows `scaleset.list` renders.
- **Disabling a profile did not close its scale-set message session**, so a daemon went on polling
  — and answering job messages — for a profile it no longer runs. A scale set has exactly one
  session, so the effect is cross-host: a second daemon whose profile had been disabled took the
  session back at the first host's next restart and captured its job
  (`HTTP 409 RunnerScaleSetSessionConflictException` on the host that should have had it).
  `ScaleSetDemandProvider.refresh()` now retires sessions whose profile is no longer enabled,
  cancelling the poll task before closing the session — closing first only lets `ensureSession`
  open a fresh one on the next poll.

Also documented, because nothing enforced it: **profile names must be unique per scope across
hosts** (`docs/install.md`, "One host per profile name, per scope").

Known and unfixed, found by the same deployment: `scripts/qualify-macos-image.sh` cannot qualify an
ephemeral profile whose scale set is live and idle — the scheduler correctly scales the instance
the script creates with `vm create` away before the guest agent connects, so `cold_boot_to_idle`
can never pass as written.

## 2026-08-28 — macOS hardening pass (H1–H2)

The runtime from M8.0–M8.4 works; this pass makes its bad states impossible rather than adding
features. Nothing here is a new capability, and none of it is qualified as production-ready until
the H3–H5 live runs below are recorded.

- **Sealed macOS images no longer carry `admin`/`admin` or SSH.** The Tart base image ships a
  well-known administrator with Remote Login on, which every clone would otherwise inherit and
  offer to whatever can reach the guest's NAT address. `scripts/provision-macos-tart.sh` now ends
  with a seal-time lockdown (`STAGE=harden`): the build account's password is rotated to a
  discarded 64-character random value, every `authorized_keys` is removed, `com.openssh.sshd` is
  disabled persistently, and the old credential is *proved* rejected (`dscl . -authonly`) before
  the guest halts. The build fails unless the guest reports an `RVM-HARDEN-V1` block.
  `--debug-ssh` opts out and records `capabilities.ssh: true` in the sealed metadata.
- **`resources.disk` on a macOS profile must equal the image's own disk, exactly.** The host
  truncates `disk.img` up before boot and the *guest* is what turns that into filesystem, which a
  macOS guest cannot do (`agent.resizeDisk` answers `NOT_SUPPORTED` on darwin). A profile asking
  for more was silently advertising capacity the job never received; it is now
  `VM_MACOS_DISK_RESIZE_UNSUPPORTED`, refused in `plan` before any row or clone exists. Asking for
  less is refused there too, rather than by `InstanceStore.materialize` after the row exists.
- **`PROFILE_NAME_SHADOWS_HOSTED_LABEL` is an error, not a warning.** A profile named `macos-26`
  sends jobs to GitHub's hosted runners — different billing, secrets, network, toolchain and
  caches, with nothing on this host to show for it. `allowHostedLabelShadowing: true` is the
  explicit opt-out and leaves a warning behind.
- **The machine identifier is written durably.** `DurableFile.atomicReplace` (unique `O_EXCL`
  temporary, write-all with `EINTR` handling, `fsync(file)`, `rename`, `fsync(directory)`) replaces
  the previous write-fsync-rename. Losing that file makes the next boot mint a *second* virtual Mac
  against auxiliary storage bound to the first, so the directory `fsync` is not academic.
- **A forced `tart stop` can no longer produce an image.** A forced stop is a power cut and leaves
  APFS merely crash-consistent; the build now fails unless `--allow-dirty-seal` is passed.
- **The guest-agent LaunchDaemon fails closed.** `plutil -lint`, `root:wheel:644` ownership and
  `launchctl bootstrap`/`enable`/`print` are all fatal in the guest, and a self-check reporting
  `launchd_loaded=no` fails the build. "The agent cannot connect" stays tolerated — there is no
  vsock peer during provisioning — but "the LaunchDaemon cannot load" does not.
- **A second fence on the two-guest ceiling.** `MacOSGuestSlot` takes an `fcntl` lock on
  `<runtime>/macos-slot-N.lock` inside `vmworker` itself and holds it for the process's life, so
  the limit holds even when runnerd is not what started the worker. The kernel frees the slot when
  the worker dies.
- **The Tart bootstrap payload is content-verified.** The guest agent binary, the LaunchDaemon
  plist, the in-guest provisioning script and the runner tarball are hashed on the host, read back
  through the guest's own `shasum` after the copy, and verified again before installation — the
  SSH transport into a throwaway NAT VM is not an authenticated channel, so the content carries
  the trust.
- **macOS image sizing floors are mandatory** (`VM_MACOS_IMAGE_MINIMUMS_MISSING`), and the
  provisioner refuses a tart `config.json` with no `cpuCountMin`/`memorySizeMin`. Without them the
  first real compatibility failure lands inside a worker, after a clone and a boot.
- **`scripts/qualify-macos-image.sh`**: an image is valid because RunnerVM cold-booted a clone of
  it, not because the build script finished. Import → create → cold boot → agent handshake →
  `agent.metrics` → `exec sw_vers` → LaunchDaemon loaded after a real boot → TCP/22 closed,
  `com.openssh.sshd` disabled, `admin/admin` rejected → destroy → no leftovers → image digest
  unchanged. JSON report; `--allow-ssh` for `--debug-ssh` images.
- **`scripts/live-macos-e2e.sh` + `scripts/lib/live-macos.sh`**: the H3–H5 driver. Concurrency
  (two guests, a third job queued, distinct machine identifier / MAC / auxiliary storage sampled
  while both are running), a recovery matrix (runnerd restart and `SIGKILL` at each state), and a
  soak — each ending in the same invariants: no GitHub runner, no non-terminal session, no
  capacity-consuming instance, no instance directory, no `vmworker`, both macOS slots free, image
  digest unchanged.
- **A profile whose instances fail to boot is held down.** `create` only throws for failures
  *before* the row exists; a boot failure — a macOS hardware model this host cannot run, say —
  reports itself by leaving the returned record in a failed state, which the orchestrator ignored.
  A permanently broken image therefore meant a full disk clone and a dead VM on every tick, for
  ever. `InstanceState.isFailedStart` now feeds the same hold-down a thrown `create` already used.
- Guest diagnostics are OS-aware: a macOS guest has no journal and no systemd unit, so the
  collection script branches on `uname -s` and reads `/var/log/runnervm-guest-agent.log` plus
  `log show`/`sw_vers` instead of `journalctl`/`dmesg`. A `context.json` beside the archive ties it
  back to the profile, image and host. The image now ships a `newsyslog.d` drop-in so the agent log
  is bounded.
- 1375 Swift tests / 174 suites; 4 bash unit-test suites in CI (two new).

## 2026-08-28 — macOS guests, runtime milestone (M8.0–M8.4)

- macOS is a guest platform now: `MacOSVMPlatform` builds `VZMacOSBootLoader` +
  `VZMacPlatformConfiguration` from the image's opaque hardware model (`isSupported` checked, typed
  `VM_MACOS_*` errors), the per-instance auxiliary storage and a per-instance
  `VZMacMachineIdentifier` (`machine-identifier.bin`, minted by `vmworker` after taking the worker
  lock, reused across restarts, never sealed into an image). One 1920×1080 virtual display, no window.
- `spec.json` gains an optional `macos` block (`MacOSInstancePlatformSpec`); image metadata records
  `minimumCPUCount`/`minimumMemoryBytes` and admission refuses undersized profiles before any row
  or clone exists. Tart imports carry `cpuCountMin`/`memorySizeMin` into those fields.
- `os: macos` profiles validate (`HostConstants.supportedGuestOS`); `lifecycle: reusable` is refused
  for macOS (`PROFILE_MACOS_REUSABLE_UNSUPPORTED`); the 2-guest cap is documented as Apple's license
  allowance / supported operating model, not a framework error. `runnerctl image import
  --hardware-model` for Tart-derived disks.
- `scripts/provision-macos-tart.sh` + `scripts/lib/macos-{guest-provision,provision-vm}.sh`: one-shot
  SSH provisioning of a Tart macOS base into a RunnerVM image (runner account, guest-agent
  LaunchDaemon, sha256-verified `actions/runner` osx-arm64, CLT, empty git credential helper as
  `runner`, sealed `metadata.json`); 57 bash unit tests in CI.
- New validation `PROFILE_NAME_SHADOWS_HOSTED_LABEL`: a profile named like a GitHub-hosted label
  (`macos-26`, `ubuntu-24.04`, `windows-2025`, `*-latest`) sends jobs to GitHub's runners, not
  yours. Landed as a warning; promoted to an error in the hardening pass above.
- Live on this host (see `docs/verification.md` "M8"): Tart `macos-tahoe-base` (26.6.2) boots under
  `vmworker`, restart keeps its identity, guest agent over vsock, one GitHub JIT job on
  `rvm-macos-26` with a 23 s cold start and the VM removed afterwards. Still open: two concurrent
  macOS guests + third job waiting (blocked by free disk on the dev host), recovery/soak (M8.5),
  native IPSW builder (M8.6).
- `ReusableLifecycleTests`: the last polling waits are event-driven (`awaitInstance`); this was the
  `a771905` CI flake.

## 2026-08-27 — Production hardening pass (`74ecb12` … see `docs/verification.md`)

- Deterministic teardown ordering (`interrupt` writes the row before dropping the guest;
  instance row before session row); event-driven test waits; the master CI flakes are gone.
- Runner sessions survive a `runnerd` restart: persisted non-terminal sessions are re-observed or
  closed out (`RunnerSessionRecovery`, `DAEMON_RESTART`), never re-issued a JIT config;
  `runnervm_sessions_recovered_total`.
- Image-build recovery keeps capacity, pin and directory until the builder worker is proven dead
  (`OrphanVerdict`, schema v3 `recovery_since`, `BUILD_RECOVERY_ABANDONED`,
  `runnervm_image_builds_recovery_pending`); `build cancel` refuses to release a live worker.
- Build contexts are packed with a NUL-delimited `tar --null -T` list; adversarial tests inspect
  the archive.
- `lifecycle: reusable` requires `reuse.acknowledgeSharedHost: true`; the guest agent restores
  HOME from a pristine snapshot between jobs (`HOME_SNAPSHOT_MISSING` fails closed).
- Bounded base-image cache (`build.cache.{maxBytes,minimumHostFreeBytes,maxEntries}`, LRU, pins,
  atomic commit, `runnervm_image_cache_*`).
- `ARG` documented as non-secret; credential-shaped values refused (`BUILD_ARG_LOOKS_LIKE_SECRET`);
  `build show` prints args; `docs/design/build-secrets.md`.
- `runnervm_github_requests_total{class}` wired; retried GitHub/Actions calls are logged;
  `PROFILE_TIMEOUT_CLONE_IGNORED`; cancellation-aware `BuilderWorker` loops; provenance audit.
- Builder fault-injection harness (`BuildHooks`, `ImageBuildFaultInjectionTests`,
  `scripts/live-builder-faults.sh`); live scripts `live-builder-e2e.sh`, new e2e scenarios,
  `debug.scaleSetReconnect`, `GitHubFaultTests`.
- Doctor: `service_user_ownership`, `runtime_dir_perms`, `free_memory`, `image_store_integrity`
  (`--deep`), `guest_agent_image`, `build_tools_service_context`; `qualify-host.sh` coverage.
- Found live: `system drain --wait` exited 1 on an idle host (fixed); restart-terminalized
  sessions kept their VM running (fixed); e2e long job ignored cancellation (fixed).

## 2026-08-27 — M14 tart import, M15 in-daemon image builder (`9d66361`, `0c15077`)

- Read-only import of tart OCI images (`runnerctl image pull ghcr.io/cirruslabs/…`); `--format`
  flag; `IMAGE_NO_GUEST_AGENT` guardrail for agent-less images; `image inspect` shows source and
  guest-agent presence; doctor `profile_image_guest_agent`.
- `runnerctl image build` with Dockerfile-syntax `Runnerfile` recipes, executed inside `runnerd`;
  `runnerctl build list|show|log|cancel`; `status` builds line; doctor `build_tools`,
  `build_guest_agent`, `build_recipes`; eight shipped recipes under `images/recipes/`.
- `QCOW2Reader` (qcow2 → sparse raw), cloud-init bootstrap seed, tar-in-ISO build context,
  `AdmissionQueue`, `BuilderWorker`, build reconciler with seal replay.
- Schema v2: `image_builds`, `image_aliases`; `Persistence.currentSchemaVersion` is the single source
  of truth (the v1 migration used to record the current version instead of `1`).
- Hardening: `ArtifactLimits`, bounded LZ4 decompression, vmworker `hardDeadline` no longer pre-empted
  by a live lease, `GuestAgentClient.waitUntilReachable`, `image import --no-guest-agent`.
- `install.sh` ships the guest agent, recipes and build directories; new `docs/image-build.md`,
  `docs/status.md`; `docs/images.md` marked legacy.
- First fully green CI run on `master` (run 33063743404).

## 2026-08-26 — Live end-to-end, autoscaling, production-readiness reviews (`b9ab328`…`10fab37`)

- Repository Runner Scale Set on GitHub.com: JobAvailable → ephemeral VM → JIT → job → VM destroyed.
- Parallel jobs honour advertised capacity (`fanout=5` on a 3-VM host).
- Two readiness-review rounds: Swift 6.1 strict-concurrency fixes, `GUEST_OS_UNSUPPORTED`, worker
  environment allowlist, `SecureFile` secrets, `RunnerVersionMonitor`, image provenance in the
  host-script builder, structured logging with rotation and external shippers, host qualification
  script, live-integration driver.

## 2026-08-25 — M0–M13

- Package skeleton, spikes (signed bare-binary vmworker boots Ubuntu; worker survives daemon crash).
- Core domain, SQLite persistence, daemon + CLI over JSON-RPC/UDS, vmworker + Linux VM engine,
  Go guest agent over vsock, content-addressed image store, host-script Ubuntu image builder,
  JIT runner sessions, scale-set demand provider + orchestrator loop, resource scheduler,
  OCI/GHCR transport, warm pool, reusable VMs, GitHub App auth, drain/metrics/packaging.
