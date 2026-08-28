# launchd packaging for `runnerd`

Two variants ship side by side; `scripts/install.sh --launchd agent|daemon` picks one. Neither is
loaded automatically — installing only writes the plist and prints the `launchctl` command to run.

## Why two variants (plan C3 spike S3)

Spec §7.2 specifies a LaunchDaemon under a dedicated unprivileged account. That is still the
long-term target, but Apple Virtualization.framework on macOS 15+ has an undocumented requirement:
the process that creates a `VZVirtualMachine` needs an **unlocked login keychain in its own
session**. A LaunchDaemon's service account has no login session and therefore no unlocked
keychain — VM creation can fail in ways that are opaque from the outside.

Until that is verified against this repo's own `vmworker` (spike S3 in `TODO.md`, still open),
the known-good path — and what Tart/Cirrus Labs recommend for the same framework — is:

| Variant | Status | Requirement |
| --- | --- | --- |
| **LaunchAgent**, dedicated auto-login user | **Recommended default** | The Mac auto-logs into a dedicated GUI session; `runnerd` inherits that session's already-unlocked login keychain. |
| **LaunchDaemon**, dedicated unprivileged account | **Experimental** | Needs explicit keychain provisioning (`security unlock-keychain`) wired into boot, and repeated-cold-boot testing, before it can be trusted. |

Both are packaged now so the choice is evidence-based, not architecture-based: run spike S3
against your own hardware/macOS version and pick the variant that actually boots a VM across a
cold reboot.

**Counter-evidence, 2026-08-28 (one host, macOS 26.5.2, Apple M4).** On a Mac mini with no GUI
login session at all — nobody logged in, no auto-login user, `/dev/console` owned by `root` —
`runnerd` booted every VM it was asked for (two image builds, ten GitHub jobs, eleven live E2E
scenarios) while `runnerctl doctor` reported `FAIL Login keychain — login keychain for blackpen is
locked (security exit 36)`. `vmworker probe` likewise answered `virtualizationSupported: true`.
The keychain requirement above did not reproduce there, so the `Login keychain` doctor check is a
false negative on that host. See `docs/verification.md` "Mac mini deployment".

That is a single host and a single OS version, and it says nothing about whether the job comes
back across a reboot — the qualification loop in `docs/qualification.md` remains unrun, so the
LaunchDaemon variant stays **experimental**. It does mean the *reason* for preferring the
LaunchAgent is worth re-testing on your own hardware rather than assumed.

## LaunchAgent path (recommended)

1. Create the dedicated service group and account (needs an admin). The group is a hidden system
   group, never `staff` — every local macOS account is a member of `staff`, which would make
   `<state-dir>` and its log/config files readable by every other user on the Mac (see
   `docs/install.md`, "Dedicated service account and auto-login"):

   ```sh
   # Pick a free GID in 200-400 (`dscl . -list /Groups PrimaryGroupID` should not already print it).
   sudo dscl . -create /Groups/_runnervm
   sudo dscl . -create /Groups/_runnervm PrimaryGroupID 250
   sudo dscl . -create /Groups/_runnervm RealName "RunnerVM Service"
   sudo dscl . -create /Groups/_runnervm Password "*"

   sudo sysadminctl -addUser _runnervm -fullName "RunnerVM Service" \
     -GID 250 -password - -home /Users/_runnervm -admin off
   ```

   (`-password -` prompts interactively; do not put the password on the command line or in shell
   history.) `scripts/install.sh` checks for both and prints the equivalent commands under "manual
   steps" whenever either is missing, so this step can also be left to the installer.

2. Enable automatic login for that account: System Settings → General → Login Screen (or Users &
   Groups, depending on macOS version) → set "Automatically log in as" to `_runnervm`. This is a
   GUI-only setting on current macOS releases; the historical `defaults write
   com.apple.loginwindow autoLoginUser` + `/etc/kcpassword` mechanism is deprecated and disabled
   by SIP on modern systems — treat any script-only path to autologin as unverified until you
   confirm it works on the target macOS version. Autologin also requires FileVault to be off, or
   the volume unlocked another way.
3. Log in once as `_runnervm` interactively (keeps the login keychain created and unlocked) before
   relying on autologin.
4. `sudo scripts/install.sh --launchd agent --user _runnervm ...` — installs the plist to
   `/Library/LaunchAgents/com.runnervm.runnerd.agent.plist`.
5. Because it is a LaunchAgent, it only runs once `_runnervm` is logged in (autologin after
   reboot, or a manual login). Load it for that session:

   ```sh
   launchctl bootstrap gui/$(id -u _runnervm) \
     /Library/LaunchAgents/com.runnervm.runnerd.agent.plist
   ```

   `scripts/install.sh` prints this command; it never runs `launchctl` itself.

## LaunchDaemon path (experimental)

1. Create the dedicated service account as above, but it does not need a GUI session or autologin.
2. Provision and unlock a keychain for that account before `runnerd` starts. There is no
   out-of-the-box launchd hook for "unlock a keychain at boot for a headless account" — options
   worth spiking:
   - a `LaunchDaemon` with a higher `RunAtLoad` priority that runs
     `security unlock-keychain -p <password> /Users/_runnervm/Library/Keychains/login.keychain-db`
     before `com.runnervm.runnerd` starts (the password has to live somewhere on disk, which is
     itself a secret-handling problem — do not store it in the plist);
   - `security create-keychain` + `security set-keychain-settings` with no lock-on-sleep, then
     unlock once and hope it survives reboots (it will not survive a reboot without a login).
   None of this is wired up by `scripts/install.sh`; it is exactly the gap spike S3 exists to
   close before this variant is the default.
3. `sudo scripts/install.sh --launchd daemon --user _runnervm ...` — installs the plist to
   `/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`.
4. Load it:

   ```sh
   sudo launchctl bootstrap system \
     /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
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
- `runnerctl doctor` checks whether the expected job is loaded
  (`launchctl print gui/$(id -u)/com.runnervm.runnerd` for the agent,
  `launchctl print system/com.runnervm.runnerd` for the daemon) and reports a warning, not a
  failure, when neither is — a freshly installed host with the daemon started by hand for testing
  is a legitimate state.
