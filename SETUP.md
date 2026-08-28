# Setting up RunnerVM on a fresh Mac

End-to-end: from a Mac you just unboxed to GitHub Actions jobs running in throwaway VMs on it,
registered against either an **organization** or a single **repository**.

Read this once before starting. Steps 1–9 are the install; step 10 makes it survive a reboot.
Budget about an hour, most of it waiting for an image build.

- Reference for every `install.sh` flag and the security model: [`docs/install.md`](docs/install.md)
- A real deployment's configuration, verbatim, with the reasoning behind each number:
  [`docs/examples/headless-mac-mini.yaml`](docs/examples/headless-mac-mini.yaml)
- What has actually been proven, and what has not: [`docs/verification.md`](docs/verification.md)

---

## 0. What you are building

```
GitHub  ──  runner scale set "runnervm-<profile>"  ──▶  runnerd (one per Mac)
                                                          │
                                             one vmworker per VM
                                                          │
                                        ephemeral Linux/arm64 guest
                                        (guest agent over vsock, JIT runner)
```

Three ideas that explain most of the configuration:

1. **A profile is a runner label.** A profile named `ubuntu-24` registers a scale set called
   `runnervm-ubuntu-24` whose label is `ubuntu-24`, so workflows say `runs-on: ubuntu-24`. The
   `runnervm-` prefix only namespaces GitHub's side; it is never what you write in a workflow.
2. **Ephemeral means one job per VM.** The VM is cloned from an image, takes exactly one job, and
   is destroyed. Nothing survives between jobs, and nothing is left on disk afterwards.
3. **`runnerd` never links Virtualization.framework.** Only `vmworker` does, one process per VM,
   carrying the `com.apple.security.virtualization` entitlement. This is why signing matters.

### Decide three things now

| decision | options | how to choose |
| --- | --- | --- |
| **Scope** | organization / repository | An org scope serves every repo in the org and needs `admin:org`-grade credentials — a host-wide compromise if the Mac is breached. A repository scope is narrower and is the right default for a first host. |
| **Credential** | PAT / GitHub App | A PAT is 5 minutes of setup. A GitHub App is better for an org (scoped, rotatable, auditable) and is worth it once you are past the first host. |
| **Service model** | LaunchAgent / LaunchDaemon / foreground | See step 10. If you just want jobs running today, start in the foreground and come back to it. |

### Is your Mac big enough?

The binding constraint is almost always **disk**, not CPU or RAM, and it surprises people. An
instance reserves:

```
max(profile.resources.disk, image.virtualBytes)
```

The shipped `ubuntu-24` image has a **16 GiB** disk layer, so every Linux instance reserves 16 GiB
no matter what the profile asks for. Concurrency is therefore roughly:

```
concurrent VMs ≈ (free disk − host.reserve.disk − image storage) ÷ 16 GiB
```

A 32 GiB / 512 GB Mac mini with ~62 GiB free ran **3** concurrent VMs. CPU and RAM ran out nowhere
near as fast: 3 × 2 vCPU and 3 × 4 GiB against 10 CPUs and 32 GiB.

> **macOS guests need far more.** A macOS guest cannot resize its APFS container, so
> `resources.disk` must equal the image's disk *exactly* and the reservation is the whole thing —
> about **80 GiB free** for one guest with a Tart-derived image. macOS is also still experimental;
> see [`docs/macos-guests.md`](docs/macos-guests.md). The rest of this guide is Linux/arm64.

---

## 1. Prepare the host

Apple Silicon, macOS 15 or later. On a fresh Mac:

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

Two things to know before you go further:

- **FileVault vs. auto-login.** If you plan to use the LaunchAgent variant (step 10), FileVault's
  pre-boot prompt happens before any session can auto-log-in, so a *cold* boot will not bring
  runners back without a human. Decide now whether at-rest encryption or unattended cold-boot
  recovery matters more.
- **Other accounts on the Mac.** Every local macOS user is in the `staff` group. If this machine is
  shared, do **not** let RunnerVM's state directory end up `staff`-readable — step 3 handles this.

---

## 2. Get the binaries

**From source** (what this guide assumes):

```sh
git clone https://github.com/andrejvysny/github-managed-runners.git
cd github-managed-runners
swift build -c release          # ~2 minutes on an M-series Mac
```

**Or via Homebrew**, if you would rather not build:

```sh
brew install andrejvysny/runnervm/runnervm
```

Homebrew builds and ad-hoc signs the same binaries but does none of the privileged setup below
(formulae must never call `sudo`). You still run `install.sh`, with `--prebuilt-dir`; see
[`docs/install.md`](docs/install.md#installing-via-homebrew).

**Go**, for the Linux guest agent that gets baked into images you build. If `go` is missing,
`install.sh` fails unless you pass `--skip-guest-agent` — but then `runnerctl image build` cannot
work. Either install Go, or cross-build the agent on another Mac and copy it in:

```sh
make -C GuestAgent build-linux          # produces GuestAgent/bin/linux-arm64/runnervm-guest-agent
# ...or copy that file from a machine that has Go; install.sh picks up an existing one and
# skips the build entirely.
```

---

## 3. Create the service account

RunnerVM runs as a dedicated `_runnervm` user whose primary group is a dedicated `_runnervm`
group — **never `staff`**, because every local account is in `staff` and would then be able to read
your GitHub credentials and job logs.

```sh
# Pick a free GID in 200-400: this should print nothing.
dscl . -list /Groups PrimaryGroupID | awk '$2 == 250'

sudo dscl . -create /Groups/_runnervm
sudo dscl . -create /Groups/_runnervm PrimaryGroupID 250
sudo dscl . -create /Groups/_runnervm RealName "RunnerVM Service"
sudo dscl . -create /Groups/_runnervm Password "*"

sudo sysadminctl -addUser _runnervm -fullName "RunnerVM Service" \
  -GID 250 -password - -home /Users/_runnervm -admin off
```

`-password -` prompts interactively — do not put a password on the command line.

`scripts/install.sh` checks for both principals on every run and prints these exact commands if
either is missing, so you can also skip ahead and let it tell you.

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

---

## 4. Write the configuration

Start from a template that already validates:

```sh
.build/release/runnerctl config init > runnervm.yaml
```

Then edit it. The two scope shapes are the only real difference between an org and a repo setup.

### Organization scope

Serves every repository in the org. Runners land in a runner group; `Default` is the group every
org has.

```yaml
github:
  demand: scaleSet
  auth:
    provider: pat
    source: file
  scopes:
    - name: engineering          # local alias, referenced by profiles below
      type: organization
      owner: acme                # the org login
      runnerGroup: Default       # optional; omit for the org default

profiles:
  - name: ubuntu-24              # this is the runs-on label
    scope: engineering
    image: ubuntu-24
    lifecycle: ephemeral
    resources:
      cpu: 2
      memory: 4GiB
      disk: 16GiB
    limits:
      maxInstances: 3
```

### Repository scope

Narrower, and the right choice for a first host.

```yaml
github:
  demand: scaleSet
  auth:
    provider: pat
    source: file
  scopes:
    - name: repo
      type: repository
      owner: acme                # user or org that owns it
      repository: project-a      # just the name, not owner/name

profiles:
  - name: ubuntu-24
    scope: repo
    image: ubuntu-24
    lifecycle: ephemeral
    resources:
      cpu: 2
      memory: 4GiB
      disk: 16GiB
    limits:
      maxInstances: 3
```

### Host sizing and the settings people miss

```yaml
host:
  reserve:
    cpu: 2                       # logical CPUs kept for macOS itself
    memory: 6GiB
    disk: 50GiB                  # absolute free-space floor; lower it on a small host
  maxVMs: auto                   # or a number, if disk is the real limit

# A failed session holds its cpu/memory/DISK reservation until this expires.
# The 2h default strands 16 GiB on a small host.
diagnostics:
  failedInstanceRetention: 15m

# The only things that outlive a job. Per-job storage is already fully reclaimed.
images:
  cache:
    maxSize: 20GiB
logging:
  retention:
    instanceLogs: 3d
```

If your host has less than ~66 GiB free, **lower `host.reserve.disk`** — the 50 GiB default will
otherwise refuse image builds and VM starts on a machine that has plenty of room in practice.

### Rules the validator enforces

| rule | why |
| --- | --- |
| A profile name must not match a GitHub-hosted label | `runs-on: macos-26` or `ubuntu-24.04` sends the job to GitHub's hosted runners instead of your Mac — different billing, secrets and network, with nothing on your host to show for it. Refused as `PROFILE_NAME_SHADOWS_HOSTED_LABEL`. Shadowing names are `ubuntu-latest`/`macos-latest`/`windows-latest`, `macos-<N>`, `ubuntu-<N>.<N>`, `windows-<NNNN>` (± `-large`/`-xlarge`/`-arm64`…). Prefix yours, e.g. `rvm-macos-26`. `ubuntu-24` is fine. |
| `lifecycle: reusable` needs `reuse.acknowledgeSharedHost: true` | A reusable VM keeps state a job can write anywhere it can `sudo`. Treat it as single-tenant. **Use `ephemeral` in production.** |
| `security.allowPublicRepositories` defaults off | Turning it on means pull-request code from strangers can execute on your Mac. Only for a dedicated, disposable host. |
| **One host per profile name, per scope** | Not validated — nothing can see your other Macs. A scale set has exactly one message session, so two hosts sharing a scope *and* a profile name fight over it (`HTTP 409 RunnerScaleSetSessionConflictException`) and whichever restarts loses its jobs to the other. Give each host distinct profile names. |

Check it before going further:

```sh
.build/release/runnerctl config validate runnervm.yaml
```

---

## 5. Create the GitHub credential

### Option A — fine-grained PAT (recommended for a repository scope)

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens.

- **Resource owner**: the user or org that owns the repo
- **Repository access**: *Only select repositories* → just the one
- **Repository permissions**:

| permission | level | what needs it |
| --- | --- | --- |
| Administration | **Read and write** | create the runner scale set, mint registration and JIT configs |
| Actions | **Read and write** | poll for job demand; *write* is only needed if you run the E2E driver, which cancels runs — Read is enough for normal operation |
| Metadata | Read-only | mandatory, auto-selected |

### Option B — classic PAT

| scope target | token needs |
| --- | --- |
| repository | `repo` |
| organization | `admin:org` |

Both are broad. An `admin:org` token on a compromised Mac is an org-wide compromise — which is the
argument for a GitHub App on any org.

### Option C — GitHub App (recommended for an organization)

Create an App owned by the org, install it on the org (or selected repos), and give it
**Administration: Read and write**, **Actions: Read**, **Metadata: Read**. Then set:

```yaml
github:
  auth:
    provider: app
```

and write `<state-dir>/state/github-app.json`:

```json
{
  "clientId": "Iv23liXXXXXXXXXXXXXX",
  "installationId": 12345678,
  "privateKeyPath": "github-app.pem"
}
```

`appId` (numeric) is accepted instead of `clientId`. A relative `privateKeyPath` resolves against
the descriptor's own directory. Required modes: `github-app.json` 0640 or stricter, the `.pem`
**0600**, both owned by the service user — the daemon refuses anything looser rather than warning.

### Storing a PAT

**Note the path.** `--state-dir` is the *root*; credentials live in its `state/` subdirectory.

```sh
# Preferred: never appears in argv or shell history.
sudo -u _runnervm sh -c 'umask 077; cat > "/Library/Application Support/RunnerVM/state/github-token"'
# paste the token, then Ctrl-D
sudo chmod 600 "/Library/Application Support/RunnerVM/state/github-token"
```

with `source: file` in the config. Once the daemon is running you can also use
`rvm auth login --token-stdin`.

`source: keychain` is the other option, but it needs an unlocked login keychain in the daemon's own
session — which a headless host does not have. **On any unattended Mac, use `file`.**

---

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
`launchctl` — anything it cannot do, it prints for you to run.

### Teach your shell where the socket is — do this now

`runnerctl` talks to `runnerd` over a Unix socket, and **its built-in default is the *development*
path** (`/tmp/runnervm-<uid>/runnerd.sock`), not the production runtime directory. There is no
environment variable for it, so every command against a real install needs `--socket`. Rather than
typing it a hundred times, put this in your shell profile:

```sh
export RVM_STATE="/Library/Application Support/RunnerVM"
export RVM_SOCK=/var/run/runnervm/runnerd.sock
rvm() { runnerctl --socket "$RVM_SOCK" "$@"; }
```

The rest of this guide uses `rvm` for anything that talks to the daemon. If you prefer not to,
substitute `runnerctl --socket /var/run/runnervm/runnerd.sock` everywhere you see it.

`doctor` is the exception — it deliberately works with no daemon at all, so it takes directories
rather than a socket:

```sh
runnerctl doctor --state-dir "$RVM_STATE" --config "$RVM_STATE/config.yaml"
```

Fix everything red before continuing. See the troubleshooting table at the bottom — two of the
common complaints are expected on a headless Mac.

---

## 7. Start the daemon

Foreground first; making it permanent is step 10.

```sh
sudo -u _runnervm /usr/local/libexec/runnervm/runnerd --foreground \
  --config "$RVM_STATE/config.yaml" \
  --state-dir "$RVM_STATE" \
  --socket-dir /var/run/runnervm
```

(The shell expands `$RVM_STATE` before `sudo` runs, so it does not matter that `sudo` drops the
environment.)

In another terminal:

```sh
rvm status                 # daemon healthy? disk pressure ok?
rvm github test            # credential and every scope, checked against GitHub
rvm scaleset list          # state ready, session open, health ok
```

`rvm github test` is the one that tells you whether your token permissions are right — it
actually calls GitHub, unlike `doctor`, which only checks that a credential is present.

At this point GitHub shows a runner scale set for the profile. `ADVERTISED` will be `0` until you
have an image.

---

## 8. Build a runner image

Images are built by the daemon itself, from `Runnerfile` recipes that ship with the project.
`ubuntu-24` is `ubuntu-24-minimal` plus Docker, so build both:

```sh
rvm image build "$RVM_STATE/share/recipes/ubuntu-24-minimal" --name ubuntu-24-minimal
rvm image build "$RVM_STATE/share/recipes/ubuntu-24"         --name ubuntu-24

rvm image list
```

Expect roughly 3 minutes for the bootstrap (it downloads and converts the pinned Ubuntu cloud image
and installs the guest agent) and 1.5 minutes for the derived one. `--name` is the alias your
profile's `image:` refers to.

> `runnerd` must be able to *read* the recipe and its build context. `_runnervm` cannot read your
> home directory, so keep recipes under `<state-dir>/share/recipes` (where `install.sh` puts them)
> or `<state-dir>/recipes`.

Other ways to get an image: `rvm image pull ghcr.io/...` for a RunnerVM image from any OCI
registry (`rvm registry login` first if it is private), or your own recipe — see
[`docs/image-build.md`](docs/image-build.md).

Once an image exists, `rvm scaleset list` should advertise real capacity.

---

## 9. Run a real job

Add a workflow to the target repository. `runs-on` is the **profile name**:

```yaml
name: RunnerVM smoke test
on: workflow_dispatch

jobs:
  smoke:
    runs-on: ubuntu-24
    steps:
      - run: |
          uname -a
          id
          cat /etc/os-release
          docker info
      - uses: actions/checkout@v4
```

Trigger it (`gh workflow run ...` or the Actions tab) and watch the host:

```sh
watch -n 2 rvm vm list
rvm status
```

You should see one instance walk the ladder — `cloning → startingWorker → startingVM →
waitingForAgent → idle → configuringRunner → runnerOnline → busy → stopping → deleted` — in about
20 seconds to first job step, then disappear.

**Verify nothing was left behind**, which is the whole point of `ephemeral`:

```sh
rvm vm list                                         # (none)
ls "$RVM_STATE/instances/"                          # empty
gh api repos/OWNER/REPO/actions/runners --jq .total_count   # 0
df -h /System/Volumes/Data                          # unchanged
```

To test more than one at a time, dispatch a matrix job and confirm concurrency stops at your
configured ceiling and queues the rest.

---

## 10. Make it survive a reboot

Nothing so far restarts `runnerd` after a reboot. Pick a variant:

| variant | needs | status |
| --- | --- | --- |
| **LaunchAgent** | a dedicated **auto-login** GUI session for `_runnervm`; FileVault off (or the volume unlocked another way) | Documented default. The GUI session provides an unlocked login keychain, which Virtualization.framework was believed to require. |
| **LaunchDaemon** | nothing beyond root | Simpler — no auto-login, no FileVault compromise — but **experimental**: the reboot loop has not been qualified. |
| **none** | your own supervisor | Fine if you already run one. |

```sh
sudo scripts/install.sh --config runnervm.yaml --launchd agent    # or: daemon
# install.sh prints the exact launchctl command; it never runs it for you:
sudo launchctl bootstrap gui/$(id -u _runnervm) /Library/LaunchAgents/com.runnervm.runnerd.agent.plist
# LaunchDaemon variant:
sudo launchctl bootstrap system /Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist
```

For the LaunchAgent you must also enable automatic login for `_runnervm` (System Settings → Login
Screen) and log in as that account once so its login keychain exists.

> **Measured 2026-08-28, one host, macOS 26.5.2:** a `runnerd` started over SSH with **no GUI
> session at all** and a **locked** login keychain booted every VM asked of it — two image builds,
> ten jobs, eleven E2E scenarios. The keychain requirement that makes the LaunchAgent the default
> did not reproduce there, and `doctor`'s `Login keychain` check was a false negative. That is one
> host and it says nothing about reboot recovery, so the LaunchDaemon stays experimental — but it
> is worth re-measuring on your own hardware rather than assuming.
> See [`packaging/launchd/README.md`](packaging/launchd/README.md).

Before trusting either on unattended hardware, run the cold-boot / power-cut loop in
[`docs/qualification.md`](docs/qualification.md).

---

## Operating it

```sh
rvm status                     # health, capacity, profiles, disk pressure
rvm vm list                    # live instances
rvm scaleset list              # GitHub-side session, demand, advertised capacity
rvm runner list                # runner sessions
rvm metrics                    # counters; Prometheus endpoint if enabled in config
```

**Logs** — full reference in [`docs/logging.md`](docs/logging.md):

| path | what |
| --- | --- |
| `<state-dir>/logs/runnerd/runnerd.log` | the daemon's JSON log, self-rotating |
| `<state-dir>/logs/events.jsonl` | one line per lifecycle transition and audit event |
| `<state-dir>/logs/instances/<id>/` | per-instance `serial.log`, `worker.log`, `failure.json`, guest `diag/` |

**Changing configuration** — applied live, no restart:

```sh
rvm config validate runnervm.yaml && rvm config apply runnervm.yaml
```

**Maintenance and upgrades.** Always drain first; `--wait` blocks until the last job finishes:

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
| `doctor`: **FAIL Login keychain … locked** | Expected on a headless Mac, and on macOS 26.5.2 it did not stop any VM from booting. Only meaningful if VM starts actually fail. Run `doctor` as the service account for a truthful answer. |
| `doctor`: **WARN Disk headroom / could not read free space** | The purgeable-space figure is unavailable without a login session; the daemon falls back to plain available capacity. Harmless. |
| `doctor`: **FAIL GitHub credential missing** | Wrong path — it is `<state-dir>/**state**/github-token`, not the state root. |
| `runnerctl` says the daemon is unreachable, but it is running | You omitted `--socket`. `runnerctl`'s built-in default is the *development* socket `/tmp/runnervm-<uid>/runnerd.sock`, and there is no environment variable for it; a production install must pass `--socket /var/run/runnervm/runnerd.sock` (or whatever `--runtime-dir` you chose) on every call. Use the `rvm` shell function from step 6. |
| `rvm github test` fails on the scope | Token permissions. Administration: Read **and write** is the one people miss; without it the scale set cannot be created. |
| VM boots, job never starts | Check `<state-dir>/logs/instances/<id>/serial.log` and `worker.log`. A common cause is an image with no guest agent — `rvm image inspect <name>` reports `guest agent`, `doctor` flags it too, and tart-imported images never have one (`IMAGE_NO_GUEST_AGENT`). |
| `image build` fails with no Go | Install Go, or copy a prebuilt `GuestAgent/bin/linux-arm64/runnervm-guest-agent` in before running `install.sh`. |
| Everything worked, then stopped after a reboot | You never installed a launchd job (step 10), or the LaunchAgent's auto-login user did not log in — FileVault is the usual reason. |

Two commands worth knowing when you are stuck: `runnerctl doctor --deep` re-hashes every image
blob, and `rvm vm exec <id> -- <cmd>` runs a command inside a live guest.

---

## Where to go next

- [`docs/install.md`](docs/install.md) — every flag, the privilege model, the security notes
- [`docs/image-build.md`](docs/image-build.md) — the `Runnerfile` instruction set and your own images
- [`docs/live-integration.md`](docs/live-integration.md) — the E2E suite, if you want to prove your host
- [`docs/qualification.md`](docs/qualification.md) — the cold-boot / power-cut loop before production
- [`docs/status.md`](docs/status.md) — what is proven, what is experimental, current limitations
