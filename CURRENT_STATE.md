# Current State

Last verified: 2026-09-02 19:54 (local)

- **Branch:** `master` at `fad78a0`, 0 commits ahead of `origin/master`, **dirty**: 137 tracked files
  modified (+8207/−797) plus 19 untracked files/dirs — the whole v0.3.0 hardening run (PLAN.md
  Phases 0–4) is uncommitted. Nothing has been committed, pushed or tagged this session.
- **Changed files (by area):**
  - Startup/launchd (Phase 0): `Sources/Orchestration/StartupFailure.swift` (new), `Sources/runnerd/RunnerD.swift`,
    `Sources/RunnerCore/Doctor/DoctorLaunchd.swift` (new), `Sources/runnerctl/Doctor*.swift`, `scripts/install.sh`,
    `packaging/launchd/*.plist`, `Sources/RunnerCore/Version.swift` (= `0.2.1`).
  - Hygiene (Phase 1): `GuestAgent/**` (module path `github.com/andrejvysny/RunnerVM/GuestAgent`), `NOTICE`,
    `PROVENANCE.md`, `README.md` "License and provenance". `.claude/worktrees` deleted (10 GB).
  - Defects (Phase 2): `Sources/ProcessSpawn/` (new leaf target) + `Package.swift`, `Sources/Orchestration/{InstanceReconciler,
    InstanceManager,InstanceTaint,ImagePulling,Orchestrator*,Reconciler,Build/RunProcess,Build/ProvisionProcessGroup(new),
    Build/MacOSProvisionStages,Build/ImageBuilderRecovery,HostProbe,DaemonServiceMaintenance,RunnerSessionManager,
    RunnerSessionRecovery}.swift`, `Sources/GitHubControl/{Credentials,HTTP}/*`, `Sources/vmworker/*`,
    `Sources/WorkerProtocol/WorkerMessages.swift`, `Sources/VirtualizationCore/VsockBridge.swift`, `Sources/HostSetup/
    {CommandRunner,SmokeTest,Upgrader,UpgraderRollback}.swift`, `Sources/ImageStore/APFSClone.swift`, `Sources/Metrics/RunnerVMMetrics.swift`,
    `scripts/bootstrap.sh`, `Proto/worker_protocol.md`.
  - Timeouts (Phase 3): `Sources/Orchestration/Deadline.swift` (new), `InstanceCreation.swift`, `InstanceGuestAgent.swift`,
    `ImageManager.swift`, `GuestControl/GuestAgentClient.swift`, `WorkerLauncher.swift`, `WorkerSupervisor.swift`,
    `ActionsServiceConnection.swift`, `RunnerCore/Models/RunnerProfileConfig.swift` (defaults: imagePull 60m, jitGeneration 2m),
    `RunnerCore/Configuration/ProfileValidation.swift`, `docs/configuration.md` (new), `docs/state_machines.md`.
  - Signing (Phase 4): `scripts/build-package.sh`, `packaging/pkg/scripts/postinstall`, `scripts/bootstrap.sh`,
    `.github/workflows/release.yml`, `Sources/RunnerCore/Signing.swift` (new, `expectedTeamID = nil`),
    `Sources/HostSetup/{PackageSignature(new),ReleaseManifest,Upgrader,UpgraderRollback,UpgradeReport}.swift`,
    `Sources/runnerctl/UpgradeCommand.swift`, `docs/design/distribution.md`, `docs/release.md`.
  - Docs/process: `CHANGELOG.md` ("Unreleased — v0.3.0" + "v0.2.1 patch" sections), `docs/status.md`, `SETUP.md`,
    `docs/install.md`, `.github/workflows/publish-images.yml` (cron removed), `PLAN.md` (run contract + run log), `TODO.md`.
- **Build/test:** `swift test --parallel` → 1905 tests / 217 suites pass (1 known issue: mknod EPERM), green on the
  last 5 consecutive runs; `swift build -c release` runnerd/runnerctl/vmworker → pass; bash suites →
  bootstrap 119, build-package 110, build-ubuntu-image 52, install 49, live-macos-e2e 34, provision-macos-tart 90,
  publish-images 51, qualify-host 53, qualify-macos-image 29, all 0 failed; `shellcheck scripts/*.sh scripts/lib/*.sh
  scripts/tests/*.sh packaging/pkg/scripts/postinstall`, `actionlint` → clean; `make -C GuestAgent all` → green.
  `swiftformat --lint` NOT run (bulk format deliberately deferred to its own commit).
- **Key decisions:** v0.3.0 = first public release (Developer ID signed + notarized in CI); Linux AND macOS
  supported (H3–H5 on the dev Mac; 10-reboot loop DEFERRED, documented as unqualified); reusable kept + reaper
  fixed; blackpen decommissioned; GHCR publish manual; FSL-derived files kept and documented; timeouts all
  enforced (jitGeneration default 2 min by intent does not cover the full retry ladder; hold-down governs);
  pgid of provisioning scripts persisted as a file in the build dir, not a schema column; vmworker exit codes
  79/80; runnerd sysexits 69/72/75/78 with supervised backoff. Full list: PLAN.md "Decisions" + run log.
- **Blockers:** (1) the user must commit (their rule; no commit was made) — the v0.2.1 patch is no longer
  separable by file, decision pending: skip v0.2.1 and go to `v0.3.0-rc.1` after the signing setup (recommended)
  or add an unsigned escape hatch to release.yml for `v0.2.x`; (2) Apple Developer ID certs, p12 exports, notary
  key, 7 secrets + `APPLE_TEAM_ID` variable, then set `RunnerVMSigning.expectedTeamID` (Swift) and
  `RUNNERVM_EXPECTED_TEAM_ID` (bootstrap.sh) — release.yml refuses to run until all agree; (3) hardware matrix
  (Phase 5) needs ~120 GiB free on the dev Mac (99 GiB now) or `host.overcommit.disk`.
