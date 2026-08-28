# worker protocol v1 — runnerd ⇄ vmworker over `vm-<shortid>.sock`

Startup: `vmworker run --instance <uuid> --spec <path/spec.json> --socket-dir <dir> --generation <n> --nonce <hex>`.
Worker: acquire fcntl `F_WRLCK` on `<instanceDir>/worker.lock` (fail ⇒ exit 75) → build VZ config → bind
`<socket-dir>/vm-<shortid>.sock` (mode 0600) → publish (rename from `.tmp`) → serve. Exit codes: 0 clean, 64 usage,
65 spec invalid, 75 lock held, 76 VZ config invalid, 77 VZ start failed.

Instance directory (`<instanceDir>`, the parent of `spec.json`): `disk.img`, `nvram.bin` (EFI variable
store on Linux, auxiliary storage on macOS), `spec.json`, `worker.lock`, `serial.log`, `worker.log`,
optional `seed.img`/`context.img` (build VMs only), and — macOS only — `machine-identifier.bin`, the
serialized `VZMacMachineIdentifier` the worker mints on first boot after taking the lock and reuses on
every restart. It is instance identity: never sealed into an image, never copied between instances.

`spec.json` carries an optional `macos` object for macOS guests only (absent for Linux):
`{hardwareModel, sourceVersion?, minimumCPUCount?, minimumMemoryBytes?}`, where `hardwareModel` is
base64 of `VZMacHardwareModel.dataRepresentation`. The minimums come from the image and are enforced
by runnerd before the instance row exists.

A second socket `<socket-dir>/vm-<shortid>-agent.sock` is a raw byte bridge: each accepted connection opens one
fresh `VZVirtioSocketConnection` to guest port 4050; both halves close together.

| method | class | payload → result |
|---|---|---|
| `worker.hello` | readOnly | `{}` → `{instanceId, generation, incarnationNonce, specDigest, pid, protocolVersion:1, vmState, agentBootId?}` |
| `worker.status` | readOnly | `{}` → `{vmState, uptimeMs, leaseExpiresAt?, bridgeConnections, lastError?}` |
| `worker.lease` | idempotentMutation | `{ttlMs}` → `{leaseExpiresAt}` — daemon renews every ttl/3; expiry starts orphan timers |
| `vm.start` | idempotentMutation | `{}` → `{vmState}`; no-op if already running |
| `vm.requestStop` | idempotentMutation | `{}` → `{accepted}` (ACPI; guest decides) |
| `vm.forceStop` | idempotentMutation | `{}` → `{vmState}` |
| `vm.state` | readOnly | `{}` → `{vmState}` |
| `agent.bridgeStatus` | readOnly | `{}` → `{socketPath, activeConnections}` |
| `worker.shutdown` | singleShot | `{reason: "drain"\|"stop", gracefulTimeoutMs}` → `{}`; drain = requestStop, wait, forceStop, exit 0 |
| `host.capabilities` | readOnly | probe mode only |

Events (`kind: event`, unsolicited, on every connection): `vm.stateChanged {vmState, at}`, `vm.error {code, message}`.

`vmState`: `stopped | starting | running | stopping | error`. Worker never re-reads the spec; runnerd never
reconfigures a worker into a different VM.

Orphan policy (lease expired): `vmState=running` and no bridge activity ⇒ after 10 min `requestStop`, +30 s `forceStop`, exit.
Busy (bridge active) ⇒ stop at `spec.hardDeadline` (absolute RFC 3339 in spec) at the latest.
