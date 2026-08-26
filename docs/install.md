# Installing RunnerVM on the host Mac

Production packaging for `runnerd`, `vmworker` and `runnerctl` (spec §7.2 privilege model, §22
layout, §129 socket security, §130 shutdown integration). Everything below is driven by
`scripts/install.sh`; read that script's `--help` for the exact flag list.

## Prerequisites

- Apple Silicon Mac, macOS 15 or later (`runnerctl doctor` checks both).
- Xcode command line tools (`swift build`, `codesign`) and, for a Developer ID build,
  `CODESIGN_IDENTITY` set to a signing identity already in your keychain.
- ~50 GiB+ free disk by default (`host.reserve.disk`; lower it in config if the host is smaller —
  `runnerctl doctor` reports the actual headroom against whatever the config says).
- A GitHub PAT or App installation for the scopes you plan to run against (spec §12).

## Install

```sh
sudo scripts/install.sh --launchd agent --config path/to/config.yaml
```

Without `sudo`, the script performs whatever it can with the invoking user's own privileges (handy
for `--prefix`/`--state-dir`/`--runtime-dir` under a writable custom location, e.g. for testing)
and prints the exact `sudo <command>` lines for everything else under **manual steps** — it never
calls `sudo` itself. Defaults: `--prefix /usr/local`, `--state-dir "/Library/Application Support/
RunnerVM"`, `--runtime-dir /var/run/runnervm`, `--user _runnervm`, `--launchd none`.

What it does, in order: builds release binaries for `runnerd`/`runnerctl`/`vmworker`; signs
`vmworker` with `Resources/vmworker.entitlements` (ad-hoc by default; set `CODESIGN_IDENTITY` for a
Developer ID build); installs `runnerd`+`vmworker` to `<prefix>/libexec/runnervm/` and `runnerctl`
to `<prefix>/bin/`; creates `<state-dir>` (mode 0750) with `images/`, `instances/`, `logs/`
subdirectories and `<runtime-dir>` (mode 0700), both owned by the service user; copies `--config`
to `<state-dir>/config.yaml`; verifies every socket path stays under the 104-byte `sun_path` limit
before writing anything; and, if `--launchd` is not `none`, installs the chosen plist. It never
runs `launchctl` — load the job yourself (the script prints the exact command).

Verify with `--dry-run` first; it performs no filesystem writes and prints every action, including
the fully rendered launchd plist.

## Choosing a launchd variant (plan spike S3)

`scripts/install.sh --launchd agent|daemon|none`. Full trade-off, provisioning steps and
`sysadminctl`/auto-login instructions live in `packaging/launchd/README.md`. Summary:

- **`agent`** (recommended default): a LaunchAgent in a dedicated auto-login user's GUI session.
  macOS 15+ Virtualization.framework needs an unlocked login keychain in the session that creates
  the VM; a GUI session already has one. This is the known-good path Tart/Cirrus Labs use for the
  same framework.
- **`daemon`** (experimental): a LaunchDaemon under a dedicated unprivileged account, matching spec
  §7.2's original wording literally. No GUI session means no automatically-unlocked keychain —
  needs explicit `security unlock-keychain` provisioning that is not wired up yet. Treat as
  unverified until spike S3 (`TODO.md`) closes.
- **`none`** (default): installs nothing launchd-related; the script prints the manual foreground
  command instead. Useful for testing or for an external process supervisor.

Both plists live in `packaging/launchd/` as templates (`__TOKEN__` placeholders); `install.sh`
substitutes them and writes the result to `/Library/LaunchAgents/com.runnervm.runnerd.agent.plist`
or `/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist`.

## Dedicated service account and auto-login

```sh
sudo sysadminctl -addUser _runnervm -fullName "RunnerVM Service" \
  -password - -home /Users/_runnervm -admin off
```

For the LaunchAgent path, also enable automatic login for `_runnervm` (System Settings → Login
Screen) and log in as that user once before relying on it, so its login keychain exists and is
unlocked going forward. `packaging/launchd/README.md` covers the LaunchDaemon keychain-provisioning
alternative. Autologin requires FileVault to be off (or the volume unlocked another way).

## Uninstall

```sh
sudo scripts/install.sh --uninstall --launchd agent
```

Removes the installed binaries and the matching launchd plist (both variants if `--launchd` is
omitted). **State (`<state-dir>`, including images and instance disks) and the runtime socket
directory are left in place** — remove them by hand if you actually want the data gone. Unload the
job first (the command is printed) so nothing tries to restart the daemon mid-uninstall.

## `runnerctl doctor`

```sh
runnerctl doctor [--state-dir <dir>] [--socket-dir <dir>] [--config <yaml>] [--output json]
```

Every check runs locally — no daemon required, matching the general RunnerVM principle that the
CLI never depends on runnerd being up just to inspect the host. Checks (spec §104, plus host-sleep
and launchd-job checks the implementation plan adds): Apple Silicon, macOS ≥ 15, `vmworker` present
and signed with the virtualization entitlement, `vmworker probe` succeeds and reports
`virtualizationSupported`, state directory writable + APFS clone support, socket path lengths,
configuration validates (when `--config` is given), free disk vs. `host.reserve.disk`, a GitHub
credential is present for the configured `github.auth.source` (presence only — this never makes a
network call; use `runnerctl github test` to actually verify it), host sleep is disabled (spec plan:
v1 does not tolerate the host sleeping out from under a running VM), and whether a
`com.runnervm.runnerd` launchd job is loaded. When `runnerd.sock` is reachable it also folds in a
`system.status` summary. Exits 1 if any check fails; `--output json` for automation.

## Log locations

- `<state-dir>/logs/runnerd.log` — the daemon's JSON logs (both launchd plists redirect
  stdout/stderr there; `runnerd` writes structured JSON to stderr, spec §42).
- `<state-dir>/logs/instances/<id>/` — per-instance `serial.log` and worker logs (spec §131).
- `packaging/newsyslog/runnervm.conf` — optional rotation policy; not installed automatically (copy
  it to `/etc/newsyslog.d/` yourself). Read the caveat in that file and in
  `packaging/launchd/README.md`: `runnerd` does not reopen its log file descriptor on rotation, so a
  rotated file only stops growing once the daemon restarts.

## Upgrade procedure

1. Stop new work from landing on this host before touching binaries. `runnerctl system drain`
   would be the ideal command, but `system.drain` is still `NOT_IMPLEMENTED`
   (`Sources/DaemonAPI/DaemonMethod.swift`) as of this writing — instead, disable every profile in
   the configuration (`profiles[].enabled: false`, or remove them) and `runnerctl config apply` the
   result, then wait for `runnerctl status` to show zero `busy`/`starting` instances.
2. `sudo launchctl bootout gui/$(id -u _runnervm) /Library/LaunchAgents/com.runnervm.runnerd.agent.plist`
   (or `system` + the daemon plist path for the LaunchDaemon variant).
3. Re-run `scripts/install.sh` with the same flags — it overwrites the binaries and re-signs
   `vmworker` in place; state and runtime directories are untouched.
4. `runnerctl doctor` to confirm the new binary is signed and `vmworker probe` still succeeds.
5. Reload the job (`launchctl bootstrap ...`, printed by `install.sh`) and re-enable the profiles
   you disabled in step 1.

## Security notes (spec §129)

- `<runtime-dir>` is mode 0700, owned by the service user; individual sockets are created mode
  0600 by `runnerd` itself (`Sources/RPC/UnixSocketListener.swift` publishes atomically via a
  `.tmp` rename so a socket is never observed group/world-accessible).
- RunnerVM never listens on TCP for internal control in v1 — only Unix-domain sockets under
  `<runtime-dir>`.
- `<state-dir>` is 0750; the `github-token` file (when `github.auth.source: file`) is enforced
  owner-only (0600) by the code that reads it — a looser mode is treated as a configuration error,
  not a warning, because a leaked PAT with `admin:org` is a host-wide compromise.
- Run production workloads as the dedicated `_runnervm` account, never as `root` — `root` is only
  needed transiently, for `sudo scripts/install.sh` itself.
