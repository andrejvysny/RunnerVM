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
| Dedicated `_runnervm` service account, no interactive use | Keeps the auto-login session (LaunchAgent path) or the login keychain (LaunchDaemon path) in a known state; a human logging in and out disturbs both | operational — see §3 step 4 |
| UPS on the host (and, ideally, the network gear between it and the internet) | `autorestart` only helps once power actually returns; a UPS avoids the power cut in the first place for short outages and gives a clean shutdown for long ones | operational, not checked |
| Controlled macOS automatic updates | An update-triggered reboot mid-job is the same interruption as a power cut, but self-inflicted and unpredictable | script (WARN, `softwareupdate --schedule`) |
| `host.overcommit.cpu` / `host.overcommit.memory` at `1.0` for the pilot | A VZ guest touches its whole memory balloon; overcommitting memory swaps the host to death (spec §16). Keep both ratios at `1.0` until you have real headroom data from this host | config review, not checked by the script |

## 2. Choosing a launchd variant

Recap of `packaging/launchd/README.md` (read it for the full provisioning steps); this is the
trade-off that matters for unattended operation specifically.

- **LaunchAgent (recommended)**: a dedicated, non-admin, **auto-login** user runs `runnerd` in a
  real GUI session. macOS 15+ Virtualization.framework needs an unlocked login keychain in the
  session that creates the VM; a GUI session already has one, automatically, because that account
  logged in. This is the path Tart/Cirrus Labs use for the same framework. **FileVault conflict**:
  FileVault's pre-boot password prompt happens before any user session — including an auto-login
  one — can start, so a *cold* boot still needs a human to unlock the disk before the auto-login
  session (and therefore `runnerd`) can start. A *warm* reboot with the volume already unlocked
  auto-logs in normally. `scripts/qualify-host.sh`'s `filevault_autologin` check reports this as
  WARN by default; pass `--require-filevault-off` if your qualification bar is "must recover from
  a cold boot with nobody present" (turn FileVault off), or `--allow-filevault` once you have
  explicitly decided at-rest encryption matters more than that guarantee.
- **LaunchDaemon (experimental)**: no GUI session, so no automatically-unlocked keychain. It only
  works with explicit keychain provisioning wired into boot (`security unlock-keychain`, run
  before `com.runnervm.runnerd` starts) — `scripts/install.sh` does not set this up; see
  `packaging/launchd/README.md`'s LaunchDaemon section for the manual steps and their own
  trade-offs (the unlock password has to live somewhere on disk). Treat this variant as unverified
  on your hardware until it passes the full loop in §3 at least 3 times.
  `runnerctl doctor` runs a `login_keychain` check (`security show-keychain-info` on the invoking
  account's `login.keychain-db`) that **fails** when the keychain is missing or locked — run
  doctor as the service account for it to be meaningful. `scripts/qualify-host.sh` repeats the
  same check as `daemon_keychain`.
- **`none`**: `scripts/install.sh --launchd none` installs no launchd job at all — nothing to
  qualify here; skip straight to running `runnerd --foreground` under whatever external supervisor
  you use, and adapt §3 to that supervisor's own restart-on-boot behavior.

The project deliberately does not auto-select either variant — run the loop in §3 against your own
hardware and macOS version and pick the one that actually recovers from a cold boot.

## 3. Qualification procedure

Run this loop **at least 3 times** before trusting a host with production jobs. Boot recovery is
exactly the kind of thing that passes once by luck (cached keychain state, a lingering session) and
fails the second or third time.

1. **Cold shutdown.** `sudo shutdown -h now` (or the Apple menu). Wait for the fans/lights to stop
   — a true power-off, not sleep.
2. **Disconnect power** at the wall or the UPS output for at least 10 seconds, to distinguish a
   real power cut from a soft restart. Skip this sub-step on a pure "reboot" iteration (see step 6)
   but always do it at least once across the 3 runs.
3. **Reconnect power / power on.** With `autorestart 1` (§1) the host should power itself back on;
   without it, this is exactly the manual-intervention case autorestart exists to avoid — press the
   power button once and note that this run required it.
4. **Wait for automatic boot to settle**, then run the qualification script **without any
   interactive login** on the console or over Screen Sharing:

   ```sh
   scripts/qualify-host.sh --profile <profile> --report qual.jsonl
   ```

   Trigger this from something that does not itself require a human-driven session — a LaunchAgent
   with `RunAtLoad`/`StartInterval` in the same auto-login session, a `cron`/`launchd` timer under
   the service account, or an SSH session used **only to read a result file a scheduled run already
   wrote**. Logging in interactively (console or Screen Sharing) before the check runs invalidates
   the test: an interactive login can itself unlock the keychain or nudge a stalled session in a
   way that would never happen with nobody physically present, silently hiding the exact failure
   mode this loop exists to catch. SSH-ing in *after* a scheduled run has already produced
   `qual.jsonl`, purely to `cat` or `scp` it, is fine — no state changes there.
5. Inspect the run: `PASS|WARN|FAIL` lines on stdout (captured in whatever logged the scheduled
   run), plus the newest line appended to `qual.jsonl`. Any `FAIL` is a blocker — fix it before the
   next iteration, don't just re-run and hope.
6. **Idle reboot.** `sudo shutdown -r now` with no job running. Repeat from step 4 (power-cycle via
   steps 1–3 is not required every time; a plain reboot alone is a valid, and cheaper, iteration —
   just make sure at least one of your 3+ runs was a real power cut, not only a soft reboot).
7. **Repeat** steps 1–6 until you have **3 clean runs** (no `FAIL`; WARNs you've consciously
   accepted are fine) — mix at least one real power cut in among them.
8. **Reboot under load.** Start a real or synthetic job (`scripts/qualify-host.sh --profile
   <profile> --github-job --report qual.jsonl` end to end once, to have a runner mid-job — or drive
   one by hand with `runnerctl debug run-jit <profile>` without `--wait` so it keeps running), then
   `sudo shutdown -r now` while it is executing. This is not a pass/fail step by itself; it is
   where you observe and record the recovery semantics:
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
| Cold-boot recovery | `scripts/qualify-host.sh --profile <profile> --report qual.jsonl` run non-interactively after a real power cut, 0 `FAIL`, at least 3 times |
| Idle reboot recovery | Same, after a plain reboot, at least 3 times (may overlap with the power-cut runs) |
| launchd job | Loaded, `state = running`, `pid` present, started within a few seconds of `kern.boottime` on every run |
| VM boot chain | `vm create` → `idle` (within the script's 180s default) → `vm exec` → `vm delete` all PASS on every run |
| GitHub job (if in scope) | `runnerctl debug run-jit --wait` completes at least once end to end |
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
