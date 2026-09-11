# State machines (authoritative transition tables)

Implemented as pure functions in `RunnerCore/StateMachines/`. Any edge not listed is illegal and must throw
`StateTransitionError`. Ambiguity resolves to `interrupted`/`tainted`, never `idle`.

## InstanceState
```
planned         -> preparing | failed | deleting
preparing       -> cloning | failed | deleting
cloning         -> startingWorker | failed | deleting
startingWorker  -> startingVM | failed | interrupted | deleting
startingVM      -> waitingForAgent | failed | interrupted | deleting
waitingForAgent -> idle | failed | interrupted | stopping
idle            -> configuringRunner | stopping | interrupted | deleting
configuringRunner -> runnerStarting | stopping | interrupted
runnerStarting  -> runnerOnline | stopping | interrupted
runnerOnline    -> busy | stopping | interrupted
busy            -> cleaning (reusable) | stopping (ephemeral) | interrupted
cleaning        -> idle | stopping | interrupted
stopping        -> deleting | stopped | interrupted
stopped         -> deleting
interrupted     -> deleting | startingWorker (idle reusable only) 
failed          -> deleting
orphaned        -> deleting
deleting        -> deleted
```
Capacity-consuming states: everything except `deleted`. Terminal: `deleted`.

`InstanceState` also permits `stopped -> startingWorker`, but nothing performs it: there is no
`vm start` command, and a reusable restart is decided from the *predecessor* state inside
`handleWorkerDisconnect`/`markWorkerDead` and always leaves from `interrupted`. It is left out of
the table above so the edges listed are the ones that actually happen.

Teardown pace: every runnerd-driven stop or delete gives the guest the *profile's*
`timeouts.gracefulShutdown` (default 30s) — it is sent to vmworker in `worker.shutdown`, to the
guest agent as `agent.stopRunner{graceMs}`, and to the worker at spawn as `vmworker run
--graceful-ms` for the shutdowns the worker starts by itself (hard deadline, orphan idle, SIGTERM).
runnerd then waits for the worker's lock to drop for that window plus 15s, capped at 120s. A profile
row that no longer exists falls back to 30s; image builds are not profile-owned and keep their own
fixed 120s. Because that whole window is spent waiting, the scheduler's cancellations run detached
from the reconcile tick.

Boot pace: `timeouts.vmBoot` (default 3m) bounds the whole clone-to-running window rather than the
guest's boot alone, so `cloning -> failed`, `startingWorker -> failed` and `startingVM -> failed`
can each carry `VM_BOOT_TIMEOUT`, with `failure.json` naming the phase that overran. The clone and
the worker spawn are checked as they finish — `clonefile(2)` is synchronous and has no cancellation
point, so an overrun there can only be reported after the fact. `instance.create` returns as soon as
`vm.start` is acknowledged, with the row in `startingVM`; what is left of the window is watched by a
task runnerd owns per instance, which fails the row only if it is still in `startingVM` (and still
on the same `worker_generation`) when the deadline passes. A `running` event that lands first wins
the row outright and leaves no failure record, no failure metric and no worker shutdown behind. The
failed row keeps its capacity reservation until the retention sweep, which is what stops the
scheduler from cloning and booting the same unbootable image on every tick. The default assumes
instance disks are `clonefile(2)` clones (`allowFullCopy == false`, the production default): a host
falling back to full copies would spend the budget copying a disk. A watch only lives in memory, so
the first reconcile tick after a restart rebuilds it for every `startingVM` row whose worker
survived: the window is measured from the row's `started_at` rather than restarted, and a row
already past it fails on that tick. Recovery asks the re-adopted worker what it sees first — a
guest that reached `running` while runnerd was away has no event left to send — so that row is
finished into `waitingForAgent` instead of failed. macOS guests are the exception — Virtualization
reports the VM `running` before macOS has booted, so a macOS first boot is bounded by
`timeouts.agentReady`, not by `vmBoot` (`PROFILE_TIMEOUT_AGENT_READY_SHORT` warns below 2m).

Retention: the reconciler deletes every `failed`, `interrupted` and `stopped` row once
`diagnostics.failedInstanceRetention` has passed since `stopped_at` (or `created_at` for a row that
never stopped) — regardless of lifecycle, because a row a sweep can see has already lost its
restart. Two exceptions: a row an in-flight `delete`/`respawn` already owns, and a maintenance row
whose `pinned_until` has not passed (`MaintenanceInstanceReaper` owns those). A row still in
`deleting` five minutes after the sweep first saw it has its delete re-issued, once per tick, off
the reconcile loop. The instance sweep runs before session recovery, so a session still open on a
swept instance is closed as `VM_LOST` on that same tick.

## RunnerSessionState
```
planned      -> jitRequested | jitFailed
jitRequested -> jitIssued | jitFailed
jitIssued    -> jitDelivered | runnerStartFailed | jobInterrupted
jitDelivered -> runnerStarting | runnerStartFailed
runnerStarting -> runnerOnline | runnerStartFailed | timedOut | runnerLost
runnerOnline -> jobRunning | timedOut | runnerLost | completed (runner exited without a job)
jobRunning   -> completed | jobInterrupted | runnerLost | timedOut
```
Terminal: `completed, jitFailed, runnerStartFailed, runnerLost, jobInterrupted, timedOut`. Every non-`completed`
terminal state schedules `ensureRunnerRemoved(githubRunnerId)` if a runner id was persisted.

`jitRequested` is bounded by the profile's `timeouts.jitGeneration` (default 2m) on both the REST
and the scale-set path: the deadline is enforced by the caller, because no observer exists in the
`jit*` states and nothing else would ever revisit the row. Expiry closes the session as `jitFailed`
with `GITHUB_JIT_GENERATION_TIMEOUT` and, unlike other failures, does **not** retain the VM — a
GitHub that is merely slow is no evidence about the guest. GitHub can still hold a registration the
caller never saw (the config arrived after the deadline, or the POST was processed and its answer
lost), so the id is looked up — from the call itself, else by runner name — written to the row, and
removed like any other terminal state's; `retryPendingRemovals` re-drives a failed DELETE from that
same column.

## Host mode
`normal -> draining -> offline -> normal`, plus `draining -> normal` (cancel drain); `draining` advertises capacity 0 but keeps jobs.
