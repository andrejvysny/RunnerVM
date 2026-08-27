# guest protocol v1 — runnerd ⇄ guest-agent (vsock port 4050 via worker bridge)

Agent listens on vsock port 4050 (Linux: `AF_VSOCK` via mdlayher/vsock; macOS: `AF_VSOCK` raw syscalls).
Host initiates everything. Agent runs as root (Linux systemd / macOS launchd); runner runs as `runner`.

| method | class | payload → result |
|---|---|---|
| `agent.hello` | readOnly | `{}` → `{protocolVersion:1, agentVersion, os, arch, hostname, bootId, capabilities:[...]}` |
| `agent.health` | readOnly | `{}` → `{state: starting\|ready\|degraded\|shuttingDown, reasons:[...]}` |
| `agent.getInfo` | readOnly | `{}` → `{ipAddresses:[...], uptimeSec, kernel, runnerVersion?, dockerVersion?}` |
| `agent.getMetrics` | readOnly | `{}` → spec §39 object (all counts int64) |
| `agent.resizeDisk` | idempotentMutation | `{}` → `{grown: bool, rootBytes}` — Linux: growpart + resize2fs; macOS: NOT_SUPPORTED in v1 |
| `agent.startRunner` | singleShot | `{sessionId, jitConfig, workDir, env:{}, labels?}` → `{pid, startedAt}`; `jitConfig` passed via env `ACTIONS_RUNNER_INPUT_JITCONFIG`, never logged; duplicate `sessionId` ⇒ error `ALREADY_STARTED` |
| `agent.runnerStatus` | readOnly | `{sessionId}` → `{state: starting\|online\|busy\|exited\|unknown, pid?, exitCode?, exitedAt?}` |
| `agent.stopRunner` | idempotentMutation | `{sessionId, graceMs}` → `{stopped}`; SIGTERM process group, SIGKILL after grace |
| `agent.cleanup` | idempotentMutation | `{epoch}` → `{ok, removed:[...]}`; same epoch twice is a no-op; on a reusable-lifecycle VM the runner's whole HOME is reset to a pristine snapshot (see below), error `HOME_SNAPSHOT_MISSING` if none exists |
| `agent.exec` | stream | `{argv:[...], cwd?, env?, timeoutMs, maxOutputBytes}` → chunks `{stream: stdout\|stderr, data(b64)}` … terminal `{exitCode}` |
| `agent.shutdown` | singleShot | `{}` → `{}` then agent triggers OS shutdown |

Readiness: `agent.hello` ok ∧ `agent.health.state == ready`. Runner state `online` is derived from the runner
process being alive ≥ 2 s and no early exit; `busy` from `_diag/Worker_*` presence or a `Runner.Worker` child.
Secrets: `jitConfig` is never written to disk or logs; agent clears it from memory after spawn.

`agent.cleanup` HOME reset (reusable lifecycle): before any job has ever run on a VM, the agent tars the
runner account's HOME to `<stateDir>/home-pristine.tar` (once; skipped if a cleanup epoch marker already
exists, i.e. a job ran before the agent could snapshot it — see cleanup.EnsureHomeSnapshot). Every
`agent.cleanup` call after that wipes HOME and re-extracts that snapshot, in addition to the cache-dir/
`_work`/`_diag`/temp/docker sweeps. This means **everything a job wrote under HOME — `.gitconfig`, `.netrc`,
`.npmrc`, cloud/registry credentials, `.ssh/*`, anything — is gone after cleanup**, not just the cache
allowlist; a job must not rely on any HOME state surviving into the next session. If the snapshot is
missing (e.g. an agent binary predating this feature, or a job ran before the first-boot snapshot could be
taken), `agent.cleanup` fails closed with `HOME_SNAPSHOT_MISSING` instead of reporting `{ok:true}` while
stale credentials remain. Files a job writes **outside HOME** (e.g. via `sudo`, to `/etc`, `/opt`, …) are
never touched by this reset — reusable VMs are single-tenant by design, so only the next job on the same
VM is exposed, and ephemeral-lifecycle VMs are unaffected entirely (the whole instance disk is destroyed
after every job).
