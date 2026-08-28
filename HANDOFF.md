# Handoff — RunnerVM production hardening pass

Session 1 · 2026-08-27

## Goal

Harden the single-host RunnerVM daemon for production ephemeral Linux/arm64 runners: deterministic
CI, restart recovery, fail-closed capacity, isolation of build inputs and reusable VMs, bounded
caches, and live GitHub / GHCR / fault-injection evidence — with every claim tiered (unit /
integration / hardware / live / production-qualified). Spec: the WP0–WP11 brief in the first
message of this session; plan: `~/.claude/plans/runnervm-production-hardening-indexed-sun.md`.

## Original plan

WP0 determinism → WP1 session recovery → WP2 build-recovery capacity → WP3 NUL tar list →
WP4 reusable guard + HOME reset → WP5 bounded base cache → WP6/WP11 ARG semantics + debt →
WP8 fault-injection harness → WP7/WP10 live scripts and runs → WP9 doctor/qualify → docs.
Implementation delegated per `fable-orchestrator` (Opus/Sonnet worktrees, each reviewed, merged
by cherry-pick onto master, pushed after every green local run).

## Done so far (and why)

- **All eleven work packages landed on master** (`74ecb12` … `a771905`, 20 commits). Evidence and
  root causes: `docs/verification.md` "Production hardening pass"; state: `docs/status.md`;
  what shipped: `CHANGELOG.md`.
- **Defects only the live runs found, all fixed:** `system drain --wait` exited 1 on an idle host
  (`drained:false`); restart-terminalized sessions kept their VM running for the 2 h retention;
  first pass after a restart cancelled a just-booted VM on registration-time `assignedJobs: 0`
  (now `DemandSnapshot.confirmed`); `image delete` of any image that had run a job failed with
  `DB_FOREIGN_KEY`; the push's immutable `@sha256:` reference was thrown away; e2e workflow's
  `long` job ignored cancellation (bash + foreground `sleep`); `BuildContextPackerTests` green on
  macOS 26 but red on CI's macOS 15 (Foundation relative-URL/`resolvingSymlinksInPath` drift).
- **Dead-ends / decisions:** do not widen timeouts to fix flakes (root causes fixed; waits are
  event-driven); `interrupt` must write the row before dropping the guest client; never `swift
  build` while a live run boots VMs (relink strips vmworker's signature — run `scripts/sign-dev.sh`
  after every build); after struct-layout changes `swift package clean` (stale `.build` SIGSEGVs the
  test process); `pkill -f` patterns kill Monitor scripts that contain the same string — use the
  `[l]ive-…` trick; the dev repo is its own e2e test repo (`.github/workflows/e2e.yml`).
- **Skipped on operator instruction:** `long-job` live scenario; LaunchDaemon install + 10-reboot /
  cold-power-cycle qualification (tooling for it is done and hardware-verified).
- **In flight at hand-off:** `scripts/live-builder-faults.sh --phase all`. The daemon behaved
  as designed at every phase seen so far (`booting`: kill -9 → `recoveryPending=yes` while the
  orphaned vmworker lived → `failed`/`BUILD_INTERRUPTED` once it was gone; `provisioning` same
  without the pending window). Both were *reported* as fail by a **driver bug**: the script builds
  every phase under one `--name faults-<ts>`, so by the third phase three succeeded images answer
  to that alias and the "at most one image" assertion trips. `queued/resolving/staging` are
  unobservable on a warm local-base build (they pass in <200 ms). Fix the driver (per-phase alias
  or scope the image check to the phase's own `imageDigest`; treat "never observed" as skipped),
  rerun, record in `docs/verification.md`.

## How to resume

1. Run the `handoff` skill with "resume".
2. `swift build && scripts/sign-dev.sh && swift test --parallel`; `gh run list --branch master
   --workflow ci --limit 3` (confirm `a771905` green).
3. Live environment: `RUNNERVM_VMWORKER=$PWD/.build/debug/vmworker .build/debug/runnerd --foreground
   --state-dir ~/runnervm-dev --socket-dir /tmp/rvm` (config already applied: scale-set demand,
   `security.allowPublicRepositories: true`, PAT in keychain via `runnerctl auth login`, GHCR
   credential stored). Env for scripts: `RUNNERVM_E2E_OWNER=andrejvysny
   RUNNERVM_E2E_REPO=andrejvysny/github-managed-runners RUNNERVM_GITHUB_TOKEN=$(gh auth token)`.
4. Next task: finish/rerun the builder fault phases
   (`RUNNERVM_FAULTS_DAEMON_UP_TIMEOUT=600 scripts/live-builder-faults.sh --recipe
   images/recipes/ubuntu-24 --phase booting --phase provisioning --phase sealing --state-dir
   ~/runnervm-dev --socket-dir /tmp/rvm`; stop any foreground runnerd first — the script runs its
   own), fix the driver's "phase never observed" handling for warm builds, record results in
   `docs/verification.md`.

## Open questions

- Startup stall: twice a restarted `runnerd` sat silent for minutes after "demand provider"; not
  reproduced on demand. Retried GitHub/Actions calls are now logged — if it recurs, the log names
  the call; otherwise `sample <pid>` while stalled.
- LaunchDaemon qualification remains open until the operator schedules reboots.

## Pointers

- Tasks → TODO.md ("Production hardening pass" section) · Snapshot → CURRENT_STATE.md ·
  Evidence → docs/verification.md · Memory → `runnervm-hardening-pass.md`
