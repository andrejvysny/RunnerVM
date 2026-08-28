# Mac mini hardware qualification

Before a Mac mini (or any Apple Silicon host) runs RunnerVM unattended in production, it has to
survive the failure modes an unattended CI host actually sees: a cold boot with nobody at the
console, a power cut, and a reboot while a job is running. `scripts/qualify-host.sh` automates the
checks; this document is the checklist, the trade-offs behind the two launchd variants, and the
repeatable procedure that proves the whole chain — cold boot → `runnerd` online → `vmworker` →
VM boot → guest agent ready → (optionally) a real GitHub job — on your own hardware. This is plan
task T4 (`TODO.md`, "Production readiness review").

Read `docs/install.md` first if you have not installed RunnerVM yet; this document assumes a host
already installed with `scripts/install.sh --launchd agent|daemon`.

## 1. Host settings checklist

`scripts/qualify-host.sh` checks most of this automatically (PASS/WARN/FAIL, see §3); the rest is
operational context the script cannot see from software alone.

| Setting | Why | Checked by |
| --- | --- | --- |
| Apple Silicon, `hv_support=1` | Apple Virtualization guests require it | script, `runnerctl doctor` |
| macOS 15+ | Virtualization.framework keychain behavior this whole document is about | script, `runnerctl doctor` |
| Local APFS SSD for `<state-dir>` | Instance disks are APFS clones (`clonefile`); a network volume or non-APFS filesystem loses cloning and is far slower | `runnerctl doctor`'s "State directory" check |
| Sleep disabled (`sleep 0`, `disksleep 0`) | A sleeping host drops every running VM | script, `runnerctl doctor` |
| Automatic restart after power failure (`autorestart 1`) | The host must come back on its own after a power cut — nobody is there to press the button | script |
| Wired Ethernet | Wi-Fi drops during a power event or AP restart are a second failure mode a wired link avoids | script (WARN if only Wi-Fi) |
| Disk reserve (`host.reserve.disk`, default 50GiB) | Headroom below this and image pulls / VM creation are refused | script, `runnerctl doctor` |
| Dedicated `_runnervm` service account and `_runnervm` group (never `staff`), no interactive use | Keeps the auto-login session (LaunchAgent path) or the login keychain (LaunchDaemon path) in a known state; a human logging in and out disturbs both. A `staff`-owned state dir would also be readable by every local account, since every macOS user is in `staff` | operational — see §3 step 4; group/account checked by `scripts/install.sh` |
| `<state-dir>`/`config.yaml`/`state/`/`logs/` owned by the service account, no world-readable bits; runtime socket dir 0700 with 0600 sockets | Ownership/permission drift after an install (a manual `chmod`, a reinstall as the wrong account) silently exposes GitHub credentials and job logs to every local account, the same failure `--group staff` above guards against | script's `check_state_ownership`/`check_runtime_dir`, `runnerctl doctor`'s `service_user_ownership`/`runtime_dir_perms` |
| Free memory covers `host.reserve.memory` plus the largest configured profile/build workload | A host that can never fit its own configuration boots VMs that are refused or thrash under memory pressure, discovered only once a real job lands | script's `check_free_memory`, `runnerctl doctor`'s `free_memory` (structural shortfall FAILs; transient pressure from `vm_stat` WARNs) |
| Local image store integrity (every manifest's blob present, right size; `--deep` re-hashes sha256) | A truncated or corrupted image blob (a crashed import, a manually edited file) would otherwise only surface mid-VM-boot in production | script's `check_image_store`, `runnerctl doctor`'s `image_store_integrity --deep` |
| Image builder works under the actual service identity, not just an interactive login | `hdiutil makehybrid` and the whole `image build` path are easy to verify by hand as yourself and never actually prove out under `_runnervm`/the LaunchDaemon | script's `check_build_as_service` (runs `hdiutil` and a real `image build` as `--user`/`_runnervm`; `--skip-build` to skip the build half) |
| UPS on the host (and, ideally, the network gear between it and the internet) | `autorestart` only helps once power actually returns; a UPS avoids the power cut in the first place for short outages and gives a clean shutdown for long ones | operational, not checked |
| Controlled macOS automatic updates | An update-triggered reboot mid-job is the same interruption as a power cut, but self-inflicted and unpredictable | script (WARN, `softwareupdate --schedule`) |
| `host.overcommit.cpu` / `host.overcommit.memory` at `1.0` for the pilot | A VZ guest touches its whole memory balloon; overcommitting memory swaps the host to death (spec §16). Keep both ratios at `1.0` until you have real headroom data from this host | config review, not checked by the script |

## 2. Choosing a launchd variant

Recap of `packaging/launchd/README.md` (read it for the full provisioning steps); this is the
trade-off that matters for unattended operation specifically.

- **LaunchDaemon (recommended production default, the variant this document qualifies)**: a
  dedicated, non-admin `_runnervm` account runs `runnerd` with no GUI session at all. The premise
  that Virtualization.framework needs an unlocked login keychain in the creating session did not
  survive measurement — see "Login-keychain evidence" below — so `runnerctl doctor` now **skips**
  its login-keychain check entirely once it detects a LaunchDaemon, rather than reporting a
  permanent, misleading FAIL. Skipping the check is not the same as qualifying the host: the reboot
  loop in §3 is still what decides whether this variant recovers unattended, and it is **required**
  before trusting a LaunchDaemon host in production.
- **LaunchAgent (secondary — developer workstations, GUI sessions)**: a dedicated, non-admin,
  **auto-login** user runs `runnerd` in a real GUI session, which already has an unlocked login
  keychain because that account logged in. Choose this only when the job workload actually needs a
  window server. **FileVault conflict**: FileVault's pre-boot password prompt happens before any
  user session — including an auto-login one — can start, so a *cold* boot still needs a human to
  unlock the disk before the auto-login session (and therefore `runnerd`) can start. A *warm*
  reboot with the volume already unlocked auto-logs in normally. `scripts/qualify-host.sh`'s
  `filevault_autologin` check reports this as WARN by default; pass `--require-filevault-off` if
  your qualification bar is "must recover from a cold boot with nobody present" (turn FileVault
  off), or `--allow-filevault` once you have explicitly decided at-rest encryption matters more
  than that guarantee. `runnerctl doctor`'s login-keychain check still runs (warn, not fail) under
  this variant.
- **`none`**: `scripts/install.sh --launchd none` installs no launchd job at all — nothing to
  qualify here; skip straight to running `runnerd --foreground` under whatever external supervisor
  you use, and adapt §3 to that supervisor's own restart-on-boot behavior.

Whichever variant you pick, the reboot loop in §3 is the qualification gate, not this recap — do
not skip it because a variant is now the documented default.

### Login-keychain evidence (2026-08-28, macOS 26.5.2, Apple M4)

The keychain argument above used to be the whole reason the LaunchAgent was recommended. On one
host it did not reproduce. A `runnerd` started over SSH on a Mac mini with **no GUI login session
at all** — nobody logged in, no auto-login user, `/dev/console` owned by `root`, the `blackpen`
login keychain locked — booted every VM asked of it: two in-daemon image builds, ten GitHub jobs
and eleven live E2E scenarios, all green. `vmworker probe` reported `virtualizationSupported: true`
in the same session, while `runnerctl doctor` (before this fix) reported a permanent

```
FAIL  Login keychain    login keychain for blackpen is locked (security exit 36); VM start needs
                        an unlocked login keychain for the account runnerd runs as
```

— a **false negative**: it failed while everything it was warning about worked. Evidence:
`docs/verification.md`, "Mac mini deployment". `doctor` now skips this check under a detected
LaunchDaemon instead of failing it; `scripts/qualify-host.sh`'s `daemon_keychain` check is unchanged
and can still be read for the raw evidence.

This is one host and one OS version, and — importantly — it says nothing about whether the job
comes *back* after a reboot, which is what §3 measures and is the actual qualification gate. Do not
treat the keychain requirement as settled fact on macOS 26 without re-measuring it yourself, and do
not treat the doctor skip as a substitute for running the loop below.

## 3. Qualification procedure

Run this loop for **10 controlled reboots, at least 2 of them real cold power cycles** (power
disconnected, not just `shutdown -r`), before trusting a host with production jobs. Boot recovery
is exactly the kind of thing that passes once by luck (cached keychain state, a lingering session)
and fails the second or third time — 3 runs is not enough evidence to sign a host off for
unattended production; 10 is.

1. **Cold shutdown.** `sudo shutdown -h now` (or the Apple menu). Wait for the fans/lights to stop
   — a true power-off, not sleep.
2. **Disconnect power** at the wall or the UPS output for at least 10 seconds, to distinguish a
   real power cut from a soft restart. Skip this sub-step on a pure "reboot" iteration (see step 6)
   but do it on at least 2 of the 10 runs.
3. **Reconnect power / power on.** With `autorestart 1` (§1) the host should power itself back on;
   without it, this is exactly the manual-intervention case autorestart exists to avoid — press the
   power button once and note that this run required it.
4. **Wait for automatic boot to settle**, then run the qualification script **without any
   interactive login, SSH session, Screen Sharing session, or manual keychain unlock**:

   ```sh
   scripts/qualify-host.sh --profile <profile> --report qual.jsonl
   ```

   (`check_build_as_service`, part of every run unless `--skip-build`, also drives a real
   `runnerctl image build` through the daemon under the service identity — pass `--build-recipe` to
   point it at a different recipe than the default `ubuntu-24-minimal`.)

   Trigger this from something that does not itself require a human-driven session — a LaunchAgent
   with `RunAtLoad`/`StartInterval` in the same auto-login session, a `cron`/`launchd` timer under
   the service account, or an SSH session used **only to read a result file a scheduled run already
   wrote**. Logging in interactively (console or Screen Sharing), or unlocking the login keychain by
   hand, before the check runs invalidates the test: any of those can themselves unlock the keychain
   or nudge a stalled session in a way that would never happen with nobody physically present,
   silently hiding the exact failure mode this loop exists to catch. SSH-ing in *after* a scheduled
   run has already produced `qual.jsonl`, purely to `cat` or `scp` it, is fine — no state changes
   there.
5. **Record the cycle's evidence**, not just PASS/FAIL: the newest line appended to `qual.jsonl`
   (every check, including the new ownership/memory/image-store/service-identity-build ones, is one
   evidence row in there automatically — see §5), plus, captured alongside it,
   `launchctl print gui/$(id -u _runnervm)/com.runnervm.runnerd` (or the `system/...` LaunchDaemon
   path) and `runnerctl status`. Any `FAIL` is a blocker — fix it before the next iteration, don't
   just re-run and hope.
6. **Idle reboot.** `sudo shutdown -r now` with no job running. Repeat from step 4 (power-cycle via
   steps 1–3 is not required every time; a plain reboot alone is a valid, and cheaper, iteration —
   just make sure at least 2 of your 10 runs were a real power cut, not only a soft reboot).
7. **Repeat** steps 1–6 until you have **10 clean runs** (no `FAIL`; WARNs you've consciously
   accepted are fine) — at least 2 of them real power cuts.
8. **Reboot under load.** Start a real or synthetic job (`scripts/qualify-host.sh --profile
   <profile> --github-job --report qual.jsonl` end to end once, to have a runner mid-job — or drive
   one by hand with `runnerctl debug run-jit <profile>` without `--wait` so it keeps running), then
   `sudo shutdown -r now` while it is executing. Across the 10 runs, make sure at least one carries
   `--github-job` so a real GitHub job's evidence lands in `qual.jsonl` too (§4 requires it when
   GitHub is in scope). This reboot-under-load step is not a pass/fail step by itself; it is where
   you observe and record the recovery semantics:
   - The instance's on-disk `runnerd.sqlite3` state persists across the reboot, but the `vmworker`
     process and the running `VZVirtualMachine` do not. Per `docs/state_machines.md`, an instance
     whose owning worker is gone resolves to **`interrupted`** — the state machine explicitly notes
     ambiguity resolves to `interrupted`/`tainted`, never `idle`.
   - A **reusable** instance may restart once from its own disk (`interrupted → startingWorker →
     …`, bounded by `worker_generation <= 1`) and recycle if that fails; an **ephemeral** instance
     does not restart — from `interrupted` it goes to `deleting`.
   - On the GitHub side, the runner session's `jobRunning` state resolves to **`jobInterrupted`**
     (a terminal state), which schedules `ensureRunnerRemoved` for the now-orphaned runner
     registration if one was persisted — GitHub sees the job fail, not hang forever.
   - Confirm what you actually observed matches this with `runnerctl vm show <id>` and `runnerctl
     runner show <session-id>` after the reboot, and record it in your qualification notes. If it
     does not match, that is a real finding, not something to explain away — file it before signing
     the host off.

## 4. Pass criteria

| Criterion | Requirement |
| --- | --- |
| Cold-boot recovery | `scripts/qualify-host.sh --profile <profile> --report qual.jsonl` run non-interactively after a real power cut, 0 `FAIL`, at least 2 times |
| Reboot recovery, overall | 10 total controlled-reboot runs (§3), 0 `FAIL`, at least 2 of them real power cuts |
| launchd job | Loaded, `state = running`, `pid` present, started within a few seconds of `kern.boottime` on every run |
| State/runtime ownership and permissions | `service_user_ownership`/`runtime_dir_perms` PASS on every run — the state dir, `config.yaml`, `state/`, `logs/` and the runtime socket dir are owned by the service account with no world access |
| Free memory | `free_memory` PASS on every run — physical RAM covers `host.reserve.memory` plus the largest configured profile/build workload, with headroom to spare at the time of the run |
| Local image store integrity | `image_store_integrity` PASS on every run (the script always passes `--deep`, so every stored image's blobs are re-hashed against their manifest, not just size-checked) |
| Image builder under the service identity | `check_build_as_service` PASS at least once: `hdiutil makehybrid` and a full `runnerctl image build` (`--name qual-<ts>`) succeed as the account `runnerd` actually runs as, and the built image is inspected then deleted cleanly |
| VM boot chain | `vm create` → `idle` (within the script's 180s default) → `vm exec` → `vm delete` all PASS on every run |
| GitHub job (if in scope) | `runnerctl debug run-jit --wait` (via `--github-job`) completes at least once end to end |
| Reboot-under-load | Behavior observed and recorded per §3 step 8, matching the documented `interrupted`/`jobInterrupted` semantics (or a filed discrepancy) |
| Outstanding WARNs | Each one explicitly accepted in writing (e.g. "FileVault on, `--allow-filevault`, accepted for at-rest encryption") — none silently ignored |
| `FAIL`s | Zero, full stop |

## 5. Attaching results to the production-readiness gate

`--report qual.jsonl` appends one JSON object per run (JSON Lines — `jq -s .` turns the file into a
JSON array if a tool needs one), so the whole loop in §3 accumulates into a single file: boot time,
run timestamp, the launchd variant detected, and every check's id/title/status/detail. Keep that
file itself as the evidence:

- Attach `qual.jsonl` (not just a pass/fail summary) to whatever production-readiness review or
  ticket tracks T4 in `TODO.md` — the per-check detail is what lets a reviewer tell a real fix
  apart from a lucky re-run.
- A quick recap for a review comment: `jq -s '[.[] | {run_at, boot_time, launchd, summary}]'
  qual.jsonl`.
- Do not hand-edit the file between runs; if a run needs to be discarded (e.g. you interactively
  logged in first, invalidating it per §3 step 4), say so next to it rather than deleting the line
  — a documented bad run is more convincing than a suspiciously short history.
