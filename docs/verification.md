# RunnerVM — Verification record

What has actually been exercised, and how. Updated 2026-08-26.

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
