# RunnerVM — pre-release review, finish & hardening plan

Status: ready (approved 2026-09-01, adversarial review folded in 2026-09-02; plan file `~/.claude/plans/act-as-senior-swift-giggly-hamming.md`)

## Context

RunnerVM (Swift 6 `runnerd`/`runnerctl`/`vmworker` + Go guest agent) is feature-complete for
milestone D and tagged `v0.2.0` (2026-08-28). The user wants a senior review of correctness,
best practices and long-term quality, then a plan to finish and harden before the first
*real* release. This file accumulates findings first, then the plan.

## Established facts (verified 2026-09-01)

Repo / CI / release:
- `master` = `fad78a0`, clean, 0 ahead of origin. CI green on `fad78a0`.
- `v0.2.0` release EXISTS (pkg + sha256 + manifest + install.sh), cut from `d742a1c` — whose CI
  swift job FAILED (MetricsEndpointTests timeouts = cooperative-pool starvation). The fix is
  `fad78a0`, only on master. Released binaries ship the blocking-probe bug (HostSetup
  `CommandRunner`/`PortProbe`/`SmokeTest`, Orchestration `TCPPortProbe`).
- README.md and SETUP.md still say "v0.2.0 is unreleased"; docs/release.md says install.sh is
  "not yet a release asset". Docs drift vs reality.
- GHCR: nothing published under `ghcr.io/andrejvysny/runnervm/*` — README's
  `image pull ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable` cannot work today.
- `publish-images.yml` monthly schedule fired 2026-09-01 and sits `queued` forever: no
  self-hosted runner with label `runnervm-publisher` exists (repo has 0 runners).
- Dependabot PR #1 (upload-artifact 4.6.2 -> 7.0.1) open; its CI failed on the same flake.
- `.claude/worktrees/`: 8 stale agent worktrees + branches, ~10 GB, none merged (content landed via
  patches). Branch `fix/headless-deployment-defects` fully merged.
- swiftformat: 435/582 files differ from `.swiftformat`; lint not in CI.
- Go module path is still the placeholder `github.com/runnervm/guest-agent`.
- Size: 57k LOC Swift sources (Orchestration 27k), 34k LOC tests, 5.9k LOC Go, 7.2k LOC bash.
  Risk-pattern counts in Sources: 20 `@unchecked Sendable`, 1 `nonisolated(unsafe)`, 3
  semaphore/`.wait()`, 2 `Task.detached`, 2 `try!`, 1 `fatalError`.

Live host `blackpen` (Mac mini M4, macOS 26.5.2) — BROKEN since 2026-08-28 19:41:
- `/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist` installed, pointing at
  `/Library/Application Support/RunnerVM` + `/var/run/runnervm`; NEITHER directory exists.
- launchd: `runs = 70547`, `last exit code = 78`, `state = spawn scheduled` — crash loop every
  5 s for 4 days (load avg 2.5 on an idle box). KeepAlive=true + ThrottleInterval=5 + fatal
  config error = unbounded respawn.
- Binaries in `/usr/local/{bin,libexec/runnervm}` dated Aug 28 14:55, pre-D1 (no
  `runnerctl --version`), no pkg receipt, no `/usr/local/share/runnervm`. This is NOT the v0.2.0
  pkg; it is an older from-source install.
- `_runnervm` exists as uid 504 / gid 206 / home `/Users/_runnervm` — violates the
  distribution contract (uid 200–400, home under state dir, dedicated group).
- The old user-scoped layout (`~/.local/bin`, `~/runnervm`, repo clone) is gone.
- Two reboots on Aug 28 (18:41, 19:41) — a reboot qualification was attempted on a broken install.

## Findings from code review

### A. VirtualizationCore / vmworker / RPC / GuestControl (scout + own read)

Verdict: sound. Main-queue pinning, completion-handler VZ APIs, dup'd vsock fd, fcntl fencing,
strict envelope validation, in-flight budgets, idle timeouts all correct. Defects are small:

- `Run.swift:47-54` + `WorkerService.swift:74-92`: VZ start failure calls `exit(vzStartFailed)`
  without `teardown()` — sockets stay published, bridge/server not stopped. (low)
- `WorkerService.swift:205-221`: `performShutdown` exits 0 even when `forceStop()` throws. (low)
- `WorkerService.swift:283-295`: SIGHUP unhandled (setsid mitigates). (low)
- `WorkerService.swift:181-221` vs `Proto/worker_protocol.md:32`: `ShutdownRequest.reason`
  `drain`/`stop` behave identically; `stop` undocumented. (doc/code gap)
- `MacOSGuestSlot` limit and worker-lock-held both exit 75. (observability)
- `VsockBridge.swift:60-63`: UID-reject path silent + untested. (low)
- `DebugCall.swift:24-38`: semaphore blocking + unsynchronized box — debug subcommand only.
- `VMRuntime.swift:184-191`: NAT attachment disconnect is reported as `stoppedWithError` and
  resumes stop waiters while the guest may still run. (semantic, low)
- `VMConfigurationBuilder.swift:67-69`: root disk `synchronizationMode: .full` on ephemeral
  clones — correctness-safe but a perf knob candidate (`.none`/`.fsync` for ephemeral).
- `HelloResponse.agentBootId` documented but never populated.
- Coverage: no test exercises a real `VZVirtualMachine` (start/stop/KVO/delegate) or real
  vsock; `WorkerService`/`Run` have no tests beyond `WorkerPolicy`. Only live scripts cover it.
  Structural: GitHub-hosted macOS cannot nest VZ; needs a self-hosted signed lane.

### B. Orchestration / Scheduler / Persistence (scout, top items verified by me)

Verdict: architecture is right (SQLite truth, CAS transitions, AdmissionQueue, fencing,
cancellation-cooperative loops, saturating capacity math). Real gaps:

- **CONFIRMED** `InstanceReconciler.swift:69-80` `sweepRetired` reaps `.failed/.interrupted/
  .stopped` for `lifecycle == .ephemeral` only. A reusable instance that never reaches idle is
  never deleted: holds cpu/mem/disk reservation + image pin + directory forever; 30 s hold-down
  retry can mint more. (medium; reusable is opt-in)
- **CONFIRMED** `Build/RunProcess.swift:93-119` watchdog sends SIGTERM only, no SIGKILL
  escalation; `waitUntilExit` on a GCD thread blocks forever if the helper ignores SIGTERM
  (`expect`/ssh/hdiutil). Configured timeout not enforced end to end. (medium)
- **CONFIRMED** unenforced profile timeouts: `timeouts.imagePull`, `timeouts.jitGeneration`
  have zero read sites; `timeouts.vmBoot` only read by `debug.runJIT`; `gracefulShutdown`
  replaced by hardcoded 30 s tunings. Parsed, documented, silently ignored. (quality)
- **CONFIRMED** `ConfigApplier.swift:30-42` DB commit then file write; crash between leaves
  `config.yaml` older than DB. (low, tiny window; check startup precedence)
- `InstanceManager.swift:210-238` `delete` can throw `workerLockHeldByOtherProcess` and park a
  row in `.deleting`; nothing retries automatically. (low)
- `InstanceManager.swift:360-387` `fail()` double `try?`: lost CAS leaves row in intermediate
  state with no failure code and no reaper. (low)
- `RunnerSessionRecovery.swift:182-198` `strayRunnerID` single lookup, no operations-row retry —
  GitHub outage at restart can orphan a registration. (low)
- `OrchestratorTick.swift:264-275` persistently failing cancel retried each tick, no hold-down or
  metric. (observability)
- `APFSClone.swift:71` `freeSpace` returns 0 (=> capacity 0) if resource values unreadable; no
  log line. (low)
- `ImageManager.swift:279` pull failure `setState(.invalid)` is `try?`; stuck `.pulling` row has
  no sweep. (low)
- `DaemonRuntime.swift:283-294` `beginShutdown` calls `exit(0)` from a detached Task
  (`exitOnShutdown` default true). (design note)
- `CapacityCalculator.swift:180-210` `probeFit` cost O(maxInstances) per profile per tick;
  `AdmissionQueue` FIFO head-of-line blocks creates and builds. (perf, low)
- Coverage: no repository fakes (all tests go through real GRDB — good fidelity, no failure
  injection for `try?` paths); `AdmissionQueueTests.swift:93` has a 30 s sleep; no negative test
  for the reusable-sweep gap.

  Correction after reading startup: `ConfigApplier` window is negligible in production because
  the LaunchDaemon always passes `--config`, which re-applies the operator file at start.

### C. Security / install / CLI / Go agent / scripts / CI (scout, spot-checked)

Verdict: security posture is deliberate and mostly good (SecureFile O_NOFOLLOW+fstat, Redactor,
JIT never persisted/logged, stdin-only registry password, argv arrays not shell strings, SHA-pinned
actions, no self-hosted job reachable from `pull_request`, bounded LZ4/manifest limits, HOME
snapshot restore fail-closed). Items:

- **Unsigned pkg**: `release-manifest.json` self-attests `signed` and carries the sha256 the
  installer trusts. A compromised release pipeline passes every check. Only Developer ID signing
  + notarization closes this. (design limitation, documented; release decision)
- **CONFIRMED LIVE** `com.runnervm.runnerd.daemon.plist` `KeepAlive=true` + `ThrottleInterval=5`
  with no self-throttle in `runnerd` on config/state-dir errors => 70k respawns on blackpen.
  runnerd should back off (sleep) before exiting on EX_CONFIG-class failures; setup/installer must
  create the state dir before loading the job. (medium)
- `bootstrap.sh:174-180,285`: `pkg_name` from manifest used unsanitized in local paths. (low)
- `Upgrader.swift:271-274`: only `sh -c` string in HostSetup (quoted correctly). (low)
- `runnerctl auth login --token <value>` argv exposure (documented). (low)
- Go agent: `agent.exec` (root) and `agent.startRunner` not gated by host-safe-mode (by design;
  the 2026-08-26 incident was cleanup). (note)
- `macos-provision-vm.sh:124-125` `StrictHostKeyChecking=no` on the build SSH channel. (accepted)
- `allowPublicRepositories`/overcommit are warnings once enabled (by design).
- `GitHubAppCredentialProvider.invalidate()` exists; scout did not find a 401 caller — verify.
- Hand-rolled DER parser for PKCS#8 (operator input only). (low)
- Doctor `login_keychain` skipped under daemon mode (correct given measurement).

### D. Release/process/docs (own findings)

- v0.2.0 released from a red-CI commit; fix only on master. README/SETUP/release.md stale.
- GHCR empty; `publish-images` needs a self-hosted `runnervm-publisher` runner that does not
  exist; schedule fires monthly into a dead queue.
- Homebrew tap formula inert (old repo URL, v0.1.0, revision 0, no license).
- 435/582 files unformatted; lint not in CI. Go module path placeholder.
- FSL-1.1-ALv2 "derived" files (19) inside an Apache-2.0 repo; NOTICE covers it, README/LICENSE
  do not spell out mixed licensing.
- No signed-build test lane: VZ lifecycle, vsock, WorkerService only proven by live scripts.

## Decisions (user, 2026-09-01)

| Topic | Decision |
| --- | --- |
| Release shape | `v0.2.1` patch first (starvation fix + crash-loop backoff + doc truth), then `v0.3.0` = first public release, target of this plan |
| Signing | Developer ID Application + Installer, notarization + stapling, in `release.yml` via repo secrets (no laptop). No identity is installed on the dev Mac today; operator creates/exports certs |
| Guests | Linux AND macOS fully supported => H3/H4/H5 + reboot loop on hardware before v0.3.0 |
| Reusable lifecycle | keep, fix reaper gap, mark experimental |
| Hardware | dev Mac for everything (macOS H3-H5 and the 10-reboot LaunchDaemon loop). blackpen: stop crash loop, decommission |
| Hygiene | swiftformat bulk + CI lint; delete 8 stale worktrees/branches; Go module -> `github.com/andrejvysny/RunnerVM/GuestAgent`; fix Homebrew tap for v0.3.0 |
| Timeouts | wire `imagePull`, `vmBoot`, `jitGeneration`, `gracefulShutdown` for real |
| Licensing | keep FSL-derived files, document mixed licensing in README + LICENSE preamble |
| Publishing | manual `scripts/publish-images.sh` from the dev Mac with operator PAT; `publish-images.yml` cron disabled (dispatch only) until a publisher host exists |
| RC tags (2026-09-02) | `v0.3.0-rc.N` prereleases through release.yml; installed via the rc-specific `install.sh` URL with `sudo RUNNERVM_VERSION=... bash` |
| Reboot loop (2026-09-02) | DEFERRED. v0.3.0 ships with the LaunchDaemon reboot recovery labelled "unqualified: the 10-reboot loop has not been run"; `doctor reboot_persistence` + rc install/upgrade on the dev Mac are the evidence that exists |
| H3 disk (2026-09-02) | if <120 GiB free after cleanup, run H3 with `host.overcommit.disk` and record the ratio in the evidence |

Dev Mac facts (2026-09-01): 57 GiB free; `~/runnervm-dev` no longer exists (macOS image and
dev DB gone => macOS image must be re-provisioned, which exercises D7 managed provisioning);
`~/Library/Caches` 57 GB, DerivedData 9.2 GB, `.claude/worktrees` 10 GB reclaimable.

## Out of scope (explicit)

- M8.6 native IPSW macOS image builder; build-time secrets (`docs/design/build-secrets.md`);
  H6 single correlation key; `ProfileRepository.get(id:)` consolidation; `fail()` double-`try?`
  hardening; `HostProbe` redesign beyond a timeout; TLS pinning; rewriting FSL-derived files;
  a self-hosted signed VZ test lane in CI; Homebrew formula automation in release.yml.

## Constraints (binding for every subagent)

- Never `git commit`, `git push`, `git tag`, or create releases — the user does. Never delete
  branches/worktrees or files outside the repo without the explicit operator step in this plan.
- Never run `swift build`/`swift test` while a live VM run is in progress; after any build that
  precedes a VM run, `scripts/sign-dev.sh`. Never run guest-agent destructive RPCs on the host.
- `tart/` is a read-only reference clone: never import or copy code from it beyond the existing
  `derived` rows in PROVENANCE.md; every new Tart-derived line needs a header + PROVENANCE row.
- Wire contracts: any change to `Proto/*.md`, `WorkerProtocol`, `GuestControl` DTOs, or
  `RunnerVMMetrics` lands in the same commit as its doc/fixture; DTOs decode leniently (old
  daemon <-> new runnerctl and vice versa must keep working).
- Tests: Swift Testing, event-driven waits only (no `Task.sleep` polling in tests), injected
  clocks, hang guards; bash suites must stay bash-3.2 compatible and shellcheck clean.
- The swiftformat bulk commit contains formatting only. Do not fix/format unrelated files in
  feature commits; match file-local style until the bulk commit lands.
- Match module layering in `Package.swift` (no new cross-module imports without a plan change).
- Executables stay thin: new logic goes into `Orchestration`/`HostSetup`/`VirtualizationCore`
  where it is testable.

## Plan

Target: `v0.3.0` = first public release. Path: `v0.2.1` patch first, then seven phases. Phases
1–4 are code (delegated per fable-orchestrator: tiers in brackets); 5–7 are hardware/operator
gates. Every phase ends with `swift build && swift test --parallel`, `make -C GuestAgent all`,
`shellcheck scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh`, `bash scripts/tests/*.sh`,
`actionlint`, plus phase-specific checks. No commits/pushes/tags without the user.

### Phase 0 — `v0.2.1` patch (small, ships first)

- 0.1 [critical] Startup failure handling (root cause re-read by the D3 reviewer: blackpen's exit
  78 is launchd's OWN spawn failure — the plists redirect stdio to `<state>/logs/runnerd/stdio.log`
  and that directory never existed because `scripts/install.sh` does not create it; runnerd never
  ran once). Four parts, all in the patch:
  (a) `scripts/install.sh` creates `<state>/logs/runnerd` (0750, service owner) in section 6 like
  `HostInstaller.swift:129` already does; `scripts/tests/install-test.sh` asserts it. Both plists:
  `ThrottleInterval` 5 -> 30, agent plist gains `ExitTimeOut` 60, both gain
  `EnvironmentVariables` `RUNNERVM_SUPERVISED=1` and `RUNNERVM_STARTUP_BACKOFF=60`;
  `LaunchdManagerTests` asserts the rendered values. Document: the stdio directory must exist
  before `launchctl bootstrap`, and "exit 78 + missing/empty stdio.log + high `runs`" = launchd
  never spawned the daemon.
  (b) In-process backoff in the binary (does not depend on ThrottleInterval, which upgraded hosts
  never receive because `upgrade` does not re-render the plist): new
  `Sources/Orchestration/StartupFailure.swift` with a pure `plan(for: error, environment:,
  supervised:) -> (class, sleep, exitCode)`; RunnerD is a three-line caller. Supervised =
  `getppid() == 1 || RUNNERVM_SUPERVISED == "1"` (not `isatty`). Classes and sysexits: config
  parse/validation -> 78 `EX_CONFIG`; state dir/identity/DB file/ENOSPC -> 72 `EX_OSFILE`; lock
  held/socket/metrics bind -> 69 `EX_UNAVAILABLE`; transient -> 75 `EX_TEMPFAIL`. Primary signal
  is `RunnerError.retryable`, with a commented override set (`lockUnavailable` branches on errno:
  EMFILE/ENFILE/ENOMEM transient; raw `CocoaError`/GRDB errors -> non-transient; unknown -> 72).
  Sleep: configuration classes `RUNNERVM_STARTUP_BACKOFF` (default 60, clamp [0,300]); transient
  5 s, escalating to the configuration backoff after 10 consecutive transient failures recorded in
  `<runtime-dir>/startup-attempts` (unwritable counter => treat as configuration). Sleep is
  `await Task.sleep`; SIGTERM/SIGINT keep default disposition during it (handlers are installed
  only after a successful start — write that invariant as a comment AND a test that
  `installSignalHandlers` is not reachable before `runtime.start()` returns).
  (c) `HostProbe.run` gets a 60 s deadline in Phase 0 (fallback probe + warning on expiry; the
  full RunProcess rework stays in D2/D11) so a wedged `vmworker probe` cannot hang startup silently.
  (d) `runnerctl doctor` `launchd_job` check parses `launchctl print` for `last exit code` and
  `runs`: warn when `runs > 10` or last exit != 0, fail when the plist's `StandardOutPath`
  directory does not exist; `doctor` also warns when the installed plist's `ThrottleInterval < 30`
  (upgraded hosts). Tests: `StartupFailureTests` (classification table, env parsing/clamp,
  escalation counter), `DoctorChecks` tests with recorded `launchctl` output, `LaunchdManagerTests`.
  Docs: `docs/install.md` "runnerd exit codes" (69/72/75/78 + the launchd-78 disambiguation),
  `packaging/launchd/README.md`, CHANGELOG.
- 0.2 [standard] Doc truth: README/SETUP/docs/release.md/docs/status.md/CHANGELOG say v0.2.0
  IS released, cut from `d742a1c`, and that v0.2.1 carries `fad78a0`; `docs/release.md` drop the
  "install.sh is not yet a release asset" paragraph; README quick start must not show the GHCR
  pull until Phase 6 lands (say "build locally, or pull once published").
- 0.3 [standard] `.github/workflows/publish-images.yml`: remove the `schedule:` trigger (dispatch
  only) with a comment pointing at docs/published-images.md; cancel the stuck queued run
  (operator: `gh run cancel 33504120630`).
- 0.4 Version bump `RunnerVMVersion.current = "0.2.1"`, CHANGELOG section; `scripts/tests/
  build-package-test.sh:122,222` hardcode `0.2.0` — derive the expectation from `Version.swift`
  instead (standing rule for every bump). Operator: push, tag
  `v0.2.1`, watch release.yml (still unsigned; that is fine for a patch).
- 0.5 Operator, blackpen decommission (I cannot sudo there):
  `sudo launchctl bootout system/com.runnervm.runnerd`;
  `sudo rm /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`;
  `sudo rm -rf /usr/local/bin/runnerctl /usr/local/libexec/runnervm`;
  optionally `sudo dscl . -delete /Users/_runnervm; sudo dscl . -delete /Groups/_runnervm`.
  Update memory + docs/status.md ("Mac mini decommissioned 2026-09").

### Phase 1 — Hygiene (mechanical; land before feature diffs)

- 1.1 Operator-confirmed destructive: `git worktree remove --force .claude/worktrees/agent-*`
  (8) + `git branch -D worktree-agent-*`; reclaims ~10 GB. Verify `git worktree list` shows one.
- 1.2 [standard] `swiftformat Sources Tests` as ONE commit (no other changes), then add
  `brew install swiftformat` + `swiftformat --lint Sources Tests` to the `lint` job in
  `.github/workflows/ci.yml`; AGENTS.md "Formatting" line updated. Note `.swiftformat` has
  `--swiftversion 6.0`; keep. Run the full test suite after the bulk format (stale `.build`
  SIGSEGV gotcha: `swift package clean` first).
- 1.3 [careful] Go module path `github.com/runnervm/guest-agent` ->
  `github.com/andrejvysny/RunnerVM/GuestAgent`: `GuestAgent/go.mod`, every import in
  `GuestAgent/**/*.go`, `Makefile` `-ldflags` package path for the version var, `AGENTS.md`,
  `Proto/README.md`, docs mentioning the path. `make -C GuestAgent all` green.
- 1.4 [standard] Merge or rebase dependabot PR #1 (upload-artifact v7.0.1) after CI is green.
- 1.5 [standard] Licensing: README "License" section (Apache-2.0 for RunnerVM; files carrying the
  Tart header remain FSL-1.1-ALv2 until their ALv2 conversion date; point to NOTICE and
  PROVENANCE.md), a short preamble comment block at the top of `LICENSE`? (no — keep LICENSE the
  verbatim Apache text; put the notice in README + NOTICE), `NOTICE` gains the actions/scaleset
  MIT attribution line if absent. Verify each `derived` file still carries its header (19/19).

### Phase 2 — Defect fixes (see "Defect bundle design" below for file-level detail)

- 2.1 [critical] D1 reusable reaper gap + negative/positive tests.
- 2.2 [critical] D2 new leaf target `Sources/ProcessSpawn` (posix_spawn runner with process-group
  kill escalation, deadline-bounded drain, correct status decoding) used by Orchestration
  (`RunProcess`, `HostProbe`, `WorkerLauncher` attrs) and HostSetup (`DefaultCommandRunner`);
  `BUILD_TOOL_TIMEOUT`; provisioning script gets `RVM_PROVISION_TIMEOUT`, env allowlist and
  `--out`; build rows persist the pgid for crash recovery. D11 `HostProbe` bounded + re-probed.
- 2.3 [careful] D4 vmworker: `abort()` runs teardown on VZ start failure; exit 79
  `vzStopFailed`; exit 80 `macOSGuestLimitReached`; `Proto/worker_protocol.md` documents `stop`
  == `drain` (kept for wire compat).
- 2.4 [careful] D5 `.deleting` rows retried by `InstanceReconciler` after N minutes.
- 2.5 [careful] D6 GitHub App token: invalidate + retry once on 401 for idempotent requests.
- 2.6 [standard] D7 bootstrap `pkg_name` validation + test; D8 `freeSpace` fallback log line;
  D9 cancel-failure counter + metric.
- 2.7 [standard] A-scope leftovers: populate `HelloResponse.agentBootId` or remove from Proto;
  `VsockBridge` UID-reject log + test.
- 2.8 [critical] D10 `RunnerSessionRecovery.recoverSessions` can terminalize a live session:
  (a) a `register` mid-`issueJIT` has a row and no observer; (b) `recoverSessions` decides on a
  stale snapshot (`rows` listed once, ownership checked before four more awaits in
  `contextForRecovery`). Fix: generate the `RunnerSessionID` in `register` BEFORE `insertRow`
  and record it in a separate `registering: [RunnerSessionID: Date]` (NOT a placeholder in
  `observers` — the success path installs the real observer at the same key and a `defer`
  removal would clobber it; `detachObservers` and the test seam `observedSessions()` would also
  see placeholders). `recoverSessions` skips rows in `registering` younger than
  `jitGeneration + 30 s` slack (older marks are stale — a stuck `register` must not strand the
  VM forever). `recover` re-reads the row at its top and skips when `fresh.state != row.state` or
  ownership appeared. Tests: stall JIT, run recovery mid-register, assert the row survives and the
  session completes; stale mark older than the slack IS recovered; state-changed-under-snapshot is
  skipped.


### Phase 3 — Enforce profile timeouts (see "Timeout wiring design" below)

- 3.1 [critical] `vmBoot` bounds clone -> running via a tracked background watcher (the
  `instance.create` RPC still returns at `startingVM` as today); failure code `VM_BOOT_TIMEOUT`;
  CAS-guarded; hold-down. Requires D1 (2.1) first.
- 3.2 [critical] `jitGeneration` bounds `issueJIT` (REST + scale-set); requires making
  `ActionsServiceConnection.adminConnection()` waiters cancellation-aware (see design). No
  `enforceDeadlines` change (no observer exists in jit* states; recovery covers crash leftovers).
- 3.3 [careful] `imagePull` caller-side deadline inside `reserve(..., profile:)`; shared pull keeps
  running; the caller learns ITS transfer's real outcome (error class preserved); planning pin
  released on every throw; default raised to 60 min.
- 3.4 [careful] `gracefulShutdown` replaces the hardcoded 30 s on every runnerd-driven path AND
  the guest `stopRunner` call deadline scales with it (GuestControl change); vmworker's
  self-initiated shutdowns receive it via a new `--graceful-ms` launch option; exit-wait capped.
- 3.5 [standard] docs: `docs/state_machines.md`, `Proto/daemon_api.md` (new failure codes),
  config reference incl. "pre-pull with `runnerctl image pull` or `images.prefetch: true` on slow
  links", the `allowFullCopy == false` precondition behind the vmBoot default, and that macOS first
  boot is bounded by `agentReady` (VZ reports `running` before the OS boots);
  `ProfileValidation` bounds incl. `PROFILE_TIMEOUT_AGENT_READY_SHORT` for macOS profiles.

### Phase 4 — Developer ID signing + notarization (design below, D1–D11/F1–F8)

- 4.1 Operator one-time: create Developer ID Application + Installer certs (Account Holder only),
  export p12s, create App Store Connect API key (Team key, role Developer), add 8 repo secrets
  (`APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64/_PASSWORD`, `APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64/
  _PASSWORD`, `APPLE_NOTARY_KEY_P8_BASE64`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`,
  `APPLE_TEAM_ID`).
- 4.2 [critical] `scripts/build-package.sh`: sign FOUR Mach-O files on the staged payload
  (runnerd, runnerctl, vmworker+entitlement, darwin guest agent — the notary scans every Mach-O)
  with `--options runtime --timestamp` UNCONDITIONALLY (ad-hoc accepts both; CI/dev then run the
  same hardened-runtime configuration as releases) and explicit `--identifier` (without it
  codesign derives a per-build hash identifier, unstable for any requirement pin);
  `productbuild --sign`; `notarytool submit --wait --timeout 30m` + `stapler staple` +
  `stapler validate` + RE-VERIFY `pkgutil --check-signature`/`spctl --assess -t install` on the
  stapled file; THEN sha256 + manifest (stapling rewrites the pkg). Manifest: `signed` = Developer ID Installer
  signature present, `notarized` = stapled ticket validated (`stapler validate` succeeded); both
  false on dev builds; plus `teamId` ("" when unsigned). Postinstall templating: copy `packaging/pkg/scripts` to `mktemp -d`, `sed -e
  "s|@RUNNERVM_TEAM_ID@|$TEAM|g"` the copy (team id validated `^[A-Z0-9]{10}$`, may be empty),
  `chmod 0755`, `pkgbuild --scripts <copy>`, `rm -rf` — never touch the checked-in file.
  Postinstall: `[ -n "$TEAM_ID" ]` gates the `codesign -R 'anchor apple generic and certificate
  leaf[subject.OU] = "TEAM"'` check on all three host binaries + the darwin agent; empty team id
  keeps today's `codesign --verify --strict` only (dev/unsigned installs keep working).
  `scripts/install.sh:444,465` must NOT re-sign a binary that already carries a non-ad-hoc
  signature (`codesign -dvv | grep -q 'Signature=adhoc'` decides); 7.3 states which signature a
  brew install ends with.
- 4.3 [critical] Install-side gate, both implementations, keyed on NOTARIZATION not on `signed`:
  `scripts/bootstrap.sh` `verify_package_signature` and Swift `PackageSignature.parse` (pure,
  structure-keyed on the certificate-chain OU line, not English prose) used by
  `Upgrader.signatureStep` placed BETWEEN `checksumStep` and `rollbackMaterialStep` (before
  drain/stop — a failed check must leave the host untouched). Evidence: `pkgutil
  --check-signature` proves a Developer ID Installer signature and yields the leaf team; the
  leaf team MUST equal a compiled-in constant (`RunnerVMSigning.teamID` in RunnerCore; the same
  literal in bootstrap.sh) — the manifest's `teamId` is never the reference. `spctl --assess -t
  install` is the ONLY notarization evidence; when `spctl --status` says disabled, proceed but
  print "notarization unverified on this host" loudly. Rule: notarized + team match => proceed
  silently; signed by a different team => hard fail, no override; signed by our team but not
  notarized => warn + confirm (`RUNNERVM_ALLOW_UNSIGNED` applies) — never a lockout; unsigned =>
  today's warning/confirm. `UpgraderRollback.swift:39` applies the same gate + cached `.sha256`
  to the previous pkg before `installer`. Fold D7's package-name validation into
  `ReleaseManifest` decoding (Swift has the same hole at `Upgrader.swift:231,326-336`).
  Precedence: explicit `RUNNERVM_PKG_URL` beats `RUNNERVM_VERSION` in BOTH bootstrap.sh and
  `ReleaseManifest.swift:145-151` (today they disagree); tests on both sides. Fix
  `RunnerVersionHealth.swift:151` prerelease comparison to numeric-aware dot segments
  (`rc.10 > rc.9`) and its `v0.3.0-rc1` doc comment.
- 4.4 [careful] `release.yml`: first step hard-fails if any signing secret/variable is empty (an
  unsigned pkg must never publish as a release); `concurrency: release-${{ github.ref }}`;
  temp keychain import (partition list output redirected; `chmod 600` the .p8; p12 files removed
  right after import), identity derivation — Application via `find-identity -p codesigning`,
  Installer via `find-identity -v` WITHOUT `-p codesigning` (installer EKU) — both asserted
  against `APPLE_TEAM_ID`; build-sign-notarize step; pkg verification step; installed-binary
  verification (`codesign -R` team requirement, hardened runtime flag, timestamp, no
  get-task-allow), guest agent `-version` exec, bootstrap smoke WITHOUT `RUNNERVM_ALLOW_UNSIGNED`,
  cleanup `if: always()`, `timeout-minutes: 90`, `--prerelease` when the tag contains `-`.
  State in the workflow comment that `vmworker probe` does not prove hardened runtime is safe
  for the full VM lifecycle — Phase 5 is that evidence.
- 4.5 [standard] Tests: `build-package-test.sh` (9-key manifest; `write_manifest` arity; a real
  `pkgbuild`+`productbuild` case under `--skip-build --skip-sign` asserting key set, checksum
  matches file, templated postinstall inside the pkg — both tools take ~1 s and accept
  `0.3.0-rc.1`), `bootstrap-test.sh` (fixture manifest -> 9 keys; cases 11/12 need notarized
  fakes; +5 cases; precedence case), `PackageSignatureTests` (verbatim fixtures captured from a
  REAL signed/notarized run — 4.1 includes a local dry run that saves `pkgutil`/`spctl` output
  for signed-unnotarized and stapled pkgs), `ReleaseManifestTests` (unknown-key fixture change,
  package-name validation), `UpgraderTests` stubs + rollback gate. Docs: distribution.md
  "Unsigned phase" -> "Signing and notarization", release.md runbook incl. cert renewal
  (timestamped signatures survive expiry; never revoke) and the rc install command shape.

### Phase 5 — Hardware validation on the dev Mac (release gate for "both guests supported")

Prereq: disk. Need ~120 GiB free for macOS work (Tart base pull 27 GB compressed / ~30 GiB
allocated, provisioned image ~30 GiB, two guests at 50 GB apparent each but sparse). Have 57 GiB.
Operator frees: worktrees (1.1, 10 GB), DerivedData (9 GB), caches of their choosing (JetBrains
8 GB, rattler 6 GB, Homebrew 6 GB, ccache 5 GB ...). Alternative: external APFS SSD as
`--state-dir`. Use `host.overcommit.disk` (~1.6) only if still short, and record it.

- 5.1 Cut `v0.3.0-rc.1` (version string `0.3.0-rc.1`; release.yml marks prerelease). This is the
  first signed artifact; fixes found here go into rc.2.
- 5.2 Fresh production-layout install on the dev Mac. `releases/latest` EXCLUDES prereleases and
  `install.sh` is per-release, so fetch the rc's own installer and keep the variable across sudo:
  `curl -fsSL https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0-rc.1/install.sh |
  sudo RUNNERVM_VERSION=v0.3.0-rc.1 bash` (plain `VAR=x curl | sudo bash` loses the variable to
  `env_reset`). Then `runnerctl setup` wizard, LaunchDaemon `_runnervm`. Later `sudo runnerctl
  upgrade --version v0.3.0-rc.2` = real upgrade + signature-gate test. Document the shape in
  docs/release.md.
- 5.3 Linux matrix: `scripts/live-github-e2e.sh` 11/11, `live-builder-e2e.sh`,
  `live-builder-faults.sh --phase staging|booting|provisioning|sealing`, `system smoke-test`,
  `doctor --deep`, reusable-lifecycle HOME reset on a real VM (opt-in profile).
- 5.4 macOS image via managed provisioning (`images.managed`, kind `macos-tart`, D7): pull, provision
  under vmworker, seal, qualify, promote. Then `scripts/qualify-macos-image.sh --pinned`.
- 5.5 H3 `scripts/live-macos-e2e.sh` concurrency (2 + 3rd queued, C starts when A finishes);
  H4 recovery matrix (runnerd/vmworker kill at each state); H5 soak 100 short jobs, then 500 at
  concurrency 2 with fault injection; leak invariants at end. `e2e.yml keychain` job on macOS.
- 5.6 Reboot loop: DEFERRED by decision. Instead: one `sudo shutdown -r now` on the dev Mac
  with no job running, then verify the LaunchDaemon came back (`launchctl print system/com.
  runnervm.runnerd`, `runnerctl doctor` incl. `reboot_persistence`, `system smoke-test`). Docs
  (status.md capability matrix, qualification.md, README status) state explicitly that the
  10-reboot/power-cut qualification has not been run for v0.3.0.
- 5.7 Record everything in `docs/verification.md` ("v0.3.0 release gate") with run ids.

### Phase 6 — Publish `ubuntu-24-base` to GHCR (operator PAT `write:packages`)

- 6.1 On the dev Mac host: `runnerctl image build images/recipes/ubuntu-24 --name ubuntu-24-base-build`,
  `echo $PAT | runnerctl registry login ghcr.io -u andrejvysny --password-stdin`,
  `scripts/publish-images.sh --image … --package ubuntu-24-base --repo ghcr.io/andrejvysny/runnervm
  --tag <date> --tag r<runner> --tag stable --tag v1`.
- 6.2 Operator one-time in GitHub package settings: make public, connect repository.
- 6.3 Verify anonymously: `runnerctl image inspect --remote ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable`
  then `image pull` + `system smoke-test`. Re-enable README quick start pull.

### Phase 7 — Release `v0.3.0`

- 7.1 Version bump, CHANGELOG (v0.3.0 section: signing, timeouts, reusable fix, macOS supported
  with evidence links), docs/status.md capability matrix updated to "live" with run ids,
  README status paragraph rewritten, SETUP.md Part 1 is the primary path.
- 7.2 Operator: push, tag `v0.3.0`; release.yml signs/notarizes/publishes.
- 7.3 Homebrew tap: `Formula/runnervm.rb` url -> RunnerVM repo, `tag v0.3.0`, `revision`, `license
  "Apache-2.0"`; `brew audit --strict`; push tap.
- 7.4 Post-release: fresh `curl | sudo bash` on the dev Mac from `releases/latest` (upgrade path
  from rc), `runnerctl --version`, `doctor`. Update memory files.

### Signing + notarization design (Plan agent, verified against local toolchain)

Facts: all three Swift executables are statically linked (no nested dylibs; only Apple-signed
weak `libswiftCompatibilitySpan` rpath); the darwin guest agent is a Go linker-ad-hoc Mach-O
(`Identifier=a.out`) and MUST be Developer ID signed or notarization fails; `stapler` rewrites the
pkg so checksum/manifest come last; `curl` sets no quarantine and `installer` does no assessment,
so the installers must verify explicitly; `stapler`/`notarytool` are Xcode-only, target hosts use
`/usr/sbin/pkgutil` + `/usr/sbin/spctl`; `productbuild --sign` suffices (no `pkgbuild --sign`,
no `productsign`); `com.apple.security.virtualization` is non-restricted and works with hardened
runtime under Developer ID (Tart ships exactly this). Team ID derived from the signature, not a
flag. `codesign --verify --deep` is a no-op on bare executables: use `--strict` + `-R`
requirement. Risks: notary latency (timeout 30m, job 90m, never fall back to unsigned publish);
Apple output wording is a parsing contract (pure parser + captured fixtures; release job runs the
real gate); cert expiry after 5 years (timestamped signatures survive; renew, never revoke).

### Timeout wiring design (Plan agent, line refs verified)

Reserved but unused error cases already exist: `ImageError.pullTimeout` (`IMAGE_PULL_TIMEOUT`,
retryable) and `VMError.bootTimeout(stage:)` (`VM_BOOT_TIMEOUT`, retryable). Only jitGeneration
needs a new case. No new state-machine edges. Wire already carries `gracefulTimeoutMs`.

- Shared helper: new `Sources/Orchestration/Deadline.swift` with
  `withDeadline<T>(_ limit: DurationValue, expired: () -> Error, body)`; move the existing
  `withDeadline` out of `InstanceReuse.swift:303-319` as a wrapper. HARD RULE: body must be
  cancellable; never wrap `await task.value` of an unstructured Task (it ignores cancellation and
  the group hangs at exit).
- `imagePull` (caller-side, shared transfer keeps running; rewritten after review):
  `ImagePulling.resolveRecord` gains `timeout`; `ImageManager.reserve` gains `pullTimeout`;
  `InstanceCreation.swift:62-63` passes `profile.effectiveTimeouts.imagePull`. Phase 1 raced with
  `withDeadline` ONLY after `beginPull` stops awaiting `running.operation.value` (an unstructured
  Task — violates the hard rule; make `beginPull` return the Task and let `startPull` alone await
  it). Phase 2 captures `let mine = running.task` and polls `inFlightPulls[digest]?.task != mine`
  (never `== nil`: prefetch runs every tick and can re-register the digest inside the poll window);
  on exit return `readyRecord`, else read the outcome from the `pull-image` operation row /
  `images.get(digest).state == .invalid` and rethrow THAT error (`REGISTRY_AUTH`,
  `IMAGE_INSUFFICIENT_DISK_SPACE` must survive), never a bare `pullFailed`. `create` widens its
  `do/catch` to cover `reserve` and releases the planning pin on ANY throw (a lost race can
  otherwise commit the pin after the sleeper wins). Use `ContinuousClock`, not `ImageManager.now`.
  Default `imagePull` 30 -> 60 min (2.9 GiB compressed + 16 GiB hash; prefetch is off by default
  so the first `vm create` pays). `reserve(reference:forBuild:)` untouched.
- `vmBoot` (clock starts at `cloning`, per-phase attribution; rewritten after review):
  `bringUp:242-261` checks the deadline after `stage` (clonefile uninterruptible) and after spawn,
  then — instead of blocking the RPC — registers a tracked watcher Task in `InstanceManager`
  (`bootWatchers[id]`, cancelled in `detachGuests`) that polls the row out of `startingVM`
  (`Tuning.vmRunningPollInterval` 200 ms): success on `state.hasRunningVM`, silent exit on
  `isFailedStart || .deleting || .deleted` (already handled), deadline branch only synthesizes
  `VM_BOOT_TIMEOUT`. `instance.create` keeps returning at `startingVM` (no 60 s socket idle
  problem, `concurrentVMStarts` semantics unchanged). `failBootTimeout` RE-READS the row and
  `guard fresh.state == .startingVM` before writing anything; `fail()` returns whether its CAS
  landed and the `failure.json`/metric/log/teardown happen only when it did (today `fail` writes
  the record before the state check and swallows a rejected CAS). Same watcher for
  `InstanceTaint.respawn:103-127` (needs D1 so the resulting `.failed` reusable row is reaped).
  Hold-down via existing `isFailedStart`. Test: `awaitInstance(.failed)` with
  `FakeWorker.statesAfterStart = []`.
- DECISION: raise `TimeoutPolicy.default.jitGeneration` 30 s -> 2 min. `RetryPolicy.github`
  (5 attempts, 1..60 s backoff) alone exceeds 30 s under 429/503, so enforcing the old default
  would fail JIT calls that succeed today after retries. CHANGELOG notes the new default.
- `jitGeneration` (rewritten after adversarial review): new `GitHubControlError.
  jitGenerationTimeout(seconds:)` -> `GITHUB_JIT_GENERATION_TIMEOUT` (class `.transport`; the
  class is cosmetic here — no orchestration consumer reads it for session failures). Wrap
  `issueJIT` in `RunnerSessionManager.register:206` with `withDeadline`. PREREQUISITE: the
  scale-set path is NOT cancellable today — `ActionsServiceConnection.adminConnection()`
  (`:290-310`) awaits an unstructured `Task.value` (probe: 200 ms deadline returned after 3.2 s).
  Fix in `Sources/GitHubControl/ScaleSet/ActionsServiceConnection.swift`: keep one shared
  exchange task, but each waiter suspends in `withTaskCancellationHandler` around a
  `CheckedContinuation` that the exchange resumes, and cancellation resumes the waiter with
  `CancellationError` without cancelling the shared exchange. Same audit for any other
  `await task.value` on the JIT path. On expiry: `finish(..., .jitFailed, retainVM: false)` (a
  GitHub slowdown must not retain a failed VM per boot); the body publishes `JITRunnerConfig.
  runnerID` (id only, never the encoded config) into a `Mutex` box before returning, so the catch
  removes exactly that registration if it arrived late, and writes the id into the row so
  `retryPendingRemovals` (keyed on `githubRunnerId`) can retry a failed DELETE. The name-based
  `strayRunnerID` (make it internal) stays the crash-recovery fallback; it must query the
  scale-set plane first when `jitSource == .scaleSet`, and `ActionsScaleSetClient.runner(scope:
  name:)` gets an exact-name re-filter like the REST path. Validation warning
  `PROFILE_TIMEOUT_JIT_GENERATION_SHORT` (<60 s). Tests: `FakeScaleSetControlPlane.stallJITConfig`
  must be an async gate awaited OUTSIDE `state.withLock`; at least one case drives the REAL
  `ActionsServiceConnection` through `FakeGitHubServer` with the token exchange stalled and
  asserts the deadline returns within a small multiple of the limit (the protocol fake cannot
  detect the non-cancellable path).
- `gracefulShutdown` (rewritten after review): `InstanceManager.gracefulShutdownMs(for:)` via the
  `profiles.list()` pattern for `stop`/`delete` (`InstanceManager.swift:182-183, 212-213`) and
  `InstanceReuse.swift:209-210, 292-293`; `RunnerSessionObserver.swift:152-153` reads
  `context.profile.effectiveTimeouts.gracefulShutdown` directly (SessionContext is frozen by
  design). Delete `RunnerSessionManager.Tuning.stopGraceMs` AND the default argument at
  `WorkerSupervisor.shutdown:360`. `GuestAgentClient.stopRunner` gets a per-call deadline of
  `graceMs + 15 s` (today's fixed 30 s `callDeadline` would cancel the guest's `waitFor` and turn
  any grace > 30 s into a SIGKILL at 30 s — the Go agent blocks for the grace before answering).
  vmworker self-initiated shutdowns (hard-deadline, orphan-idle, SIGTERM: `WorkerService.swift:
  277,279,289`) get the profile value through a new `vmworker run --graceful-ms` option set by
  `WorkerLauncher` (default 30 000 when absent; `Proto/worker_protocol.md` documents it).
  `waitForWorkerExit(id:graceMs:)` attempts = `max(tuning.workerExitPollAttempts, (graceMs+15s)/
  poll)` CAPPED at 120 s / poll; `OrchestratorTick.cancel` deletes run as tracked detached tasks
  (like `launchStart`, joined by `drainCancels` in `stop()`) so a long grace never stalls the
  10 s tick. Builds keep `ImageBuilder.Tuning.gracefulShutdownMs` 120 s (document).
  `M2Harness.configuration` gains `gracefulShutdown` with a 200 ms default.
- Validation warnings: `PROFILE_TIMEOUT_IMAGE_PULL_SHORT` (<1m), `PROFILE_TIMEOUT_VM_BOOT_SHORT`
  (<30s), `PROFILE_TIMEOUT_GRACEFUL_SHUTDOWN_LONG` (>10m), `PROFILE_TIMEOUT_JIT_GENERATION_SHORT`
  (<60s), `PROFILE_TIMEOUT_AGENT_READY_SHORT` (macOS, <2m); keep `PROFILE_TIMEOUT_CLONE_IGNORED`,
  reword to say vmBoot now owns clone overruns.
- Tests (all event-driven, ms deadlines, no sleeps): harness gains the four timeouts +
  compressed poll intervals; `FakeScaleSetControlPlane.stallJITConfig(for:)`;
  `FakeGitHubServer.Reply.delay`; `FakeWorker` records the decoded `ShutdownRequest`;
  `FakeGuestAgent` records `StopRunnerRequest.graceMs`. Nine cases listed in the design:
  pull timeout leaves transfer running + no row + no planning pin; second caller shares transfer;
  VM never `running` -> `VM_BOOT_TIMEOUT` + worker shutdown; boot timeout holds profile down;
  scale-set + REST JIT timeouts; stop/stopRunner use profile grace; validation warnings.
- Execution order: Deadline.swift -> gracefulShutdown -> jitGeneration -> vmBoot -> imagePull ->
  docs. Steps 2-5 parallel-safe after step 1.
- Pre-existing hazard found (fix in Phase 2 as D10, critical):
  `RunnerSessionRecovery.recoverSessions:47` skips only rows with a live observer; a `register`
  with `issueJIT` in flight has a `jitRequested` row and no observer, so a reconcile tick can
  terminalize it and tear the VM down under the live call. Fix: `register` marks the row owned
  (placeholder observer entry) for its duration.
- Follow-up (not in scope): `ProfileRepository.get(id:)` to replace three O(profiles) scans.

### Defect bundle design (Plan agent, line refs verified; my decisions marked DECISION)

- **D3 crash loop (Phase 0).** Superseded by item 0.1 above after adversarial review: the
  incident was a launchd spawn failure (missing stdio directory), so the fix is (a) installer +
  plist hygiene + doctor visibility, and (b) an in-binary backoff for genuine startup failures
  that does not rely on `ThrottleInterval`. Rejected from the original design: `CocoaError.
  fileWriteOutOfSpace` as transient (ENOSPC persists), `isatty` as the supervised discriminator,
  a hardcoded second retryability list (use `RunnerError.retryable` + overrides), and an
  unbounded transient class (escalation counter added).
- **D1 reusable reaper (rewritten after adversarial review).** Restart eligibility is decided
  synchronously from the *predecessor* state (`reusableRestartStates == [.idle, .cleaning]`,
  evaluated inside `handleWorkerDisconnect`/`markWorkerDead`) and is never persisted; there is no
  `vm start` command and no `.stopped -> .startingWorker` caller. So any `.failed/.interrupted/
  .stopped` row a sweep sees has already lost its restart, whatever its lifecycle. Rule:
  `sweepRetired` reaps EVERY `.failed/.interrupted/.stopped` row past retention, regardless of
  lifecycle, EXCEPT (1) rows owned by an in-flight `delete`/`respawn` (`InstanceManager.
  isTearingDown(id)` / `isRestarting(id)` — expose the existing `teardown` set plus a new
  `restarting` set maintained by `respawn`), and (2) maintenance rows with `pinnedUntil > now`
  (`MaintenanceInstanceReaper` stays the only thing that reclaims those). No restart-budget
  injection needed. `fail()` stamps `stoppedAt = now` (as `interrupt` does) so the retention
  marker is the failure time, not `createdAt`. TOCTOU: the sweep must commit on the state it
  judged — add `InstanceManager.delete(id:expectedState:)` that re-reads, requires the same state,
  CAS-transitions to `.deleting` from it, else returns `.skipped`; the sweep uses it. Inject `now`
  into `InstanceReconciler` (clock seam like `MaintenanceInstanceReaper`); add a field-level force
  helper in `RestartSupport.swift`. `docs/state_machines.md:21` "stopped -> startingWorker" is
  documented but unimplemented — remove the edge from the doc. Tests (`ReusableSweepTests.swift`):
  never-idle reusable `.failed` swept; crash-between-stop-and-delete `.stopped` reusable swept;
  in-flight `respawn` row NOT swept; pinned maintenance row NOT swept before ttl; ephemeral inside
  retention NOT swept; `expectedState` mismatch skips; `failure.json` survives until retention.
  Accepted + documented: `InstanceReconciler` runs before `RunnerSessionReconciler`, so a swept
  instance's non-terminal session closes as `VM_LOST`.
- **D5 stuck `.deleting`.** No `deleting_at` column exists and `delete` from `.idle` does not
  stamp `stoppedAt`, so age is tracked in-memory: an `InstanceReconciler` actor records first-seen
  time per `.deleting` row (lost on restart — correct, no in-process delete survives one). Retry
  when first-seen is older than `deletingRetryGrace` (default 300 s) AND `!isTearingDown(id)`;
  retries run as ONE tracked background task per tick (in-flight guard, one row per tick) so a
  wedged worker's `waitForWorkerExit` never stalls the reconcile loop. `ReconcileCounts.
  deletingRetried` + the `CompositeReconcileStep.run` merge line (field-by-field; forgetting it
  reads 0); the wire DTO does not carry sweep counts — the metric
  `runnervm_instance_delete_retries_total{profile}` is the operator surface (add its
  `MetricDefinition`). Tests: retried after grace; fresh row left alone; row owned by a live
  delete left alone. D5b (same task): first tick marks `.pulling` image rows with no
  `inFlightPulls` entry and no `running` `pull-image` operation as `.invalid` (log once).
- **D2 process runner (rewritten after review; experiments on this host).** New leaf SwiftPM
  target `ProcessSpawn` (no deps; own `SpawnError`), used by `Orchestration` and `HostSetup`
  (`HostSetup` cannot depend on `Orchestration`). Spawn: `posix_spawn` with
  `POSIX_SPAWN_SETPGROUP` (spawn-pgroup 0 => pgid == pid; capture `pgid = pid` at spawn, never
  re-derive via `getpgid` — it returns ESRCH for a zombie leader while `kill(-pgid)` still works)
  + `POSIX_SPAWN_CLOEXEC_DEFAULT` (explicit `adddup2` for the three pipe fds) +
  `POSIX_SPAWN_SETSIGDEF` (full set) + `POSIX_SPAWN_SETSIGMASK` (empty): runnerd SIG_IGNs
  TERM/INT/HUP and ignored dispositions survive exec, so without SETSIGDEF the SIGTERM leg is dead
  and the provisioning script's `trap cleanup EXIT` never runs (regression vs Foundation.Process).
  Apply the same attrs fix to `WorkerLauncher.swift:122-134`. Environment is NOT inherited by
  posix_spawn: pass the `WorkerEnvironment.allowedVariables` set (PATH, HOME, TMPDIR, LANG/LC_*)
  and add `--out <build dir>` to the provisioning argv (`OUT` defaults to `$HOME/...` under
  `set -u`). Escalation: watchdog at `timeout` -> SIGTERM group -> `killGrace` (10 s, injectable)
  -> SIGKILL group; every `kill(-pgid)` takes a lock and is a no-op once the single `waitpid` has
  reaped the leader (PID reuse impossible while a zombie). Drain: non-blocking raw fds polled
  with `poll(2)` against an absolute deadline (leader exit + `drainGrace`, and the overall
  timeout) — `expect` `setsid()`s its spawned child, so group kill does NOT reach `ssh`, and any
  detached holder of the pipe write end would otherwise hang the drain forever; on deadline stop
  reading, return captured output with `timedOut`, close. No `Pipe.availableData` (uncatchable
  ObjC exception). Retained output capped head+tail (the 40-min transcript is streamed via
  `onOutput`). Status: `WIFEXITED ? WEXITSTATUS : 128 + WTERMSIG` (also fix the raw-status log at
  `WorkerSupervisor.swift:442`); `waitpid` -1/ECHILD = status unknown, not a loop. Cancellation:
  one `Mutex`-guarded state machine `pendingSpawn(cancelled) -> running(pid) -> reaped`; the
  cancel handler only flags + signals when running; body re-checks after spawn; exactly one
  continuation resume from the wait path; leader reaped even on the cancel path (no zombie for the
  daemon's lifetime). `ProcessResult.timedOut`; `ImageBuildError.toolTimedOut` = `BUILD_TOOL_
  TIMEOUT` mapped at Orchestration call sites. `MacOSProvisionStages.swift:180-210`: export
  `RVM_PROVISION_TIMEOUT = run.input.timeout - 5 min` (the script's own ceiling equals
  `build.timeout` today, so both expire together), throw before reading `result.json` when timed
  out, persist the pgid on the build row and group-kill it in build recovery after a daemon crash.
  Tests (`ProcessSpawnTests` + `RunProcessTests`, all under a hang guard, `killGrace`/`drainGrace`
  ms-scale): `trap '' TERM; sleep 60` -> timedOut; parent SIG_IGNs TERM then child `trap 'exit 42'
  TERM` -> exit 42 (proves SETSIGDEF); `expect -c 'spawn -noecho sleep 60; expect eof'` (setsid
  grandchild holding the pty/pipe) -> bounded; pgid leader; output captured on timeout; happy
  path; cancellation reaps; status decoding for signal exit.
- **D11 `HostProbe` (with D2).** `HostProbe.invoke` (`HostProbe.swift:83-98`) runs a fully
  blocking spawn on `Task.detached` (the `fad78a0` anti-pattern) and drains stdout to EOF before
  stderr (deadlock if stderr fills first): move to the `ProcessSpawn` runner (concurrent drain,
  GCD hop, 60 s timeout — Phase 0 (c) ships the timeout + GCD hop early). A timed-out probe must
  NOT pin the daemon to `virtualizationSupported: false` for its lifetime: re-probe on each
  maintenance tick while degraded and count timeouts distinctly from "no executable".
  `DefaultCommandRunner` (`HostSetup/CommandRunner.swift`) same treatment.
- **D6 App token 401.** `GitHubCredentialProvider` gains `invalidate()` with a no-op default;
  `GitHubHTTPClient.send` wraps `sendWithRetry`: on `.authentication` error for an idempotent
  request, `invalidateOnce()` (rate-limited by `Options.authRefreshInterval` 60 s, actor state)
  then retry once. Mint call runs on a separate client with `StaticCredentialProvider` — no
  recursion (verify in review). `generate-jitconfig` must stay non-idempotent. Tests in
  `HTTPClientTests` (4) + `AppAuthTests` extension.
- **D4 vmworker.** (a) `WorkerService.abort(exitCode:) -> Never` runs `teardown()` then exits;
  `Run.swift:50-53` uses it. (b) New `WorkerExitCode.vzStopFailed` — DECISION: value **79** (not
  78, avoid confusion with runnerd's EX_CONFIG); `performShutdown` exits it when `forceStop`
  threw. (c) DECISION: doc fix only — `Proto/worker_protocol.md:32` says both reasons behave
  identically, `stop` is what runnerd sends, `drain` kept for wire compat (mixed-version upgrade
  window). (d) New `WorkerExitCode.macOSGuestLimitReached` = **80**; `Run.acquireMacOSSlot`
  distinguishes `VM_MACOS_GUEST_LIMIT_REACHED` from an unwritable runtime dir. Tests:
  `WorkerMessagesTests.exitCodesMatchTheProtocolDocument` extended; pure
  `Run.exitCode(forSlotFailure:)`; manual verification of (a) recorded in docs/verification.md.
- **D9 cancel storm.** `Orchestrator.cancelFailures: [InstanceID: Int]`; warn on first, error
  every 30th; entry cleared on a successful cancel; pruned in `refreshMetrics` to ids seen this
  pass with `state != .deleted` (the pass lists `.deleted` rows too — follow the `workerCPU`
  precedent). Metric `runnervm_instance_cancel_failures_total{profile,code}` where `code` is
  `(error as? any RunnerError)?.code ?? "INTERNAL"` — never `describe(error)` (embeds per-instance
  paths => unbounded series). Add `MetricDefinition`s for both new families in one
  `RunnerVMMetrics.swift` edit.
- **D8 freeSpace.** Pure `freeSpace(importantUsage:available:) -> (bytes, unreadable)` +
  once-per-process error log via `Mutex<Bool>`; tests for the five input combinations (includes
  the live-outage regression `(0, 70e9)`); comment at `Mapping.swift:200` that status uses a
  different source than admission.
- **D7 bootstrap pkg_name.** `verify_pkg_name` with `case` globs (bash 3.2 style): no `/`, no
  leading `-`, charset `[A-Za-z0-9._-]`, must end `.pkg`, non-empty; called before `download_pkg`.
  Ten pure checks + one full-flow scenario in `bootstrap-test.sh` asserting installer never ran.
  Also assert the produced name in `build-package.sh`; the Swift side validates the same rule
  in `ReleaseManifest` decoding (Phase 4.3).
- Invariant after D1+D5+D9: no instance row stays non-`deleted` indefinitely without being
  retried or reaped, and both are counted.

## Execution mechanics (fable-orchestrator)

On approval: write `PLAN.md` at the repo root from this file (status `ready`), run
`/fable-plan-review`, then `/fable-run` phase by phase. Each phase = one review gate: I read every
diff, run the verification commands myself, then the user commits. Tiers: critical items ->
`impl-critical` + `reviewer-critical`; careful -> `impl-careful`; standard -> `impl-standard`.
Parallel-safe groups (disjoint files; no worktrees needed):
Phase 1: 1.2 (swiftformat, alone — must land first and be committed), then 1.3 ∥ 1.5 ∥ 1.4.
Phase 2: {D1+D5+D9: InstanceReconciler, InstanceManager delete/fail/isTearingDown, Orchestrator,
OrchestratorMetrics, RunnerVMMetrics, ImageManager sweep} ∥ {D2+D11: new `ProcessSpawn` target
+ Package.swift, RunProcess, HostProbe, WorkerLauncher attrs, WorkerSupervisor status log,
HostSetup/CommandRunner, MacOSProvisionStages, ImageBuilderRecovery} ∥ {D6: GitHubControl} ∥
{D4: vmworker, WorkerProtocol, Proto} ∥ {D7+D8: bootstrap.sh, APFSClone} ∥ {D10:
RunnerSessionManager, RunnerSessionRecovery}. D10 and D6 must be reviewed before Phase 3.
Phase 3: `Deadline.swift` first; then {gracefulShutdown: InstanceManager, InstanceReuse,
RunnerSessionObserver, GuestAgentClient, vmworker `--graceful-ms`, WorkerLauncher, OrchestratorTick
cancel detach} ∥ {jitGeneration: RunnerSessionManager, ActionsServiceConnection,
ActionsScaleSetClient, GitHubControlError}; then vmBoot (InstanceCreation, InstanceManager
watchers, InstanceTaint); then imagePull (ImagePulling, ImageManager, InstanceCreation) —
sequential because they share InstanceCreation/InstanceManager. Then 3.5 docs.
Phase 4: build-package.sh+postinstall+its test ∥ bootstrap.sh+its test ∥ Swift HostSetup
(`PackageSignature`, ReleaseManifest, Upgrader) + tests ∥ release.yml — after the manifest shape
(`teamId`, `notarized`) is fixed in the brief. Phases 5–7 are operator-driven with me preparing scripts, configs, and reading results.

## Whole-plan acceptance check

Code phases (0–4) are accepted when, on `master` after each phase: `swift package clean &&
swift build && swift test --parallel` reports 0 failures (known issue: `mknod` EPERM);
`make -C GuestAgent all` green; `shellcheck scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh`
clean; every `bash scripts/tests/*.sh` passes; `actionlint` clean; `swiftformat --lint Sources
Tests Package.swift` clean (from 1.2 on); CI green on the pushed commit. Release phases (5–7)
are accepted when `docs/verification.md` "v0.3.0 release gate" lists a run id or report file for
every item in Phase 5 and the curl one-liner installs the notarized pkg with no
`RUNNERVM_ALLOW_UNSIGNED`; the deferred reboot loop is stated as unqualified in the docs.

## Destructive steps (precondition -> rollback)

| Step | Precondition | Rollback |
| --- | --- | --- |
| 1.1 delete worktrees/branches | `git worktree list` shows the 8 `agent-*` entries; `git branch --merged master` shows none of them (content landed via patches — user confirmed) | none needed (throwaway clones); refuse if any worktree has uncommitted changes newer than 2026-08-29 |
| 1.2 swiftformat bulk | clean tree, tests green before | `git checkout -- Sources Tests` before commit |
| 0.5 blackpen bootout/remove | operator runs it; `launchctl print system/com.runnervm.runnerd` shows the loop | reinstall via curl at Phase 5 if ever needed |
| 5.2 production install on the dev Mac (creates `_runnervm`, LaunchDaemon, `/Library/Application Support/RunnerVM`) | user says go at that step; no dev daemon running; `~/runnervm-dev` absent | `docs/install.md` "Uninstall" (bootout, remove plist, dirs, account) |
| 5.x disk cleanup (caches, DerivedData) | operator picks what to delete | none |
| 5.6 reboots / power cuts | operator; no job running except the reboot-under-load step | none |
| Phase 4 `security` keychain ops in CI | temp keychain only; `if: always()` cleanup | `security delete-keychain` |

## Operator-only actions (cannot be delegated)

1. Push/tag/release for v0.2.1, v0.3.0-rc.N, v0.3.0.
2. blackpen sudo: bootout + remove (0.5).
3. Apple: certs, p12 export, notary key, 8 secrets (4.1).
4. Disk: free ~60 GiB on the dev Mac or attach an external APFS SSD (Phase 5).
5. GHCR PAT with `write:packages`; package visibility + repo connection (Phase 6).
6. Physical reboots and power cuts for the qualification loop (5.6).
7. Confirm deletion of the 8 stale worktrees (1.1).

## Unresolved questions

None. All decisions recorded above (2026-09-01/02).

## Run log

- 2026-09-02 0.3 DONE (inline): `.github/workflows/publish-images.yml` `schedule:` removed with rationale comment; `actionlint` clean. Operator still to cancel queued run 33504120630.
- 2026-09-02 0.4 DONE (inline, uncommitted): `RunnerVMVersion.current = "0.2.1"`; `scripts/tests/build-package-test.sh` derives `EXPECTED_VERSION` from Version.swift (was hardcoded 0.2.0 at two sites); suite: `46 passed, 0 failed`; shellcheck clean. CHANGELOG section owned by the 0.2 agent.
- 2026-09-02 1.1 DONE: precondition verified (8 worktrees, 0 uncommitted changes each, last commits 2026-08-27, none merged, content landed via patches); `git worktree remove --force` ×8, `git branch -D` ×8, `git worktree prune`. `git worktree list` = main only; free disk 57 → 99 GiB.
- 2026-09-02 0.2 DONE (impl-standard): README/SETUP/docs/release.md/docs/status.md/CHANGELOG now state v0.2.0 IS released (from red-CI d742a1c, fixed by fad78a0), v0.2.1 section added, GHCR "nothing published" with local build first. VERIFY: `grep -rn "unreleased\|No release is tagged\|not yet a release asset" README.md SETUP.md docs/release.md docs/status.md` → no output. Reviewed diff (71+/39-). Inline fix: status.md publish-images row said "monthly".
- 2026-09-02 0.1(a) DONE (impl-careful): install.sh section 6 creates `logs/runnerd` (0750, service owner) before section 7; plists ThrottleInterval 30, agent ExitTimeOut 60, `RUNNERVM_SUPERVISED=1`/`RUNNERVM_STARTUP_BACKOFF=60`; launchd README rules. VERIFY: `install-test.sh` 45 passed/0 failed (incl. "created before the launchctl bootstrap line"); shellcheck clean; `plutil -lint` OK ×2; LaunchdManagerTests 12/12; HostInstallerTests 26/26. Diff reviewed. Follow-up: install.sh/upgrade do not re-render an existing plist (doctor warns in 0.1(d)).
- 2026-09-02 0.1(c)(d) DONE (impl-careful): `HostProbe.run(deadline:)` (default 60 s) on a GCD queue with concurrent drain, SIGTERM→5 s→SIGKILL watchdog, distinct timeout log + fallback facts; new pure `RunnerCore/Doctor/DoctorLaunchd.swift` (`launchd_job` parses runs/last exit code → warn when runs>10 or exit≠0; `launchd_stdio_dir` fails when the plist's StandardOutPath directory is missing; `launchd_throttle` warns when ThrottleInterval<30). VERIFY: `swift test --filter HostProbe` 5/5 (hang stub falls back at 300 ms; 128 KiB stderr flood decodes); `swift test --filter Doctor` 52/52 incl. 13 DoctorLaunchdTests; DaemonRuntime 20/20. Deviation: throttle is its own check; remediation text says re-run `runnerctl setup` (no `--refresh-launchd` flag exists). Follow-ups: grandchild holding the pipe still blocks past SIGKILL (D2); `DoctorChecks.runProcess` has no timeout; `launchdJobLoaded` probes gui/ before system/ while service-mode detection prefers the daemon.
- 2026-09-02 0.1(b) DONE (impl-critical; reviewer-critical pass in flight): `Sources/Orchestration/StartupFailure.swift` (classes configuration/environment/unavailable/transient → 78/72/69/75, `retryable`-primary with commented overrides, `RUNNERVM_STARTUP_BACKOFF` clamp 0…300, `RUNNERVM_SUPERVISED`/`getppid()==1`, `StartupAttemptCounter` in `<runtime-dir>/startup-attempts` escalating after 10 transient failures, unreadable ⇒ escalate); `RunnerD.startupExit` sleeps (async) only when supervised, signal handlers still installed after a successful start; docs/install.md "runnerd exit codes". VERIFY: StartupFailureTests 11/11; DaemonRuntimeTests 20/20.
- 2026-09-02 Phase 0 full verification: `swift test --parallel` → `1758 tests in 205 suites passed` ×2 (1 known issue: mknod EPERM); all 9 bash suites pass (38/46/52/45/34/90/51/53/29); shellcheck, actionlint, `bash -n` clean; `make -C GuestAgent test` ok. Inline fix found by the parallel run: `HostProbe` watchdog moved from a GCD `asyncAfter` work item to a cooperative `Task` (under load every GCD thread was parked in blocking drains and the 300 ms deadline fired after ~11 s; `aProbeThatNeverExitsFallsBackAtTheDeadline` failed once, green ×2 after the fix).
- 2026-09-02 1.3 DONE (impl-careful): Go module path → `github.com/andrejvysny/RunnerVM/GuestAgent` (20 files: go.mod + imports + AGENTS.md + TODO.md). VERIFY: `grep -rn "github\.com/runnervm/guest-agent"` → only PLAN.md's own text; `make -C GuestAgent all` green (fmt-check, vet incl. linux vet, all packages ok); `go test -race` ok; darwin/linux cross-builds ok; `-version` prints. Inline: `go mod tidy` applied (x/sys promoted from indirect to direct). Note: `share/runnervm/guest-agent` install paths are unrelated and unchanged.
- 2026-09-02 1.5 DONE (inline): README "License and provenance" (Apache-2.0; 19 FSL-derived Tart files until 2027-05; 7 MIT-ported scaleset files; NOTICE for deps), NOTICE gains the actions/scaleset MIT attribution + dependency licenses (GRDB MIT, swift-nio/argument-parser/log Apache-2.0, Yams MIT, mdlayher/vsock MIT, x/sys BSD-3), PROVENANCE audit record 2026-09-02 (headers 19/19, 7/7 re-verified). Open/accepted: independent legal review of the FSL competing-use clause (PROVENANCE flags it; operator decision).
- 2026-09-02 0.1(b) reviewer-critical: fix-required → fixed inline. Findings: `ConfigLoadError` (CONFIG_YAML_SYNTAX/UNKNOWN_KEY/UNSUPPORTED_VERSION) escaped `startStages` raw and was classified environment/72 instead of 78 (live-reproduced) → `fixed(for:)` now maps any `RunnerError` whose code starts with `CONFIG_` to configuration; `VMError.workerSpawnFailed` (retryable) was transient → override to environment; `backoff` now trims newlines; docs row 75 reworded (busy at open/migrate exits 72). Tests: +3 loader rows, +1 spawn row, +1 newline case, override list = 3. Deferred (follow-up): a test pinning "signal handlers installed only after start" needs a runnerd test target; ambiguity resolved: an unwritable attempt counter keeps class transient/75 and only escalates the sleep. VERIFY after fixes: StartupFailure+DaemonRuntime 32/32; `swift test --parallel` → 1759 passed (1 known issue).
- 2026-09-02 PHASE 0 + 1.1/1.3/1.5 CODE-COMPLETE, awaiting operator commit. Pausing before 1.2 (swiftformat bulk must be its own commit on top of the committed Phase 0).
- 2026-09-02 DEVIATION: user asked to continue before committing Phase 0; 1.2 (swiftformat bulk, must be its own commit) is deferred until the Phase 0/2 commits exist; Phase 2 proceeds on the uncommitted tree matching file-local style (allowed by Constraints). Phase 2 launched as six disjoint groups: G1 D1+D5+D5b+D9 (impl-critical), G2 D2+D11 ProcessSpawn (impl-critical), G3 D6 (impl-careful), G4 D4+2.7 (impl-careful), G5 D7+D8 (impl-standard), G6 D10 (impl-critical).
- 2026-09-02 2.3/2.7 (G4) DONE (impl-careful): `WorkerService.abort(exitCode:)` runs teardown on every exit path incl. VZ start failure; exit 79 `vzStopFailed`, 80 `macOSGuestLimitReached` (`Run.exitCode(forSlotFailure:)` pure + tests); `VsockBridge(onRejected:)` logs rejected peer uid; Proto worker_protocol.md updated (exit codes, `stop`==`drain`, `agentBootId` dropped from the doc, deprecated in code). VERIFY: `swift test --filter "WorkerMessages|VMWorker|VsockBridge|WorkerProtocol|VirtualizationCore"` 72/72; `sign-dev.sh` + `vmworker probe --json` ok. Diff reviewed. Follow-ups: CHANGELOG line at the phase gate; SIGHUP still unhandled (accepted); real-VZ socket-teardown check is Phase 5.
- 2026-09-02 2.5 (G3) DONE (impl-careful): `GitHubCredentialProvider.invalidate()` (no-op default), `GitHubHTTPClient.send` = wrapper that on `.authentication` for an idempotent request drops the credential once (rate-limited by `Options.authRefreshInterval` 60 s, injected clock) and retries once; mint runs on a static-credential client (no recursion); JIT POST stays non-idempotent (tested). VERIFY: GitHubControlTests 121/121 incl. 5 new; OrchestrationTests 451 passed (signature sanity). Diff reviewed. Follow-up: `ChainedCredentialProvider` does not forward `invalidate()` (harmless today).
- 2026-09-02 2.6 D7+D8 (G5) DONE (impl-standard): `bootstrap.sh verify_pkg_name` (case globs) before `download_pkg`; `build-package.sh assert_pkg_name_valid`; `APFSClone.freeSpace(importantUsage:available:)` pure + once-per-process unreadable log; docs. VERIFY: bootstrap-test 53/53 (+15), build-package-test 46/46, shellcheck clean, ImageStoreTests 66/66. Diff reviewed.
- 2026-09-02 2.8 D10 (G6) IMPLEMENTED (impl-critical; reviewer-critical in flight): `RunnerSessionManager.registering: [RunnerSessionID: Date]` set before the first suspension in `register` (id minted before `insertRow`), cleared by `defer`; `recoverSessions` skips marks younger than `jitGeneration + 30 s` (profile from recovery context; placeholder profile ⇒ defaults); `recover` re-reads the row and skips when state moved or an observer appeared, acting on the fresh row. VERIFY: RunnerSession/Recovery/GitHubFault 49/49; `swift test --parallel` 1771 passed; counterfactual (guards removed) fails 14 expectations incl. "stale snapshot DELETEd a live registration"; new tests 5×/5× green. Deviations: `isRegistering(_:within:)` (grace from profile), test-side `GatedScaleSetPlane` instead of touching GitHubControl (delete in Phase 3 when `stallJITConfig` lands), skips counted as `deferred`. Follow-ups: wall-clock mark (clock jump), O(profiles) scan.
- 2026-09-02 D10 reviewer-critical: fix-required → round-1 feedback sent to the G6 agent: (1) re-stamp the mark after `issueJIT` + slack 60 s (mark must cover `deliver` + `startedAnyway`, ~60 s of guest calls after the JIT); (2) `ContinuousClock.Instant` not `Date`; (3) reap stale marks in `recoverSessions`; (4) test binding the `observers` half of the re-read guard (counterfactual showed it untested). Reviewer confirmed the 14-expectation counterfactual and that the mark precedes the first suspension.
- 2026-09-02 D10 round 1 APPLIED: mark re-stamped after `issueJIT`, slack 60 s, `ContinuousClock.Instant` marks, stale marks reaped in `recoverSessions`, new test `aRowSomebodyElseAdoptedUnderTheSnapshotKeepsItsObserver` binds the observer half of the guard (`observerTask` identity seam). VERIFY (agent, isolated scratch build): RunnerSession/Recovery/GitHubFault 50/50 ×3. Full parallel run re-checked by me at the Phase 2 gate.
- 2026-09-02 2.1/2.4/2.6-D9 (G1) IMPLEMENTED (impl-critical; reviewer-critical in flight): `InstanceManager.delete(id:expectedState:)` (re-read + ownership check + CAS from the judged state → `.deleted`/`.skipped`), counted `restarting` claims (`respawn` claims/releases; a Set lost the winner's claim when two respawns raced — caught by test), `fail()` stamps `stoppedAt`; `sweepRetired` reaps every lifecycle except owned rows and pinned maintenance rows; `retryStuckDeletes` one row per tick as a tracked task with an in-flight guard, in-memory first-seen ages (`DeletingLog`), grace 300 s injected; D5b `ImageManager.sweepStalePulls()` on first tick (fails closed if the operations table is unreadable); D9 `CancelBackoff` + pruning to live rows + clearing on success; both metric families + definitions. Tests: ReusableSweepTests (7), StuckDeleteTests (8), FakeWorker launch gate. VERIFY (agent): filtered 130/130; `swift test --parallel --skip ProcessSpawnTests` 1786 passed (ProcessSpawn failures belong to the in-flight G2). Follow-ups: pre-existing `teardown` bracket cleared by inner `stop` defer (make counted); `InstanceState` still permits `stopped -> startingWorker` (doc removed, edge kept); D5b cannot clear a `.pulling` row whose `pull-image` operation is still `running` after a crash; narrow window between `restartInterrupted`'s check and `respawn`'s claim (needs retention expiry, near-unreachable); deliberately `stopped` reusable VMs are now reaped after retention (CHANGELOG line at the gate).
- 2026-09-02 2.2 (G2) IMPLEMENTED (impl-critical; reviewer-critical in flight): new leaf target `ProcessSpawn` (SpawnControl Mutex phase machine — all `kill(-pgid)` under the lock, `.reaped` set by the single `waitpid`; SETPGROUP/CLOEXEC_DEFAULT/SETSIGDEF/SETSIGMASK; `PipeDrain` poll loop with absolute deadline `min(start+timeout+killGrace+drainGrace, leaderExit+drainGrace)` + final sweep; head+tail capture; status decoding), used by `RunProcess`, `HostProbe` (60 s + maintenance-tick re-probe while degraded), `WorkerLauncher` attrs, `HostSetup/CommandRunner` (60 s default; Upgrader/Rollback 900 s for download/installer). `BUILD_TOOL_TIMEOUT`; provisioning gets env allowlist, `--out`, `RVM_PROVISION_TIMEOUT = build.timeout − 5 min`; pgid+start-time marker in `<build dir>/.provision/provision.pgid` (deviation: no schema column) terminated by build recovery. VERIFY (agent): filtered 258 passed; `swift test --parallel` 1827 passed ×3; removing SETSIGDEF fails the discriminator test (137 ≠ 42). Follow-ups: `SmokeTest.swift:271` + `DoctorChecks.runProcess` still on Foundation.Process; InstanceManager/Orchestrator keep the startup probe after re-probe; `ProvisionProcessGroup.record` not exercised end-to-end by the fake.
- 2026-09-02 G1 reviewer-critical: fix-required → round 1 sent: re-arm retry grace (starvation + unthrottled retries), D5b first-tick rule (ignore `running` op on first tick; DECISION recorded), cancellable/joined retry task with deadline + `InstanceReconciler.stop()` from teardown, claim at top of `restartInterrupted`, CAS comment + non-stale error logging, test hygiene (gate defer, hang guards, dead helper). Reviewer confirmed: `fail()` stoppedAt safe, maintenance exception correct, counted claim cannot leak, ticks cannot overlap, D9 cardinality/prune/clear correct, the reported pre-existing teardown-bracket bug does not exist.
- 2026-09-02 G1 round 1 APPLIED: retry grace re-armed at `beginRetry` (wedged row retried once per grace; no starvation), `sweepStalePulls(firstTick:)` runs EVERY tick (first tick ignores the `running` operation; later ticks keep both checks — deviation accepted), `DeletingLog.shutdown()` + `InstanceReconciler.stop()` from `DaemonRuntime.teardown`, retry under a 2×grace deadline, claim at top of `restartInterrupted`, CAS comment + non-stale error warning, test hygiene, +5 tests (20 total). VERIFY (agent): filtered 135/135 ×2; `swift test --parallel` 1832 passed ×2. CHANGELOG "Unreleased — v0.3.0" section written by me with all Phase 2 bullets.
- 2026-09-02 PHASE 2 GATE (my verification, shared tree, before the G2 review verdict): `swift test --parallel` → `1832 tests in 214 suites passed` ×2 (1 known issue mknod); all 9 bash suites pass (53/46/52/45/34/90/51/53/29); shellcheck + actionlint clean; `make -C GuestAgent all` green. Phase 3 launched: 3.2 jitGeneration (impl-critical, also creates `Deadline.swift`, cancellable scale-set exchange, `stallJITConfig`) ∥ 3.4 gracefulShutdown (impl-careful, incl. guest call deadline, `--graceful-ms`, detached cancels). vmBoot then imagePull follow sequentially.
- 2026-09-02 G2 reviewer-critical: accept-with-fixes (adversarial experiments: 64 concurrent spawns 0 fd growth; setsid escape impossible for a SETPGROUP leader; detached holder bounded 0.41 s; self-stopped leader bounded). Round 1 sent: cancel arms the SIGKILL ladder + `SpawnResult.cancelled` (a cancelled build was held up to `build.timeout` and recorded as BUILD_TOOL_TIMEOUT), `waitid WNOWAIT` before reaping under the lock, orphan-group warning, re-probe only after a timeout, end-to-end test of the pgid marker seam, HostSetup runner keeps the full environment (curl proxy vars) + SmokeTest `ps` on the runner, honest module header. DECISION ratified: pgid marker file `<buildDir>/.provision/provision.pgid` (pid + start time) instead of a schema column. Accepted follow-ups: `InstanceManager`/`ImageManager` keep startup probe facts after a re-probe (values coincide on Apple silicon); `waitpid` on an uninterruptible leader is unbounded (same as Foundation.Process).
- 2026-09-02 3.4 DONE (impl-careful): `InstanceManager.gracefulShutdownMs(for:)`, `waitForWorkerExit(id:graceMs:)` with `workerExitAttempts` = min(max(floor,(grace+15 s)/poll), 120 s/poll); `InstanceReuse` sends the profile grace in `StopRunnerRequest`; `RunnerSessionObserver.timeOut` reads the frozen context; `GuestAgentClient.stopRunner` per-call deadline grace+15 s; `WorkerLaunchRequest.gracefulShutdownMs` → `vmworker run --graceful-ms` used by hard-deadline/orphan/signal paths; `OrchestratorTick.cancel` detached (`cancelTasks` keyed by id, `drainCancels`); `PROFILE_TIMEOUT_GRACEFUL_SHUTDOWN_LONG`; harness/fakes record grace; +tests. VERIFY (agent): filtered 191/191 ×2; `swift test --parallel` 1847 passed; `vmworker run --help` shows `--graceful-ms`; counterfactual (blocking cancel) fails the new tick test. Inline by me: `Orchestrator.stop()` cancels in-flight cancel tasks before joining (a wedged worker could hold teardown past launchd's 60 s ExitTimeOut; the row stays `deleting` and D5 finishes it after restart). Follow-ups: `RunnerSessionManager.Tuning.stopGraceMs` now dead (remove at the 3.2 merge); builder workers still launch with the default `--graceful-ms 30000` while their shutdown requests carry 120 s.
- 2026-09-02 G2 round 1 APPLIED: cancel arms a SIGKILL-after-`killGrace` task; `SpawnResult/ProcessResult/CommandResult.cancelled` checked before the timeout throw (→ `CancellationError` → `BUILD_CANCELLED`); `waitid(WNOWAIT)` then `waitpid(WNOHANG)` under the lock (invariant now true; `terminate` also refuses its own pgid); vanished-leader warning; re-probe only after a timed-out probe; marker seam tested end to end (streaming fake, recovery consumes an orphan marker); HostSetup runner passes the full environment, `pipeFailed` → `SETUP_COMMAND_FAILED`, `SmokeTest.vmworkerRunning` on the runner; honest header. VERIFY (agent): filtered 276 passed ×2; `swift test --parallel` 1847 passed. Phase 2 COMPLETE pending my next full run at the Phase 3 gate.
- 2026-09-02 Phase 4 launched in parallel with Phase 3 (disjoint files): 4A build-package.sh + postinstall + install.sh re-sign guard + distribution.md/release.md (impl-critical) ∥ 4B bootstrap.sh gate + tests (impl-critical) ∥ 4C Swift `RunnerVMSigning.expectedTeamID` (nil until certs exist), `PackageSignature.parse`, `ReleaseManifest` (+teamId/notarized, package-name validation, PKG_URL-beats-version precedence), `Upgrader.signatureStep` before rollbackMaterial, rollback gate, rc comparator fix (impl-critical) ∥ 4D release.yml (secrets fail-closed incl. the compiled team-id check, temp keychain, verify, prerelease, cleanup) (impl-careful). Fixtures for signed/notarized `pkgutil`/`spctl` output are synthetic until the first rc captures real ones (Phase 5 checkpoint). 3.1 vmBoot running; 3.3 imagePull queued behind it.
- 2026-09-02 4.4 (4D) DONE (impl-careful): release.yml = fail-closed signing gate (7 secrets + `vars.APPLE_TEAM_ID` + compiled `RunnerVMSigning.expectedTeamID` must exist and match), temp keychain (prepend search list, partition list redirected, p12s removed), identity derivation (installer without `-p codesigning`), notary key staged 0600, build with the 4A flags, pkg verification (pkgutil/stapler/spctl/jq manifest) BEFORE install, installed-binary verification for 4 Mach-Os, bootstrap smoke without `RUNNERVM_ALLOW_UNSIGNED`, `--prerelease` on `-` tags, `if: always()` cleanup, 90 min, concurrency group. `actionlint` clean; YAML parses. Inline by me: `get-task-allow` read from `codesign -d --entitlements :-` (the `-dv` dump has no entitlements). Follow-ups: build-package.sh flags land with 4A; `Signing.swift` with 4C; docs/release.md prose rewrite owned by 4A.
- 2026-09-02 4.3 Swift half (4C) DONE (impl-critical): `RunnerVMSigning.expectedTeamID` (nil until certs), pure `PackageSignature.parse` (structure-keyed, fail-closed: `Notarization:` must begin with `trusted`, spctl must show `: accepted` + `source=Notarized Developer ID`; forged lines via the package path are not evidence), `ReleaseManifest` (+teamId/notarized as claims, package-name validation incl. leading `-`, precedence overrideURL > version > latest), `Upgrader.signatureStep` between checksum and rollback-material, `confirmStep` decides from the verified signature (foreign team = unconditional refusal before any host mutation), rollback gate (sha256 + foreign-team refusal; unsigned cached pkg warns and proceeds), `--check` prints "manifest claims"; rc ordering numeric by dot segments. VERIFY (agent): filtered 199/199 ×2; GitHubControlTests 123 (shared SemanticVersion); counterfactuals: gate-never-rejects fails 8, rollback-skips-gate fails 10. Fixtures: unsigned + a real Developer ID/notarized Homebrew-cache pkg captured on this Mac; remaining synthetic ones marked for replacement at rc.1. Follow-ups: `manifest.version` unvalidated in cache paths (both installers) — fix at the Phase 4 gate; `rollbackMaterialStep` may prompt before `confirmStep` refuses a foreign pkg; docs samples for `--check` output.
- 2026-09-02 inline (4C follow-up): `ReleaseManifest.validate(version:)` at decode (MAJOR.MINOR.PATCH + optional `[0-9A-Za-z.-]` prerelease; `version` names the cache dir and rides on curl/spctl argv) + test; ReleaseManifest+Upgrader 69/69. bootstrap.sh gets the same check once 4B lands.
- 2026-09-02 3.2 IMPLEMENTED (impl-critical; reviewer-critical in flight): `Deadline.swift` (+HARD RULE doc); `issueJIT` under `withDeadline`, runner id published to a Mutex box, `failJIT` (id from box else bounded `strayRunnerID`) merges the id onto the closing CAS via `pendingRunnerID` so `finish` removes exactly once through the operations bracket; D10 mark re-stamped after JIT and before cleanup; `strayRunnerID` internal + scale-set plane first; `ActionsServiceConnection` waiters cancellable (shared exchange unstructured, un-awaited); exact-name re-filter; default `jitGeneration` 2 min; `PROFILE_TIMEOUT_JIT_GENERATION_SHORT`; fakes: `stallJITConfig(for:_:)` (.untilReleased/.pastCancellation), `Reply.delay`; `GatedScaleSetPlane` deleted. VERIFY (agent): filtered 248/248 ×2; `swift test --parallel` 1888 passed; counterfactuals (no id merge / no exact filter / non-cancellable waiter / zero limit) all fail. Deviations: removal via `finish` (not before it) to keep exactly-once; timing tests lead with ordering assertions (load-independent). Follow-ups: `M2Harness.gateway(scaleSetPlane:)` now unused; REST fallback for scale-set stray lookup assumes shared id space; a misplaced `clone` comment in ProfileValidation.
- 2026-09-02 3.2 reviewer-critical: fix-required → round 1 sent: warning + test for the both-lookups-fail orphan case; profile hold-down on GITHUB_* hand-off failures in `OrchestratorTick.assign` (retainVM=false otherwise loops create/destroy under slow GitHub with standing demand); delete dead `gateway(scaleSetPlane:)` and `Tuning.stopGraceMs`; correct the 2-min rationale (does NOT cover the full retry ladder — by intent); log a waiterless exchange failure; fake fixes (liveTickets guard, stopLoading race). Reviewer probes (3200 waiter races, 64-way exchange dedupe, group drains the loser before rethrow) all held. DECISION: 2 min default kept; earlier give-up + hold-down is the intended behaviour.
- 2026-09-02 4.3 bash half (4B) DONE (impl-critical): `bootstrap.sh verify_package_signature` (anchored pkgutil chain/notarization parsing — pkgutil echoes the package path, so unanchored greps were forgeable; `spctl --status` before `--assess`; `RUNNERVM_EXPECTED_TEAM_ID` constant, empty = unpinned with a loud line; foreign team = die with no override; our-team-unnotarized / unsigned = warn+confirm; manifest claims only feed a NOTE line; `notarized` optional for old manifests). VERIFY (agent): bootstrap-test 88/88 (was 53), shellcheck clean, bash 3.2 rerun green, six counterfactual mutations all fail, hermeticity canary 0 hits. Inline by me: `verify_manifest_version` (same rule as the Swift side) called before any download + 12 pure checks; stale "planned for a later milestone" wording replaced. Follow-ups: `RUNNERVM_EXPECTED_TEAM_ID` and `RunnerVMSigning.expectedTeamID` must be set byte-equal at 4.1; `manifest_field_fallback` treats empty as missing (unread keys only).
- 2026-09-02 3.2 round 1 APPLIED: orphan warning (instance, runner name, scope, `runnerctl runner list`) + test; `beginHoldDown` on `GITHUB_*` hand-off failures in `assign` (tick N+1 creates nothing; counterfactual fails); dead `gateway(scaleSetPlane:)` and `Tuning.stopGraceMs` deleted; 2-min rationale corrected everywhere; waiterless exchange failure logged; fake fixes (liveTickets, stopLoading race). VERIFY (agent): filtered 260/260 ×2; `swift test --parallel` 1892 passed. Note: assignment to an already-idle VM is not gated by hold-down (matches the VM-start path; warm pool during an outage) — accepted.
- 2026-09-02 3.1 IMPLEMENTED (impl-critical): `bringUp` vmBoot clock at `cloning`, checkpoints after stage/spawn (throw out of `create`, attributed to the phase), `watchBoot` watcher after `boot` (`bootWatchers`, cancelled on `running`/`releaseGuest`/`detachGuests`/newer boot; exits on `hasRunningVM`/terminal), `failBootTimeout(_:expecting:generation:stage:)` re-reads state AND workerGeneration, `fail()` reordered CAS-first returning Bool (record/metric/log only when landed); `respawn` gets the same watcher; validation warnings `PROFILE_TIMEOUT_VM_BOOT_SHORT`, `PROFILE_TIMEOUT_AGENT_READY_SHORT` (macOS); docs "Boot pace". VERIFY (agent): filtered 130/130 ×2; `swift test --parallel` 1892 passed; counterfactuals (no watcher / no fresh-state guard / record-before-check) fail the expected tests. Deviation accepted: hold-down after a watcher-detected timeout is emergent (the failed row's reservation until retention), same as the agentReady timeout; synchronous checkpoints arm the real hold-down. Follow-up sent (round 1): re-arm watchers for `startingVM` rows after a daemon restart. Other follow-ups: `waitForWorkerExit` swallows cancellation; `failure.json` now written after the transition.
- 2026-09-02 4.2 (4A) DONE (impl-critical): build-package.sh signs four Mach-Os on the staged payload (`--options runtime --timestamp` unconditional, explicit identifiers), `resolve_team_id` from the signature (`^[A-Z0-9]{10}$`), templated postinstall via a temp copy, `notarize_and_staple` (notarytool JSON, log on rejection, staple, validate) → re-verify → sha256 → 9-key manifest (`signed` from pkgutil, `notarized` from stapler validate, `teamId` from the binary); five optional flags with usage guards; postinstall verifies four binaries with the `-R` team requirement when baked (fails closed on a malformed/unsubstituted id); install.sh never re-signs a non-ad-hoc vmworker; docs distribution.md "Signing and notarization" + release.md runbook/rc install. VERIFY (agent): build-package-test 110/110, install-test 49/49, shellcheck clean, real ad-hoc pipeline produced a pkg whose four payload binaries read back `runtime` + identifiers; `pkgbuild --version 0.3.0-rc.1` accepted. Inline by me: stale "Unsigned phase" references in bootstrap.sh/docs/install.md. Follow-ups: notarize/staple path only mocked until the operator dry run.
- 2026-09-02 3.1 round 1 APPLIED: `rearmBootWatch` on the first tick for `startingVM` rows with a live worker (deadline rebuilt from `started_at` + vmBoot, clamped; adopted worker's reported VM state applied first so a guest that came up during the outage proceeds; past-deadline rows fail via the same CAS-guarded path on the watcher's first poll; dead workers left to `interruptDeadWorkers`). VERIFY (agent): filtered 133/133 ×2; `swift test --parallel` 1895 passed; counterfactuals bind. Follow-up: `handshake` never feeds `hello.vmState` into `onState` for other states (WorkerSupervisor, out of scope). reviewer-critical on 3.1 + 3.3 imagePull (impl-careful) launched.
- 2026-09-02 3.5 DONE (impl-standard): new `docs/configuration.md` (timeouts table sourced from code, PROFILE_TIMEOUT_* table, slow-links, retention/retries), README link. Follow-up for me after 3.3 lands: replace the doc's "no imagePull warning yet" note with `PROFILE_TIMEOUT_IMAGE_PULL_SHORT` and confirm the 60 min default text.
- 2026-09-02 Phase 4 seam review (reviewer-critical): fix-required → routed: release.yml now also gates `RUNNERVM_EXPECTED_TEAM_ID` in bootstrap.sh (a half-filled pin would have published an install.sh that accepts any Developer ID) + concurrency comment corrected (inline, actionlint clean); docs/release.md gains step 4b "Pin the Team ID in both installers" (inline); bash parity fixes sent to 4B (notarization `trusted` prefix, 10-char team rule/no `$` anchor, positive `assessments enabled` match, hoisted assessor-off notice, `v`-prefix tolerance); Swift fixes sent to 4C (anchored chain-leaf marker + path-forgery fixture, trailing-text/9-char team cases, ASCII digits in version core, leniency comment). Accepted: `rollbackMaterialStep` may prompt before the foreign-team refusal (order pinned by test, host untouched); PATH-resolved pkgutil/spctl in bootstrap (same trust as `installer`).
- 2026-09-02 4C parity round APPLIED: chain-leaf marker anchored (line start, optional `N.`), path-forgery fixture → `.unsigned`, real chain-line shapes incl. `[expired]` still parse, wrong-length team → `.unsigned`; `validate(version:)` core digits `isASCII && isNumber`; leniency asymmetry documented as deliberate. VERIFY (agent): PackageSignature|ReleaseManifest|Upgrader 86/86 ×2 (+4 tests); counterfactuals fail. Note: the anchor + the manifest charset rules are two halves of one defence (a line-initial forgery is impossible because `package`/`version` cannot carry spaces/colons/parens/newlines).
- 2026-09-02 3.1 reviewer-critical: fix-required → round 2 sent. MAJOR: the boot-timeout CAS did not carry the validated state/generation (`fail` re-read and CASed from the second read; WAL pool + reentrancy ⇒ a guest that reported `running` between the reads could be failed and its worker shut down) — fix by passing `from:`/`expectedGeneration:` into `InstanceRepository.transition` + an interleaving test; watcher must not `break` on a transient DB fault. MINOR: configuration.md hold-down wording (reservation, not hold-down, limits retries on the watcher path), GuestReadinessTests unguarded failure.json read, boot histogram polluted on adoption, missing workerPID in the post-spawn checkpoint record, generation-0 comment. Reviewer confirmed: record/metric/log only after a landed CAS, watcher lifecycle (no leak/double-register/successor clobber), clone-checkpoint teardown does not stall, planning pin safe, rearm ordering safe. Note: five boot tests use 3 s budgets (~14 s wall) — accepted with the attribution argument.
- 2026-09-02 4B parity round APPLIED: first-word `trusted` match, 10-ASCII-alnum team rule without `$` anchor (non-10-char group ⇒ unsigned path), positive `assessments enabled` match, assessor-off notice printed before any verdict, `RUNNERVM_VERSION` `v` normalisation; +19 tests (bootstrap-test 119/119; bash 3.2 rerun green; six counterfactual mutations fail; hermeticity canary 0). The "verify_manifest_version" edits in the same files were mine (coordinator) — no clobber. Phase 4 seam findings all closed.
- 2026-09-02 PHASE 4 CODE-COMPLETE: script gate bash suites 119/110/52/49/34/90/51/53/29 pass; shellcheck (incl. postinstall) + actionlint clean. Operator prerequisites remain (4.1: certs, p12s, notary key, 7 secrets + `APPLE_TEAM_ID` variable, then set `RunnerVMSigning.expectedTeamID` and `RUNNERVM_EXPECTED_TEAM_ID`; release.yml refuses to run until both pins match).
- 2026-09-02 3.1 round 2 APPLIED: `InstanceManager.transition(expectedGeneration:)` + `fail(expecting:generation:workerPID:)` commit the validated read (no re-read) with the generation fenced in the same write transaction; interleaving tests via an internal `afterBootTimeoutRead` hook (state moved / generation bumped between read and commit → no `.failed`, no record, no shutdown; counterfactual reproduces the reviewer's four failures); refused commit keeps watching (logged once); configuration.md hold-down wording corrected; GuestReadinessTests waits for failure.json; adoption skips the boot histogram; workerPID threaded; generation-0 comment. VERIFY (agent): filtered 136/136 ×2; `swift test --parallel` 1905 passed. 3.1 DONE. Not done: a dedicated test for the post-spawn checkpoint (needs an injectable clock in InstanceCreation — follow-up).
- 2026-09-02 3.3 DONE (impl-careful): `beginPull` no longer awaits the unstructured operation Task; `resolveRecord(timeout:)` → `boundedPull` (phase 1 raced with `withDeadline`, phase 2 `awaitInFlightPull` polls `inFlightPulls[digest]?.task != mine` against a ContinuousClock instant, returns the ready record or throws the transfer's real code read from its `pull-image` row); `reserve(pullTimeout:)`; `create` releases the planning pin on any throw; default `imagePull` 60 min; `PROFILE_TIMEOUT_IMAGE_PULL_SHORT`; docs images.md/daemon_api.md/CHANGELOG. VERIFY (agent): filtered 115/115 ×2; `swift test --parallel` 1905 passed ×2; counterfactuals fail. Deviation accepted: unbounded callers now also go through the poll path (one behaviour; a failed shared pull surfaces the transfer's own code). Inline by me: configuration.md gains the new warning row. Reported intermittents under --parallel (not reproducible alone): `ReusableSweepTests.aRespawnInFlightOwnsItsRowAndNoSweepMayTakeIt`, `GitHubFaultTests.aStalledTokenExchangeIsAbandonedAtTheDeadlineNotWaitedOut` — checked at the gate below.
- 2026-09-02 PHASE 3 GATE: `swift test --parallel` 9/10 runs green (1905 tests, 1 known issue); the one failure is `GitHubFaultTests.aStalledTokenExchangeIsAbandonedAtTheDeadlineNotWaitedOut` (first-leg request count 0 ≠ 1 under load — the deadline can fire before URLSession dispatches the first leg; assertion is timing-dependent, not the code) → fix sent to the 3.2 agent. `aRespawnInFlightOwnsItsRowAndNoSweepMayTakeIt` (reported once by another agent mid-edit) did not fail in 10 gate runs + 6 filtered runs.
- 2026-09-02 release-config check: `swift build -c release` runnerd/runnerctl/vmworker all succeed (the CI/Homebrew shape). Working tree: 137 files changed (+8207/−797) + 19 new files/dirs, all uncommitted.
- 2026-09-02 3.2 flake fix APPLIED (test only): the stalled-exchange test enters the deadline race only after the fake recorded the first leg (warm-up caller), so `== 1` now asserts exchange sharing; 10/10 filtered + 3/3 full runs green; counterfactual still binds.
- 2026-09-02 PHASES 0–4 GATE (my final runs): `swift test --parallel` green ×2 (1905 tests, 1 known issue); Go tests ok; bash suites/shellcheck/actionlint/release build green (above). Handing the commit + release-shape decision to the operator; swiftformat bulk (1.2) queued right after the first commit.
