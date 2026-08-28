# Building and running RunnerVM from source

This is the path the project itself is developed and tested against: build
`runnerd`/`runnerctl`/`vmworker` yourself, run a dev daemon, and (optionally) install it the same
way `scripts/install.sh` would on a production host. If you just want a working runner host and do
not care how the binaries were built, use **[`SETUP.md`](../SETUP.md)**'s one-command install
instead — this page is for development, or for installing from source before a tagged release
exists.

Read [`SETUP.md`](../SETUP.md) first for the shape of the system, the scope/credential decision,
and host sizing — this document assumes you have already read it.

## 1. Prepare the host

Apple Silicon, macOS 15 or later.

```sh
# Xcode Command Line Tools — provides swift and codesign
xcode-select --install

# The host must not sleep out from under a running VM
sudo pmset -a sleep 0 disksleep 0 displaysleep 10

# Confirm
sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize
sw_vers
df -h /System/Volumes/Data
pmset -g | grep -E ' sleep|disksleep'
```

## 2. Get the binaries

```sh
git clone https://github.com/andrejvysny/RunnerVM.git
cd RunnerVM
swift build -c release          # ~2 minutes on an M-series Mac
scripts/sign-dev.sh              # ad-hoc sign vmworker — required before any local VM run
```

**Go**, for the Linux guest agent that gets baked into images you build. If `go` is missing,
`install.sh` fails unless you pass `--skip-guest-agent` — but then `runnerctl image build` cannot
work. Either install Go, or cross-build the agent on another Mac and copy it in:

```sh
make -C GuestAgent build-linux          # produces GuestAgent/bin/linux-arm64/runnervm-guest-agent
# ...or copy that file from a machine that has Go; install.sh picks up an existing one and
# skips the build entirely.
```

## 3. Quick local dev daemon (no GitHub, just images)

The fastest way to confirm a build works — builds images locally, no service account, no launchd,
no GitHub registration:

```sh
swift build && scripts/sign-dev.sh
make -C GuestAgent build-linux
R=$HOME/runnervm-dev; mkdir -p $R/guest-agent/linux-arm64 /tmp/rvm
cp GuestAgent/bin/linux-arm64/runnervm-guest-agent $R/guest-agent/linux-arm64/
.build/debug/runnerd --foreground --state-dir $R --socket-dir /tmp/rvm &
.build/debug/runnerctl --socket /tmp/rvm/runnerd.sock image build images/recipes/ubuntu-24-minimal --name ubuntu-24-minimal
.build/debug/runnerctl --socket /tmp/rvm/runnerd.sock image build images/recipes/ubuntu-24 --name ubuntu-24
```

`runnerctl`/`runnerd` also honor `RUNNERVM_SOCKET`/`RUNNERVM_STATE_DIR`/`RUNNERVM_RUNTIME_DIR` if
you would rather export those once than pass `--socket`/`--state-dir` on every call.

The rest of this document walks the full path to a real GitHub-registered host, install-script
style — for that you need the service account and a GitHub credential.

## 4. Create the service account

RunnerVM runs as a dedicated `_runnervm` user whose primary group is a dedicated `_runnervm`
group — **never `staff`**, because every local account is in `staff` and would then be able to read
your GitHub credentials and job logs.

```sh
# Pick a free GID/UID in 200-400: this should print nothing.
dscl . -list /Groups PrimaryGroupID | awk '$2 == 250'

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

`dscl` only — no `sysadminctl`, no interactive password prompt, no real home under `/Users`. The
account never logs in, so it needs neither. `scripts/install.sh` and `runnerctl setup`'s
`ServiceAccountManager` both run exactly this sequence and print it under "manual steps" when they
lack the privilege to run it themselves, so you can also skip ahead and let either tool tell you.

<details>
<summary><b>No root on this machine?</b> There is a working root-free path.</summary>

Everything can live under your own home directory instead. This is what a real deployment did on a
Mac where `sudo` needed a password nobody wanted to type into automation:

```sh
--prefix /Users/you/.local \
--state-dir /Users/you/runnervm \
--runtime-dir /Users/you/runnervm/run \
--user "$(id -un)" --group staff --allow-staff-group
```

`--group staff` is refused without `--allow-staff-group` for the reason above. If you take this
path on a machine with other accounts, tighten the state directory by hand afterwards, because
0750 + `staff` is readable by all of them:

```sh
chmod 700 /Users/you/runnervm
```

You give up: the dedicated account, a launchd job at boot (both plist locations need root), and
`root:staff` ownership of the shipped recipes. Everything else works identically.
</details>

## 5. Write the configuration

```sh
.build/release/runnerctl config init > runnervm.yaml
```

Then edit it. The two scope shapes are the only real difference between an org and a repo setup —
see [`SETUP.md`](../SETUP.md) for the full YAML for each, and for the GitHub credential to create
first. Host sizing knobs (`host.reserve`, `host.overcommit.disk`, `images.cache`) are also in
[`SETUP.md`](../SETUP.md) and [`docs/install.md`](install.md).

Store the PAT once you have one:

```sh
sudo -u _runnervm sh -c 'umask 077; cat > "/Library/Application Support/RunnerVM/state/github-token"'
# paste the token, then Ctrl-D
sudo chmod 600 "/Library/Application Support/RunnerVM/state/github-token"
```

with `source: file` in the config — `source: keychain` needs an unlocked login keychain in the
daemon's own session, which a headless host does not have.

Check the config before going further:

```sh
.build/release/runnerctl config validate runnervm.yaml
```

## 6. Install

```sh
sudo scripts/install.sh --dry-run --config runnervm.yaml --launchd none   # read what it will do
sudo scripts/install.sh           --config runnervm.yaml --launchd none
```

Defaults: `--prefix /usr/local`, `--state-dir "/Library/Application Support/RunnerVM"`,
`--runtime-dir /var/run/runnervm`, `--user _runnervm`, `--group _runnervm`.

It builds release binaries, signs `vmworker` with the virtualization entitlement, installs
`runnerd`/`vmworker` under `<prefix>/libexec/runnervm/` and `runnerctl` on your `PATH`, creates the
state (0750) and runtime (0700) directories owned by the service user, copies your config in, and
installs the Linux guest agent and the shipped recipes. It never calls `sudo` itself and never runs
`launchctl`; anything it cannot do, it prints for you to run. Full flag reference:
[`docs/install.md`](install.md).

A production install's socket is discovered automatically (flag > `RUNNERVM_SOCKET` >
`/var/run/runnervm/runnerd.sock` if it exists > the development path), so `sudo runnerctl status`
works with no flags once the daemon is running. For convenience during development, a shell
function still helps if you juggle multiple state directories:

```sh
export RVM_SOCK=/var/run/runnervm/runnerd.sock
rvm() { runnerctl --socket "$RVM_SOCK" "$@"; }
```

`doctor` deliberately works with no daemon at all, so it takes directories rather than a socket:

```sh
runnerctl doctor --state-dir "/Library/Application Support/RunnerVM" \
  --config "/Library/Application Support/RunnerVM/config.yaml"
```

Fix everything red before continuing.

## 7. Start the daemon

Foreground first; making it permanent is step 9.

```sh
sudo -u _runnervm /usr/local/libexec/runnervm/runnerd --foreground \
  --config "/Library/Application Support/RunnerVM/config.yaml" \
  --state-dir "/Library/Application Support/RunnerVM" \
  --socket-dir /var/run/runnervm
```

In another terminal:

```sh
rvm status                 # daemon healthy? disk pressure ok?
rvm github test            # credential and every scope, checked against GitHub
rvm scaleset list          # state ready, session open, health ok
```

`rvm github test` is the one that tells you whether your token permissions are right — it
actually calls GitHub, unlike `doctor`, which only checks that a credential is present. At this
point GitHub shows a runner scale set for the profile; `ADVERTISED` is `0` until you have an image.

## 8. Get a runner image, then run a job

Pull a published one, or build your own — see [`docs/published-images.md`](published-images.md) and
[`docs/image-build.md`](image-build.md):

```sh
rvm image pull ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable
# or:
rvm image build "$STATE/share/recipes/ubuntu-24-minimal" --name ubuntu-24-minimal
rvm image build "$STATE/share/recipes/ubuntu-24"         --name ubuntu-24
```

Then add a workflow to the target repository (`runs-on` is the profile name), trigger it, and watch
`rvm vm list` walk `cloning → … → idle → … → busy → deleted` and disappear.

## 9. Make it survive a reboot

Nothing so far restarts `runnerd` after a reboot. Pick a variant — full trade-off in
[`packaging/launchd/README.md`](../packaging/launchd/README.md):

| variant | needs | status |
| --- | --- | --- |
| **LaunchDaemon** | nothing beyond the service account | Recommended production default — no GUI session, no auto-login, no FileVault compromise. `runnerctl doctor` skips the login-keychain check under a detected LaunchDaemon rather than failing it. |
| **LaunchAgent** | a dedicated **auto-login** GUI session for `_runnervm`; FileVault off (or the volume unlocked another way) | Secondary — developer workstations and GUI sessions where something in the job workload needs a window server. |
| **none** | your own supervisor | Fine if you already run one. |

```sh
sudo scripts/install.sh --config runnervm.yaml --launchd daemon    # or: agent
# install.sh prints the exact launchctl command; it never runs it for you:
sudo launchctl bootstrap system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
# LaunchAgent variant:
launchctl bootstrap gui/$(id -u _runnervm) /Library/LaunchAgents/com.runnervm.runnerd.agent.plist
```

For the LaunchAgent you must also enable automatic login for `_runnervm` (System Settings → Login
Screen) and log in as that account once so its login keychain exists.

Before trusting either on unattended hardware, run the cold-boot / power-cut loop in
[`docs/qualification.md`](qualification.md) — that loop, not this section, is what decides whether
a host is production-ready.

---

## Operating it

```sh
rvm status                     # health, capacity, profiles, disk pressure
rvm vm list                    # live instances
rvm scaleset list              # GitHub-side session, demand, advertised capacity
rvm runner list                # runner sessions
rvm metrics                    # counters; Prometheus endpoint if enabled in config
```

**Logs** — full reference in [`docs/logging.md`](logging.md):

| path | what |
| --- | --- |
| `<state-dir>/logs/runnerd/runnerd.log` | the daemon's JSON log, self-rotating |
| `<state-dir>/logs/events.jsonl` | one line per lifecycle transition and audit event |
| `<state-dir>/logs/instances/<id>/` | per-instance `serial.log`, `worker.log`, `failure.json`, guest `diag/` |

**Changing configuration** — applied live, no restart:

```sh
rvm config validate runnervm.yaml && rvm config apply runnervm.yaml
```

**Maintenance and upgrades (source install).** Always drain first; `--wait` blocks until the last
job finishes. A source install re-runs `scripts/install.sh`; a pkg install uses `runnerctl upgrade`
instead (see [`SETUP.md`](../SETUP.md)):

```sh
rvm system drain --wait
sudo launchctl bootout system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
sudo scripts/install.sh --config runnervm.yaml --launchd daemon    # same flags as before
sudo launchctl bootstrap system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
rvm system resume
```

> **The SQLite schema migration is one-way.** `runnerd` migrates the database forward on startup and
> never downgrades it; rolling back to an older binary on the same state directory is not supported.
> Take a backup before a major upgrade.

**Uninstall** — removes binaries and the launchd job; **state, images and the service account are
left in place** deliberately:

```sh
rvm system drain --wait
sudo launchctl bootout system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
sudo scripts/install.sh --uninstall --launchd daemon
```

---

## Troubleshooting

| symptom | cause and fix |
| --- | --- |
| `rvm status` shows `capacity: 0` and jobs queue forever | Almost always disk. Check `Disk pressure` in `rvm status` — if free space is below `host.reserve.disk`, lower the reserve or free space. Remember the reservation is `max(profile.disk, image.virtualBytes)`, ≥16 GiB per Linux instance. |
| `IMAGE_INSUFFICIENT_DISK_SPACE` on `image build` | Same thing, against `host.reserve.disk`. The default is 50 GiB — far too high for a small Mac. |
| Jobs stay queued; `rvm scaleset list` shows `SESSION closed` and `HTTP 409 … RunnerScaleSetSessionConflictException` | Another host is registered against the same scope with the same profile name and holds the one message session. Rename this host's profile, or disable it on the other host. |
| Jobs run on GitHub's hosted runners instead of your Mac | The profile name shadows a hosted label. `config validate` refuses this now (`PROFILE_NAME_SHADOWS_HOSTED_LABEL`); rename to e.g. `rvm-macos-26`. |
| `doctor`: **Login keychain — skip** | Expected under a detected LaunchDaemon; it no longer runs the check there at all. Under a LaunchAgent or foreground process it still warns rather than fails if locked — only meaningful if VM starts actually fail. |
| `doctor`: **WARN Disk headroom / could not read free space** | The purgeable-space figure is unavailable without a login session; the daemon falls back to plain available capacity. Harmless. |
| `doctor`: **FAIL GitHub credential missing** | Wrong path — it is `<state-dir>/**state**/github-token`, not the state root. |
| `runnerctl` says the daemon is unreachable, but it is running | Check `--socket`/`RUNNERVM_SOCKET` against what `--socket-dir`/`--runtime-dir` the daemon actually started with — auto-discovery only finds the *production* path (`/var/run/runnervm/runnerd.sock`); a dev daemon under `$HOME` still needs one of the two spelled out. |
| `rvm github test` fails on the scope | Token permissions. Administration: Read **and write** is the one people miss; without it the scale set cannot be created. |
| VM boots, job never starts | Check `<state-dir>/logs/instances/<id>/serial.log` and `worker.log`. A common cause is an image with no guest agent — `rvm image inspect <name>` reports `guest agent`, `doctor` flags it too, and tart-imported images never have one (`IMAGE_NO_GUEST_AGENT`). |
| `image build` fails with no Go | Install Go, or copy a prebuilt `GuestAgent/bin/linux-arm64/runnervm-guest-agent` in before running `install.sh`. |
| Everything worked, then stopped after a reboot | You never installed a launchd job (step 9), or the LaunchAgent's auto-login user did not log in — FileVault is the usual reason. |

Two commands worth knowing when you are stuck: `runnerctl doctor --deep` re-hashes every image
blob, and `rvm vm exec <id> -- <cmd>` runs a command inside a live guest.
