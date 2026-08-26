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
| `agent.cleanup` | idempotentMutation | `{epoch}` → `{ok, removed:[...]}`; same epoch twice is a no-op |
| `agent.exec` | stream | `{argv:[...], cwd?, env?, timeoutMs, maxOutputBytes}` → chunks `{stream: stdout\|stderr, data(b64)}` … terminal `{exitCode}` |
| `agent.shutdown` | singleShot | `{}` → `{}` then agent triggers OS shutdown |

Readiness: `agent.hello` ok ∧ `agent.health.state == ready`. Runner state `online` is derived from the runner
process being alive ≥ 2 s and no early exit; `busy` from `_diag/Worker_*` presence or a `Runner.Worker` child.
Secrets: `jitConfig` is never written to disk or logs; agent clears it from memory after spawn.
