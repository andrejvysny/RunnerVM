# TODO

## Now

- [ ] `scripts/live-builder-faults.sh`: per-phase image alias (or scope the "≤1 image" check to the phase's `imageDigest`), treat unobservable warm phases as skipped, rerun `--phase booting --phase provisioning --phase sealing`, record in `docs/verification.md`
- [x] Confirm CI green for `a771905` — flake, rerun green (see M8.0)
- [ ] LaunchDaemon + reboot qualification (operator-driven; skipped 2026-08-27). Now also blocked on `sudo` for the Mac mini — the plist is rendered at `/Users/blackpen/com.runnervm.runnerd.daemon.plist` and lint-clean, and the keychain objection to this variant did not reproduce on macOS 26.5.2 (see the deployment section below)


Plans: `~/.claude/plans/act-as-senior-swift-calm-cherny.md` (M0–M13) and
`~/.claude/plans/act-as-senior-swift-ticklish-garden.md` (M14/M15). Current state: `docs/status.md`.

## D — Distribution hardening (started 2026-08-28)

Plan: `~/.claude/plans/act-as-senior-swift-federated-willow.md` (approved; decisions locked there).
Goal: one-command curl install on a fresh Apple Silicon Mac — pkg, wizard, headless LaunchDaemon,
GHCR pull-only Linux, native managed macOS provisioning, auto image updates, per-VM CI keychain,
manual `runnerctl upgrade`. Version source of truth becomes `RunnerVMVersion.current = "0.2.0"`.

- [x] D0 contracts: `docs/design/distribution.md`, LICENSE (Apache-2.0), status pointer
- [x] D1 operator plumbing: `RunnerPaths.resolve` (+`RUNNERVM_SOCKET`), root allowed on RPC,
      `Version.swift`, `runnerctl --version`, atomic token write, doctor `skip` status +
      service-mode/filevault/reboot-persistence checks, launchd README tier flip, dscl-only
      service account in install.sh
- [x] D2 pkg: `scripts/build-package.sh`, `packaging/pkg/`, release-manifest.json, tests
- [x] D3 `.github/workflows/release.yml` (tag == RunnerVMVersion gate, pkg install smoke, gh release)
- [x] D4 `scripts/bootstrap.sh` (published as install.sh) + `Sources/HostSetup` + `runnerctl setup`
      (wizard, dscl account, launchd, PAT, pull, profiles-last flow, dry-run) + tests
- [x] D5 publish-images.yml (self-hosted) + docs; first `ubuntu-24-base:stable` publish = user step
      (operator-run: registry login, dispatch/schedule, make public + connect repo — unexecuted)
- [x] D6 `ImageUpdateService` + schema v4 `managed_images` + promoted-digest resolution +
      `image update check|run|status` + retention (keepPrevious)
- [x] D7 native managed macOS provisioning: `ImagePullPurpose.provisioningBase`,
      `image_builds.kind = macosProvision`, `MacOSProvisionStages`, DHCP-lease IP, script
      `--attach` mode, qualify-then-promote via alias
- [x] D8 pinned maintenance instances (`purpose`/`pinned_until`, orchestrator exemptions, TTL
      reaper) + `runnerctl system smoke-test` + fix qualify-macos-image.sh (H2) + move shared
      helpers into lib/live-common.sh (live-macos-e2e.sh bug). D8b: `HostSetup` target +
      `SmokeTest` (reusable, tested against a fake daemon) + `doctor --deep`'s `smoke_test` +
      qualify-macos-image.sh `--pinned` + the seven (+`runnerd_pid`) helpers moved to
      lib/live-common.sh
- [x] D9 guest CI keychain (Go + Swift selfTest wiring done; live e2e workflow pending docs sweep): `GuestAgent/internal/keychain`, startRunner fail-closed env,
      `agent.selfTest`, capability, Proto + Swift DTOs, e2e keychain job
- [ ] D10 `runnerctl upgrade` (--check/--version, drain, backup, rollback-if-schema-unchanged)
- [ ] Docs sweep: README/SETUP/install/qualification/macos-guests/published-images/release/
      status/CHANGELOG/AGENTS/Proto
- [ ] Hardware/live matrix (user Macs): blackpen pkg install + wizard + reboot loop + upgrade;
      dev Mac managed macOS build/qualify/promote + keychain e2e; release v0.2.0 + curl e2e

## Mac mini deployment (2026-08-28) — follow-ups

First deployment onto a host that is not the development Mac, and the first headless run (no GUI
login session). Evidence, host layout, and the full tested/skipped list: `docs/verification.md`
"Mac mini deployment". Five defects found and fixed there; what is left:

- [ ] **Persistence on the Mac mini.** `runnerd` runs as a detached foreground process and does not
      survive a reboot. Needs `sudo` to install `/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`
      (already rendered on the host) and `launchctl bootstrap system`.
- [ ] **Dedicated `_runnervm` account/group on the Mac mini.** The daemon runs as `blackpen` with
      `--group staff --allow-staff-group`, mitigated only by a hand-set `0700` state directory on a
      machine with three other `staff` accounts. Fix when root is available.
- [ ] **`runnerctl doctor`'s `Login keychain` check is a false negative on macOS 26.5.2** — it fails
      while every VM starts fine headless. Decide whether it should warn, probe for the condition it
      actually cares about, or be dropped; do not leave a permanent red FAIL on a healthy host.
- [x] **`scripts/qualify-macos-image.sh` cannot pass as written** (H2) — fixed by `vm create --pinned` (D8); see the M8 section.
- [ ] **macOS guests do not fit on the Mac mini** (~20 GiB short; the reservation is the image's
      full 50 GB and a macOS guest cannot resize its APFS container). Either free the space, or
      produce a smaller macOS image, or accept Linux-only there.
- [ ] Consider making the free-space fallback visible: the daemon now silently uses a less accurate
      figure on a host with no login session. A one-line startup log ("purgeable-aware free space
      unavailable; using volumeAvailableCapacity") would save the next person the same hunt.
- [ ] **`runnerctl` cannot reach a production daemon without `--socket` on every call.**
      `GlobalOptions.socketURL` falls back to `RunnerPaths.development(...)`
      (`/tmp/runnervm-<uid>/runnerd.sock`) and there is no environment variable, so every command
      against a real install (`--runtime-dir /var/run/runnervm`) needs the flag spelled out.
      `SETUP.md` works around it with a shell function. Options: honour a `RUNNERVM_SOCKET`
      environment variable (the live-e2e scripts already use that name), read the runtime dir from
      an installed config, or probe the production path before falling back to the development one.


## M8 — macOS guests (started 2026-08-27; runtime first, native IPSW builder last)

Roadmap from the M8 review (kept in the session prompt; summarized in `docs/macos-guests.md`).
Assumed answers to the review's open questions (review's own recommendations): first milestone =
A (prebuilt/Tart image runs a GitHub job); Tahoe 26 only; host macOS ≥ 15; GitHub.com; macOS v1
ephemeral-only; no Xcode/simulators/signing in the first image; no GUI; `minIdle: 0`; runner
auto-update disabled.

- [x] M8.0 baseline: `a771905` CI failure was a flake (`ReusableLifecycleTests` idle poll, rerun green); idle waits made event-driven (`awaitInstance`)
- [x] M8.1 identity plumbing (1338 tests green): `ImageMetadata.MacOSPlatform` minimums · `MacOSInstancePlatformSpec` · `VMInstanceSpec.macos` / `InstanceSpecFile.macos` · `VMRuntimePaths.machineIdentifier` + `VMInstanceLayout.machineIdentifierName` · `MacOSMachineIdentity` (load/create after lock) · `VMError` macOS cases · admission CPU/memory-vs-image checks · Tart `cpuCountMin`/`memorySizeMin` mapping · tests
- [x] M8.2 (code landed, 1354 tests; LIVE: Tart macos-tahoe-base 26.6.2/25G83 booted under vmworker 2026-08-27, ssh ok, serial from our machine id) `MacOSVMPlatform` (`VZMacOSBootLoader`, `VZMacPlatformConfiguration`, `isSupported` check, one 1920×1080@80 display, no window) · `supportedGuestOS += .macos` · `PROFILE_MACOS_REUSABLE_UNSUPPORTED` · live: Tart `macos-tahoe-base` imported + boots under vmworker
- [x] M8.3 (LIVE 2026-08-27: provisioned Tart base, imported `macos-26-base`, agent over vsock) guest agent over vsock in macOS (provision Tart image over SSH: `runner` user, darwin guest-agent + LaunchDaemon, actions/runner osx-arm64, `git config --global credential.helper ""` as runner) · hello/health/guestInfo · `startSession`
- [x] M8.4 (LIVE 2026-08-27: run 33118688632 on `rvm-macos-26`, 23 s cold start, VM removed after job) (`runs-on: [self-hosted, macos, arm64]`; `sw_vers`, `uname -m`, checkout)
- [ ] M8.5 (restart-keeps-id proven; 2-VM test blocked by disk: needs ~95 GiB free) identity uniqueness across clones, restart keeps id, 2 concurrent + 3rd blocked by scheduler, crash/restart recovery, 100 short jobs, no leaks
- [x] M8 re-provisioned and re-proven on the hardened path 2026-08-28: image `macos-26` (`capabilities.ssh: false`, 46.6 GiB virtual / 30.6 GiB on disk), live GitHub JIT job run 33159698945 passed in 7 s, ~23 s cold start, `Darwin … RELEASE_ARM64_VMAPPLE`, guest agent loaded, clean teardown. Profile `rvm-macos-26` needs `disk: 50000000000` (bytes) — `47GiB` is rejected by the exact-size rule
- [ ] M8.6 native IPSW builder (`runnerctl image build-macos`), separate from the Runnerfile builder — **not started until H1–H6 below are done**; separate risk domain from hardening
- [x] validation: profile name shadowing a GitHub-hosted label (`macos-*`, `ubuntu-*`, `windows-*`, `*-latest`) — found live; now an **error** with `allowHostedLabelShadowing: true` as the opt-out (H1)
- [ ] docs: rewrite `docs/macos-guests.md` (graphics not an Apple requirement; 2-guest rationale = Apple license/framework operating model), `docs/status.md`, `CHANGELOG.md`

### M8 hardening pass (2026-08-28 review; H1–H6 before "macOS supported")

**H1 — security + correctness (minimum for public beta). Landed 2026-08-28.**

- [x] P0 seal-time lockdown: `STAGE=harden` in `scripts/lib/macos-guest-provision.sh` rotates the build account's password to a discarded 64-char random value, removes every `authorized_keys`, `launchctl disable system/com.openssh.sshd`, proves the old credential is rejected (`dscl . -authonly`), then halts gracefully. `--debug-ssh` opts out and records `capabilities.ssh: true`; the host refuses to seal without an `RVM-HARDEN-V1` block
- [x] P1 macOS disk contract: `resources.disk` must equal the image's disk layer exactly — `VM_MACOS_DISK_RESIZE_UNSUPPORTED`, thrown in `plan` before any row exists (`agent.resizeDisk` is `NOT_SUPPORTED` on darwin)
- [x] P1 durable machine-ID write: `DurableFile.atomicReplace` (unique `O_EXCL` temp, write-all with `EINTR`, `fsync(file)`, `rename`, `fsync(dir)`) under `MacOSMachineIdentity.create`
- [x] P1 no seal after a forced stop: `wait_for_guest_down` records `GRACEFUL_SHUTDOWN`; `require_clean_shutdown` fails the build unless `--allow-dirty-seal`
- [x] P1 LaunchDaemon fails closed: `plutil -lint`, `root:wheel:644` ownership, `launchctl bootstrap`/`enable`/`print` all fatal in the guest, and `launchd_loaded != yes` is fatal on the host
- [x] P1 hosted-label collision is an error (above)
- [x] **H1 payload check fixed 2026-08-28** — it could never pass over password SSH: `verify_staged_payload` compared raw `ssh` output, which carries the `expect` pty's own `password:` prompt, so the run died with all four digests visibly identical (`the staged payload does not hash to what this host sent`). Only digest lines are compared now. The check had never been run against the transport it defaults to
- [x] P2 second macOS-capacity fence: `MacOSGuestSlot` `fcntl` locks (`<runtime>/macos-slot-N.lock`) taken by `vmworker` itself, so the two-guest ceiling holds even without runnerd
- [x] P2 Tart bootstrap payload manifest: agent binary, plist, guest script and runner tarball hashed on the host, read back through the guest's own `shasum`, verified a third time before install
- [x] P2 macOS image minimums are mandatory (`VM_MACOS_IMAGE_MINIMUMS_MISSING`); the provisioner refuses a tart `config.json` with no `cpuCountMin`/`memorySizeMin`
- [x] P3 guest-agent log rotation: `newsyslog.d` drop-in installed into the image
- [x] P3 image circuit breaker: a bring-up that returns a failed record now holds the profile down (`InstanceState.isFailedStart`), so a permanently unbootable image is not re-cloned every tick
- [ ] P3 follow-up: mark an image/profile *unhealthy* until its digest or configuration changes, rather than only holding it down for `startHoldDown`

**H2 — image qualification (an image is valid because RunnerVM cold-booted a clone of it)**

- [x] `scripts/qualify-macos-image.sh`: import → create → cold boot → agent hello/health/guestInfo → `exec sw_vers` → TCP/22 unreachable → `admin/admin` rejected → destroy → report
- [x] re-provisioned image produced 2026-08-28 (`macos-26`, hardened; the old `macos-26-base` predated the lockdown)
- [x] **the script cannot pass as written — fix it, then run it.** Fixed by `vm create --pinned` (D8). First run 2026-08-28 against `macos-26`: `FAIL cold_boot_to_idle — instance reached deleted` after 11 s. Not the image: the clone booted normally and reached `waitingForAgent` in 6 s, then the scheduler correctly scaled it away because a `vm create` instance is surplus with zero confirmed GitHub demand (`instance.cancelled (demand dropped)`). The other four checks (teardown, no live instances, instance directory removed, image digest unchanged) passed. Needs `github.demand: manual`, a pin on the instance it creates, or a host mode that suspends scale-to-zero for the duration. Run it (H2's remaining "run pending") is still outstanding -- needs hardware

**H3–H5 — concurrency, recovery, soak (need hardware; 2-VM test still blocked on disk)**

- [x] `scripts/live-macos-e2e.sh`: concurrency (2 VMs + 3rd queued, unique identity/MAC/aux storage), recovery matrix (runnerd/vmworker kill at each state), soak, and the end-of-run leak invariants (GitHub runners = 0, non-terminal sessions = 0, live instance dirs = 0, vmworkers = 0, 2 macOS slots free, image digest unchanged)
- [ ] run H3 (2 concurrent + 3rd waits, then A finishes and C starts)
- [ ] run H4 (graceful restart and `SIGKILL` at each state)
- [ ] run H5 (100 short jobs, then 500 at concurrency 2 with fault injection)

**H6 — observability**

- [x] guest diagnostics collection is OS-aware (`/var/log/runnervm-guest-agent.log` + `log show` on darwin instead of `journalctl`/`dmesg`)
- [ ] single correlation key (job/session/instance/runner id) across host logs, `_diag` and guest-agent logs

Facts: Apple catalog latest for this host = macOS 26.6.2 (25G83), `mostFeaturefulSupportedConfiguration`
min 2 vCPU / 4 GiB; hardware-model base64 captured as a test fixture. `tart pull
ghcr.io/cirruslabs/macos-tahoe-base:latest` started 2026-08-27 (27.3 GB compressed; log in the
session scratchpad). Disk free at start: 74 GiB.

## M0 — Foundation + spikes
- [x] Package skeleton (all targets compile)
- [x] `Resources/vmworker.entitlements`, `scripts/sign-dev.sh`
- [x] `PROVENANCE.md`, `NOTICE`
- [x] `.swiftformat`, `.gitignore`, CI workflow
- [x] `vmworker probe --json` (HostCapabilities) — proves bare-binary signing
- [x] Go module skeleton `GuestAgent/`
- [x] S1: signed bare-binary vmworker boots Ubuntu 24.04 cloud image (EFI, NAT, main queue, `dispatchMain`), `requestStop` honored by guest ⇒ GO.
  Findings: (a) `swift test` rebuilds vmworker and strips the ad-hoc signature — always re-run `scripts/sign-dev.sh` before VZ runs;
  (b) `VZVirtualMachineConfiguration.validate()` needs the entitlement ⇒ validation only in vmworker (tests use `build(validate:false)`);
  (c) serial.log empty: Ubuntu cloud image kernel cmdline lacks `console=hvc0` ⇒ image builder must set it;
  (d) RESOLVED in M3: guest agent reports IPs (`192.168.64.x` NAT lease works); `vm ssh` now skips docker0/bridge interfaces;
  (e) qcow2→raw conversion done with lima-vm/go-qcow2reader (Apache-2) — reuse in `build-ubuntu-image.sh` instead of requiring qemu-img.
- [ ] S6: `actions/scaleset` Go oracle against test repo/org — **blocked: need org/repo + PAT from user**

## M1 — Core + persistence + daemon skeleton — DONE 2026-08-25 (445 tests; manual runnerd/runnerctl round trip OK)
- [x] RunnerCore: IDs, models, state machines (Instance, RunnerSession, HostMode), errors, RunnerConfiguration + validation, Paths, ByteSize/DurationValue/RetryPolicy (147 tests)
- [x] RunnerLogging: JSON handler + Redactor (23 tests)
- [x] RPC: framing, strict envelope, budgets, own accept loop + `getpeereid`, CLOEXEC, NIO UDS server/client (34 tests)
- [ ] Persistence: GRDB open (WAL/FK/busy_timeout), migrations v1 (spec §45 + C1 additions), repositories
- [x] ConfigLoader: YAML → DTO → RunnerConfiguration (21 tests; `ExampleConfig.example`)
- [x] DaemonAPI: full `Proto/daemon_api.md` catalogue + typed server/client (unimplemented methods answer `NOT_IMPLEMENTED`); Orchestration `DaemonRuntime` (lock, SQLite, host-id, `vmworker probe` + fallback, config apply, socket, reconcile tick); `runnerd --foreground` with SIGINT/SIGTERM; `runnerctl status|version|config init|validate|apply|get|profile list|show|scope list|show` (47 tests)
- [x] Persistence `GRDBConfigStore`: whole-document config apply in one transaction (upsert by name, absent ⇒ `enabled=0`, `operations` + `audit_events` rows)
- [x] S4: Swift↔Go golden fixtures (`Proto/fixtures/envelopes.json`) pass on both sides; cross-process Swift⇄Go socket test still TODO in M3
- [ ] Freeze worker fencing/handshake spec in `Proto/worker_protocol.md`

## M2 — vmworker + Linux VM + minimal capacity
- [x] VirtualizationCore: VMInstanceSpec (+hardDeadline, canonical ISO-8601 codec), SpecDigest, WorkerLock, LinuxVMPlatform, VMConfigurationBuilder, VMRuntime (main queue, KVO state), VsockBridge (POSIX relay)
- [ ] ImageMetadata
- [x] vmworker `run`: lock → socket → VZ; full worker RPC catalogue; lease; orphan policy; exit codes 0/64/65/75/76/77 verified on a real Ubuntu guest. Hidden helpers: `debug-call`, `prepare-nvram`.
  Findings: (a) BSD `accept(2)` inherits the listener's `O_NONBLOCK` — the relay must clear it; (b) relay sockets need `SO_NOSIGPIPE` or a vanished peer kills the worker; (c) `RunnerPaths.agentSocket` says `agent-<id>.sock` but Proto/worker_protocol.md says `vm-<id>-agent.sock` — worker implements the Proto name, RunnerCore needs fixing.
- [ ] WorkerSupervisor: spawn detached, fencing, reconnect
- [x] ImageStore + InstanceStore: content-addressed local images, clonefile + truncate, tmp→rename, worker.lock, sealer, retention sweep (34 tests); pins/reservations live in Persistence
- [x] Scheduler: HostBudget, CapacityCalculator (macOS cap 2, disk floor), DesiredCapacity (busy-over-idle, unbound cancellation), Allocator round-robin, StartupThrottle, SingleHostPlacement (58 tests)
- [x] `runnerctl image import|list|inspect|delete`, `vm create|list|show|stop|delete`; `status` reports real running VMs, image cache and reconcile counts
- [x] S2: `kill -9 runnerd` → vmworker survived (reparented to PID 1, own session), restart reconnected at the same generation and pid, instance stayed `waitingForAgent` ⇒ GO. No launchd fallback needed.
- [ ] S3 LaunchDaemon vs LaunchAgent; S5 clonefile bench; S7 macOS identity
- **M2 findings**: (a) RESOLVED: vmworker `run` now creates the EFI variable store when missing; (b) RESOLVED: `ImageReference.isValidProfileImage` accepts bare local names / `sha256:` digests; (c) `instances.image_digest` is a FK, so deleted-instance tombstones block image GC — `InstanceRepository.purgeDeleted(imageDigest:)` now clears them; (d) worst-case `disk_reservation_bytes` (profile size) makes a 20 GiB profile unschedulable on a Mac with ~9 GiB free.

## Incident 2026-08-26
- Go-agent subagent ran `agent.cleanup` against a live agent on the HOST (non-root, prod defaults): deleted `~/.npm`, `~/.yarn/cache`, `~/.nuget/packages`, `~/.gradle/caches`, uid-501 entries under `/private/tmp` (incl. session scratchpad: Ubuntu qcow2/raw disk, qcow2tool, codex output). Caches regenerable; codex output already integrated into plan.
- Fix landed by subagent: non-root ⇒ temp/home/docker sweeps disabled. Follow-ups DONE: host-safe-mode (cleanup/resizeDisk/shutdown refused unless `kern.hv_vmm_present`/DMI says VM, or `--allow-host-destructive`); OrchestrationTests `withHarness` cleanup (0 leaked dirs).

## M3 — Guest agent + Ubuntu image
- [x] Go `internal/rpc` framing server/client + `internal/vsock` (linux listener; darwin TODO) — fixtures pass
- [x] Go agent: all guest v1 handlers, runner Manager (setpgid, uid drop, JIT via env), exec stream, cleanup, resizeDisk (linux), darwin AF_VSOCK, systemd/launchd packaging, Makefile (70 tests)
- [x] GuestControl: `GuestMethod` catalogue, DTOs pinned to `Proto/guest_agent.md`, `GuestAgentClient` (actor, lazy reconnect, `waitUntilReady` 200ms→2s backoff), `FakeGuestAgent` test server (26 tests).
  Wired into the daemon: `waitingForAgent -> idle` on `agent.hello` + `health == ready` (`boot_id`/`agent_ready_at` persisted), `AGENT_READY_TIMEOUT` ⇒ `failed` (instance kept, `failure.json` written), reconnect re-handshake with `bootId` compare ⇒ `tainted` + `interrupted`.
  `instance.exec` (stream) / `instance.metrics` / `instance.sshInfo` + `runnerctl vm exec|metrics|ssh`.
  Findings: (a) the RPC terminal chunk carries no payload, so `agent.exec`'s `{exitCode}` is the last *payload-bearing* chunk before the empty `end:true` frame — same on the daemon side; (b) guest DTO timestamps stay RFC-3339 `String`, because `GuestMetrics` is forwarded verbatim by `DaemonServer`'s stock `JSONEncoder`, which would write a `Date` as a reference-epoch double; (c) a blank raw disk cannot be used to smoke-test agent readiness — VZ EFI finds no boot device and stops the VM ~50ms after `running`, so `VM_STOPPED_UNEXPECTEDLY` beats the deadline; an Alpine `virt` aarch64 ISO boots and idles, which does exercise it.
- [x] vmworker bridge socket: real guest agent behind it, verified over vsock on an Ubuntu 24.04 guest
- [x] `scripts/build-ubuntu-image.sh` (cloud-init NoCloud seed disk). `vmworker run` attaches `<instanceDir>/seed.img` as a read-only disk when present (`Run.swift buildConfiguration`); runner instances have none. `docs/images.md` documents build/contents/limits.
  Build: 127 s wall, virtual 12 GiB / allocated 3.2 GiB, Ubuntu 24.04.4 + docker-ce 29.7.2 + actions-runner 2.336.0 + guest agent.
  Findings: (a) systemd's getty on `/dev/hvc0` calls `vhangup(2)`, which kills cloud-init's already-open write handle — the build trace silently stopped at the login banner until `bootcmd` masked `serial-getty@hvc0.service`; (b) AF_UNIX's 104-byte cap means the worker socket dir must be short (`/tmp/rvm-build-<id>`), not nested under `--out`; (c) `hdiutil makehybrid -iso -joliet` preserves lowercase `user-data`/`meta-data` names and labels the volume `CIDATA`, so no mkisofs/genisoimage is needed — but the label case is not guaranteed, so the guest resolves it case-insensitively via `lsblk`; (d) `installdependencies.sh` probing `libicu80..75` before finding `libicu74` prints `E: Unable to locate package` and is harmless; (e) `runnerctl image import` does **not** read the sealed `metadata.json` — `ImageManager.importLocal` synthesises its own, so `runnerVersion`/`guestAgentVersion`/`capabilities` are lost on import.
- [x] `runnerctl vm exec|metrics|ssh` (`exec` streams live and exits with the guest's code; `ssh --connect` execs `/usr/bin/ssh`)
- [x] **§147 milestone proven end to end** (2026-08-26): `image import` -> `vm create` -> `idle` via the real guest agent over vsock -> `vm exec -- uname -a` / `docker info` / `id runner` -> `vm metrics` -> `vm ssh` -> `vm stop` -> `vm delete`.
  §102 timings: clone->running 120 ms, running->agent ready 5.4 s (2 vCPU / 2 GiB / 12 GiB profile); `vm stop` 3.6 s; import (hash 3.2 GiB) 4.9 s.
  M0 finding (c) closed: instance `serial.log` now carries the full kernel+systemd boot (376 lines) because the image appends `console=hvc0`.
  Open bug (not fixed here, other module): `runnerctl vm ssh` prints docker0's `172.17.0.1` instead of the NIC address — `GuestAgent/internal/system/system.go:132` sorts addresses lexicographically and `Sources/runnerctl/VMGuestCommands.swift:143` takes `.first`.

## Follow-ups from §147 e2e
- [x] `runnerctl image import --metadata <path>` + implicit adoption of the sealed `metadata.json` next to the disk (`SealedImageMetadata.swift`); `runnerVersion`/`guestAgentVersion`/`capabilities`/`provenance` survive the import, `image inspect` prints the provenance summary
- [ ] Rebuild the Ubuntu image after the guest-agent IP ordering fix (`vm ssh` printed docker0 address)
- [ ] Cross-process Swift⇄Go framing test in CI (currently only proven live)

## M4 — ImageStore proper — DONE
- [x] `image.prune` (pins + live instances + pending operations exempt; LRU under `maxSize`; staging sweep), `DiskPressureMonitor` (ok/warning/critical; create refused when critical), 5-min maintenance loop
- [x] Pin race fixed: `ImageManager.reserve` takes a `planning` pin inside the ImageManager actor before inspect; converted to `instance` pin after insert; released on failure; stale planning pins swept on first reconcile tick.

## M5–M13
See plan C2.
- [x] M5 groundwork: GitHubControl — HTTP client (timeouts, retry/Retry-After/rate-limit, error classes), PAT providers (env/file 0600/Keychain/chain), GitHub App JWT + installation token, REST JIT (repo/org), runners list/get/remove, runner groups, visibility guard, FakeGitHubServer (50 tests). Unverified against GitHub.com: repo-scope `runner_group_id: 1` requirement, 429 vs 403 for rate limits.
- [x] M5: `RunnerSessionManager` (row-before-JIT → jitRequested → jitIssued → jitDelivered → runnerStarting, `agent.runnerStatus` poll → runnerOnline/jobRunning → completed; every non-`completed` terminal calls `ensureRunnerRemoved` behind a `remove-runner` operation row retried by the maintenance loop), `agent.startRunner` secret delivery (lost reply recovered via `runnerStatus`, never retried), `job_summaries` on terminal, ephemeral teardown (stop + delete), `GitHubGateway` (one HTTP client, cached auth probe), `GitHubAuthFactory` (env/file 0600/keychain; `provider: app` reads `<stateDir>/github-app.json`), `ScopeHealthMonitor` (runner-group id, visibility, health at apply + 5-min loop, `unknown` after 3 unreachable passes), `runnerctl auth login|status|logout`, `runnerctl github test`, `runnerctl runner list|show`, `runnerctl debug run-jit <profile> [--wait]` (21 new tests, 608 total).
  Unverified against GitHub.com: everything above runs only against `FakeGitHubServer`. Needs a PAT + repo/org for: `generate-jitconfig` on a real org scope with a named runner group, the claim that GitHub auto-removes a JIT runner after its job (the happy path deliberately issues no DELETE), and `runnerctl debug run-jit --wait` against a queued workflow.
- [ ] M5 follow-ups: `runnerctl auth app` (writes `github-app.json`). (Reusable-after-one-job resolved by M11.)
- [x] M6/M7/M10 core: `DemandProvider` seam (`DemandEvent`, `DemandSnapshot`, `DemandProviderReport`) with `ManualDemandProvider` and `ScaleSetDemandProvider` (per-profile scale set `runnervm-<profile>`, one message session per scale set, durable inbox `intent -> processed -> deleted` + monotonic cursor, `AcquireJobs` on `JobAvailable`, `JobStarted`/`JobCompleted` correlation, replay + new generation on restart, jittered backoff, `X-ScaleSetMaxCapacity` from the orchestrator); `Orchestrator` actor (advertise -> `DesiredCapacity.compute` -> `Allocator` + `StartupThrottle` -> `InstanceManager.create`, cancellation of unbound reservations, `idleTTL` reaping, session hand-off with `jitSource = scaleSet`, per-profile start hold-down, `OrchestratorEvent` ring); `RunnerSessionManager.startSession(instanceId:origin:)` + scale-set JIT + scale-set-aware `ensureRunnerRemoved`; `GitHubGateway.scaleSetControlPlane()`; `scaleset.list` / `debug.demandSet`, `runnerctl scaleset list` / `runnerctl debug demand set`, `status` shows `demand / busy / idle / starting`; `FakeScaleSetControlPlane` (13 new tests, 665 total).
  Unverified against GitHub.com: everything scale-set-shaped runs only against `FakeScaleSetControlPlane` — see the live checklist below.
- [x] `GitHubConfig.demand: DemandMode` (`scaleSet` default) is now first-class config (`github.demand: scaleSet|manual`), mapped by ConfigLoader and read by `DaemonRuntime`; `Options.demandMode` remains only as a test/CLI override, and the old env-var escape hatch is gone.
- [ ] M6 follow-ups:
  - Warm-pool `idleTTL` reaping deletes stale idle VMs whenever the profile has no unserved demand; the replacement is started by the next tick. Still true after M11: `idleTTL` and `reuse.maxAge` are independent clocks.
  - `runner_sessions` has no `scale_set_id` column, so a scale-set session is correlated to a job only through `github_runner_name`; add the column if job-level attribution is needed.
- [ ] Live checklist for M6 (needs a PAT + org/repo, see open question 2):
  - `runnerctl scaleset list` shows a `ready` scale set, an `open` session and a moving cursor against a real org.
  - `X-ScaleSetMaxCapacity` is honoured: queue more jobs than the host can take and confirm GitHub stops assigning at the advertised number.
  - `AcquireJobs` partial results on a second host competing for the same scale set.
  - A JIT runner created with `generateJITConfig(scaleSetID:)` is picked up by the scale set and receives a job.
  - `ensureRunnerRemoved` through the scale-set API for a runner that never came online.
  - Restart runnerd mid-job: new session generation, no duplicate `AcquireJobs`, the running job survives.
  - Live integration: `scripts/live-github-e2e.sh` (`docs/live-integration.md`) — success/cancel-before-assignment/cancel-during-job/restart-while-booting/restart-during-job/redelivery/long-job/concurrent/queue-overflow scenarios against a real org/repo; scaffolded, not yet run.
- [x] M6 client: `ActionsScaleSetClient`/`ActionsMessageSession` ported from actions/scaleset v0.4.0 (MIT; PROVENANCE rows), `FakeActionsService` (92 GitHubControl tests). Endpoints/headers documented in `Sources/GitHubControl/ScaleSet/`; live verification pending (S6).
- [x] M6 orchestration: `DemandProvider` (manual + scale set: registration, sessions/generations, durable inbox, acquireJobs, JobStarted/Completed correlation, advertised capacity), `Orchestrator` tick (capacity → desired plan → round-robin/throttled starts → unbound cancellation → scale-set JIT session assignment → idleTTL reaping; per-profile hold-down), `runnerctl scaleset list`, `debug demand set` (667 tests). Live verification pending (S6).
- [x] `github.demand: scaleSet|manual` config model
- [x] M9 transport: `OCIRegistry` (reference, token/basic auth, credential chain incl. docker helpers/Keychain, manifest/blob client with ranged resume + chunked upload < 4 MB, RunnerVM artifact schema, LZ4 layerizer with sparse reassembly, `RunnerVMImageTransfer`, `FakeRegistry`; 66 tests; P9 portability round trip proven locally)
- [x] M9 daemon integration: `ImageManager.pull(reference:profile:)` / `push(imageRef:to:)` over `RunnerVMImageTransfer` behind an injectable `RegistryClientFactory`. Tag → digest via `inspect`, cached 5 min per reference; concurrent pulls of the same *manifest* digest share one `Task` and one `pull-image` operation (idempotency key `pull-image:<digest>`, spec §137) — the in-flight entry is published synchronously so two callers cannot both miss it. `host.limits.concurrentImagePulls` gates distinct transfers; free space minus `host.reserve.disk` must cover `transferBytes` first. Staging is `images/.tmp/pull-sha256-<hex>/`, resumable across restarts: `ImageManager.sweepStaging` replaces `ImageStore.sweepStaging` and spares any directory whose `pull-image` operation is still `running`. The in-flight row is keyed by the registry manifest digest (the local content digest does not exist until the bytes do); it becomes `invalid` on failure and is replaced by the content-keyed `ready` row on success. Profile `image:` registry refs resolve/pull inside `images.reserve(…, profile:)` before the `planning` pin. `image.pull`/`image.push` return `{operationId}` after resolving (so `REGISTRY_AUTH`/`REGISTRY_NOT_FOUND` still surface synchronously); `runnerctl image pull|push` wait on `operation.get` by default (`--no-wait`), `image.list` gains `canonicalReference`/`pulledAt`, `status` shows `Pulling`. `registry.login|logout|status` + `runnerctl registry …` (daemon-owned Keychain, `--local` for dev). `runnervm_image_pull_seconds{profile|registry}` observed. 14 new tests against `FakeRegistry`. Live GHCR verification with a real token still pending (S9).
- [ ] M8 macOS: blocked on disk (~27 GiB free; cirruslabs base images are 30+ GiB) — needs user to free space or provide an image
- [ ] Bug: `TimeoutPolicy.clone` (`RunnerProfileConfig.swift`) is parsed by `ConfigMapper` but never read anywhere in `Sources/Orchestration` — protects nothing today. Decide: wire into instance-provisioning deadline checks, or drop the field.
- [x] M11 reusable lifecycle: `InstanceManager.afterSession` (`InstanceReuse.swift`) is the single exit from a runner session. Ephemeral keeps the old behaviour (completed ⇒ stop+delete, failed ⇒ interrupted + `failure.json`). Reusable walks `busy → cleaning → idle` behind `agent.stopRunner` → `agent.cleanup(epoch: jobs_consumed)` → `agent.health == ready` → `agent.hello().bootId == instances.boot_id` → ≥10 % root headroom from `agent.getMetrics`, all inside `timeouts.cleanup`. Recycle triggers (spec §126): public-repository scope, `tainted`, `retire_after_session`, non-`completed` session with `recycleOnFailure`, `jobs_consumed >= reuse.maxJobs`, age ≥ `reuse.maxAge`; a recycle with a taint goes `cleaning → interrupted → deleting → deleted`, a planned retirement `→ stopping → stopped → deleting → deleted`. Taint vocabulary `TaintReason` (`CLEANUP_FAILED` / `AGENT_DEGRADED` / `UNEXPECTED_REBOOT` / `DISK_PRESSURE` / `SESSION_FAILED` / `DISK_LOST` / `MANUAL`). `InstanceManager.taint(id:reason:)` + `instance.taint` + `runnerctl vm taint <id> --reason` (audited `vm.taint`); idle ⇒ recycled now, busy ⇒ `retire_after_session`. `Orchestrator` never assigns a session to a tainted/retiring VM and removes idle ones on the next tick. §138: `config.apply` calls `retireOutdatedReusable()`, marking reusable VMs whose `image_digest` no longer matches the profile's resolved digest. §72: an idle/cleaning reusable VM whose worker dies is restarted once from its own disk (`interrupted → startingWorker → … → idle`, budget = `worker_generation <= 1`), then recycled. New `InstanceRepository.applyReuse(id:_:)` writes `tainted`/`taint_reason`/`retire_after_session`/`jobs_consumed` outside the state CAS. `vm show` adds lifecycle / age / jobs consumed / retire after session. 16 new tests (739 total).
- [x] M11 follow-up — `imageUpdates.recycleReusable` (spec §138) is real config now: `ImageUpdatesConfig` on `RunnerConfiguration` (lenient decode), DTO/mapper/schema rows; `InstanceTaint.retireOutdatedReusable` reads `configuration?.imageUpdates.recycleReusable` instead of the old `ImageUpdatePolicy` constant.
- [x] M11 follow-up — `reuse.maxRestarts` (default 1, validated 0-5, `PROFILE_REUSE_MAX_RESTARTS_INVALID`) replaces the `InstanceManager.maxReusableRestarts` constant; `restartInterrupted` resolves it per-profile, falling back to `ReusePolicy.default.maxRestarts` if the profile row is gone.
- [x] **Security gap, reusable lifecycle** (fixed): `agent.cleanup` used to only sweep an allowlist of cache dirs, never touching credentials a job's own build tooling might write outside it (`.gitconfig`, `.netrc`, `.npmrc`, cargo/docker/ssh/aws/gh/pypirc/m2 creds). Fix: `GuestAgent/internal/cleanup/home.go` — `SnapshotHome`/`RestoreHome` (stdlib `archive/tar`, no third-party deps) capture the runner's whole HOME once, before any job ever runs, and `agent.cleanup` now wipes+restores HOME from that pristine snapshot on every reusable-lifecycle pass, in addition to the existing cache/`_work`/`_diag`/temp/docker sweeps. Fails closed (`HOME_SNAPSHOT_MISSING`, not `{ok:true}`) if no snapshot exists. `Proto/guest_agent.md` documents the reset is wholesale (anything a job wrote under HOME is gone) and scoped to HOME only (files written outside it, e.g. via `sudo`, are untouched — reusable VMs are single-tenant by design). `ephemeral` lifecycle unaffected (disk destroyed every job).
- [x] M13 operations: host mode control + metrics. `HostModeControl` (CAS over `hosts.mode` + `audit_events` row) behind `system.drain {wait,timeoutMs}` / `system.resume` / `system.offline` / `system.shutdown {force}` and `runnerctl system drain|resume|offline|shutdown` (aliased `daemon`); draining advertises 0 and admits nothing while active sessions finish, `offline` drains first, shutdown without `--force` refuses while a job runs and leaves vmworkers alive (spec §108, §109). New `Metrics` module: `MetricRegistry` actor (counters/gauges/histograms, fixed seconds buckets, whole-label-set gauge republish), `MetricsSnapshot` DTOs, `PrometheusEncoder` (0.0.4 text). 25 families wired — lifecycle timings §41 from `InstanceCreation`/`InstanceManager`/`RunnerSessionObserver`, worker RSS/CPU §40 from `HostProcessMetrics` each tick, capacity/demand/reservations/disk gauges, session and failure counters. `metrics.snapshot {format}` + `runnerctl metrics [--format human|json|prometheus]`, and an optional loopback-only `NWListener` endpoint (`metrics.prometheus.enabled/listen`, `GET /metrics` + `/healthz`, non-loopback refused at startup). `runnerctl status` prints `Mode: draining (N active jobs)`. 39 new tests.
- [ ] M13 hardening leftovers: failure-injection matrix §99, launchd packaging; `runnervm_github_requests_total` is declared but unobserved (its call sites live in `GitHubControl`)

## Watch items
- A full `swift test` hung once for 43 min at 0 % CPU holding the `.build` lock (during concurrent agent builds); not reproduced in 6 later runs. If it recurs without concurrent builds, bisect the Orchestration/DaemonRuntime suites for a lost continuation.

## Open questions (need user)
1. LZ4 (assumed) vs zstd for disk layers
2. GitHub org/repo + PAT for S6/M5/M6
3. Naming: `runnerd`/`runnerctl`/`vmworker`, `com.runnervm`, `RUNNERVM_` (assumed); Go module path placeholder `github.com/runnervm/guest-agent`
4. Package lives at workspace root, `tart/` as sibling reference (assumed); repo not `git init`ed (user rule: no git ops unless told)
5. Auto-login service user acceptable if LaunchDaemon spike fails?
6. Reusable VMs needed at all?

## Production readiness review (2026-08-26) — tasks
All code tasks landed 2026-08-26 (921 Swift + 70 Go tests green). Still open: hardware runs of `scripts/qualify-host.sh`, live runs of `scripts/live-github-e2e.sh` (need org/PAT), a real vsock connect on the new completion-handler path (needs image on disk + signed vmworker), CI green on Swift 6.1.2 (unverified locally: dev host is 6.3.3).
- [x] T1 P0 Swift 6.1 vsock: `VZVirtioSocketConnection` never crosses a concurrency boundary (completion handler + dup inside callback)
- [x] T2 P0 macOS guests not advertised: drop example profile, `GUEST_OS_UNSUPPORTED` validation error, README/docs say Linux ARM64 only
- [x] T3 P0 live GitHub integration workflow scaffold (`scripts/live-github-e2e.sh`, `.github/workflows/github-integration.yml`, `docs/e2e/`, `docs/live-integration.md`) — NOT yet run: needs org/repo + PAT
- [x] T4 P0 Mac mini unattended-boot qualification script + docs (`scripts/qualify-host.sh`, `docs/qualification.md`, doctor `login_keychain` check) — hardware runs still pending
- [x] T5 P1 vmworker env allowlist + regression test
- [x] T6 P1 SecureFile reader (open+fstat, owner, 0600, no symlink) for PAT + GitHub App key
- [x] T7 P1 install.sh fails closed on codesign/entitlement verify
- [x] T8 P1 reproducible image builds: base/runner sha256, resolved versions, manifest, package list; `image import` keeps sealed metadata
- [x] T9 P1 runner-version freshness: HEALTHY/STALE/TOO_OLD/UNKNOWN in image list/status/doctor, optional admission deny
- [x] T10 P1 CI hardening: `permissions: contents: read`, checkout@v7.0.1 + setup-go@v7.0.0 SHA-pinned, no `|| true`, shellcheck + bash tests job, gofmt, go race, codesign/entitlement verify. swiftformat lint NOT enabled: tree predates `.swiftformat` (≈250 files) — run `swiftformat .` as its own commit, then add `swiftformat --lint .` to the lint job
- [x] T11 P1 external log persistence: in-process rotation, JSON sink, correlation fields, Vector/Fluent Bit example
- [x] T12 P2 docs sync (install.md drain, README scope)
- [x] T13 P2 dependabot (swift, gomod, actions)

## Readiness review round 2 (2026-08-26) — tasks
- [x] R2-1 `RunnerVersionPolicy`: 30-day window from the first missed release (`recentRunnerReleases`, `RunnerReleaseHistory`), regression test
- [x] R2-2 actions/runner digest from GitHub release asset metadata (`--runner-sha256` pin > asset digest > error/`--allow-unverified-runner`); `digestSource` recorded
- [x] R2-3 missing guest manifest fails closed (`--allow-partial-provenance` for dev; `provenance.partial`)
- [x] R2-4 service group default `_runnervm` (refuses `staff` without `--allow-staff-group`), `scripts/tests/install-test.sh`
- [x] R2-5 `SecureFile.ownerAndGroupRead` rejects `0o037`; `WorkerEnvironment` derives `HOME` from passwd; vsock connect closes the fd if cancelled mid-flight; `actionlint` in CI
- [x] R2-6 CI green on `master` — run 33063743404 (commit 0c15077, 2026-08-27): Swift 6.1 build+tests, shellcheck, guest agent all green. Timing-sensitive suites (`RunnerSessionTests`, `ReusableLifecycleTests`) still flake under CI load on some runs — de-flake candidate.

## Live end-to-end PROVEN (2026-08-26)
- Registered RunnerVM as a repo Runner Scale Set (`runnervm-ubuntu-24`, label `ubuntu-24`) on andrejvysny/RunnerVM.
- `.github/workflows/runnervm-selftest.yml` (`runs-on: ubuntu-24`) ran to SUCCESS on an ephemeral Linux VM: JobAvailable -> VM create -> guest agent -> JIT -> runnerOnline -> jobRunning -> completed -> VM destroyed. 12/12 steps green (uname/os, guest-agent active, docker info + `docker run alpine`, checkout, setup-go, `go build`+`go test`, summary).
- Two live bugs found + fixed this session:
  - `[x] R2-6` scale-set label was the prefixed scale-set name; GitHub keeps labels from creation, so `runs-on: <profile>` never matched. Fixed: label = profile name (`row.name`); `runs-on` = profile name in all workflows/docs (commit b9ab328).
  - `[x]` Swift 6.1 strict-concurrency: `VMRuntime.start/stop`, `ActionsMessageSession.withSessionRefresh<T>`, `ImagePulling.gated<T>`, `RegistryClient.mapTransportErrors<T>` sent non-Sendable values across isolation; fixed with completion handlers / `T: Sendable`. CI on Swift 6.1.2 was red for these; local dev host (6.3.3) did not flag them.
- `[x]` Builder rejects non-GPT/qcow2 base images early (`require_partition_table`); Ubuntu `cloudimg .tar.gz` is a bare rootfs that cannot EFI-boot — use the qcow2 `.img` converted to raw. Verified raw sha256 63cb4783… boots.

## Autoscaling proven (2026-08-26)
- Run 32999466546: `fanout=5` against a 3-VM host — GitHub assigned exactly 3 concurrently (advertised capacity honoured), RunnerVM ran 3 VMs in parallel, recycled them and booted 2 replacements for the queued legs; 5/5 jobs succeeded, all VMs deleted. Details in `docs/verification.md`.
- Swift 6.1.2-only CI failures fixed this session: non-Sendable sends (VMRuntime start/stop, `withSessionRefresh<T>`, `gated<T>`, `mapTransportErrors<T>`), `UInt64` tuple inference in OCIRegistryTests, `@Test` macro type-check timeout in ByteSizeTests, and a wall-clock-sensitive `waitUntilReady` test.
- macOS guests: milestone plan in `docs/macos-guests.md`; IPSW (macOS 26.6.2, build 25G83) downloading for the M8 build.

## M14 — Tart read-only importer + M15 — in-daemon image builder (plan approved 2026-08-26)
Plan: `~/.claude/plans/act-as-senior-swift-ticklish-garden.md` (Codex sol/xhigh review integrated; B1–B10, N1–N5 accepted).
- [x] P0 prerequisites: Migrator literal versions + public `Persistence.currentSchemaVersion`; vmworker `hardDeadline` before lease early-return; `ArtifactLimits` + bounded LZ4 decompressor; `GuestAgentClient.waitUntilReachable`
- [x] P1 Part A 1–2: `PlacedChunk`/`ChunkAnnotationKeys`; `ImageMetadata.Capabilities.guestAgent/labels`, `hasGuestAgent` inference, `Provenance.imported/recipe/parentImageDigest`; `image import --no-guest-agent`; golden-bytes digest test
- [x] P2 Part A 3–9 + N1: `TartVMConfig`, `TartArtifact`, `RemoteArtifact`, `inspect(require:purpose:)`, `TartImagePublisher`, `IMAGE_NO_GUEST_AGENT` guard, `--format`, inspect fields, doctor, docs, PROVENANCE
- [x] P3 `Sources/ImageBuild` (Runnerfile parser/planner/ignore/probe) + `ImageBuildTests` + `images/recipes/*`
- [x] P4 schema v2 (`image_builds`, `image_aliases`), `ImageBuildRepository`, `QCOW2Reader`, `ImageBuildConfig`+`images.limits`, `ImageBuildError`, Build DTOs/methods, `Reservation.imageBuild` + `AdmissionQueue`, `VMDirectoryStaging`/`BuildStore`, `Run.swift` context disk
- [x] P5 `Orchestration/Build/*`, `ImageSealing`, `DaemonServiceBuilds`, runtime wiring + drain, `BuildHarness` tests (crash matrix, concurrency, flood/stall)
- [x] P6 CLI `image build` / `build *`, `status` builds line, `install.sh` assets, docs, doctor checks.
  `runnerctl image build [<dir-or-Runnerfile>]` (`ImageBuildCommand.swift`): local pre-flight
  (`access(R_OK)`, `RecipeParser.parse` for fast `path:line:` syntax errors, daemon-socket-owner
  uid warning) before `image.build`; `--wait` (default) tails `build.log` to stdout + `[n/total]`
  progress to stderr (TTY-gated) over one connection, then prints the `image inspect` table.
  `runnerctl build list|show|log|cancel` (`BuildCommands.swift`, top-level `build` subcommand,
  named `BuildCommand` to avoid colliding with `Image.Build`). `SystemStatus.builds?:
  {running, queued}` (`BuildsSummary`, optional for wire compat) filled by
  `DaemonServiceSystem.buildsSummary()` from a new `DaemonServiceImpl.imageBuildRows` reading
  `ImageBuildRepository.list(states:)` directly (cheaper than decoding every `BuildInfoDTO`);
  `runnerctl status` prints `Builds: N running, M queued` only when the field is present.
  `scripts/install.sh`: builds/installs the guest agent (`make -C GuestAgent build-linux` when
  missing and Go is available, `--skip-guest-agent` to opt out) to
  `<state-dir>/guest-agent/linux-arm64/` + its systemd unit; copies `images/recipes/` to
  `<state-dir>/share/recipes/` (`root:<group>`, not the service user); creates
  `state/builds`, `cache/base-images`, `logs/builds`; 21 `scripts/tests/install-test.sh` checks
  (was 10). Doctor: `build_tools` (real `hdiutil makehybrid` smoke test), `build_guest_agent`
  (mirrors `BuildSeed.resolveAgent`'s config/env/rootDir precedence), `build_recipes`
  (`DoctorBuildChecks.swift`). New `docs/image-build.md`; `docs/images.md` now points to it and
  marks the host script legacy; `docs/install.md` gets the new assets + a one-way schema-v2
  upgrade note; `Proto/daemon_api.md` documents `BuildInfoDTO`'s shape and `system.status.builds`.
  1206 tests green (was 1203; +3 `SystemStatus.builds` DTO round-trip tests). Manually verified
  against a live `runnerd --foreground`: `image build` against a recipe whose local-image `FROM`
  does not exist yet fails clearly (`IMAGE_NOT_FOUND`) both with `--no-wait` (via `build show`)
  and the default `--wait` path (`runnerctl: IMAGE_NOT_FOUND: ...`, exit 1); `build list`/`build
  cancel`/`build show --output json` all behave correctly; `status` prints the builds line.
  Deviation: `BuildInfoDTO` has no `args` field (the persisted `argsJson` is never surfaced past
  `Sources/Orchestration/Build/BuildMapping.swift`, which was off-limits for this phase), so
  `build show` omits the `args` row the plan asked for rather than adding a wire field on the side.
- [x] P7 live (2026-08-27, dev host): bootstrap `ubuntu-24-minimal` 3m43s cold / 2m04s warm, derived `ubuntu-24` 1m16s, `vm create` → idle in 5s, tart import of `ghcr.io/cirruslabs/ubuntu:latest` + `--format runnervm` refusal + `IMAGE_NO_GUEST_AGENT` guardrail — see `docs/verification.md`. Not run live: GitHub job on the built image (no credential on host), restart mid-build, `--push` to a real registry, LaunchDaemon builds.
- [ ] M14/M15 follow-ups: `image list` NAME should prefer the alias (rebuilds show two rows named alike); `build show` lacks an `args` row (`BuildInfoDTO` omits `argsJson`); `config validate` only flags an agentless profile image once the *tag* has been resolved locally (canonical digest row only); RPC-level stream backpressure (Codex B9 follow-up); `scripts/install.sh` is 572 lines; consider `swiftformat .` as a standalone commit before enabling lint.

## Production hardening pass (2026-08-27) — plan `~/.claude/plans/runnervm-production-hardening-indexed-sun.md`
- [x] WP0 deterministic green CI (100× flaky suites clean; CI green): `interrupt` row-before-guest, instance-row-before-session-row in `markOnline`/`markBusy`, throwing `waitUntil`, event-driven `awaitSession`/`awaitInstance` over `LifecycleEventLog.subscribe()`; 100× flaky suites
- [x] WP1 (integration; live restart scenarios in run 2) runner-session recovery after restart (`RunnerSessionRecovery.swift`, `RunnerSessionReconciler`, startup call) + tests + live `restart-during-job-sigkill`
- [x] WP2 (integration) build recovery keeps capacity while worker death unproven (`OrphanVerdict`, `recovery_since` v3, hard bound, cancel path)
- [x] WP3 `BuildContextPacker` NUL-delimited `tar --null -T` + adversarial archive-content tests
- [x] WP4 (unit; not on a real VM) reusable guard (`reuse.acknowledgeSharedHost`) + guest-agent HOME pristine snapshot/restore + sentinel tests
- [x] WP5 bounded base-image cache (`build.cache.{maxBytes,minimumHostFreeBytes,maxEntries}`, LRU, atomic commit, metrics)
- [x] WP6 ARG = non-secret docs/help/refusal; `docs/design/build-secrets.md`
- [x] WP11 clone timeout deprecation warning, cancellation-aware BuilderWorker loops, GitHub request metric, provenance audit
- [x] WP8 builder fault-injection harness (in-process 20× clean; live kill -9 run: staging/booting/provisioning/sealing in flight at hand-off — rerun `scripts/live-builder-faults.sh --phase staging --phase booting --phase provisioning --phase sealing`) (in-process freeze + live kill -9 script)
- [x] WP7 builder→GitHub→GHCR live E2E (`live-builder-e2e.sh` 5/5 on 2026-08-27) — scripting done (`scripts/live-builder-e2e.sh`,
  factored `scripts/lib/live-common.sh` shared with `live-github-e2e.sh`); live run still pending
- [x] WP10 live GitHub lifecycle matrix: 11/11 scenarios pass live (long-job skipped on operator instruction); API faults integration-tested —
  scripting/tests done: `live-github-e2e.sh` scenarios `restart-while-runner-starts`,
  `restart-during-job-sigkill` (`--kill-cmd`), `scaleset-reconnect` (new `debug.scaleSetReconnect`
  RPC); `assert_no_leftovers` now also converges on `runnerctl status` capacity; 4 new
  `Tests/OrchestrationTests/GitHubFaultTests.swift` fault-injection tests (getMessage
  timeout/rate-limit, scale-set JIT 5xx, guest-startup failure). Live run against a real org/repo
  and hardware SIGKILL still pending.
- [ ] WP9 doctor/qualify checks DONE (hardware-verified on the dev layout); LaunchDaemon reboot qualification SKIPPED (operator decision 2026-08-27) — still open
- [x] Docs: status.md / verification.md / CHANGELOG / image-build.md / install.md / live-integration.md

## Homebrew packaging (2026-08-27) — plan `~/.claude/plans/act-as-expert-on-reflective-lightning.md`
- [x] `scripts/install.sh --prebuilt-dir <dir>`: consumes an already-built Homebrew-keg-shaped
  layout (`bin/runnerctl`, `libexec/{runnerd,vmworker}`,
  `share/runnervm/{Resources,recipes,guest-agent/...}`) instead of running `swift build`/`make -C
  GuestAgent build-linux`; every other step (signing, service account, state/runtime dirs,
  launchd) unchanged. Missing guest agent under `--prebuilt-dir` fails fast instead of trying to
  build from a source tree that isn't there. 10 new `scripts/tests/install-test.sh` cases (32
  total); shellcheck clean.
- [x] CI: `swift build -c release` step added (the formula runs exactly this).
- [x] Docs: `docs/install.md` "Installing via Homebrew" section + upgrade-procedure note,
  `docs/release.md` (manual tag → tap-formula-bump runbook, version scheme), README pointer.
- [x] Tap repo `andrejvysny/homebrew-runnervm` created (public) and pushed: `Formula/runnervm.rb`
  (builds from source + ad-hoc signs, `--prebuilt-dir`-compatible layout, `caveats` naming the one
  sudo command; `brew style` clean), `README.md`, `.github/workflows/tests.yml`.
- [ ] Formula still inert: `license` unset (repo has no `LICENSE` file, only `NOTICE` for the
  derived Tart code) and `tag`/`revision` are placeholders — no `vX.Y.Z` cut yet. `brew install
  andrejvysny/runnervm/runnervm` won't work until both are resolved; see `docs/release.md`.
