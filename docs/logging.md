# Logging, lifecycle events and diagnostics

What RunnerVM writes, where it writes it, how long it keeps it, and how to ship it somewhere else.

Everything below lives under `<state-dir>` (`--state-dir`, default
`/Library/Application Support/RunnerVM`). `<state-dir>` is mode 0750 and owned by the service
account, so a log shipper has to run as that account or be granted read access to `logs/`.

## What is written where

| Path | Format | Written by | Rotation |
| --- | --- | --- | --- |
| `logs/runnerd/runnerd.log` | JSON, one object per line | `runnerd` | In process, by size (`logging.file`) |
| `logs/runnerd/runnerd.log.1` … `.N` | same | rotation | Kept: `logging.file.maxFiles` |
| `logs/runnerd/stdio.log` | plain text | launchd | External only (`newsyslog`) |
| `logs/events.jsonl` | JSON, one object per line | `runnerd` | In process, same policy |
| `logs/instances/<id>/serial.log` | plain text | vmworker (guest serial console) | Retention sweep |
| `logs/instances/<id>/worker.log` | plain text | vmworker stdout/stderr | Retention sweep |
| `logs/instances/<id>/failure.json` | JSON | `runnerd` | Retention sweep |
| `logs/instances/<id>/diag/runner-diag.tar.gz` | gzip tarball | `runnerd`, pulled from the guest | Retention sweep |

`logs/runnerd/stdio.log` is **not** the daemon log. Both launchd plists point
`StandardOutPath`/`StandardErrorPath` there, and it collects only what escapes the logging system:
a dyld failure, a Swift runtime trap, output from a crash before logging is bootstrapped. If it is
empty, that is the healthy state.

`serial.log`, `worker.log` and `failure.json` are produced inside `instances/<id>/` — the VM's
disk directory — and are **moved** into `logs/instances/<id>/` immediately before that directory
is unlinked, so they outlive the VM. A live VM's copies are still under `instances/<id>/`.

`runnerd` writes its JSON log to the file *in addition to* stderr, never instead of it: launchd
captures stderr and an operator running the daemon in a terminal reads it there. The file is
opened when `--log-file <path>` is given, or automatically whenever stderr is not a terminal
(which is how launchd runs it) and `logging.file.enabled` is true. `--log-file off` keeps stderr
only; an explicit `--log-file <path>` opens the file even when the section disables it.

Logging has to be up before anything can report a configuration error, so `runnerd` reads
`logging.file` out of `--config` itself, before the daemon runtime parses and applies the document
properly. A change to `logging.file` therefore takes effect at the next daemon start, not at the
next `runnerctl config apply`; `retention`, `collectRunnerDiagnostics` and `diagnosticsTimeout`
are read at the point of use and do take effect on apply.

## Field glossary

Every line in `runnerd.log` carries `timestamp` (RFC 3339, UTC, fractional seconds), `level`,
`component` and `message`. Every other key is correlation metadata; a key is present only when the
value was actually in scope at the call site, and the same key always means the same thing.

| Key | Meaning |
| --- | --- |
| `host_id` | This host's stable id (`state/host-id`). Attached to every line once the daemon has loaded it. |
| `instance_id` | The VM. Joins `instances`, `logs/instances/<id>/` and the instance's directory. |
| `profile_id` | The runner profile the VM belongs to. Some scheduler lines carry the profile *name* here. |
| `runner_session_id` | One GitHub runner registration and the job it ran. |
| `scale_set_id` | The local `scale_sets` row id, not GitHub's numeric one (that is `github_scale_set_id`). |
| `github_runner_id` | GitHub's numeric runner id for the session's registration. |
| `github_runner_name` | The runner name GitHub sees — the instance name. |
| `github_job_request_id` | The scale-set message's `runnerRequestId`. |
| `github_request_id` | `X-GitHub-Request-Id` from the API response. Quote it in GitHub support tickets. |
| `operation_id` | A durable `operations` row (runner removal, image pull). |
| `worker_pid` | The `vmworker` host process. Never a guest pid. |
| `image_digest` | The image the VM was cloned from. |

Secrets never appear. Every message and every metadata value passes through `Redactor`
(`Sources/RunnerLogging/Redactor.swift`) before any sink sees it: Authorization/Bearer headers,
GitHub PAT/App/installation tokens, PEM private keys, long base64 blobs, and any metadata key
whose *name* matches `jitconfig|password|secret|token|private_key|…` are replaced wholesale. The
JIT config in particular is never persisted, never logged and never returned to a caller.

## The lifecycle event stream

`logs/events.jsonl` is one JSON object per lifecycle transition and per audit event. It is
deliberately a separate stream from `runnerd.log`: it is fixed-shape, never filtered by log level,
and meant to be joined on rather than read.

```json
{"event":"instance.transition","from":"busy","host_id":"9d1c…","instance_id":"8b13…","profile_id":"ee07…","to":"cleaning","ts":"2026-08-26T14:46:22.417Z"}
```

Keys, all optional except `ts`, `event` and `host_id`: `instance_id`, `profile_id`,
`runner_session_id`, `scale_set_id`, `github_runner_id`, `from`, `to`, `reason`.

| `event` | Emitted when |
| --- | --- |
| `instance.transition` | Any committed VM state change. `from`/`to` are `InstanceState` values; `reason` is the failure code if one is set. |
| `session.transition` | Any committed runner-session state change. `from`/`to` are `RunnerSessionState` values. |
| `instance.diagnostics` | A guest `_diag` tarball was collected. `reason` is the byte count. |
| `audit` | An `audit_events` row was written. `from` is the actor, `to` is the audit kind, `reason` is the detail JSON. |
| `demand.changed`, `capacity.advertised`, `instance.started`, `instance.startFailed`, `instance.cancelled`, `session.assigned`, `session.assignmentFailed`, `provider.degraded` | The orchestrator's scheduling events, mirrored from its in-memory ring. `to` repeats the event name, `reason` carries the detail. |

The stream is best effort by construction: if the file cannot be written the line is dropped and
`runnervm_log_lines_dropped_total` moves. No state machine ever blocks on it. The persisted rows
in SQLite remain the source of truth; this is a trace, not a ledger.

Note on `JobCompleted`: scale-set `JobCompleted` messages are logged (`job completed`, with
`github_job_request_id` and `github_runner_name`) and never drive teardown. The runner process's
own exit, observed through `agent.runnerStatus`, is the sole authority on when a session is over —
GitHub's message can be redelivered, can arrive late, and can arrive for a runner this host does
not own.

## Rotation and retention

```yaml
logging:
  file:
    enabled: true          # write logs/runnerd/runnerd.log and logs/events.jsonl at all
    maxSize: 32MiB         # rename to .1 once the live file reaches this
    maxFiles: 10           # keep .1 … .10; the live file is extra
  retention:
    instanceLogs: 7d       # delete logs/instances/<id>/ this long after its last write
  collectRunnerDiagnostics: true
  diagnosticsTimeout: 60s
```

Worst case on disk for the two rotating files: `2 × maxSize × (maxFiles + 1)` — 704 MiB at the
defaults. Per-instance logs are bounded by `retention.instanceLogs` and by how many jobs the host
runs in that window; a `serial.log` is typically tens of KiB and a collected `_diag` tarball a few
MiB, so a host running 200 jobs a day at 7 days needs a few GiB of headroom.

Validation rejects `maxSize` below 1MiB, `maxFiles` outside 1…100, a negative
`retention.instanceLogs`, and a non-positive `diagnosticsTimeout` while diagnostics are on. A
`retention.instanceLogs` of `0` is accepted but warns: it keeps every directory forever.

The retention sweep runs on the daemon's five-minute maintenance loop. It deletes a
`logs/instances/<id>/` directory when the newest write anywhere inside it is older than
`retention.instanceLogs` **and** the instance is not still live in the database — a long-running
job legitimately produces no writes for hours, so mtime alone is never enough. Each sweep bumps
`runnervm_instance_log_dirs_swept_total`.

This is a different policy from `diagnostics.failedInstanceRetention`, which drops the *disk*
directory of a VM that never came up (default 2h). Both can be tuned independently.

### SIGHUP

`runnerd` reopens every log file it owns on `SIGHUP`. That makes external rename-based rotation
(`newsyslog`, `logrotate`-style tooling) take effect immediately instead of at the next daemon
restart, which was the old limitation.

launchd owns the daemon's pid and writes no pid file, so signal it by job label:

```sh
sudo launchctl kill HUP system/com.runnervm.runnerd                 # LaunchDaemon variant
launchctl kill HUP gui/$(id -u _runnervm)/com.runnervm.runnerd      # LaunchAgent variant
```

In-process size rotation bounds every file whether or not you ever send the signal;
`packaging/newsyslog/runnervm.conf` is optional policy on top of it.

## Guest runner diagnostics

When an ephemeral VM finishes — successfully or not — and when a reusable VM is recycled, the
guest is about to be destroyed, and the Actions runner's own `_diag` directory only exists inside
it. `runnerd` therefore runs one bounded command through `agent.exec` **before** stopping the VM
and streams the result to `logs/instances/<id>/diag/runner-diag.tar.gz`.

The command tars, to stdout, a temporary directory containing:

- the runner's `_diag` directory, found at the first of `/opt/actions-runner`,
  `/home/*/actions-runner`, `/root/actions-runner`, `/Users/*/actions-runner`;
- `journalctl -u runnervm-guest-agent --no-pager -o short-iso -n 5000` (the guest agent's own log
  — the unit name matches `GuestAgent/packaging/systemd/runnervm-guest-agent.service`);
- the last 2000 lines of `dmesg`.

Each part silences its own failure, so a guest with no journal or no `_diag` still yields a
smaller tarball rather than an error. `agent.exec` chunks carry their payload as base64 on the
wire, so the gzip stream needs no extra encoding.

Limits, all of which fail the collection and nothing else:

- **60 s** (`logging.diagnosticsTimeout`), enforced both as the exec's own `timeoutMs` and as a
  host-side deadline;
- **64 MiB**, enforced both as the exec's `maxOutputBytes` and as a host-side byte count;
- collection is skipped entirely when `collectRunnerDiagnostics: false` or when the guest agent is
  unreachable.

A failure is one `warning` line and a deleted partial file. **It never blocks or aborts a
teardown** — a VM that will not give up its logs is stopped and deleted exactly as it would have
been.

## Shipping the logs

Two worked examples ship with the repo; neither is installed by `scripts/install.sh`. Both tail
`runnerd/runnerd.log`, `events.jsonl` and `instances/*/{serial,worker}.log`, parse JSON where the
file is JSON, leave the guest console output as text, and attach `host_id` and `source` labels.
Read the header of each file for the placeholders to replace.

`<state-dir>` is 0750 and `logs/`/`logs/instances/` are 0750 too, owned by the service user and its
dedicated `_runnervm` group (never `staff` — see `docs/install.md`), so a log shipper needs to
either run as `_runnervm` itself or be added to that group:
`sudo dseditgroup -o edit -a <shipper-user> -t user _runnervm`.

- **Vector** — `packaging/vector/vector.toml`, with a Loki sink.
  `vector validate --config packaging/vector/vector.toml`.
- **Fluent Bit** — `packaging/fluent-bit/fluent-bit.conf` (plus `parsers.conf` and
  `instance_path.lua`), shipping to `stdout` by default with a commented OpenSearch sink.

Both exclude the rotated `*.log.1` … `.N` archives from their tail globs. `RotatingFileSink`
renames rather than truncates, so without that exclusion a shipper re-ingests every archive as a
new file after each rotation.

Recommendations:

- Ship `events.jsonl` to whatever you alert from; ship `runnerd.log` to whatever you search.
- Do not make `instance_id` an indexed label in a label-based store such as Loki — its
  cardinality is unbounded. Keep it in the line body.
- Set your remote retention longer than `logging.retention.instanceLogs`; local retention exists
  to bound the disk, not to be the archive.
- Alert on `runnervm_log_lines_dropped_total > 0`. It is non-zero only when a log file cannot be
  written, which usually means the state volume is full.

## Metrics

| Metric | Meaning |
| --- | --- |
| `runnervm_log_lines_dropped_total` | Lines a rotating file sink could not write. Should stay at 0. |
| `runnervm_instance_log_dirs_swept_total` | Per-instance log directories deleted by the retention sweep. |

Both are exported by the Prometheus endpoint (`metrics.prometheus.enabled`) and by
`runnerctl metrics`.
