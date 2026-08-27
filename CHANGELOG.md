# Changelog

Dates are when the work landed on `master`; see `docs/verification.md` for what was proven live.

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
