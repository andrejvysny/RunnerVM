# Setting up RunnerVM on a fresh Mac

End-to-end: from a Mac you just unboxed to GitHub Actions jobs running in throwaway VMs on it,
registered against either an **organization** or a single **repository**.

- Reference for every install flag, the privilege model and the security model: [`docs/install.md`](docs/install.md)
- Building from source and running a local dev daemon: [`docs/developer-setup.md`](docs/developer-setup.md)
- A real deployment's configuration, verbatim, with the reasoning behind each number:
  [`docs/examples/headless-mac-mini.yaml`](docs/examples/headless-mac-mini.yaml)
- What has actually been proven, and what has not: [`docs/verification.md`](docs/verification.md),
  [`docs/status.md`](docs/status.md)

> **v0.2.0 is unreleased.** Part 1 below — the curl one-liner and the wizard — is what a tagged
> release ships. Until then, use [`docs/developer-setup.md`](docs/developer-setup.md) (Part 2).

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

### Decide two things now

| decision | options | how to choose |
| --- | --- | --- |
| **Scope** | organization / repository | An org scope serves every repo in the org and needs `admin:org`-grade credentials — a host-wide compromise if the Mac is breached. A repository scope is narrower and is the right default for a first host. |
| **Credential** | PAT / GitHub App | A PAT is 5 minutes of setup. A GitHub App is better for an org (scoped, rotatable, auditable) and is worth it once you are past the first host. |

Service model (headless LaunchDaemon vs. GUI LaunchAgent) is a wizard question, not something to
decide up front — see "The wizard" below.

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
> about **80 GiB free** for one guest with a Tart-derived image. macOS guests are also still
> experimental; see [`docs/macos-guests.md`](docs/macos-guests.md).

---

## Part 1 — One-command install (from the first tagged release)

### 1. Get a GitHub credential first

The wizard asks for one, so create it before you start.

**Fine-grained PAT (recommended for a repository scope)** — GitHub → Settings → Developer
settings → Personal access tokens → Fine-grained tokens:

- **Resource owner**: the user or org that owns the repo
- **Repository access**: *Only select repositories* → just the one
- **Repository permissions**: Administration — **Read and write**; Actions — **Read and write**
  (Read is enough unless you also run the E2E driver, which cancels runs); Metadata — Read-only

**Classic PAT**: `repo` scope for a repository, `admin:org` for an organization. Both are broad —
an `admin:org` token on a compromised Mac is an org-wide compromise, which is the argument for a
GitHub App on any org.

**GitHub App (recommended for an organization)**: an App owned by the org, installed on the org (or
selected repos), with **Administration: Read and write**, **Actions: Read**, **Metadata: Read**.
The wizard's non-interactive PAT flow does not cover App credentials yet — write
`<state-dir>/state/github-app.json` by hand afterwards; see [`docs/install.md`](docs/install.md).

### 2. Prepare the host

Apple Silicon, macOS 15 or later. No Xcode, Swift, Go, or Homebrew needed — the pkg ships
everything prebuilt.

```sh
# The host must not sleep out from under a running VM
sudo pmset -a sleep 0 disksleep 0 displaysleep 10

# Confirm
sw_vers
df -h /System/Volumes/Data
pmset -g | grep -E ' sleep|disksleep'
```

If this Mac is shared with other accounts, know that every local macOS user is in the `staff`
group — the installer never uses it for RunnerVM's own state (see [`docs/install.md`](docs/install.md)).

### 3. Install

```sh
curl -fsSL https://github.com/andrejvysny/RunnerVM/releases/latest/download/install.sh | sudo bash
```

This downloads the release manifest, the pkg and its `.sha256`, verifies the checksum, prints an
unsigned-package warning and waits for confirmation on `/dev/tty` (the pkg is not yet
Developer-ID-signed — `RUNNERVM_ALLOW_UNSIGNED=1` skips the prompt for non-interactive runs),
installs immutable files only under `/usr/local/{bin,libexec,share}/runnervm`, and hands off to
`runnerctl setup` on the same tty. `RUNNERVM_NO_SETUP=1` stops after the pkg install if you want to
run the wizard yourself later; `RUNNERVM_VERSION=vX.Y.Z` or `RUNNERVM_PKG_URL=<dir>` pin a specific
release instead of latest.

### 4. The wizard (`runnerctl setup`)

Answers a short set of questions and does everything else: creates the hidden `_runnervm` service
account (`dscl` only — no `sysadminctl`, no interactive password, no real home under `/Users`),
lays out the state directory, writes `config.yaml`, installs and loads the launchd job, stores the
GitHub token, pulls the Linux image, applies the profiles **after** the image is ready, and finishes
with `doctor` plus a smoke test. It is re-runnable — an existing account, directory or plist is
verified, not recreated.

| Question / flag | What it controls |
| --- | --- |
| `--mode daemon\|agent` | Headless LaunchDaemon (default, recommended) or a LaunchAgent in a GUI session. |
| scope | `org:<owner>` or `repo:<owner>/<repo>`. |
| `--runner-group` | Runner group for an organization scope (`Default` otherwise). |
| GitHub token | Read without echo, or `--token-stdin` to pipe it in. |
| `--linux` / `--no-linux` | Create the Linux runner profile (on by default). |
| `--macos` | Also declare a macOS runner profile, provisioned via the managed-image flow — see [`docs/macos-guests.md`](docs/macos-guests.md). |
| `--macos-source` | The Tart base to track (default `ghcr.io/cirruslabs/macos-tahoe-base:latest`). |
| `--linux-concurrency` / `--macos-concurrency` | Concurrent runners per guest family; macOS is capped at 2. |
| `--profile-prefix` | Overrides the generated `rvm-<host6>-*` prefix (see "Labels" below). |
| `--dry-run` | Prints the plan and the generated YAML; changes nothing. |
| `--non-interactive` | Takes every answer from flags instead of prompting; requires `--scope`. |

Needs root (the account creation and `/Library` writes require it) unless `--dry-run`.

### 5. `sudo runnerctl`, no flags needed

A production install's socket is discovered automatically — flag > `RUNNERVM_SOCKET`/
`RUNNERVM_STATE_DIR`/`RUNNERVM_RUNTIME_DIR` > the production path if it exists > the development
path. `runnerd` also accepts RPC from uid 0, so this just works once setup finishes:

```sh
sudo runnerctl status
sudo runnerctl vm list
sudo runnerctl scaleset list
```

### 6. Labels

The wizard's generated profile names are `rvm-<host6>-ubuntu-24` / `rvm-<host6>-macos-tahoe`, where
`host6` is derived from this Mac's `IOPlatformUUID` — stable across reboots and reinstalls, so two
hosts registered against the same GitHub scope never collide on a scale-set message session (the
scale set has exactly one; the second host to connect gets `HTTP 409
RunnerScaleSetSessionConflictException`). A profile's name **is** its `runs-on` label. The wizard
prints the sample to use, e.g.:

```yaml
runs-on: rvm-a1b2c3-ubuntu-24
```

### 7. Verify with a real job

```yaml
name: RunnerVM smoke test
on: workflow_dispatch
jobs:
  smoke:
    runs-on: rvm-a1b2c3-ubuntu-24   # your generated label
    steps:
      - run: uname -a && id && docker info
      - uses: actions/checkout@v4
```

Trigger it and watch `sudo runnerctl vm list` walk `cloning → … → idle → … → busy → deleted` and
disappear — that disappearance, and nothing left under `<state-dir>/instances/`, is the whole point
of `ephemeral`.

### 8. Smoke-testing after that

`runnerctl system smoke-test` boots a pinned instance of a profile and proves the guest actually
works (agent hello, `sw_vers`/`uname`, `agent.selfTest`), independent of live GitHub demand — the
same check `setup` runs at the end and `doctor --deep` folds in. Useful after a config change, an
image update, or just to confirm a host you have not touched in a while is still healthy.

### 9. Keeping images current

```yaml
images:
  updates:
    enabled: true
    interval: 24h
    jitter: 2h
    keepPrevious: 1
    smokeTest: true
```

With this on, the host re-resolves every tracked registry tag (`:stable` on a profile) or managed
macOS source on the interval, pulls the candidate, qualifies it with a boot-to-idle smoke test, and
only then promotes it — atomically, and only for **new** instances: a VM already running keeps the
digest it was created with. A failed candidate (download, verify, or qualification failure) never
replaces what is currently promoted; the failure is recorded and retried next interval.

```sh
runnerctl image update status          # every tracked source, its state, when it last moved
runnerctl image update check           # re-resolve now, transfer nothing
runnerctl image update run --wait      # pull + qualify + promote now; --no-wait to fire and forget
```

The wizard defaults a fresh Linux profile to `image: …:stable` with `images.updates.enabled: true`,
so a new install stays current without operator intervention.

### 10. Upgrading

```sh
runnerctl upgrade --check          # report installed vs. released version; no root, changes nothing
sudo runnerctl upgrade             # --version vX.Y.Z for a specific tag, --drain-timeout 30m (default),
                                    # --yes/-y to answer every confirmation including the unsigned-pkg one
```

Manual only — nothing on the host upgrades itself. Fetches `release-manifest.json`, verifies the
pkg against both its detached `.sha256` and the manifest's own hash (any failure aborts before the
host is touched), backs up `config.yaml` and the database, drains the host, swaps the package,
restarts the daemon, and runs `doctor`. If `doctor` fails afterward and the database schema has not
advanced, the cached previous package and the backup are restored automatically; if the schema did
advance, migrations are one-way and manual restoration steps are printed instead. Full contract:
[`docs/design/distribution.md`](docs/design/distribution.md) ("Upgrade policy").

> **This command landed very recently.** It has not yet been exercised on real hardware — verify
> the flags above against `runnerctl upgrade --help` on your build before relying on this section.

---

## Part 2 — From source (development)

This repository is built and tested from source, not from the pkg. If you are developing RunnerVM
itself, or want a from-source install before a release exists:
**[`docs/developer-setup.md`](docs/developer-setup.md)** — `swift build`, `scripts/sign-dev.sh`,
building the Go guest agent, and running a local dev daemon.

`runnerctl setup` (Part 1, step 4) works the same way against source-built binaries — it only
cares that `runnerctl`/`runnerd`/`vmworker` exist where it expects them, not how they got there.

---

## Rules the validator enforces

| rule | why |
| --- | --- |
| A profile name must not match a GitHub-hosted label | `runs-on: macos-26` or `ubuntu-24.04` sends the job to GitHub's hosted runners instead of your Mac — different billing, secrets and network, with nothing on your host to show for it. Refused as `PROFILE_NAME_SHADOWS_HOSTED_LABEL`. Shadowing names are `ubuntu-latest`/`macos-latest`/`windows-latest`, `macos-<N>`, `ubuntu-<N>.<N>`, `windows-<NNNN>` (± `-large`/`-xlarge`/`-arm64`…). The wizard's generated `rvm-<host6>-*` names are already clear of this. |
| `lifecycle: reusable` needs `reuse.acknowledgeSharedHost: true` | A reusable VM keeps state a job can write anywhere it can `sudo`. Treat it as single-tenant. **Use `ephemeral` in production.** |
| `security.allowPublicRepositories` defaults off | Turning it on means pull-request code from strangers can execute on your Mac. Only for a dedicated, disposable host. |
| **One host per profile name, per scope** | Not validated — nothing can see your other Macs. A scale set has exactly one message session, so two hosts sharing a scope *and* a profile name fight over it (`HTTP 409 RunnerScaleSetSessionConflictException`) and whichever restarts loses its jobs to the other. The wizard's `IOPlatformUUID`-derived names exist specifically to avoid this; a manual `--profile-prefix` can still collide. |

Check a config before applying it:

```sh
runnerctl config validate <path>
```

---

## Where to go next

- [`docs/install.md`](docs/install.md) — every flag, the privilege model, the security notes
- [`docs/developer-setup.md`](docs/developer-setup.md) — building from source, dev daemon
- [`docs/published-images.md`](docs/published-images.md) — the prebuilt images and sizing a host for one
- [`docs/image-build.md`](docs/image-build.md) — the `Runnerfile` instruction set and your own images
- [`docs/macos-guests.md`](docs/macos-guests.md) — native managed macOS provisioning, the CI keychain, what is still hardware-pending
- [`docs/live-integration.md`](docs/live-integration.md) — the E2E suite, if you want to prove your host
- [`docs/qualification.md`](docs/qualification.md) — the cold-boot / power-cut loop before production
- [`docs/status.md`](docs/status.md) — what is proven, what is experimental, current limitations
