# `fleet.*` — daemon methods for external autoscalers (GitLab fleeting plugin)

Part of the `daemon` protocol v1 over `runnerd.sock` (same envelope, framing, peer-uid check and
16 MB frame cap as every other daemon method; see [daemon_api.md](daemon_api.md)). The only
intended client is `fleeting-plugin-runnervm`, which gitlab-runner's taskscaler drives. RunnerVM
does not see GitLab demand: gitlab-runner decides how many instances it wants, RunnerVM decides
whether they fit the host budget.

Every method accepts only profiles with `provider: gitlab`; any other profile answers
`FLEET_PROFILE_NOT_GITLAB`. Instances created here have `purpose: fleet`: they hold host capacity
like any instance, are never counted as GitHub demand, never cancelled as surplus, never reaped on
`idleTTL`, never recycled and never given a runner session. They live until `fleet.delete` or
until their lease (`pinnedUntil`) passes, at which point the lease reaper deletes them through the
ordinary `instance.delete` path (logged as `instance.fleetLeaseExpired`). The lease bounds the
damage of a crashed gitlab-runner: its VMs are freed within one lease.

Integer fields are int64 on the wire. Timestamps are the same ISO-8601 strings `InstanceInfoDTO`
uses for `pinnedUntil`.

| Method | Mut | Request | Response |
|---|---|---|---|
| `fleet.info` | | `{profile}` | `{profile, guestOS, arch, sshUser, maxInstances}` |
| `fleet.list` | | `{profile}` | `{instances: [{id, state, leaseUntil?}]}` |
| `fleet.create` | mut | `{profile, leaseMs}` | `{id, leaseUntil}` |
| `fleet.delete` | mut | `{id}` | `{id, accepted}` |
| `fleet.renew` | mut | `{ids, leaseMs}` | `{renewed: [id]}` |
| `fleet.connect` | mut | `{id, publicKey}` | `{id, address, port, user, guestOS, arch}` |

- `guestOS` is `linux` or `macos`; `arch` is `arm64`; `sshUser` is the guest account jobs run as
  (`runner`).
- `maxInstances` is what the profile could reach on this host if it were otherwise empty and
  admitting work (`CapacityCalculator.profileCapacity` with no reservations, host mode `normal`),
  capped by `limits.maxInstances`. The plugin reads it once at Init as `ProviderInfo.MaxSize`, so
  it deliberately ignores what GitHub jobs or a drain hold at that moment; admission at
  `fleet.create` enforces the live budget.
- `fleet.list` returns this profile's `purpose: fleet` instances that are not yet `deleted`, plus
  any deleted within the last 10 minutes (so the plugin observes `deleted`). `state` mapping from
  `InstanceState`: `planned`…`waitingForAgent` ⇒ `creating`; `idle` ⇒ `running`; `stopping`,
  `deleting` ⇒ `deleting`; `stopped`, `interrupted`, `failed`, `orphaned`, `deleted` ⇒ `deleted`.
  Any other state (runner-session states never occur for fleet instances) ⇒ `running`.
- `fleet.create` returns as soon as the instance row exists (boot continues in the background;
  watch `fleet.list`). `leaseMs` must be 60 000…86 400 000 (`FLEET_LEASE_INVALID`). Refusals reuse
  the existing admission errors (host draining/offline, disk pressure critical, capacity does not
  fit, image unavailable).
- `fleet.delete` is idempotent: an unknown id, an already-deleting or deleted instance answers
  `accepted: true`. A non-fleet instance answers `FLEET_INSTANCE_NOT_FLEET`.
- `fleet.renew` sets `pinnedUntil = now + leaseMs` for each listed live fleet instance; ids that
  are unknown, deleted or not fleet instances are silently left out of `renewed`.
- `fleet.connect` requires the instance to be `idle` (`FLEET_INSTANCE_NOT_READY` otherwise).
  `publicKey` must be exactly one OpenSSH `ssh-ed25519 <base64>` line, optional comment matching
  `[A-Za-z0-9@._-]{0,64}`, total ≤ 512 bytes (`FLEET_INVALID_PUBLIC_KEY`). The daemon replaces the
  guest user's `~/.ssh/authorized_keys` with that single key (dir 0700, file 0600, owned by the
  user) through `agent.exec`, passing the key as an argv element — never interpolated into a shell
  string. `address` is the guest's vmnet NAT address (`agent.getInfo.primaryAddress`, else the
  first non-loopback IPv4 that is not on a docker/bridge interface); `FLEET_NO_ADDRESS` if none.
  `port` is 22. Calling again with a new key replaces the old one (plugin restart path).

Error codes: `FLEET_PROFILE_NOT_GITLAB`, `FLEET_LEASE_INVALID`, `FLEET_INSTANCE_NOT_FOUND`,
`FLEET_INSTANCE_NOT_FLEET`, `FLEET_INSTANCE_NOT_READY`, `FLEET_INVALID_PUBLIC_KEY`,
`FLEET_NO_ADDRESS`, `FLEET_KEY_INSTALL_FAILED`, `FLEET_IMAGE_NO_SSH`.

`FLEET_IMAGE_NO_SSH` is answered by `fleet.create` for a macOS profile whose resolved image does not declare `capabilities.ssh: true`, because a macOS fleet VM can only be reached over ssh. `instance.create {purpose: fleet}` answers `FLEET_USE_FLEET_API`.
