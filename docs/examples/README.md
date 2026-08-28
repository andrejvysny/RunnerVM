# Worked examples

Artifacts from a real deployment, kept verbatim where that is useful. The narrative that goes with
them is `docs/verification.md`, "Mac mini deployment".

## `headless-mac-mini.yaml`

The **exact** configuration `runnerd` is running on the Mac mini (`blackpen`) — byte-for-byte the
file at `<state-dir>/config.yaml`, not a cleaned-up illustration. It is worth reading for the
comments, which record *why* each number is what it is rather than what the key means.

It is currently sized for **one** Linux runner at a time (4 vCPU / 8 GiB, `maxVMs: 1`). The
autoscaling and parallel-VM evidence in `docs/verification.md` was gathered with the same file at
`maxVMs: 3` and 2 vCPU / 4 GiB per guest — the only difference is those four numbers.

Host it was written for: Apple M4, 10 logical CPUs, 32 GiB RAM, 62 GiB free, macOS 26.5.2, no GUI
login session, three other local accounts.

What you must change:

| key | why |
| --- | --- |
| `github.scopes[].owner` / `.repository` | your scope, obviously |
| `host.maxVMs`, `profiles[].limits.maxInstances` | **disk-bound, not CPU/RAM-bound.** An instance reserves `max(profile.resources.disk, image.virtualBytes)`, and the shipped `ubuntu-24` image has a 16 GiB disk layer, so every Linux instance reserves 16 GiB whatever the profile asks for. 3 was the *ceiling* at 62 GiB free; this file sets 1 |
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

There is **no macOS profile**, and the file says why: a macOS guest cannot resize its APFS
container, so its reservation is the image's whole 50 GB virtual disk. With the 30 GiB image stored,
this host would need ~48 GiB free to admit one macOS guest at all and ~65 GiB to run one alongside
the Linux guest; it has 62 GiB free and about 8.5 GiB reclaimable. Adding the profile anyway would
register a scale set on GitHub that can only ever advertise zero.

## `restart-runnerd.sh`

A `--restart-cmd` for `scripts/live-github-e2e.sh` on a host with no launchd job, generalized from
the one used during that deployment. The suite's restart scenarios are meaningless without a command
that actually restarts *this* daemon — the built-in default assumes a launchd job and silently does
nothing otherwise. Read the header comment before adapting it; the `pkill -f` self-match trap it
avoids is a real one.

## Reports

`docs/e2e/reports/` holds the raw JSON the drivers wrote during the same session, unedited:

- `2026-08-28-blackpen-suite.json` — the 11-scenario run. `redelivery` is recorded `fail` and that
  result is **not** the daemon's: another host had taken the scale-set message session out from
  under this one, so the job was captured elsewhere and never delivered here. Kept as-is rather than
  edited, because the honest artifact is more useful than a tidy one.
- `2026-08-28-blackpen-redelivery-rerun.json` — `redelivery` re-run on its own once the session was
  back: pass, 29 s.
- `2026-08-28-macos-qualify-h2.json` — the first-ever run of `scripts/qualify-macos-image.sh` (the
  H2 gate), against the hardened `macos-26` image, from the development Mac rather than the Mac
  mini. `qualified: false`, one check failed: `cold_boot_to_idle — instance reached deleted`. Kept
  because the *shape* of the failure is the finding: the clone booted normally and the other four
  checks passed, but the script creates its instance with `vm create`, and an ephemeral instance
  with no confirmed GitHub demand behind it is surplus, so the scheduler removed it after 11 s
  (`instance.cancelled (demand dropped)`). The gate cannot pass as written — see
  `docs/macos-guests.md`, "Image qualification".

The cause of the `redelivery` interference is fixed (a disabled profile no longer keeps its
scale-set session) and the rule it violated is now written down in `docs/install.md`, "One host per
profile name, per scope".
