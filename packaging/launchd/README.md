# launchd packaging for `runnerd`

Two variants ship side by side; `scripts/install.sh --launchd agent|daemon` picks one. Neither is
loaded automatically — installing only writes the plist and prints the `launchctl` command to run.

## Which variant

| Variant | Status | Requirement |
| --- | --- | --- |
| **LaunchDaemon**, dedicated unprivileged account | **Recommended production default** | Nothing beyond the service account. Starts at boot with no login session, no GUI, no autologin and no login keychain. |
| **LaunchAgent**, dedicated auto-login user | Secondary — developer workstations and GUI sessions | The Mac must auto-log into a dedicated GUI session; `runnerd` only runs once that account is logged in. |

Spec §7.2 always specified a LaunchDaemon under a dedicated unprivileged account. This packaging
previously demoted it to "experimental" on the premise that Apple Virtualization.framework on
macOS 15+ needs an **unlocked login keychain in the creating process's session** — a thing a
LaunchDaemon's service account does not have. That premise did not survive measurement.

**Measurement, 2026-08-28 (macOS 26.5.2, Apple M4 Mac mini).** With no GUI login session at all —
nobody logged in, no auto-login user, `/dev/console` owned by `root` — `runnerd` booted every VM it
was asked for (two image builds, ten GitHub jobs, eleven live E2E scenarios) while `runnerctl
doctor` reported the login keychain locked (`security show-keychain-info` exit 36). `vmworker
probe` likewise answered `virtualizationSupported: true`. The keychain requirement did not
reproduce, so the old `login_keychain` **FAIL** was a false negative; `runnerctl doctor` now skips
that check entirely under a detected LaunchDaemon and reports it as informational elsewhere.

That removes the reason to prefer the LaunchAgent. It does **not** close the remaining gate: the
measurement says nothing about whether the job comes back across a power cycle. **The reboot loop
in `docs/qualification.md` remains the qualification gate for a production install** — run it on
your own hardware before trusting an unattended host. `runnerctl doctor`'s `reboot_persistence`
check reports whether a loaded LaunchDaemon exists to come back at all; it cannot prove the reboot
itself.

Choose the LaunchAgent only when you actually want `runnerd` inside a GUI login session — a
developer's own workstation, or a host where something in the job workload needs a window server.

## LaunchDaemon path (recommended)

1. Create the dedicated service group and account (needs an admin). The group is a hidden system
   group, never `staff` — every local macOS account is a member of `staff`, which would make
   `<state-dir>` and its log/config files readable by every other user on the Mac (see
   `docs/install.md`, "Dedicated service account and auto-login"):

   ```sh
   # Pick a free GID/UID in 200-400 (`dscl . -list /Groups PrimaryGroupID` and
   # `dscl . -list /Users UniqueID` should not already print it).
   sudo dscl . -create /Groups/_runnervm
   sudo dscl . -create /Groups/_runnervm PrimaryGroupID 250
   sudo dscl . -create /Groups/_runnervm RealName "RunnerVM Service"
   sudo dscl . -create /Groups/_runnervm Password "*"

   sudo dscl . -create /Users/_runnervm
   sudo dscl . -create /Users/_runnervm UserShell /usr/bin/false
   sudo dscl . -create /Users/_runnervm RealName "RunnerVM Service"
   sudo dscl . -create /Users/_runnervm UniqueID 250
   sudo dscl . -create /Users/_runnervm PrimaryGroupID 250
   sudo dscl . -create /Users/_runnervm NFSHomeDirectory "/Library/Application Support/RunnerVM/home"
   sudo dscl . -create /Users/_runnervm Password '*'
   sudo dscl . -create /Users/_runnervm IsHidden 1
   ```

   No password and no `sysadminctl`: the account never logs in, so it needs neither an interactive
   password prompt nor a real home under `/Users`. `scripts/install.sh` runs exactly these commands
   (or prints them under "manual steps" when it lacks the privilege), so this step can be left to
   the installer.

2. `sudo scripts/install.sh --launchd daemon --user _runnervm ...` — installs the plist to
   `/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`.
3. Load it:

   ```sh
   sudo launchctl bootstrap system \
     /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
   ```

   `scripts/install.sh` prints this command; it never runs `launchctl` itself.
4. Qualify the host before trusting it unattended: `scripts/qualify-host.sh`, then the reboot loop
   in `docs/qualification.md`. FileVault interacts with this — an encrypted boot volume can require
   pre-boot authentication before launchd starts anything at all, so an unattended cold boot may
   never reach step 3's job. `runnerctl doctor`'s `filevault` check reports the state and takes no
   position; RunnerVM itself works either way once the host is up.

## LaunchAgent path (developer workstations, GUI sessions)

1. Create the dedicated service group and account as above.
2. Enable automatic login for that account: System Settings → General → Login Screen (or Users &
   Groups, depending on macOS version) → set "Automatically log in as" to `_runnervm`. This is a
   GUI-only setting on current macOS releases; the historical `defaults write
   com.apple.loginwindow autoLoginUser` + `/etc/kcpassword` mechanism is deprecated and disabled
   by SIP on modern systems — treat any script-only path to autologin as unverified until you
   confirm it works on the target macOS version. Autologin also requires FileVault to be off, or
   the volume unlocked another way. An account created for the LaunchAgent path needs a real home
   directory and a login-capable password, unlike the LaunchDaemon account above.
3. Log in once as `_runnervm` interactively before relying on autologin.
4. `sudo scripts/install.sh --launchd agent --user _runnervm ...` — installs the plist to
   `/Library/LaunchAgents/com.runnervm.runnerd.agent.plist`.
5. Because it is a LaunchAgent, it only runs once `_runnervm` is logged in (autologin after
   reboot, or a manual login). Load it for that session:

   ```sh
   launchctl bootstrap gui/$(id -u _runnervm) \
     /Library/LaunchAgents/com.runnervm.runnerd.agent.plist
   ```

   `scripts/install.sh` prints this command; it never runs `launchctl` itself.

## Common notes

- `RUNNERVM_LOG_LEVEL` is set in both plists' `EnvironmentVariables`; `runnerd` uses it as the
  fallback when no `--log-level` argument is given (the plists pass `--log-level` too, which wins).
- Both plists redirect `StandardOutPath`/`StandardErrorPath` to
  `<state>/logs/runnerd/stdio.log`. That file carries **crash and launch output only** — a dyld
  failure, a Swift runtime trap, anything that escapes the logging system. The daemon's actual
  JSON log is `<state>/logs/runnerd/runnerd.log`, which `runnerd` writes and rotates itself
  (`logging.file` in the configuration; see `docs/logging.md`).
- launchd creates the stdio *file* but not its directory. `runnerd` creates
  `<state>/logs/runnerd/` at startup, so it exists from the first run onward; on a brand new host
  create it once before the first `launchctl bootstrap` so no early crash output is lost:
  `sudo mkdir -p "<state>/logs/runnerd" && sudo chown _runnervm "<state>/logs/runnerd"`.
- `runnerd` reopens every log file it owns on `SIGHUP`, so external rename-based rotation
  (`packaging/newsyslog/runnervm.conf`) takes effect immediately rather than at the next restart.
  launchd owns the pid and writes no pid file, so signal it with
  `sudo launchctl kill HUP system/com.runnervm.runnerd` (daemon variant) or
  `launchctl kill HUP gui/$(id -u _runnervm)/com.runnervm.runnerd` (agent variant). In-process
  size rotation bounds the files even if you never send the signal.
- `runnerctl doctor` detects which variant is installed (`service_mode`) and reports whether the
  job is loaded (`launchd_job`, `reboot_persistence`). A freshly installed host with the daemon
  started by hand for testing is a legitimate state, so an unloaded job is a warning, not a
  failure.
- `runnerctl` and `runnerd` both auto-discover a production install: with no `--socket`/
  `--state-dir` and no `RUNNERVM_SOCKET`/`RUNNERVM_STATE_DIR`/`RUNNERVM_RUNTIME_DIR`, an existing
  `/var/run/runnervm/runnerd.sock` wins over the development layout. The daemon also accepts RPC
  from root, so `sudo runnerctl status` works against a daemon running as `_runnervm`.
