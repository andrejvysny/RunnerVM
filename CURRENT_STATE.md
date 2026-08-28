# Current State

Last verified: 2026-08-28 12:05 (local)

- **Branch:** `master`. The Mac mini deployment work landed as `3d8fae8` plus a docs commit on
  `fix/headless-deployment-defects`, merged to `master`; nothing is left uncommitted.
- **Build/test:** `swift build && swift test --parallel` → **1379 tests / 174 suites pass** (1 known
  issue: `mknod` needs root). `shellcheck scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh` clean;
  `bash scripts/tests/provision-macos-tart-test.sh` → 75/75. `swiftformat --lint` unchanged from
  `HEAD` on every touched file (the pre-existing violations in `DaemonServiceImpl.swift` and
  `DoctorChecks.swift` are untouched).
- **Deployed:** RunnerVM runs on the Mac mini `blackpen` (`ssh blackpen`) — Apple M4, 32 GiB,
  macOS 26.5.2, headless. Serves `andrejvysny/github-managed-runners` on profile `ubuntu-24`,
  3 concurrent VMs, images `ubuntu-24-minimal` + `ubuntu-24` built on the host. Install is
  user-scoped and root-free: prefix `/Users/blackpen/.local`, state `/Users/blackpen/runnervm`,
  runtime `/Users/blackpen/runnervm/run`, PAT at `<state-dir>/state/github-token` (0600).
  `runnerd` is a **detached foreground process** — it does not survive a reboot.
- **Proven live on that host (2026-08-28):** `runnerctl image build` 2/2; single job (guest agent
  ready 5.5 s after demand); 3-way matrix at capacity; 6-way matrix at 2× capacity (never exceeded
  3, drained in waves); 4-way matrix; `scripts/live-github-e2e.sh` **11/11** (`long-job` skipped).
  Per-job storage fully reclaimed: 0 VMs, 0 instance directories, 0 stranded GitHub runners, free
  disk unchanged across ten jobs.
- **Proven live on the dev Mac (2026-08-28):** one macOS guest on a freshly re-provisioned hardened
  image `macos-26` (`capabilities.ssh: false`) — GitHub run 33159698945, 7 s job, ~23 s cold start,
  clean teardown. macOS does **not** fit on the Mac mini (needs ~20 GiB more).
- **Five defects found by the headless host, all fixed:** free space read 0 without a login session
  (daemon advertised `capacity=0`); the image builder never received the applied configuration
  (whole `build:` block ignored, every build refused); disabling a profile did not close its
  scale-set session (a stale daemon stole a live job); `provision-macos-tart.sh` could never verify
  its payload over password SSH; `runnerctl status` hardcoded "Scale sets: 0 healthy". Detail:
  `CHANGELOG.md` and `docs/verification.md` "Mac mini deployment".
- **Key decisions:** `--group staff` on the Mac mini only because the dedicated `_runnervm` group
  needs root — state dir hand-tightened to 0700 · `github.auth.source: file`, not keychain, because
  the host is headless · profile names must be unique per scope across hosts (a scale set has one
  message session) · the dev Mac's `ubuntu-24` profile stays removed from `~/runnervm-dev/config.yaml`
  while blackpen serves that repo · macOS profile disk must be `50000000000` bytes exactly.
- **Blockers:** nothing for code. `sudo` on the Mac mini blocks the LaunchDaemon (plist rendered and
  lint-clean at `/Users/blackpen/com.runnervm.runnerd.daemon.plist`), the `_runnervm` account, and
  the reboot qualification loop. `scripts/qualify-macos-image.sh` (H2) cannot pass as written.
  macOS on the Mac mini is blocked on disk.
