# daemon protocol v1 — runnerctl ⇄ runnerd over `runnerd.sock`

All methods `readOnly` unless marked. Long-running mutations return `{operationId}`; poll `operation.get`.

`system.status`, `system.doctor`, `system.reconcile` (mut), `system.drain` (mut), `system.resume` (mut), `system.offline` (mut), `system.shutdown {force, timeoutMs}` (mut), `system.version`
`config.get`, `config.validate {yaml}`, `config.apply {yaml}` (mut → `{diff, operationId}`)
`profile.list`, `profile.get {name}` · `scope.list`, `scope.get {name}`
`image.list`, `image.get {digest|name}`, `image.import {path, os, name}` (mut), `image.delete {digest}` (mut), `image.prune` (mut)
`instance.list`, `instance.get {id}`, `instance.create {profile}` (mut, debug), `instance.stop {id, force}` (mut), `instance.delete {id}` (mut), `instance.taint {id, reason}` (mut), `instance.exec {id, argv, timeoutMs}` (stream), `instance.sshInfo {id}`, `instance.metrics {id}`
`runner.list`, `runner.get {sessionId}` · `scaleset.list` · `operation.get {id}`, `operation.list` · `logs.tail {component?, instanceId?, lines}` (stream) · `metrics.snapshot`
`auth.status`, `auth.login {token}` (mut), `auth.logout` (mut) · `github.test` · `debug.runJit {profile}` (mut, debug) · `debug.demandSet {profile, assignedJobs}` (mut, debug)

`scaleset.list` returns one row per enabled profile: `{profile, name, githubScaleSetId, state, sessionState, sessionGeneration, lastMessageId, advertisedCapacity, assignedJobs, healthy, statistics, updatedAt, lastError}`. `name` is `runnervm-<profile>` (spec §14); `lastMessageId` is the message-queue cursor inside `sessionGeneration`; `advertisedCapacity` is what the next poll sends as `X-ScaleSetMaxCapacity` and is 0 while the host is draining. The message-session bearer token is never returned, logged, or persisted.

`debug.demandSet` overrides local demand and is rejected with `DEMAND_NOT_MANUAL` unless runnerd runs the manual demand provider (`RUNNERVM_DEMAND_MODE=manual`). With a scale set in front, demand is GitHub's statistics and nothing else.

`auth.login` is the only method that carries a secret. The token travels over `runnerd.sock` (peer-UID checked, 0700 directory) and is written straight to `github.auth.source`; it is never echoed back, logged, or written to the applied YAML.

`runnerctl` never opens SQLite, instance files, or GitHub directly. Output modes: human table, `--output json`.

`system.drain`, `system.resume` and `system.offline` move `hosts.mode` (spec §109) with a compare-and-swap and an `audit_events` row, and all three answer `{mode, activeSessions, drained}`. `draining` advertises 0 capacity to every scale set and admits no new work while the jobs already on the host finish; `resume` returns to `normal` from either `draining` or `offline`; `offline` drains first when the host was still `normal`, because `normal -> offline` is not an edge. `system.drain {wait: true}` blocks until `activeSessions` reaches 0 or `timeoutMs` elapses and reports which happened in `drained`. `system.shutdown` drains, waits for the active sessions unless `force` (otherwise it fails `UNAVAILABLE`), answers `{accepted, mode, activeSessions}` and only then closes the socket; vmworkers and their VMs are deliberately left running for the next start to reconnect (spec §108).

`metrics.snapshot {format?}` returns `{collectedAt, families[], prometheus?}`, where each family is `{name, type, help, samples[]}` and each sample is `{labels[], value?, histogram?}`; `format: prometheus` additionally renders the 0.0.4 exposition text daemon-side so `runnerctl metrics --format prometheus` reproduces a scrape without the endpoint being enabled. Metric label values are profile names, instance ids, instance/session state names and fixed enumerations only — never anything a workflow supplied. The optional endpoint (`metrics.prometheus.enabled`, spec §43) serves `GET /metrics` and `GET /healthz` on loopback only; a non-loopback `listen` is rejected at startup with `CONFIG_VALIDATION_FAILED`.

`system.status` reports `daemon.mode` plus `daemon.activeSessions`, which is what `runnerctl status` prints as `Mode: draining (N active jobs)`.
