# Wire protocols

Shared framing for all three channels: `uint32_be length` + UTF-8 JSON, one frame per message.
Three protocol identities with independent versions and limits:

| protocol | client → server | frame cap |
|---|---|---|
| `daemon` | runnerctl → runnerd (`runnerd.sock`) | 16 MiB |
| `worker` | runnerd → vmworker (`vm-<id>.sock`) | 4 MiB |
| `guest`  | runnerd → guest-agent via vmworker bridge (`vm-<id>-agent.sock` ↔ vsock:4050) | 4 MiB |

Envelope and rules: see plan C1. Catalogues: `daemon_api.md`, `worker_protocol.md`, `guest_agent.md` (M1).
Golden fixtures live in `Proto/fixtures/` and are tested from Swift and Go.
