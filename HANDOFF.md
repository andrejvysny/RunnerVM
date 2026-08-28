# Handoff — first headless deployment (Mac mini `blackpen`)

Session 2 · 2026-08-28 · previous session's notes are in `git log` (`a3cca52`)

## Goal

Deploy RunnerVM onto the Mac mini reached as `ssh blackpen` and exercise it for real: functionality,
autoscaling, parallel VMs, cleanup, and at least one macOS guest. Not a rehearsal — a live host
serving `andrejvysny/RunnerVM`.

## What happened

The Mac mini is the first host that is not the development Mac, and the first one with **no GUI
login session** — which is the state a LaunchDaemon and any unattended Mac are actually in. That
single difference exposed five defects, two of which made the daemon completely non-functional
there. All five are fixed; the deployment then passed everything asked of it.

Full record, including host layout, sizing rationale and the tested/skipped list:
`docs/verification.md`, "Mac mini deployment". What shipped: `CHANGELOG.md`.

## Results

- **Linux, on blackpen:** `image build` 2/2 (`ubuntu-24-minimal` 2 m 56 s, `ubuntu-24` 1 m 30 s);
  single job with the guest agent ready 5.5 s after demand; 3-way matrix at capacity; 6-way matrix
  at 2× capacity (never exceeded 3, drained and refilled in waves); 4-way matrix;
  `scripts/live-github-e2e.sh` **11/11** including both restart-during-job scenarios and the
  `kill -9` one. `long-job` (65 min) skipped.
- **Storage:** after ten jobs — 0 VMs, 0 instance directories, 0 `vmworker` processes, 0 stranded
  GitHub runner registrations, free disk unchanged. Per-job storage is fully reclaimed; what
  outlives a job is now bounded explicitly in that host's config (`images.cache.maxSize`,
  `logging.retention.instanceLogs`, `build.cache.maxBytes`, `diagnostics.failedInstanceRetention`).
- **macOS:** one guest proven on the **development Mac**, on a freshly re-provisioned hardened
  image `macos-26` — GitHub run 33159698945, 7 s job, ~23 s cold start, `capabilities.ssh: false`,
  clean teardown. It does not fit on the Mac mini (below).

## Defects fixed (all in `3d8fae8`)

1. `APFSClone.freeSpace` returned **0** in any session without a login window, because
   `volumeAvailableCapacityForImportantUsage` is computed by a per-login-session service. Daemon sat
   in permanent `critical` disk pressure and advertised `capacity=0` — no VM ever scheduled. Would
   have broken the documented LaunchDaemon variant identically. Falls back to
   `volumeAvailableCapacity`; `doctor` now delegates to the same function instead of reading the
   volume keys a second time.
2. `ImageBuilder.updateConfiguration` was **never called**, so the whole `build:` block was ignored
   and `host.reserve.disk` stayed at its 50 GiB default — every build refused. Added to the
   `ImageBuildService` protocol, wired into both config-application paths.
3. Disabling a profile did **not** close its scale-set message session, so a stale daemon kept
   answering job messages and took the session back at the other host's next restart — it stole a
   live job mid-suite. `refresh()` now retires sessions whose profile is no longer enabled.
4. `scripts/provision-macos-tart.sh` could never verify its payload over password SSH: the `expect`
   pty's `password:` prompt leaked into the compared output.
5. `runnerctl status` hardcoded "Scale sets: 0 healthy".

## Dead-ends / decisions worth keeping

- **Do not give `ImageBuildService.updateConfiguration` a default implementation.** A
  protocol-extension no-op outranks the actor's own method at a concrete call site; the version that
  had one silently disabled the build harness's configuration and four lifecycle tests started
  failing (6.7 s green → 80 s with four failures).
- **In `retire`, cancel the poll task before closing the session.** `ensureSession` re-opens a
  missing session at the top of every poll, so closing first just hands the loop a fresh one.
- **Never run two daemons against one scope with the same profile name.** Disabling the profile is
  the remedy and now actually works (defect 3). Nothing calls `deleteScaleSet`, so removing a
  profile from one host's config leaves the other host's scale set alone.
- **Virtualization.framework needed no unlocked login keychain** on macOS 26.5.2 — every VM booted
  with `doctor` reporting `FAIL Login keychain`. Documented as counter-evidence in
  `packaging/launchd/README.md` and `docs/qualification.md`, not as a qualification.
- macOS profile disk must be **`50000000000` bytes exactly**; `47GiB` is rejected by the exact-size
  rule.

## How to resume

1. Run the `handoff` skill with "resume". Read `CURRENT_STATE.md`, then
   `docs/verification.md` "Mac mini deployment".
2. `swift build && scripts/sign-dev.sh && swift test --parallel` (expect 1379 pass, 1 known issue).
3. Mac mini: `ssh blackpen '/Users/blackpen/.local/bin/runnerctl --socket
   /Users/blackpen/runnervm/run/runnerd.sock status'`. If `runnerd` is not up (it does not survive a
   reboot), start it with `/Users/blackpen/rvm-restart.sh`.
4. Next tasks are in `TODO.md`, "Mac mini deployment (2026-08-28) — follow-ups".

## Open — needs the operator

- **`sudo` on the Mac mini**, for three things: install the LaunchDaemon (plist already rendered and
  lint-clean at `/Users/blackpen/com.runnervm.runnerd.daemon.plist`), create the dedicated
  `_runnervm` account/group so the install stops relying on `--group staff` plus a hand-set 0700
  state directory, and run the reboot qualification loop in `docs/qualification.md`.
- **macOS on the Mac mini is blocked on disk** — needs ~20 GiB more than exists. A guest reserves
  the image's full 50 GB virtual disk (no APFS resize), so one guest needs ~80 GiB free; the host
  has 62 GiB and ~11 GiB reclaimable. The only large reclaimable area is another user's home.
  Either free space, produce a smaller macOS image, or accept Linux-only there.
- **`scripts/qualify-macos-image.sh` (H2) cannot pass as written** — its `vm create` instance is
  surplus with zero GitHub demand, so scale-to-zero removes it before the agent connects. Needs
  `demand: manual`, a pin, or a mode that suspends scale-to-zero.
- **`doctor`'s `Login keychain` check is a false negative on macOS 26.5.2** — decide whether it
  should warn, probe for what it actually cares about, or go.

## Pointers

- Tasks → `TODO.md` ("Mac mini deployment (2026-08-28) — follow-ups", "M8") · Snapshot →
  `CURRENT_STATE.md` · Evidence → `docs/verification.md` · Install layout → `docs/install.md`
  ("One host per profile name, per scope") · macOS → `docs/macos-guests.md`
