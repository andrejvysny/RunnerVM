# Live GitHub integration testing

`scripts/live-github-e2e.sh` drives `runnerd` through REST JIT and Runner Scale Set flows
against real GitHub.com infrastructure: a dedicated test org (or user) and a dedicated test
repo. It is manually triggered, opt-in, and **never** runs as part of `swift test` or CI's
default triggers (TODO.md T3, "Live checklist for M6"). This document is the preconditions,
setup and scenario reference for running it.

Companion files:

- [`scripts/live-github-e2e.sh`](../scripts/live-github-e2e.sh) — the driver (`--help` for flags).
- [`scripts/live-builder-e2e.sh`](../scripts/live-builder-e2e.sh) — a separate, single-pipeline
  driver for the builder → GitHub → GHCR path (image build, a real job against it, then a push /
  delete / pull-by-digest / redispatch round trip). See "Live builder integration testing" below.
- [`scripts/lib/live-common.sh`](../scripts/lib/live-common.sh) — logging, `runnerctl` wrapper,
  polling and JSON-report helpers shared by both drivers.
- [`docs/e2e/test-repo-workflow.yml`](e2e/test-repo-workflow.yml) — copy to the test repo as
  `.github/workflows/e2e.yml`.
- [`.github/workflows/github-integration.yml`](../.github/workflows/github-integration.yml) —
  optional: runs the driver from a self-hosted Actions job on the Mac mini itself.

## Why a dedicated org/repo

Several scenarios are deliberately destructive from GitHub's point of view: draining and
resuming the host, cancelling in-flight runs, restarting `runnerd` mid-job, and dispatching
2x-capacity job bursts to prove GitHub never over-assigns. None of this is safe to point at an
org or repo that anyone else depends on. Create (or dedicate) an org/user and a single repo
that exists only for this suite, and never reuse its PAT for anything else.

## Preconditions

The script checks most of these itself and fails fast with an actionable message
(`check_preconditions` in `scripts/live-github-e2e.sh`); the rest — PAT scopes and the test
repo's workflow file — cannot be verified locally and must be set up first.

- `runnerd` running and reachable (`runnerctl status`), matching the `--socket`/`RUNNERCTL` the
  script is told about.
- `runnerctl github test` reports the credential and every configured scope `healthy`.
- The target profile (`--profile`, default `ubuntu-24`) exists, is enabled, and its image is
  imported/pulled and `ready` locally (`runnerctl image list`).
- `gh auth status` succeeds and `gh repo view <owner>/<repo>` can see the test repo — export
  `RUNNERVM_GITHUB_TOKEN` (the script sets `GH_TOKEN` from it for `gh`) or run `gh auth login`
  first.
- The test repo has `.github/workflows/e2e.yml` (copied from
  [`docs/e2e/test-repo-workflow.yml`](e2e/test-repo-workflow.yml)) on its default branch.
- `github.demand: scaleSet` in the applied configuration (the default), so the profile has a
  live scale set (`runnerctl scaleset list` shows it `ready`) that GitHub actually assigns jobs
  to. `manual` demand mode will not exercise the flows this suite is testing.

### PAT scopes

| Scope target | Token needs |
| --- | --- |
| Organization scope (`scope.type: organization` in the applied config) | `admin:org` |
| Repository scope (`scope.type: repository`) | `repo` |

Both are broad, host-wide-compromise-grade scopes for whatever org/repo they're issued against
— another reason the test org/repo must be dedicated and otherwise worthless. Store the token
the same way production would (`runnerctl auth login`; see `docs/install.md`'s security notes),
not as a stray file.

## Setup

1. Create the dedicated test org (or user) and repo; note `RUNNERVM_E2E_OWNER` and
   `RUNNERVM_E2E_REPO=owner/repo`.
2. Mint a PAT with the scope from the table above for that org/repo only.
   `RUNNERVM_GITHUB_TOKEN=<pat>`.
3. Copy [`docs/e2e/test-repo-workflow.yml`](e2e/test-repo-workflow.yml) to
   `.github/workflows/e2e.yml` in the test repo and push it to the default branch.
4. On the Mac mini: `swift build`, `scripts/sign-dev.sh`, apply a configuration whose
   `github.scopes` includes the test org/repo and whose `profiles` includes the profile you'll
   pass as `--profile` (`runnerctl config apply <yaml>`), then `runnerctl auth login` with the
   same PAT (or a separate one with matching scopes — the daemon's own GitHub calls and the
   script's `gh`/`gh api` calls are independent credentials).
5. `runnerctl doctor` and `runnerctl github test` should both be clean before running anything.
6. Optional, only if you'll trigger the suite from
   [`github-integration.yml`](../.github/workflows/github-integration.yml) instead of running the
   script by hand: register a long-lived self-hosted Actions runner on the Mac mini itself, in
   *this* repo (github-managed-runners), labelled `self-hosted, macOS, ARM64, runnervm-host`.
   This is a plain GitHub Actions runner you set up by hand (`https://github.com/<owner>/<repo>/settings/actions/runners/new`)
   — it is **not** one of RunnerVM's own managed VMs, and GitHub-hosted macOS runners cannot
   nest `Virtualization.framework`, so there is no GitHub-hosted alternative. Set repo variables
   `E2E_OWNER`, `E2E_REPO` (and optionally `E2E_STATE_DIR` if `runnerd` doesn't use the default
   `$HOME/Library/Application Support/RunnerVM`) and secret `E2E_GITHUB_TOKEN`.

## Running scenarios by hand

```sh
export RUNNERVM_E2E_OWNER=my-test-org
export RUNNERVM_E2E_REPO=my-test-org/rvm-e2e
export RUNNERVM_GITHUB_TOKEN=ghp_xxx

# Prove the control flow first -- no daemon, no PAT validity, no GitHub calls needed:
scripts/live-github-e2e.sh --dry-run --all

# One scenario:
scripts/live-github-e2e.sh --scenario success

# A batch, with a JSON report written explicitly:
scripts/live-github-e2e.sh --scenario success --scenario cancel-during-job --scenario concurrent \
  --json-report /tmp/e2e-report.json

# Everything, including the 65+ minute long-job scenario:
scripts/live-github-e2e.sh --all
```

Run `success` alone first on a fresh setup — it is the cheapest signal that the whole chain
(daemon, scale set, workflow file, PAT) actually works before spending time on the rest.

## Scenario reference

| Scenario | Asserts | Typical duration |
| --- | --- | --- |
| `success` | A `quick` job dispatched via the scale set succeeds; the instance and runner session are gone afterward; the scale set shows 0 assigned jobs. | 1-5 min |
| `cancel-before-assignment` | Draining the host, dispatching, then cancelling while the run is still queued leaves no VM or runner session behind. | 1-2 min |
| `cancel-during-job` | Cancelling a `long` job after it reaches `jobRunning` tears the VM and runner session down. | 1-3 min |
| `restart-while-booting` | Restarting `runnerd` while an instance is `startingWorker`/`startingVM`/`waitingForAgent` does not stop the job from completing (spike S2 already proved the worker survives a daemon restart; this proves the job-level path does too). | 2-6 min |
| `restart-while-runner-starts` | Restarting `runnerd` while the runner is being configured/started for the job (`configuringRunner`/`runnerStarting`, later than `restart-while-booting`'s window, earlier than `restart-during-job`'s) does not stop the job from completing, and no duplicate runner session appears for it. | 2-6 min |
| `restart-during-job` | Same, but the restart happens after the runner reaches `jobRunning`: the job still completes and no duplicate runner session appears for it. | 2-6 min |
| `restart-during-job-sigkill` | Same as `restart-during-job`, but `runnerd` is SIGKILLed instead of restarted gracefully. Asserts the vmworker/VM are left completely untouched (its `workerPid` is unchanged), the GitHub run shows exactly one attempt and one job (no GitHub-side retry masked a RunnerVM-side duplicate), and the runner registration/VM/host capacity all converge afterward. Own timeouts (`RUNNERVM_E2E_SIGKILL_TIMEOUT`, default 240s) — an unclean death has strictly more to recover than a graceful restart. | 2-8 min |
| `redelivery` | Best-effort (see below): restarting `runnerd` immediately after dispatch does not produce a second VM/runner for the same job. | 1-3 min |
| `scaleset-reconnect` | Forces the scale set's message session to drop and reconnect mid-job via the debug RPC `debug.scaleSetReconnect` (`Proto/daemon_api.md`); the job still completes exactly once on a new session generation, and no duplicate VM appears. | 1-4 min |
| `long-job` | A job that sleeps `--long-minutes` (default 65) actually runs that long without the VM being torn down partway through, and completes successfully. | `--long-minutes` + ~15 min |
| `concurrent` | `--concurrency` (default 4) `quick` jobs dispatched together never push the peak VM count for the profile above its advertised capacity. | 2-10 min |
| `queue-overflow` | 2x the advertised capacity dispatched together: GitHub never assigns more than the advertised number at once (`X-ScaleSetMaxCapacity` honoured), and everything eventually completes. | 5-20 min |

Every scenario, on failure, leaves whatever GitHub/VM state it was in — inspect with
`runnerctl vm list`, `runnerctl runner list`, `gh run list -R <repo>` before rerunning.

`restart-during-job-sigkill` needs a way to actually deliver the SIGKILL: by default the script
resolves `runnerd`'s pid from `runnerctl status`'s `daemon.pid`, falling back to `pgrep -f
runnerd`, and signals it directly, which only works when the script runs on the same host as
`runnerd` under a user allowed to signal it. `--kill-cmd '<shell command>'` overrides pid discovery
entirely (mirroring `--restart-cmd`) for a remote or sandboxed setup; it always runs before the
normal restart step, never instead of it.

Every scenario also compares `runnerctl status`'s per-profile `busy`/`idle`/`demand`/`starting`
against a baseline captured at the scenario's own start, as part of its normal leftover check —
not just that the VM/session lists emptied out, but that the daemon's own capacity accounting
actually came back to where it was.

## Reading the report

`--json-report <path>` (default `<state-dir>/logs/e2e-report-<timestamp>.json`) is written once
at the end of a real (non-dry-run) invocation:

```json
{
  "owner": "my-test-org",
  "repo": "my-test-org/rvm-e2e",
  "profile": "ubuntu-24",
  "scenarios": [
    {
      "name": "success",
      "status": "pass",
      "startedAt": "2026-08-26T14:00:00Z",
      "endedAt": "2026-08-26T14:02:11Z",
      "durationSeconds": 131,
      "detail": ""
    }
  ]
}
```

`status` is `pass` or `fail`; the script's own exit code is 0 only if every selected scenario
passed. Warnings printed during a run (`[e2e] warning: ...`) explain *why* a scenario failed —
the report itself only records pass/fail and timing, so keep the console log (or the
`e2e-logs-*` artifact from the driver workflow, which bundles `<state-dir>/logs`) alongside the
report when filing a follow-up.

## Known non-determinism and limitations

- **`redelivery` is not forceable.** RunnerVM's scale-set poll loop
  (`Sources/Orchestration/ScaleSetDemandPolling.swift`) logs nothing at the point a
  `JobAvailable` message is received but not yet acknowledged — the only log line is "scale set
  ready" at registration time. There is no reliable hook to restart `runnerd` in that exact
  window, so the scenario restarts after a fixed `RUNNERVM_E2E_REDELIVERY_DELAY` (default 5s)
  and can only assert the eventual outcome (one VM, job still completes), not that a redelivery
  actually happened. Treat a `pass` here as "no observed duplicate," not "redelivery was
  exercised."
- **`restart-while-booting` and `restart-while-runner-starts` can race a warm pool.** If the
  profile's `warmPool.minIdle` keeps an idle instance around, the dispatched job may be served by
  that instance instead of a freshly booting one, and the scenario fails its own precondition
  (`wait_for_instance_state` times out) without RunnerVM being at fault. Run these scenarios
  against a profile with `warmPool.minIdle: 0`, or accept the occasional false negative.
- **`restart-during-job`, `restart-while-runner-starts` and `restart-during-job-sigkill`'s
  duplicate-runner check is a heuristic**, not a real correlation: the daemon has no
  `scale_set_id`/job-id column on `runner_sessions` (TODO.md M6 follow-up), so the script counts
  sessions for the profile with a non-null `githubRunnerId` created after the scenario's own
  dispatch time. It is a reasonable proxy for one scenario running in isolation, not a guarantee
  under concurrent scenario runs (don't run scenarios in parallel against the same profile).
- **`restart-during-job-sigkill`'s pid discovery is best-effort off-host.** `runnerctl status`'s
  `daemon.pid` and the `pgrep -f runnerd` fallback both assume the script runs on the same host as
  `runnerd`; from a self-hosted Actions job on that same Mac mini (`github-integration.yml`) this
  is exactly the case, but a driver running elsewhere needs `--kill-cmd`.
- **GitHub-side leftover checks are best-effort.** `assert_no_leftovers` also queries
  `orgs/<owner>/actions/runners` and `repos/<repo>/actions/runners`, matching runner names by
  the `rvm-<profile-shortName>-` prefix RunnerVM uses
  (`Sources/RunnerCore/Models/RunnerProfileConfig.swift`'s `shortName`: non-alphanumerics
  stripped, lowercased, first 12 characters). This call is unpaginated (fine for a dedicated
  test org with a handful of runners) and only warns, never fails a scenario, because GitHub's
  own runner-list can lag the daemon-side teardown by a few seconds.
- **No CLI surface reports "image ready" as a single boolean.** The precondition check
  (`check_profile_image_ready`) cross-references `runnerctl profile show`'s `image` field
  against `runnerctl image list`'s `canonicalReference`/`name` and `state`; if a profile's
  `image:` is a registry reference that hasn't been pulled locally yet, pull it first
  (`runnerctl image pull <ref>`) — the script will not do this for you.

## Live builder integration testing

`scripts/live-builder-e2e.sh` is a separate driver for the image-builder → GitHub → GHCR path:
one fixed pipeline rather than `live-github-e2e.sh`'s independently selectable scenarios, since
each step's output (the built image's name and digest) feeds the next.

```sh
export RUNNERVM_E2E_OWNER=my-test-org
export RUNNERVM_E2E_REPO=my-test-org/rvm-e2e
export RUNNERVM_GITHUB_TOKEN=ghp_xxx

# Prove the control flow first -- no daemon, no PAT validity, no GitHub or registry calls needed:
scripts/live-builder-e2e.sh --dry-run --recipe images/recipes/ubuntu-24 --profile ubuntu-24 \
  --registry ghcr.io/my-test-org/runnervm-e2e

# The real run:
scripts/live-builder-e2e.sh --recipe images/recipes/ubuntu-24 --profile ubuntu-24 \
  --registry ghcr.io/my-test-org/runnervm-e2e --config path/to/e2e-config.yaml

# Skip the OCI leg (push/delete/pull-by-digest/redispatch) if no registry credentials are set up:
scripts/live-builder-e2e.sh --recipe images/recipes/ubuntu-24 --profile ubuntu-24 --skip-oci
```

1. `runnerctl image build <recipe> --name e2e-<timestamp> --wait` builds a real image in-daemon.
2. `runnerctl image inspect` asserts `guestAgent == true` and captures the digest; the matching
   `runnerctl build show` record asserts `recipeSHA256` is present (that field lives on the build
   record, not on the persisted image's own provenance summary).
3. **Precondition, not an action**: `--profile`'s applied `image:` must already equal the alias
   just built. The script never edits `runnerd`'s configuration itself — `--config <path>` applies
   a document you supply (`runnerctl config apply`); without one, the profile must already point
   at `e2e-<timestamp>`, which nothing before this run could have known in advance, so a first run
   normally needs `--config`.
4. Dispatches [`runnervm-selftest.yml`](../.github/workflows/runnervm-selftest.yml) (`profile`
   input) against the freshly built image, waits for success, and asserts the runner
   registration/VM/session/capacity all converge back to baseline — the same
   `assert_no_leftovers`/`capture_capacity_baseline` helpers `live-github-e2e.sh` uses, shared via
   `scripts/lib/live-common.sh`.
5. The OCI leg (`--skip-oci` to omit): pushes to `--registry`, deletes the local image, pulls it
   back by the immutable `@sha256:<digest>` the push reported (never a mutable tag), asserts the
   round-tripped image matches (same digest, `guestAgent == true`), then dispatches the workflow a
   second time. **A RunnerVM OCI push/pull does not round-trip the local name alias** — the pulled
   image is named after the resolved reference, not the alias it had before `image delete`, so the
   script re-checks (and, with `--config`, re-applies) the profile precondition from step 3 before
   the second dispatch rather than assuming the same alias still resolves.

Same conventions as `live-github-e2e.sh`: `--json-report` (default
`<state-dir>/logs/builder-e2e-report-<timestamp>.json`), the report shape, `RUNNERVM_E2E_*`
timeout overrides (`RUN_TIMEOUT`, `LEFTOVER_TIMEOUT`, `POLL_INTERVAL`), and `RUNNERCTL`/`--socket`
for the daemon connection.
