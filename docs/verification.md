# RunnerVM — Verification record

What has actually been exercised, and how. Updated 2026-08-28.

## Live end-to-end (Linux/arm64) — PASS

Proven on **`andrejvysny/github-managed-runners`** (public repo), host macOS 26.4 (Apple Silicon),
against **GitHub.com** (not a fake):

1. Built a runner image with `scripts/build-ubuntu-image.sh` from the Ubuntu 24.04 arm64 cloud
   image (qcow2 → raw), full provenance: actions/runner `2.337.0` (sha256 from the GitHub release
   **asset digest**), docker-ce `29.7.2`, 749 packages, guest agent `110c9e4`, sealed disk sha256.
2. `runnerd --foreground` applied the config, authenticated the PAT, and registered a repository
   **Runner Scale Set** `runnervm-ubuntu-24` (GitHub scale-set id 1, label **`ubuntu-24`**).
3. Dispatched `.github/workflows/runnervm-selftest.yml` (`runs-on: ubuntu-24`).
4. Observed the full path in `runnerctl`:

   ```
   JobAvailable (msg 100000001) → VM create → guest agent (vsock) → JIT config
   → runner online (rvm-ubuntu24-7f314b82, id 2) → jobRunning → completed
   → VM stopping → deleted → demand 0
   ```

5. **All 12 job steps green**: host/OS facts, `systemctl is-active runnervm-guest-agent`,
   `docker info` + `docker run --rm alpine`, `actions/checkout`, `actions/setup-go`,
   `go build ./cmd/guest-agent` + `go test ./internal/rpc/...`, summary, and the runner's own
   Set up / Post / Complete steps. Run concluded **success**; the ephemeral VM was destroyed and
   `runnerctl vm list` returned empty.

### Bugs found and fixed during live bring-up

| # | Symptom | Cause | Fix (commit) |
|---|---------|-------|--------------|
| 1 | Job sat `queued`, scale set never received demand | Scale set registered with the prefixed scale-set name as its **label**; GitHub keeps labels from creation, so `runs-on: <profile>` never matched | Label = **profile name** (`row.name`); the `runnervm-` prefix only namespaces the scale-set *name*. `runs-on: <profile>` in all workflows/docs (`b9ab328`) |
| 2 | CI red on Swift 6.1.2 (green on dev 6.3.3) | `VMRuntime.start/stop` async overlays and `withSessionRefresh<T>` / `gated<T>` / `mapTransportErrors<T>` sent non-`Sendable` values across an isolation boundary | Completion-handler APIs; `T: Sendable` bounds (`04b0f29`, `b9ab328`) |
| 3 | Builder VM stopped ~1 s after boot, empty serial | Base was a bare ext4 rootfs (the Ubuntu cloud **`.tar.gz`**), which EFI cannot boot | `require_partition_table` rejects non-GPT / qcow2 bases early; use the qcow2 `.img` → raw (`04b0f29`) |
| 4 | CI red on 6.1.2 | `OCIRegistryTests` sparse-disk island offsets: untyped `0` not inferred as the tuple's `UInt64` on 6.1.2 | Annotate `0 as UInt64` (`29e8e17`) |

**Lesson recorded:** the dev host runs Swift 6.3.3; CI's Swift 6.1.2 is stricter about
sending/inference. Treat a green CI run as the authoritative build gate, not a local `swift build`.

## Autoscaling / parallel jobs (Linux) — PASS

Run [`32999466546`](https://github.com/andrejvysny/github-managed-runners/actions/runs/32999466546),
2026-08-26. Host configured to **3 VMs** (`host.maxVMs: 3`, `profiles[].limits.maxInstances: 3`,
2 vCPU / 4 GiB each); workflow dispatched with **`fanout=5`, `sleep_seconds=45`** so demand
deliberately exceeded capacity.

Observed, in order:

| Phase | Scale set | RunnerVM |
|-------|-----------|----------|
| dispatch | `advertised=3`, GitHub assigned **exactly 3** of 5 | 3 VMs created in parallel (`waitingForAgent` → `idle` → `configuringRunner`) |
| saturation | `assigned=3`, `running=3` | `3 busy` — host at its configured cap, remaining 2 legs stay queued at GitHub |
| drain + refill | first legs complete | finished VMs `stopping`; **2 replacement VMs booted immediately** for the queued legs (peak 4 instances observed across the overlap) |
| finish | `assigned=0` | last VMs stopped and deleted; `runnerctl vm list` empty |

Result: **5/5 legs succeeded**, 5 ephemeral VMs consumed one job each.

```
leg 1  18:24:42 → 18:26:46   leg 3  18:25:02 → 18:27:04   leg 4  18:24:42 → 18:26:39
leg 2  18:27:07 → 18:28:58   leg 5  18:27:07 → 18:28:54
```

The second wave starts ~20 s after the first wave's VMs release — i.e. capacity is recycled
promptly, and `X-ScaleSetMaxCapacity` is honoured (GitHub never assigned a 4th concurrent job).

This closes three items from the M6 live checklist: advertised-capacity enforcement, concurrent
jobs, and queue-larger-than-capacity.

## Automated tests — PASS (local)

- Swift: **935 tests / 127 suites** pass (`swift test`). Note: after `ImageMetadata` grew a
  `Provenance` field, a stale shared `.build` produced a SIGSEGV in `ImageMetadata.init(from:)`;
  `swift package clean` resolves it.
- Go guest agent: `go vet` + `go test -race ./...` (70 tests) pass.
- Shell: `shellcheck` + `bash -n` clean; `scripts/tests/build-ubuntu-image-test.sh` (52) and
  `scripts/tests/install-test.sh` (10) pass.
- Workflows: `actionlint` clean.

## CI (`.github/workflows/ci.yml`) — GREEN target

Jobs: `swift` (Xcode 16.4 / Swift 6.1.2 — build + test + sign vmworker + entitlement verify +
probe), `lint` (shellcheck, bash, actionlint, both bash test suites), `go` (vet, gofmt, race,
darwin cross-build). Least-privilege `permissions: contents: read`, SHA-pinned actions.

The first hardening pushes were blocked by a **GitHub Actions major outage** on 2026-08-26 (runs
`startup_failure`/`queued` with zero jobs, including GitHub's own Dependabot). Once Actions
recovered, the Swift job surfaced the 6.1.2 issues in the table above; they are fixed. Latest
commit's CI is the authoritative check for full green.

## Production hardening pass (2026-08-27, dev host, live GitHub)

Evidence tiers used below: **unit** (fakes, `swift test`), **integration** (real actors over GRDB +
in-process fake worker/guest/GitHub), **hardware** (real VMs on this Apple Silicon host),
**live GitHub** (real scale set on `andrejvysny/github-managed-runners`), **production-qualified**
(LaunchDaemon, reboot loop). Anything not listed under a tier was not verified.

### Determinism (WP0) — unit/integration

Root causes of the master CI flakes (`RunnerSessionTests`, `ReusableLifecycleTests`), all fixed at
the source rather than by widening timeouts:

| Test | Root cause |
| --- | --- |
| `aWorkerDisconnectDuringAJobInterruptsTheSession` | `InstanceManager.interrupt` dropped the guest client *before* writing the `interrupted` row; the actor is reentrant at that `await`, so the session observer could poll a half-closed client under a row still reading `busy` and end the session as `RUNNER_STATUS_UNAVAILABLE` (or stall on the dead call). Row first, guest second now. |
| `taintingABusyVMRetiresItWhenTheJobEnds` | `markBusy` wrote the session row (`jobRunning`) before the instance row (`busy`); a reader that saw `jobRunning` could still read `runnerOnline`. Instance row first now; a failed CAS re-reads instead of polling on with a stale copy. |
| `aFailedRemovalIsQueuedAndRetriedLater` | Test waited for the `remove-runner` operation row to *exist*, not to have `failed`. |
| `happyPath…`, `metricsSnapshot…` | `awaitTerminal` returns on the terminal transition; the job summary / metrics are written after it. The VM's deletion is the sync point. |
| `aGuestThatNeverBecomesReadyIsNotSealed` | `BuildHarness.settle` had a 400×10 ms poll budget against a 5 s injected `agentReadyTimeout`. |

`waitUntil` now throws on timeout; lifecycle waits are event-driven (`LifecycleEventLog.subscribe()`,
`awaitSession`/`awaitInstance`) behind a 30 s hang guard that is not a race margin. Loops:
`RunnerSessionTests|ReusableLifecycleTests` **100/100** clean, full suite ×10 clean under concurrent
load; after WP1 the recovery/session suites **20/20 ×3** clean.

### Restart recovery (WP1) — integration + live GitHub

`RunnerSessionRecovery` (every reconcile tick + once at startup before the demand provider
starts): `planned`/`jitRequested` → `jitFailed`, `jitIssued` → `runnerStartFailed` (runner
removed), `jitDelivered`… `jobRunning` → re-observed with `sawBusy` seeded from the row; the VM of a
session closed only because of the restart is destroyed, not kept for diagnosis. 15 integration
cases (every state, guest missing, worker missing, guest silent, ladder alignment, degraded scope,
idempotence, capacity released). Live: see the scenario table below.

### Build recovery capacity (WP2) — integration + hardware

`probeOrphan` verdicts; a build whose worker cannot be proven dead keeps its capacity, pin and
directory (`recovery_since`, schema v3, applied in place on the dev database: `schema_migrations`
1/2/3), abandoned after 15 min with `BUILD_RECOVERY_ABANDONED`. 12 integration cases with a real
`fcntl` lock held by a child process. Fault injection (WP8): every `BuildPhase` frozen mid-flight
converges (pending while the worker lives, terminal once it is gone), replay registers exactly one
image, `pushing` produces exactly one push operation.

### Build context (WP3) — integration (real `tar`/`hdiutil`)

`tar --null -T`; newline / CR / tab / leading-dash / literal `-C` / 200-deep names archived
verbatim, escaping symlinks, hard links, FIFOs, sockets refused, archive contents inspected
byte-for-byte after a real extraction. Device nodes: recorded as a known issue when `mknod` is
not permitted (unprivileged CI). Finding: Foundation normalises relative paths to NFD, so an
NFC-named context file lands in the archive under its NFD form (pre-existing, unrelated to `--null`).

### Reusable lifecycle (WP4) — unit (Go + Swift)

`lifecycle: reusable` refused without `reuse.acknowledgeSharedHost: true`; the guest agent
restores HOME from a pristine snapshot on every cleanup (fails closed with `HOME_SNAPSHOT_MISSING`);
sentinel credentials in `.gitconfig/.netrc/.npmrc/.cargo/.docker/.ssh/.aws/gh/.pypirc/.m2` do not
survive. Not exercised on a real VM in this pass.

### Base-image cache (WP5) — unit + hardware

Bounded LRU with pins from live build rows, atomic `.part` commits, reserve floor, metrics. The
rebuild of `ubuntu-24-minimal` on this host hit the cache (`base-4a281a92….raw`) under the new
index.

### Doctor / qualification tooling (WP9) — hardware

`runnerctl doctor --deep --state-dir ~/runnervm-dev --config …`: 26 checks, `image_store_integrity`
re-hashed 5 images (all consistent), `service_user_ownership` correctly **failed** the dev layout
(0755 root, 0644 config), `free_memory` warned at 5.1 GiB free. LaunchDaemon reboot loop: not run
(see "Not yet verified").

### Live GitHub matrix (WP10) — live GitHub

Run 1 (before the fixes below) surfaced three real defects: `HostModeControl.drain()` reported
`drained:false` on an idle host so `system drain --wait` exited 1 and the scenario left the host
draining (advertised capacity 0 → every later job queued forever); a session terminalized by a
restart left an `interrupted` instance whose vmworker kept running (capacity held for the 2 h
retention window); the test workflow's `long` job ignored the runner's cancellation for up to
5 min because bash defers SIGINT while a foreground `sleep` runs. All three fixed (`04f992c`).

Runs 2–5 (after the fixes; `runnerd --foreground` on this host, scale set `runnervm-ubuntu-24`,
image `ubuntu-24` `sha256:6bd52891…` built with the new guest agent):

| Scenario | Result | Notes |
| --- | --- | --- |
| `success` | pass (35 s) | |
| `cancel-before-assignment` | pass (35 s) | drain/resume round trip |
| `cancel-during-job` | pass (90 s) | runner cancels within seconds once the job's `sleep` is signal-friendly |
| `restart-while-booting` | pass (44 s) | |
| `restart-while-runner-starts` | pass (44 s) | job completed once after the restart |
| `restart-during-job` | pass (317 s) | daemon log: `runner session recovered … from jobRunning outcome reattached` |
| `restart-during-job-sigkill` | pass (726 s) | `kill -9 runnerd`, vmworker untouched; one run attempt, one job; session terminal; registration gone; VM gone; capacity baseline |
| `redelivery` | pass (29 s) | one runner session, one instance (before `45192b3` the first pass after a restart reaped the VM on unconfirmed demand and booted a second one) |
| `scaleset-reconnect` | pass (34 s) | `debug.scaleSetReconnect` → new session generation, job completed once |
| `concurrent` | pass (85 s) | 4 jobs, peak VMs ≤ 3 |
| `queue-overflow` | pass (108 s) | 6 jobs, GitHub never assigned more than the advertised 3 |
| `long-job` | **not run** | skipped on the operator's instruction (the long-running path is covered by the 65-min run on 2026-08-26 and by `restart-during-job`) |
| GitHub API timeout / 429 / 5xx; JIT issued but guest startup fails | integration (fakes) | `GitHubFaultTests`, `RunnerSessionTests` — cannot be induced on GitHub.com |

Run 1 also found three script defects (org-runner lookup on a user login, `jq fromdateiso8601` on
fractional timestamps, skipped workflow jobs counted as executions) and the 65-minute `long` job
being dispatched by scenarios with a 30-minute budget; all fixed in the driver.

### Builder → GitHub → GHCR (WP7) — live GitHub + GHCR

`scripts/live-builder-e2e.sh --recipe images/recipes/ubuntu-24 --name e2e-hardening --registry
ghcr.io/andrejvysny/runnervm-e2e`, run 4 (`builder-e2e-report4.json`): **5/5** — `image build`
(39–45 s warm) → `image inspect` (guestAgent true, recipe sha recorded on the build row) →
profile applied → `runnervm-selftest.yml` job **success** on the built image (66–106 s) → `image
push` → local delete → `image pull` by the immutable manifest reference
(`…runnervm-e2e@sha256:f0a24bc9…`) → pulled content digest identical (`sha256:1b0264c0…`),
guestAgent true → second selftest job **success**. Digest identity held through the round trip.

Defects the first three runs found, all fixed on master: `image delete` of any image that had run a
job failed with `DB_FOREIGN_KEY` (deleted-instance tombstones referenced by their sessions and
summaries; `fbe52b2`); the push's immutable reference was computed and thrown away, so nothing
could pin what the registry assigned (`03272b7`, now `OperationInfo.result.pushedReference`); one
GHCR chunk upload timed out (transient; the rerun succeeded).

### Builder fault injection (WP8) — integration + live (partial)

Integration: `ImageBuildFaultInjectionTests` freezes a builder at each of the 11 `BuildPhase`s and
recovers with a second `ImageBuilder` over the same state (20× loop clean). Live
(`scripts/live-builder-faults.sh --phase all` against a real `runnerd`, warm `ubuntu-24` build):
`queued` and `resolving` are not observable on a warm local-base build (both pass in <200 ms, the
script reports them as "never observed" — a driver limitation, not a daemon fault); the
`staging`/`booting`/`provisioning`/`sealing` kills were still running when this pass was handed
off — see `TODO.md` for the follow-up.

### Startup stall — observed, not root-caused

Twice (15:16 and 18:54 UTC) a `runnerd` started right after a SIGTERM'd predecessor logged
"demand provider" and nothing else for minutes (6 min the first time; the second was killed by a
60 s budget). A third restart under the same conditions came up in seconds. Every retried
GitHub/Actions call — including the token exchange — is now logged at warning level so the next
occurrence names the call; `scripts/live-builder-faults.sh` takes
`RUNNERVM_FAULTS_DAEMON_UP_TIMEOUT` for the same reason.

## Not yet verified (needs hardware time / dedicated org)

- `scripts/qualify-host.sh` cold-boot / power-cut qualification (needs the Mac mini itself).
- `scripts/live-github-e2e.sh` remaining scenarios: cancel-before-assignment, cancel-during-job,
  daemon restart while booting / mid-job, message redelivery, 65-min long job. (Happy path,
  concurrency and queue-overflow are proven above.)
- External log shipping (Vector / Fluent Bit configs ship; a real pipeline is not stood up).

## Guest OS support

- **Linux/arm64: supported and proven** (above).
- **macOS guests: not implemented.** Config validation rejects `os: macos` with
  `GUEST_OS_UNSUPPORTED`. See `docs/macos-guests.md` for the milestone plan and status.

## Image builder + tart import (2026-08-27, dev host, uncommitted M14/M15 tree)

Host: macOS 26.4, Swift 6.3.3, 14 CPU / 24 GiB, `runnerd --foreground --state-dir ~/runnervm-dev`,
no GitHub credential configured (`github.demand: manual`).

- `runnerctl image build images/recipes/ubuntu-24-minimal --name ubuntu-24-minimal` — **succeeded in
  3m43s** from a cold cache: downloaded the pinned qcow2
  (`ubuntu-24.04-server-cloudimg-arm64.img`, release-20260814, sha256 `4a281a92…`), converted it to a
  sparse raw base with `QCOW2Reader`, booted with the cloud-init bootstrap seed, reached the guest
  agent over vsock with `waitUntilReachable`, ran the 7 recipe steps over `agent.exec`
  (`RUNNER_VERSION=latest` resolved on the host to `2.337.0`, tarball digest from the GitHub release
  asset), passed the final `waitUntilReady` gate, probed, sealed and registered
  `sha256:767002e8…` (16 GiB virtual, 2.5 GiB on disk, 736 packages).
- `runnerctl image build images/recipes/ubuntu-24 --name ubuntu-24` (derived, `FROM ubuntu-24-minimal`)
  — **succeeded in 1m16s**: Docker `5:29.7.2-1~ubuntu.24.04~noble`, 743 packages, 2.9 GiB on disk,
  `provenance.parentImageDigest` set. Rebuilding under the same `--name` moved the `image_aliases`
  row to the new digest (`image inspect ubuntu-24` → the newer digest; the old row stays listed).
- Bugs found and fixed by the live run: the probe read no runner version (actions/runner ships none;
  it is now taken from `Runner.Listener.deps.json`, with the host-resolved ARG as fallback),
  `sshEnabled` was false on 24.04 (socket-activated `ssh.socket`), `architecture` was recorded as
  `aarch64` (normalised to `arm64`), and `RUNNER_VERSION=latest` failed once a GitHub scope was
  configured without a credential (the anonymous fallback was skipped).
- `runnerctl vm create --profile ubuntu-24` on the built image: `planned → … → waitingForAgent → idle`
  in 5 s (guest agent ready, boot id recorded); the orchestrator then reaped the idle VM because no
  demand was queued. A GitHub job was **not** run (no credential on this host); the runner/JIT path is
  unchanged from the proven 2026-08-26 e2e.
- `runnerctl image pull ghcr.io/cirruslabs/ubuntu:latest` — **imported** (40 layers, 2.84 GiB
  compressed → 20 GB sparse, 4.9 GiB on disk) as local `sha256:f5e2d25c…`, `source: tart (imported)`,
  `guest agent: absent`, `createdAt` from the tart upload-time annotation; staging directory cleaned.
- `image pull … --format runnervm` → `REGISTRY_UNSUPPORTED_MANIFEST: manifest is tart, not runnervm`
  before any blob transfer.
- `vm create --profile tart` (profile on the imported image) → `IMAGE_NO_GUEST_AGENT` in 1.8 s, no
  clone, no pin left behind.
- Not covered live: a daemon restart mid-build (covered by `ImageBuildTests` against fakes), `--push`
  to a real registry, LaunchDaemon (`_runnervm`) builds — `doctor build_tools` gates those.

## M8 — macOS guests (2026-08-27, uncommitted work in progress)

Tier: **hardware** (this Mac, macOS 26.4, Apple Silicon). Not yet production-qualified.

- **M8.2 cold boot (manual vmworker, admission bypassed).** Image: Tart `ghcr.io/cirruslabs/macos-tahoe-base:latest`
  (`sha256:fa96c198…`, 50 GB raw disk, 33 MB auxiliary storage), APFS-cloned into a scratch instance
  directory with a hand-written `spec.json` carrying the `macos` block (hardware model from Tart's
  `config.json`, 4 vCPU, 8 GiB). `vmworker run` created `machine-identifier.bin`, took the lock,
  published both sockets and reported `vm state running` 0.3 s after `starting`. Guest reachable over
  NAT (`/var/db/dhcpd_leases` by the spec's MAC) and SSH (Tart's `admin/admin`): `sw_vers` =
  macOS 26.6.2 (25G83), `uname -m` = arm64, `hw.model` = VirtualMac2,1, `kern.hv_vmm_present` = 1,
  4 CPUs / 8 GiB as specified, `IOPlatformSerialNumber` derived from RunnerVM's freshly minted
  machine identifier (not Tart's ECID), Command Line Tools + git 2.50.1 present, passwordless sudo.
  No window was shown; one 1920×1080 virtual display configured.
- **M8.2 restart keeps identity.** Guest halted (`shutdown -h now`), worker terminated, `vmworker run`
  re-issued on the same directory with generation 2: log shows `loaded macOS machine identifier`
  (not `created`), `machine-identifier.bin` byte-identical (sha256 prefix `dc002e89de227e22` before and
  after), guest back to `running` in 0.3 s.
- **M8.3 first provisioning run failed, root cause found live.** The Tart base image ships
  `/Users/runner -> /Users/admin` (symlink) and a pre-installed `actions-runner` owned by `admin`;
  `sysadminctl -addUser runner -home /Users/runner` therefore bound the new account to admin's home and
  `sudo -u runner tar` collided with admin's files (9,287 `Permission denied`). The in-guest agent
  itself came up under launchd and logged `guest-agent listening … vsock(4294967295):4050`, and its
  cleanup refused the symlinked HOME as designed. Fix: the provisioner removes the symlink before
  creating the account and replaces any pre-existing runner directory wholesale.
- **M8.3 provisioning + import (run #3).** `scripts/provision-macos-tart.sh --force` on the Tart base:
  symlink removed, `runner` (uid 502) created with a real `/Users/runner`, agent LaunchDaemon loaded,
  `actions/runner` 2.337.0 (sha256 verified twice) unpacked, CLT already present, `credential.helper`
  reset to the empty override as `runner`, passwordless sudo; guest halted in 10 s; `metadata.json`
  sealed with the hardware model, `sourceVersion` 26.6.2, minimums 2 vCPU / 4 GiB; imported as
  `macos-26-base` (46.6 GiB virtual, 30.4 GiB on disk, guest agent present, runner health healthy).
- **Daemon path, manual create (`runnerctl vm create --profile …`).** Clone → worker → `startingVM` →
  `waitingForAgent` in ~2 s, then `instance.cancelled (demand dropped)`: with zero confirmed demand
  the ephemeral VM is surplus and scale-to-zero removes it. Correct, and the reason `vm create` is a
  debug surface, not the M8 acceptance path.
- **Label collision found live.** A profile named `macos-26` registers scale-set label `macos-26`,
  which is also a GitHub-hosted runner label: run 33118542128 (`runs-on: macos-26`) was executed by
  `GitHub Actions 1000003524` (hosted) and never reached RunnerVM. Profile renamed `rvm-macos-26`.
  Follow-up: validation warning for profile names that shadow hosted labels.
- **M8.4 GitHub JIT job, ephemeral macOS (run 33118688632, `long`, 1 minute).** Dispatched
  21:33:27Z; instance `45df4889` `waitingForAgent` by 21:33:36, `configuringRunner` 21:33:42,
  `runnerOnline` 21:33:47, job started 21:33:50 (**23 s cold start**: clone + boot + agent over
  vsock + JIT registration), `busy` through the job, job `success` 21:34:54, session `completed`
  (`result: job`), instance `stopping` → deleted; runner `rvm-rvmmacos26-45df4889` with label
  `rvm-macos-26`, `Machine name: Manageds-Virtual-Machine`. No SSH involved anywhere on this path.
- **Two concurrent macOS guests: blocked by disk on this host, not by code.** Admission reserves
  `max(profile.disk, image.virtual)` = 47 GiB per instance plus the `host.reserve.disk` floor; with
  ~90 GiB free the scale set advertises 1. Needs ≥ ~95 GiB free (or a smaller macOS image) to
  exercise the 2-guest cap and the third-job wait.

## Mac mini deployment — `blackpen` (`olympics-Mac-mini`), 2026-08-28

First deployment of RunnerVM onto a machine that is not the development Mac, and the first time
the daemon has run **headless**: no GUI login session, no auto-login user, driven entirely over
SSH. The goal was to exercise functionality, autoscaling and parallel VMs end to end, and to
validate at least one macOS guest.

### Host and install layout

| | |
| --- | --- |
| Host | Apple M4, 10 logical CPUs, 32 GiB RAM, macOS 26.5.2 (25F84) |
| Free disk | 62 GiB (228 GiB volume shared with three other local accounts) |
| Toolchain | Swift 6.2.4 from Command Line Tools; **no** Xcode, Go, Homebrew, `tart` or `shellcheck` |
| GUI session | none — `/dev/console` is owned by `root`, no auto-login user, login keychain locked |
| Install | user-scoped, no root: `--prefix /Users/blackpen/.local`, `--state-dir /Users/blackpen/runnervm`, `--runtime-dir /Users/blackpen/runnervm/run`, `--user blackpen --group staff --allow-staff-group` |
| GitHub | `github.auth.source: file` — a fine-grained PAT (Actions RW, Administration RW, Metadata R) at `<state-dir>/state/github-token`, 0600 |
| Profile | `ubuntu-24`, ephemeral, 2 vCPU / 4 GiB / 16 GiB, `maxInstances: 3`, `host.maxVMs: 3` |

`--group staff` was used only because creating the dedicated `_runnervm` group needs root, which
this deployment deliberately did not use. The state directory was then tightened to `0700` by hand,
which is what keeps it away from the other three accounts on the machine — on a host with root
available, use the default `_runnervm` group instead and do not repeat this.

The Linux guest agent was cross-built on the development Mac and copied in, because Go is not
installed on the Mac mini; `scripts/install.sh` picks up an existing
`GuestAgent/bin/linux-arm64/runnervm-guest-agent` and skips the `make` step.

### Virtualization.framework works headless, with the login keychain locked — PASS

`packaging/launchd/README.md` treats the LaunchDaemon variant as experimental on the premise that
"Virtualization.framework on macOS 15+ needs an unlocked login keychain in the session that creates
the VM", and `runnerctl doctor` fails a `Login keychain` check for the same reason. On this host,
on macOS 26.5.2, that premise did not hold:

- `vmworker probe` over SSH reports `virtualizationSupported: true`, `macOSGuestLimit: 2`,
  `nestedVirtualizationSupported: true`.
- `runnerctl doctor` reports `FAIL Login keychain — login keychain for blackpen is locked
  (security exit 36)`, and the daemon nevertheless booted every VM in this record: two image
  builds, ten GitHub jobs, and the whole live E2E suite below.

This is a single-host, single-OS-version data point, not a qualification of the LaunchDaemon
variant — the reboot loop in `docs/qualification.md` is still unrun. But the reason the
LaunchAgent variant was preferred does not reproduce here, and the `Login keychain` doctor check is
a false negative on this host.

### Defects found and fixed

1. **Free space reads as 0 in any session without a GUI login → the daemon advertises
   `capacity=0` and never schedules a VM.** `APFSClone.freeSpace` used only
   `volumeAvailableCapacityForImportantUsageKey`, which is computed by a per-login-session service
   and answers 0 where there is none. Measured side by side: on the development Mac (GUI session)
   `volumeAvailableCapacity` 90.8 GB / `…ForImportantUsage` 97.0 GB; on `blackpen` over SSH
   70.4 GB / **0**. The daemon therefore came up in permanent `critical` disk pressure
   (`"free_bytes":"0","floor_bytes":"4294967296","to":"critical"`) and advertised `capacity=0`.
   This would have broken the documented LaunchDaemon variant identically. Fixed by falling back
   to `volumeAvailableCapacityKey`, which undercounts purgeable space — the safe direction for an
   admission check. `DoctorChecks.freeBytes` now delegates to `APFSClone.freeSpace` rather than
   reading the volume keys a second time, because the two had drifted: doctor said "could not read
   free space" while the daemon sat in `critical`.

2. **The in-daemon image builder never received the applied configuration.**
   `ImageBuilder.updateConfiguration` existed but nothing called it: `DaemonServiceImpl` updated
   `images`, `instances`, `gateway` and `orchestrator` on both config-application paths and not the
   builder. The builder therefore answered from `ImageBuildConfig()` and `HostConfig.Reserve()`
   forever, so the entire `build:` configuration block had no effect and the default 50 GiB disk
   reserve refused every build: `IMAGE_INSUFFICIENT_DISK_SPACE: image.build: needs 25836919434B,
   only 16273380KiB free` on a host with 65.5 GiB free and `host.reserve.disk: 4GiB`
   (65.5 − 50 = 15.5). Fixed by adding `updateConfiguration` to the `ImageBuildService` protocol
   and calling it from both sites.

   Deliberately **without** a default implementation in a protocol extension. The first attempt
   added one so test doubles would not need it; a protocol-extension no-op outranks the actor's own
   method at a concrete call site, so `BuildHarness`'s own `await builder.updateConfiguration(...)`
   silently became a no-op and four `ImageBuilderLifecycleTests` cases started failing (the suite
   went from 6.7 s green to 80 s with four failures). `ImageBuilder` is the only conformer, so the
   requirement stands on its own.

3. **`scripts/provision-macos-tart.sh` could never verify its own payload over password SSH.**
   The H1 hardening added a third payload check that compares the guest's `shasum -a 256` output
   against the host's expectation. Without `--ssh-key` that command runs through `expect`, whose
   pty echoes ssh's `admin@<ip>'s password:` prompt onto stdout, so the comparison failed with all
   four digests visibly identical:
   `error: the staged payload does not hash to what this host sent`. The check had never been run
   against the password path it is the default for. Fixed by keeping only digest lines before
   comparing; a missing or altered digest still fails, because the two sorted sets must still agree
   line for line.

4. **`runnerctl status` always reported "Scale sets: 0 healthy".** `Mapping.github` hardcoded
   `scaleSetsHealthy: 0`. On this host `status` said `Scale sets: 0 healthy` while `scaleset list`
   said `ready` / `open` / `ok` for the same scale set — an operator reading `status` during a
   deployment sees a broken GitHub connection that is not broken. Now counted over the same
   `demandReport()` rows `scaleset.list` renders.

5. **Disabling a profile did not close its scale-set message session.**
   `ScaleSetDemandProvider.refresh()` only ever *added* sessions (`row.enabled && states[row.id]
   == nil`); nothing removed one, and `ensureSession` re-opens a missing session at the top of every
   poll. So a profile disabled by `config.apply` kept polling its scale set for the life of the
   process. A scale set has exactly one message session, so this is not cosmetic — it caused a live
   mis-route during this deployment:

   The development Mac's daemon was started while the Mac mini owned `runnervm-ubuntu-24`, and its
   `ubuntu-24` profile was then disabled precisely to get it out of the way. It kept the session
   anyway, took it back at the Mac mini's next restart (`scaleset list` on the development Mac:
   `session open, gen 87, demand 1`; on the Mac mini: `closed`, `HTTP 409
   RunnerScaleSetSessionConflictException`), and captured a job the Mac mini was then locked out
   of. The E2E `redelivery` scenario ran during that window and its result was discarded.

   Fixed with the mirror of `register`: `refresh()` now retires sessions whose profile is no longer
   enabled — cancel the poll task first (closing first would just let `ensureSession` open a fresh
   one), then close the session and record it `closed`. Regression test:
   `disablingAProfileClosesItsMessageSession`.

### Defects found and **not** fixed

6. **`scripts/qualify-macos-image.sh` cannot qualify an ephemeral profile whose scale set is live
   and idle.** The script creates an instance with `vm create`; with zero confirmed GitHub demand
   the scheduler correctly treats it as surplus and scales it away, so the clone never reaches
   `idle`: `FAIL cold_boot_to_idle — instance reached deleted` after 11 s, daemon log
   `instance.cancelled (demand dropped)`. The VM itself booted normally (it reached
   `waitingForAgent` in 6 s) — the script and the scale-to-zero policy are in conflict, not the
   image. The other four checks (teardown, no live instances, instance directory removed, image
   digest unchanged) passed. This is the first time H2 has been run; it needs either
   `github.demand: manual`, a host in a mode that suspends scale-to-zero, or a pin on the
   instance it creates.

7. **Two RunnerVM hosts sharing one repository scope collide on the scale-set session** — by
   design, and worth knowing before it bites. While the
   Mac mini owned `runnervm-ubuntu-24`, starting the development Mac's daemon against the same
   repository produced a steady `GITHUB_CONFLICT … HTTP 409 …
   RunnerScaleSetSessionConflictException: The actions runner scaleset runnervm-ubuntu-24 already
   has an active session`, and the second host's `ubuntu-24` scale set sat `closed`. The incumbent
   keeps the session — until it restarts, at which point the other host takes it and starts
   answering jobs meant for the first (which is exactly what happened, via defect 5).
   **Profile names must be unique per scope across hosts.** This was documented nowhere; it is now
   in `docs/install.md` ("One host per profile name, per scope"). Disabling the profile on the
   losing host is the right remedy and, with defect 5 fixed, now actually works. Nothing in the
   orchestrator calls `deleteScaleSet`, so removing a profile from one host's configuration leaves
   the other host's scale set alone.

### Linux — what was tested

Images built on the host with the in-daemon builder, from the shipped recipes:

| image | result | time | on disk |
| --- | --- | --- | --- |
| `ubuntu-24-minimal` (from the pinned Ubuntu 24.04 cloud image) | PASS | 2 m 56 s, 8/8 steps | 2.5 GiB |
| `ubuntu-24` (`FROM ubuntu-24-minimal`, adds Docker) | PASS | 1 m 30 s, 3/3 steps | 2.9 GiB |

`ubuntu-24` carries actions/runner 2.337.0, docker-ce 29.7.2, kernel 6.8.0-137, 743 packages.

Autoscaling and parallel VMs, `runs-on: ubuntu-24` against `andrejvysny/github-managed-runners`:

| run | what | result |
| --- | --- | --- |
| 33158249526 | single `quick` job | PASS, job 5 s; guest agent ready **5.5 s** after demand |
| 33158308797 | `matrix` × 3 — at capacity | PASS 3/3; three VMs `runnerOnline` concurrently, then scale to zero |
| 33158434567 | `matrix` × 6 — 2× capacity | PASS 6/6; concurrency never exceeded 3, drained and refilled in waves |

Full instance ladder observed: `planned → preparing → cloning (apfs_cow) → startingWorker →
startingVM → waitingForAgent → idle → configuringRunner → runnerStarting → runnerOnline → busy →
stopping → deleted`.

`scripts/live-github-e2e.sh`, 11 of 12 scenarios (`--concurrency 3`):

| scenario | result | time |
| --- | --- | --- |
| `success` | PASS | 38 s |
| `cancel-before-assignment` | PASS | 32 s |
| `cancel-during-job` | PASS | 32 s |
| `restart-while-booting` | PASS | 26 s |
| `restart-while-runner-starts` | PASS | 28 s |
| `restart-during-job` | PASS | 331 s |
| `restart-during-job-sigkill` | PASS | 334 s |
| `redelivery` | PASS | 29 s |
| `scaleset-reconnect` | PASS | 211 s |
| `concurrent` | PASS | 39 s |
| `queue-overflow` | PASS | 93 s |
| `long-job` | **skipped** | 65-minute scenario, not run |

`redelivery` failed on its first attempt (523 s) and that result was discarded, not the defect's
fault and not the daemon's: the development Mac's daemon had taken the scale-set session out from
under this host (defect 5 above), so the job was captured elsewhere and never delivered here. Re-run
on its own once the session was back, it passed in 29 s. Every other scenario in the table ran with
this host holding the session throughout.

`restart-during-job-sigkill` is the strongest of these: `runnerd` is `kill -9`ed mid-job, and the
job still completes exactly once with the `vmworker` untouched, the runner registration cleaned up
and capacity converged afterwards.

Raw reports as the driver wrote them: [`docs/e2e/reports/2026-08-28-blackpen-suite.json`](e2e/reports/2026-08-28-blackpen-suite.json)
and [`…-redelivery-rerun.json`](e2e/reports/2026-08-28-blackpen-redelivery-rerun.json). The exact
configuration this host ran is [`docs/examples/headless-mac-mini.yaml`](examples/headless-mac-mini.yaml).

### Storage: nothing is left behind by a job — PASS

After the ten jobs above:

| | |
| --- | --- |
| `runnerctl vm list` | empty |
| `<state-dir>/instances/` | **0 B** |
| `vmworker` processes | none |
| GitHub runner registrations | **0** (`/actions/runners` → `total_count: 0`) |
| free disk | 62 GiB — unchanged from before the runs |

An ephemeral instance's disk is an APFS clone that is deleted with the VM, so per-job storage is
fully reclaimed. What outlives a job is bounded and was made explicit in this host's configuration
rather than left on defaults: `images.cache.maxSize: 20GiB`, `logging.retention.instanceLogs: 3d`
(instance logs measured ~75 KiB per job), `build.cache.maxBytes: 8GiB`, and
`diagnostics.failedInstanceRetention: 15m` (the 2 h default would strand a 16 GiB reservation on a
host this small). Steady-state footprint after both images: 7.2 GiB — 5.4 GiB images, 1.8 GiB
base-image cache, the rest logs and SQLite.

### macOS guest — PASS, on the development Mac

**Not on the Mac mini: it does not have the disk.** A macOS guest cannot resize its APFS container,
so `resources.disk` must equal the image's own disk exactly and admission reserves that full figure
— 46.6 GiB for the Tart-derived image, plus the free-space floor. The Mac mini has 62 GiB free and
~11 GiB reclaimable; storing the 30 GiB image leaves ~43 GiB against the ~48 GiB admission needs,
and that is with both Linux images deleted. It needs roughly 20 GiB more; the only large
reclaimable area belongs to another user account. Recorded as blocked on disk, like the two-guest
case already in the M8 record above.

Validated instead on the development Mac (83 GiB free), on a **freshly re-provisioned, hardened**
image rather than the pre-lockdown `macos-26-base`:

- `scripts/provision-macos-tart.sh --force --import macos-26` from
  `ghcr.io/cirruslabs/macos-tahoe-base:latest` — payload verified (4 files, after fix 3),
  `/Users/runner` symlink removed, `runner` uid 502 created, guest agent LaunchDaemon loaded,
  actions/runner 2.337.0 unpacked (sha256 verified twice), Command Line Tools present, empty
  credential helper, passwordless sudo, Spotlight disabled.
- H1 lockdown proved at seal time: `password rotated, old credential rejected=yes, sshd disabled,
  authorized_keys cleared`; guest halted gracefully in 10 s; sealed metadata records
  `capabilities.ssh: false`.
- Imported as `macos-26`: 46.6 GiB virtual, 30.6 GiB on disk, guest agent present, minimums
  2 vCPU / 4 GiB, `sourceVersion` 26.6.2.
- **Live GitHub job (run 33159698945, `quick`, profile `rvm-macos-26`) — PASS in 7 s.**
  `instance.started` 09:31:10Z → JIT config 09:31:28Z → job start 09:31:33Z: **~23 s cold start**,
  matching the M8.4 figure. Runner `rvm-rvmmacos26-c56a6b91`, machine name
  `Manageds-Virtual-Machine`, `Darwin … RELEASE_ARM64_VMAPPLE arm64`, macOS 26.6.2,
  `uid=502(runner)`, `guest agent: loaded`. Teardown clean: no VMs, `instances/` empty, disk
  restored.

### Not tested / skipped

- **`long-job`** (65-minute scenario) — skipped for wall-clock; `cancel-during-job` and both
  `restart-during-job` scenarios already exercise a running job with the 5-minute variant.
- **macOS on the Mac mini** — blocked on disk (above).
- **Two concurrent macOS guests** — not attempted; still blocked on disk on the development Mac,
  as already recorded for H3.
- **H2 `qualify-macos-image.sh`** — run, and it cannot pass as written (defect 5 above).
- **H4 recovery matrix / H5 soak** (`scripts/live-macos-e2e.sh`) — not run.
- **LaunchDaemon / LaunchAgent reboot qualification** — the plist is rendered and lint-clean, but
  installing it needs root, and the 10-reboot / cold-power-cycle loop in `docs/qualification.md`
  has still not been run. `runnerd` on the Mac mini currently runs as a detached foreground
  process and does **not** survive a reboot.
- **Dedicated `_runnervm` service account** — not created (needs root); the daemon runs as
  `blackpen`.
