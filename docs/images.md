# Building the Ubuntu 24.04 arm64 runner image

`scripts/build-ubuntu-image.sh` turns a stock Ubuntu 24.04 arm64 cloud disk into
a RunnerVM base image: `disk.img` + `nvram.bin` + `metadata.json`, ready for
`runnerctl image import` (spec §18, §19, §60, §62).

Everything happens **inside a throwaway VM**. The host never mounts the guest
filesystem, never runs the guest agent locally, and never touches the base
image: the builder disk is an APFS `clonefile(2)` copy. Progress is visible on
the host only because the guest tees cloud-init's output to `/dev/hvc0`, which
`vmworker` captures into `serial.log` (spec §131).

```
Ubuntu cloud disk ──clonefile──▶ builder disk.img ──┐
GuestAgent (linux/arm64) ──┐                        ├──▶ vmworker run ──▶ guest
packaging/*.service        ├──▶ NoCloud seed.img ───┘        │ cloud-init
user-data (cloud-config)  ─┘   (ISO9660, label cidata)       │ poweroff
                                                             ▼
                              <out>/disk.img + nvram.bin + metadata.json
```

## Usage

```bash
# 1. a signed vmworker is required (VZ needs the virtualization entitlement)
swift build
scripts/sign-dev.sh

# 2. build
scripts/build-ubuntu-image.sh \
  --base /path/to/ubuntu-24.04-server-cloudimg-arm64.raw \
  --out  /path/to/out \
  --disk-gib 12

# 3. import + boot
runnerctl image import /path/to/out/disk.img \
  --nvram /path/to/out/nvram.bin --os linux --name ubuntu-24
runnerctl vm create --profile ubuntu-24
```

The base image must be a **raw** disk (GPT + EFI). Ubuntu ships `.img` files in
qcow2; convert them first — this host has no `qemu-img`, so M0 used
`lima-vm/go-qcow2reader`.

### Flags

| flag | default | meaning |
| --- | --- | --- |
| `--base <path>` | — | raw Ubuntu 24.04 arm64 cloud disk (required, never modified) |
| `--out <dir>` | — | where the sealed image lands (required) |
| `--runner-version <v>` | `latest` | actions/runner version; `latest` is resolved on the host via the GitHub API and pinned into the guest's user-data |
| `--disk-gib <n>` | `16` | virtual size of the built image; cloud-init `growpart` grows the root partition to fill it |
| `--cpus <n>` | `4` | builder VM vCPUs |
| `--memory-gib <n>` | `4` | builder VM memory |
| `--socket-dir <dir>` | `/tmp/rvm-build-<id>` | vmworker socket directory — keep it short, `AF_UNIX` paths cap at 104 bytes |
| `--no-sudo` | off | do not grant the `runner` account passwordless sudo |
| `--keep-build-dir` | off | keep `<out>/.build/<uuid>/` (builder disk, seed, serial.log, worker.log) |

`VMWORKER` overrides the vmworker path; `BUILD_TIMEOUT_MIN` (default 40) bounds
the guest run.

## What the image contains

Baseline packages (spec §18): `git curl wget ca-certificates jq tar gzip
xz-utils zstd unzip zip rsync openssh-server build-essential python3
python3-pip pipx dnsutils iproute2 netcat-openbsd cloud-guest-utils`, plus a
full `apt upgrade`.

* **Docker Engine** from the official Docker apt repository (`noble`, arm64):
  `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  docker-compose-plugin`, enabled at boot (spec §19).
* **GitHub Actions runner** in `/opt/actions-runner`, owned by `runner`, with
  `bin/installdependencies.sh` already run (spec §36).
* **`runner` account**, uid 1001, shell `/bin/bash`, member of `docker`,
  passwordless sudo unless `--no-sudo` (spec §37). The `docker` group is created
  by cloud-init *before* the user, because users are configured in the init
  stage long before the docker package exists.
* **Guest agent** at `/usr/local/bin/runnervm-guest-agent` with the packaged
  systemd unit enabled — this is what makes an instance reach `idle`.
* `/etc/runnervm-image.json` — `{runnerVersion, guestAgentVersion, builtAt}`.

Boot and network changes:

* `console=hvc0` appended to `GRUB_CMDLINE_LINUX_DEFAULT` via
  `/etc/default/grub.d/99-runnervm.cfg`. The stock cloud cmdline names only
  `tty1`/`ttyAMA0`, so without this `serial.log` stays empty on Apple
  Virtualization (spec §131).
* `serial-getty@hvc0.service` is masked. systemd's getty calls `vhangup(2)` when
  it takes the console, which invalidates every *other* process's open handle on
  `/dev/hvc0` — that silently truncated the build trace the moment the login
  banner appeared. A CI guest has no use for a console login, and masking keeps
  `serial.log` a pure diagnostic channel.
* `/etc/netplan/99-runnervm.yaml` matches `en*` with `dhcp4: true`, and
  cloud-init's `50-cloud-init.yaml` (pinned to the *builder's* MAC) is deleted.
  Every instance gets a fresh MAC, so a MAC-pinned netplan file would leave it
  without an address.

## Sealing (spec §62)

Inside the guest, before poweroff:

* hostname reset to `runnervm` (in `/etc/hostname` and `/etc/hosts`)
* `/etc/ssh/ssh_host_*` deleted; `runnervm-firstboot.service` (a `sysinit.target`
  oneshot running `ssh-keygen -A`, guarded by `ConditionPathExists=!…`)
  regenerates them per instance
* `/etc/machine-id` truncated to zero length — systemd regenerates it on first
  boot; `/var/lib/dbus/machine-id` re-pointed at it
* `touch /etc/cloud/cloud-init.disabled` — instances must not re-run cloud-init,
  and its datasource probing would otherwise cost boot time
* `apt-get clean`, `/var/lib/apt/lists`, `/var/log/journal`, `/tmp`, `/var/tmp`
  emptied, then `fstrim -av` so the sparse file stays small

On the host the script then moves `disk.img`/`nvram.bin` into `<out>`, copies the
build's `serial.log` to `<out>/build-serial.log`, and writes `metadata.json`.

## Profile snippet

```yaml
host:
  reserve:
    disk: 1GiB          # profile disk must fit in free - reserve

profiles:
  - name: ubuntu-24
    scope: local
    image: ubuntu-24    # the --name the image was imported under
    lifecycle: ephemeral
    resources:
      cpu: 2
      memory: 2GiB
      disk: 12GiB       # must be >= the image's virtual size
    ssh:
      enabled: true
    timeouts:
      agentReady: 3m
```

`profiles[].resources.disk` smaller than the image's virtual size is rejected at
admission. A *larger* value works, but nothing grows the filesystem
automatically any more (cloud-init is disabled): the host must call
`agent.resizeDisk` after boot.

## Publishing and pulling from a registry (M9)

A sealed image can live in any OCI registry (spec §21, §54–§58). References must
name their registry — RunnerVM never falls back to an implicit Docker Hub.

```bash
# credentials: the daemon owns the Keychain item, because runnerd does the pull
echo "$GHCR_PAT" | runnerctl registry login ghcr.io -u "$GITHUB_USER" --password-stdin
runnerctl registry status          # offline: which provider answers for which registry

runnerctl image push ubuntu-24 ghcr.io/acme/runners/ubuntu-24:stable
runnerctl image pull ghcr.io/acme/runners/ubuntu-24:stable
```

Credentials resolve per registry host, first match wins:
`RUNNERVM_REGISTRY_USERNAME` / `RUNNERVM_REGISTRY_PASSWORD` (optionally pinned
with `RUNNERVM_REGISTRY_HOSTNAME`), then `~/.docker/config.json` including
`credHelpers` / `credsStore`, then the Keychain. `registry login --local` writes
the *invoking user's* Keychain instead of the daemon's, which only helps when
runnerd runs as that same user.

A profile may point straight at a registry:

```yaml
profiles:
  - name: linux
    image: ghcr.io/acme/runners/ubuntu-24:stable
```

The tag is resolved to an immutable digest before any VM starts and the digest
— never the tag — is what lands on the instance record (spec §21), so an
incident stays reproducible after `:stable` moves. Consequences worth knowing:

* **The first `vm create` after the tag moves is as slow as the image is large.**
  Resolution and the pull happen inside `instance.create`. Pre-pull with
  `runnerctl image pull <ref>` to keep that cost off the first job.
* A tag → digest resolution is cached for five minutes per reference, so
  steady-state creates do not touch the registry at all.
* Concurrent pulls that resolve to the same manifest digest share **one**
  transfer and one `pull-image` operation (spec §137); `host.limits.concurrentImagePulls`
  bounds how many distinct transfers run at once.
* A pull refuses to start unless free space minus `host.reserve.disk` covers the
  compressed transfer size.
* An interrupted pull keeps its staging directory
  (`images/.tmp/pull-sha256-<hex>/`) and the next attempt resumes into it,
  re-fetching only the chunks that never verified (spec §119). The maintenance
  sweep skips a staging directory whose `pull-image` operation is still
  `running`, so a resumable pull is never swept out from under itself.
* `runnerctl image pull|push` wait for the operation by default and print a
  progress line on a terminal; `--no-wait` returns the operation id instead.

`images.canonical_reference` holds the immutable reference the image was
resolved from; `image list`'s `NAME` column keeps showing the local label from
the image manifest, which a later pull cannot move.

## Known limitations

* **`runnerctl image import` ignores `<out>/metadata.json`.** The daemon builds
  its own `ImageMetadata` from the disk size and `--os`
  (`Sources/Orchestration/ImageManager.swift:40`), so `runnerVersion`,
  `guestAgentVersion`, `capabilities` and `createdAt` do **not** survive the
  import. The file is written for provenance and for a future
  `image import --metadata`; the same facts are also readable inside the guest
  at `/etc/runnervm-image.json`.
* **No SSH keys are provisioned.** `sshd` listens (socket-activated) and
  `PasswordAuthentication` is off, so `runnerctl vm ssh --connect` cannot
  authenticate until an `authorized_keys` is injected.
* **`runnerctl vm ssh` may print the wrong address.** The guest agent sorts its
  addresses lexicographically, so docker0's `172.17.0.1` sorts ahead of the real
  NIC's `192.168.64.x` (`GuestAgent/internal/system/system.go:132`,
  `Sources/runnerctl/VMGuestCommands.swift:143`).
* **`/var/lib/cloud` is left in place.** Removing it while cloud-init is still
  executing its own final stage is not worth the risk; `cloud-init.disabled`
  makes it inert.
* The builder VM needs outbound network (Ubuntu archive, download.docker.com,
  github.com). There is no offline mode.
* x86_64 guests are not supported: Apple Virtualization is arm64-only.

## Debugging a failed build

The script fails if the guest never prints `RUNNERVM-BUILD-OK` on the console,
and dumps the tail of `serial.log`. Re-run with `--keep-build-dir` to hold on to
the builder disk, the seed and the full log. Inside the guest every provisioning
step is one `set -x` line from `/usr/local/sbin/runnervm-build.sh`, so the last
line before the failure is the command that failed.

Common causes: the Docker repo codename (`noble`) not matching the base image,
`apt` fighting `unattended-upgrades` for the dpkg lock (the script disables the
timers and passes `DPkg::Lock::Timeout=900`), and
`installdependencies.sh` probing `libicu80…75` before finding `libicu74` — those
`E: Unable to locate package` lines are expected and harmless.
