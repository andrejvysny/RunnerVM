# Timeout and validation reference

Operator reference for `profiles[].timeouts` and the `PROFILE_TIMEOUT_*` validation codes wired
in Phase 3. Every number below is read from the code cited next to it, not remembered — re-check
the cited file if you suspect drift.

`timeouts` is optional per profile; a profile that omits it (or omits individual fields — decoding
is lenient) gets `TimeoutPolicy.default`
(`Sources/RunnerCore/Models/RunnerProfileConfig.swift:108-158`).

## `profiles[].timeouts`

| field | default | what it bounds | on expiry |
| --- | --- | --- | --- |
| `imagePull` | 60m | caller-side deadline inside `ImageManager.reserve`, from admission until the image record is ready. A shared pull between two callers keeps running for whichever caller is still inside its own deadline; a caller whose deadline fires gets `IMAGE_PULL_TIMEOUT` and its own planning pin released, while the transfer itself is unaffected. | `ImageError.pullTimeout` -> `IMAGE_PULL_TIMEOUT`, retryable (`Sources/RunnerCore/Errors/ImageError.swift:8,29`) |
| `clone` | 10m | nothing — accepted for config compatibility but not enforced. `clonefile(2)` is a synchronous APFS metadata operation with no cancellation point, so there is nothing a deadline could interrupt; an overrun is charged instead to `vmBoot`, which now bounds the whole clone-to-running window. | validation warns (`PROFILE_TIMEOUT_CLONE_IGNORED`) if set to anything but the default; no runtime effect |
| `vmBoot` | 3m | the whole clone -> running window, not just the guest boot: clock starts at `cloning`, and `startingWorker`/`startingVM` are checked as each phase finishes. `instance.create` still returns as soon as `vm.start` is acknowledged (row in `startingVM`); what is left of the window is watched by a per-instance task runnerd owns, which fails the row only if it is still in `startingVM` on the same `worker_generation` when the deadline passes — a `running` event that lands first wins the row outright. On a runnerd restart the watch is rebuilt from the row's `started_at` (not restarted), so a row already past deadline fails on the first reconcile tick. Precondition: the default assumes `allowFullCopy == false` (clonefile clones); a host falling back to full disk copies would spend the budget copying the disk. macOS is the exception — Virtualization reports the guest `running` before macOS has booted, so a macOS first boot is bounded by `agentReady`, not `vmBoot`. | `cloning`/`startingWorker`/`startingVM` -> `failed`, `VM_BOOT_TIMEOUT` naming the overrun phase in `failure.json` (`Sources/RunnerCore/Errors/VMError.swift:11,43,68`); failed row keeps its capacity reservation until retention. What limits retries is that reservation, not backoff: the failed row still counts as this profile's, so the scheduler plans no replacement for demand it already covers. The scheduler's hold-down applies only to the synchronous clone/spawn checkpoints, which throw out of `instance.create`; a watcher-detected timeout lands after that call has returned. With demand above the failed rows' cover, each tick still starts one VM per uncovered demand unit — bounded by host capacity and `limits.maxInstances`, not by a retry delay |
| `agentReady` | 2m | the guest agent bridge becoming ready after the VM is `running`. On macOS this is effectively the real first-boot bound (see `vmBoot` note above). | `GuestAgentError` `AGENT_READY_TIMEOUT` (`Sources/RunnerCore/Errors/GuestAgentError.swift:24`) |
| `jitGeneration` | 2m | the `jitRequested` session state, enforced by the caller (`RunnerSessionManager.register`) because no observer exists in the `jit*` states. Deliberately not sized to cover the whole `RetryPolicy.github` retry ladder (5 attempts, 1..60s backoff, ~168s worst case) — only a credential mint plus a couple of GitHub 429/503 retries. Giving up before the full ladder is the intent; the scheduler's hold-down, not this budget, decides how soon registration is retried. | session -> `jitFailed`, `GITHUB_JIT_GENERATION_TIMEOUT` (`Sources/RunnerCore/Errors/GitHubControlError.swift:39,74`); VM is destroyed (`retainVM: false` — a slow GitHub is no evidence about the guest); a late-arriving registration id is looked up and removed, retried by `retryPendingRemovals` if the DELETE itself fails; profile hold-down applies |
| `runnerOnline` | 2m | the `runnerStarting` session state (runner process launched, not yet registered online with GitHub). | session -> `timedOut`, `RUNNER_ONLINE_TIMEOUT` (`Sources/Orchestration/RunnerSessionObserver.swift:138`); `stopRunner` issued with `gracefulShutdown` grace |
| `jobMaxRuntime` | 6h | the `jobRunning` session state, from `jobStartedAt`. | session -> `timedOut`, `JOB_MAX_RUNTIME_EXCEEDED` (`Sources/Orchestration/RunnerSessionObserver.swift:142`); `stopRunner` issued with `gracefulShutdown` grace |
| `gracefulShutdown` | 30s | the grace every runnerd-driven `stop`/`delete` gives the guest before it is forced down: sent to vmworker in `worker.shutdown`, to the guest agent as `agent.stopRunner{graceMs}`, and to the worker at spawn as `vmworker run --graceful-ms` for shutdowns the worker starts on its own (hard deadline, orphan idle, SIGTERM). The guest-agent call deadline is `graceMs + 15s` (a fixed 30s call deadline would cancel the guest's wait and turn any grace above 30s into a SIGKILL at 30s). runnerd then waits for the worker's lock to drop for `graceMs + 15s`, capped at 120s. A profile row that no longer exists falls back to 30s. Image builds are not profile-owned and keep their own fixed 120s (`ImageBuilder.Tuning.gracefulShutdownMs`). | none directly — governs how long a stop/delete waits before a SIGKILL, not a failure path |
| `cleanup` | 5m | the `cleaning` state for a reusable instance between jobs (guest-side cleanup + the health/bootId/disk-headroom checks). | `ReuseFailure.timedOut` -> `INSTANCE_CLEANUP_TIMEOUT` (`Sources/Orchestration/InstanceReuse.swift:31,41`); instance recycled with taint `CLEANUP_FAILED` |

Source of truth: field list and defaults —
`Sources/RunnerCore/Models/RunnerProfileConfig.swift:108-158`; enforcement — `Sources/Orchestration/Deadline.swift`,
`InstanceCreation.swift`, `InstanceManager.swift`, `RunnerSessionManager.swift`,
`RunnerSessionObserver.swift`, `InstanceReuse.swift`; narrative — `docs/state_machines.md`
("Boot pace", "Teardown pace" paragraphs).

## `PROFILE_TIMEOUT_*` validation codes

Emitted by `RunnerProfileConfig.validateTimeouts`
(`Sources/RunnerCore/Configuration/ProfileValidation.swift:228-274`); only fires when a profile
sets `timeouts` explicitly (a profile inheriting `TimeoutPolicy.default` is never checked).

| code | severity | threshold | meaning |
| --- | --- | --- | --- |
| `PROFILE_TIMEOUT_NOT_POSITIVE` | error | any timeout field <= 0 | every field in `TimeoutPolicy.all` must be a positive duration |
| `PROFILE_TIMEOUT_CLONE_IGNORED` | warning | `clone` set to anything but the default (10m) | `clone` is parsed but never enforced; remove the setting, `vmBoot` now owns clone overruns |
| `PROFILE_TIMEOUT_VM_BOOT_SHORT` | warning | `vmBoot` < 30s | leaves nothing for the boot itself after the clone and worker spawn; an ordinary VM is failed with `VM_BOOT_TIMEOUT` and retried forever |
| `PROFILE_TIMEOUT_AGENT_READY_SHORT` | warning | macOS profile with `agentReady` < 2m | Virtualization reports the VM `running` before macOS has booted, so `agentReady` — not `vmBoot` — bounds a macOS first boot, and a cold one takes minutes |
| `PROFILE_TIMEOUT_JIT_GENERATION_SHORT` | warning | `jitGeneration` < 60s | a credential mint plus a couple of GitHub rate-limit/5xx retries can outlast it, failing a JIT request that was about to succeed |
| `PROFILE_TIMEOUT_IMAGE_PULL_SHORT` | warning | `imagePull` < 60s | a 16 GiB disk layer cannot transfer, decompress and hash in less; every `instance.create` on this profile would fail admission with `IMAGE_PULL_TIMEOUT` |
| `PROFILE_TIMEOUT_GRACEFUL_SHUTDOWN_LONG` | warning | `gracefulShutdown` > 10m | a stop or delete waits out the whole window before forcing the guest down; host capacity for this profile's VMs stays reserved that long |


## Slow links

A slow registry pull can still eat the `imagePull` budget on the first `vm create` against a new
image. Two ways to move that cost off the critical path:

- Pre-pull explicitly: `runnerctl image pull <ref>`.
- Set `images.prefetch: true` so `runnerd` pulls every referenced image at daemon start (a
  reference that fails to resolve is logged and stepped over; other profiles are still
  prefetched) — see `docs/images.md`.

## Retention and retries

- `diagnostics.failedInstanceRetention` (default 2h,
  `Sources/RunnerCore/Models/RunnerConfiguration.swift:87-90`) is how long a `failed`, `interrupted`
  or `stopped` instance row keeps its capacity reservation before the reconciler deletes it. A
  `VM_BOOT_TIMEOUT` (or any other) failure therefore blocks the profile from retrying on the same
  broken image/config until this window passes, unless a hold-down clears sooner.
- The reaper sweeps every `failed`/`interrupted`/`stopped` row past retention regardless of
  lifecycle (a row a sweep can see has already lost its restart), except a row an in-flight
  `delete`/`respawn` already owns, and a maintenance row whose `pinned_until` has not passed.
- A row stuck in `deleting` for 5 minutes (`InstanceReconciler`'s `deletingRetryGrace`, default
  300s, `Sources/Orchestration/InstanceReconciler.swift:31`) has its delete re-issued, once per
  reconcile tick.
- A `cancel` (scheduler-issued delete) that keeps failing on the same instance is counted per
  attempt in `runnervm_instance_cancel_failures_total`, labeled by profile and error code
  (`Sources/Metrics/RunnerVMMetrics.swift:62`); log noise escalates from one warning to an error
  every 30 failures (`CancelBackoff`, `Sources/Orchestration/Orchestrator.swift:290-301`) — the
  metric, not the log, is the alertable signal.

## See also

- `docs/state_machines.md` — the instance and session state tables, "Boot pace"/"Teardown pace"
  paragraphs, retention paragraph.
- `docs/images.md` — image pull/prefetch mechanics and the `timeouts:` profile example.
- `docs/install.md` — installation and deployment.
