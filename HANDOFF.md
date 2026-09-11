# Handoff — v0.3.0 pre-release review, finish & hardening run

Session 3 · 2026-09-02 · previous handoffs: `git log` (`a3cca52`, Mac mini deployment)

## Goal

Ship RunnerVM's first real public release (`v0.3.0`): a senior review of correctness and long-term quality,
then finish + harden — signed/notarized pkg, enforced timeouts, reaper/process fixes, and a hardware-validated
Linux + macOS runner host — per the approved plan.

## Original plan

`~/.claude/plans/act-as-senior-swift-giggly-hamming.md`, copied to repo `PLAN.md` (status `ready`, all decisions
recorded, adversarial plan review folded in). Phases: 0 v0.2.1 patch → 1 hygiene → 2 defects → 3 timeouts →
4 signing → 5 hardware matrix on the dev Mac → 6 GHCR publish → 7 tag v0.3.0. Execution via the
fable-orchestrator: tiered subagents, every critical diff adversarially reviewed, run log appended to `PLAN.md`.

## Done so far (and why)

- **Review findings that reframed the work:** the Mac mini's 70k launchd respawns were a launchd *spawn*
  failure (the plists' stdio directory `<state>/logs/runnerd` never existed on a from-source install; runnerd
  never ran once) — fixed in install.sh + plists + doctor + an in-binary supervised backoff. `v0.2.0` had been cut
  from a red-CI commit; docs said "unreleased". Dev state root `~/runnervm-dev` is gone (macOS image must be
  re-provisioned — that exercises native managed provisioning, which was never run live).
- **Phases 0–4 code-complete and verified** (see CURRENT_STATE.md). Highlights and the reasoning:
  - Reapers: reusable instances that never reached idle were never deleted; now every `failed/interrupted/stopped`
    row past retention is reaped unless owned by an in-flight delete/respawn or pinned maintenance, with the sweep
    committing through a compare-and-swap on the state it judged (a plain `delete` could tear down a VM a respawn
    had just booted). Stuck `deleting` rows are retried once per 5 min off the tick.
  - `ProcessSpawn`: `Foundation.Process` inherited runnerd's SIG_IGN for SIGTERM (so the "graceful" leg was dead),
    and a grandchild holding the pipe (`expect` setsid()s its child) hung builds forever. Now posix_spawn with a
    private process group, SETSIGDEF, group SIGTERM→SIGKILL, deadline-bounded drain, cancel escalation.
  - Timeouts: `imagePull`/`vmBoot`/`jitGeneration`/`gracefulShutdown` were parsed but never enforced. vmBoot is a
    background watcher (the `instance.create` RPC still returns at `startingVM`) whose failure CAS carries the
    validated state AND worker generation (first version could fail a healthy guest — caught in review);
    jitGeneration needed a cancellable scale-set token exchange; gracefulShutdown had to reach the guest
    `stopRunner` call deadline or any grace > 30 s became a SIGKILL at 30 s.
  - Session recovery could terminalize a live registration mid-JIT (row existed, observer not yet) and acted on
    stale snapshots — fixed with an ownership mark (monotonic clock, re-stamped per stage) + re-read.
  - Signing: both installers verify the pkg themselves (manifest flags are never evidence), keyed on notarization,
    with a compiled-in team pin in Swift AND bootstrap.sh; release.yml fails closed without secrets or if either
    pin is empty/mismatched; stapling rewrites the pkg so checksum/manifest are computed last; the darwin guest
    agent must be signed too (notary scans every Mach-O). Signed/notarized `pkgutil`/`spctl` fixtures are partly
    synthetic until the first rc.
- **Dead-ends / decided:** Set-based restart claims lost the winner's claim under a double respawn (counted map);
  a GCD watchdog fired 11 s late under parallel test load (cooperative Task instead); `manifest.version`/`package`
  are validated in both installers because they ride on argv/paths; `waitpid` on an uninterruptible leader cannot
  be bounded (documented); the v0.2.1 patch is no longer separable from the tree.

## How to resume

1. Run the `handoff` skill with "resume". Read `CURRENT_STATE.md`, then `PLAN.md` "Run log" (bottom) and
   "Decisions"; memory file `runnervm-v030-release-plan.md` has the compressed history.
2. Verify: `swift test --parallel 2>&1 | grep "Test run with"` (expect 1905 pass, 1 known issue) and
   `for t in scripts/tests/*.sh; do bash "$t" | tail -1; done`. If the shared `.build` SIGSEGVs after struct
   changes, `swift package clean` first.
3. Next actions, in order: (a) user commits (two commits suggested in the last session message: hygiene, then the
   hardening feature commit); (b) run Phase 1.2 — `swiftformat Sources Tests Package.swift` as ONE commit, then add
   `brew install swiftformat` + `swiftformat --lint Sources Tests Package.swift` to the `lint` job in
   `.github/workflows/ci.yml`; (c) resolve the v0.2.1-vs-rc.1 decision and retitle the CHANGELOG sections;
   (d) Phase 5 checklist (PLAN.md "Phase 5"): free disk, rc.1 signed install via the rc-specific install.sh URL
   with `sudo RUNNERVM_VERSION=... bash`, Linux live matrix, managed macOS provisioning, H3 (overcommit allowed,
   recorded)/H4/H5, single reboot check, `docs/verification.md` "v0.3.0 release gate".
4. Operator-only items still open: `gh run cancel 33504120630`; blackpen `sudo launchctl bootout
   system/com.runnervm.runnerd` + remove plist/binaries; merge dependabot PR #1; Apple certs/p12/notary key/secrets
   + both team pins; disk cleanup; GHCR `write:packages` PAT for the manual publish.

## Open questions

- Skip the v0.2.1 tag and go straight to `v0.3.0-rc.1` after the signing setup (recommended), or add an unsigned
  escape hatch to release.yml for `v0.2.x` tags so v0.2.1 ships now?
- Independent legal review of the FSL "competing use" clause (PROVENANCE.md flags it) — accepted for v0.3.0
  unless the operator decides otherwise.

## Pointers

- Tasks → `TODO.md` · Snapshot → `CURRENT_STATE.md` · Contract + run log → `PLAN.md` · Evidence →
  `docs/verification.md` · Timeouts reference → `docs/configuration.md` · Signing runbook → `docs/release.md`
