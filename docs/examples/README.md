# Worked examples

Artifacts from a real deployment, kept verbatim where that is useful. The narrative that goes with
them is `docs/verification.md`, "Mac mini deployment".

## `headless-mac-mini.yaml`

The **exact** configuration `runnerd` was running on the Mac mini (`blackpen`) for the 2026-08-28
deployment — byte-for-byte the file at `<state-dir>/config.yaml`, not a cleaned-up illustration. It
is worth reading for the comments, which record *why* each number is what it is rather than what the
key means.

Host it was written for: Apple M4, 10 logical CPUs, 32 GiB RAM, 62 GiB free, macOS 26.5.2, no GUI
login session, three other local accounts.

What you must change:

| key | why |
| --- | --- |
| `github.scopes[].owner` / `.repository` | your scope, obviously |
| `host.maxVMs`, `profiles[].limits.maxInstances` | **disk-bound, not CPU/RAM-bound.** An instance reserves `max(profile.resources.disk, image.virtualBytes)`, and the shipped `ubuntu-24` image has a 16 GiB disk layer, so every Linux instance reserves 16 GiB whatever the profile asks for. 3 was the ceiling at 62 GiB free |
| `host.reserve.*` | 4 GiB disk / 6 GiB memory / 2 CPU suited this host; the shipped default is 50 GiB disk |
| `metrics.prometheus.listen` | bound to loopback here |
| `security.allowPublicRepositories` | `true` only because the test repo is public. Leave it off unless you have decided that untrusted pull-request code may run on the host |

Two settings exist because of this host's size and are easy to miss:

- `diagnostics.failedInstanceRetention: 15m` — a failed session holds its cpu/memory/**disk**
  reservation until this expires. The 2 h default would strand a 16 GiB reservation.
- `images.cache.maxSize`, `build.cache.maxBytes`, `logging.retention.instanceLogs` — the only things
  that outlive a job. Per-job storage is already fully reclaimed (an ephemeral instance's disk is an
  APFS clone deleted with the VM); these bound the rest.

`github.auth.source: file` rather than `keychain` is deliberate: the host has no login session, so
there is no unlocked login keychain to read from. The token lives at `<state-dir>/state/github-token`
(note: under `state/`, not the state root) at mode 0600 and is **not** in this file.

## `restart-runnerd.sh`

A `--restart-cmd` for `scripts/live-github-e2e.sh` on a host with no launchd job, generalized from
the one used during that deployment. The suite's restart scenarios are meaningless without a command
that actually restarts *this* daemon — the built-in default assumes a launchd job and silently does
nothing otherwise. Read the header comment before adapting it; the `pkill -f` self-match trap it
avoids is a real one.

## Reports

`docs/e2e/reports/` holds the raw JSON `scripts/live-github-e2e.sh` wrote for the same deployment:

- `2026-08-28-blackpen-suite.json` — the 11-scenario run. `redelivery` is recorded `fail` and that
  result is **not** the daemon's: another host had taken the scale-set message session out from
  under this one, so the job was captured elsewhere and never delivered here. Kept as-is rather than
  edited, because the honest artifact is more useful than a tidy one.
- `2026-08-28-blackpen-redelivery-rerun.json` — `redelivery` re-run on its own once the session was
  back: pass, 29 s.

The cause of that interference is fixed (a disabled profile no longer keeps its scale-set session)
and the rule it violated is now written down in `docs/install.md`, "One host per profile name, per
scope".
