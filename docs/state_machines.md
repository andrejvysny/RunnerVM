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
stopped         -> deleting | startingWorker (reusable restart)
interrupted     -> deleting | startingWorker (idle reusable only) 
failed          -> deleting
orphaned        -> deleting
deleting        -> deleted
```
Capacity-consuming states: everything except `deleted`. Terminal: `deleted`.

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

## Host mode
`normal -> draining -> offline -> normal`, plus `draining -> normal` (cancel drain); `draining` advertises capacity 0 but keeps jobs.
