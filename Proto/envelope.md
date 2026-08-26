# RPC framing and envelope (v1)

Shared wire primitive for the `daemon`, `worker` and `guest` protocols. Each protocol has its own
version, method catalogue and limits; they never share a socket.

## Frame

```
uint32 big-endian length   // 1 <= length <= channel frame cap
length bytes               // UTF-8 JSON object, exactly one envelope
```

Frame caps: `daemon` 16 MiB, `worker` 4 MiB, `guest` 4 MiB. A frame over the cap closes the connection.

## Envelope

```json
{
  "protocol": "guest",          // "daemon" | "worker" | "guest"
  "version": 1,                 // protocol version; mismatch => error PROTOCOL_VERSION
  "kind": "request",            // request | response | event | chunk | cancel
  "requestId": "uuid",          // client-generated; unique per connection
  "method": "agent.exec",       // required for request/event; echoed on response/chunk
  "streamSeq": 0,               // chunk only: 0,1,2,... exactly once each
  "end": false,                 // chunk only: true on the terminal chunk
  "payload": {}                 // method-specific; absent => {}
}
```

Response: `{"protocol","version","kind":"response","requestId","payload":{...}}` or
`{"kind":"response","requestId","error":{"code":"VM_NOT_RUNNING","message":"...","retryable":false}}`.

Rules (host side is authoritative; guest is untrusted):
- Strict decoding: unknown top-level keys rejected; duplicate keys rejected; trailing bytes rejected.
- Integers: signed 64-bit. Swift `Int64`, Go `int64`/`json.Number`. Never float64 for counts/bytes/times.
- Timestamps: RFC 3339 strings with `Z`. Byte counts: integers.
- One request ⇒ exactly one response, OR N chunks with monotonically increasing `streamSeq` where the
  last chunk has `end: true` (and optional `error`). A response after chunks is invalid.
- `cancel` carries the `requestId` to cancel; server replies with a terminal chunk/response `error.code = CANCELLED`.
- Per-connection budgets: max in-flight requests (16), max total stream bytes per request (64 MiB guest /
  unlimited daemon), idle timeout (60 s), per-request deadline supplied in `payload.deadlineMs` when relevant.
- Disconnect cancels non-detachable requests. Detachable methods (e.g. `agent.startRunner`) carry an
  idempotency key and a status method; callers never retry them blindly.
- Method classes: `readOnly`, `idempotentMutation`, `singleShot`. Catalogues mark each method.
- Unix sockets: server checks peer UID with `getpeereid`; mismatch closes connection.

Error codes are UPPER_SNAKE strings; `retryable` is a boolean hint. Common codes:
`PROTOCOL_VERSION`, `MALFORMED`, `UNKNOWN_METHOD`, `INVALID_PARAMS`, `DEADLINE`, `CANCELLED`, `BUSY`, `INTERNAL`.
