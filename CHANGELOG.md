# Changelog

Dates are when the work landed on `master`; see `docs/verification.md` for what was proven live.

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
