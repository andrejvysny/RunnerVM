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

# 2. build -- every downloaded input is pinned and checksum-verified
scripts/build-ubuntu-image.sh \
  --base /path/to/ubuntu-24.04-server-cloudimg-arm64.raw \
  --base-sha256 <sha256 of that file> \
  --out  /path/to/out \
  --disk-gib 12

# 3. import + boot (the sealed metadata.json next to disk.img is adopted)
runnerctl image import /path/to/out/disk.img \
  --nvram /path/to/out/nvram.bin --os linux --name ubuntu-24
runnerctl image inspect ubuntu-24     # shows the provenance summary
runnerctl vm create --profile ubuntu-24
```

The build refuses to start without `--base-sha256` unless you pass
`--allow-unverified-base`, which is recorded as such in the sealed metadata. A
`--print-seed` run resolves every input and renders the cloud-init user-data
without launching anything, which is the cheapest way to see what a build would
actually do.

The base image must be a **raw** disk (GPT + EFI). Ubuntu ships `.img` files in
qcow2; convert them first — this host has no `qemu-img`, so M0 used
`lima-vm/go-qcow2reader`.

### Flags

| flag | default | meaning |
| --- | --- | --- |
| `--base <path>` | — | raw Ubuntu 24.04 arm64 cloud disk (never modified); required unless `--base-url` |
| `--base-url <url>` | — | download the base image into the cache instead of using a local file; requires `--base-sha256` |
| `--base-sha256 <hex>` | — | expected sha256 of the base image, verified before anything else runs |
| `--allow-unverified-base` | off | build from an unverified base image; logs a loud warning and records the observed digest |
| `--out <dir>` | — | where the sealed image lands (required except with `--print-seed`) |
| `--runner-version <v>` | `latest` | actions/runner version; `latest` is resolved **on the host** (`gh api`, else the REST API) and only the resolved version ever reaches the guest |
| `--runner-sha256 <hex>` | — | pin the runner tarball digest as the operator; must agree with GitHub's release asset digest when one exists, or the build stops (see [Verifiability and provenance](#verifiability-and-provenance)) |
| `--allow-unverified-runner` | off | when GitHub's release asset has no digest and no `--runner-sha256` was given, trust the host's own download hash instead of refusing; logs a loud warning and records `digestSource: "download"` |
| `--package-upgrade yes\|no` | `yes` | run a full `apt upgrade`; recorded in the manifest either way |
| `--docker-suite <name>` | `noble` | suite in the Docker apt repository line |
| `--guest-agent <path>` | — | use a prebuilt linux/arm64 guest agent instead of running `make -C GuestAgent build-linux` |
| `--print-seed` | off | resolve every input, render the user-data, print both, exit without launching a VM |
| `--disk-gib <n>` | `16` | virtual size of the built image; cloud-init `growpart` grows the root partition to fill it |
| `--cpus <n>` | `4` | builder VM vCPUs |
| `--memory-gib <n>` | `4` | builder VM memory |
| `--socket-dir <dir>` | `/tmp/rvm-build-<id>` | vmworker socket directory — keep it short, `AF_UNIX` paths cap at 104 bytes |
| `--no-sudo` | off | do not grant the `runner` account passwordless sudo |
| `--keep-build-dir` | off | keep `<out>/.build/<uuid>/` (builder disk, seed, serial.log, worker.log) |
| `--allow-partial-provenance` | off | seal the image even if the guest's `RVM-MANIFEST` block could not be recovered from `serial.log`; logs a loud warning and records `provenance.partial: true` |

`--allow-unverified-runner` and `--allow-partial-provenance` exist for recovering a
broken build environment, not for routine use. **Production builds must not pass
either flag** — an image sealed with one is only as trustworthy as the operator
who ran the build, not as GitHub's or the guest's own attestations.

`VMWORKER` overrides the vmworker path; `BUILD_TIMEOUT_MIN` (default 40) bounds
the guest run; `RUNNERVM_BUILD_CACHE` (default `~/.cache/runnervm-build`) is
where downloaded base images and runner tarballs are kept between builds.

## What the image contains

Baseline packages (spec §18): `git curl wget ca-certificates jq tar gzip
xz-utils zstd unzip zip rsync openssh-server build-essential python3
python3-pip pipx dnsutils iproute2 netcat-openbsd cloud-guest-utils`, plus a
full `apt upgrade` unless `--package-upgrade no`. The exact versions that landed
are recorded in `metadata.json` under `provenance.packages`.

* **Docker Engine** from the official Docker apt repository (`--docker-suite`,
  default `noble`, arm64):
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
build's `serial.log` to `<out>/build-serial.log` and the decoded guest manifest
to `<out>/build-manifest.json`, hashes the sealed disk, and writes
`metadata.json`.

## Verifiability and provenance

Nothing enters the guest unpinned. Before the builder VM starts, the host:

1. verifies the base image against `--base-sha256` (or refuses, unless
   `--allow-unverified-base`),
2. resolves `--runner-version latest` to a concrete release **on the host** —
   the string `latest` never reaches the guest, so two builds a week apart can
   never silently disagree about what "the runner" is,
3. resolves the *expected* sha256 of that release's arm64 tarball from
   **GitHub's own release asset metadata** (`GET
   repos/actions/runner/releases/tags/v<version>`, `assets[].digest`) — this is
   the trust anchor, not a hash of whatever an unauthenticated first download
   happens to contain,
4. downloads the tarball itself and verifies it against that digest *before*
   anything is rendered into cloud-init — a mismatch stops the build outright,
5. renders the runner URL *and* the verified digest into the cloud-init
   user-data, where the guest re-checks the same digest with `sha256sum -c`
   before extracting anything.

### Runner digest precedence and the two escape hatches

`--runner-sha256 <hex>` pins the digest as the operator. Precedence is strict
and never silent:

* no pin: the GitHub release asset digest is trusted, recorded as
  `provenance.actionsRunner.digestSource: "github-release-asset"`.
* a pin that **agrees** with the release asset digest: the operator's pin
  wins, recorded as `digestSource: "operator"`.
* a pin that **disagrees** with the release asset digest: hard error. The
  build refuses to guess which one is right.
* no pin, and GitHub has no digest for that asset (rare, but the API does not
  guarantee one for every release): the build refuses unless
  `--allow-unverified-runner` is passed, in which case it falls back to
  hashing its own download and records `digestSource: "download"`.

Similarly, a build whose guest never produced a usable `RVM-MANIFEST` block
(see below) fails closed — non-zero exit, the `serial.log` path, and a hint —
unless `--allow-partial-provenance` is passed, in which case it seals anyway
with `provenance.partial: true` and `provenance.partialReason` set.

**Neither `--allow-unverified-runner` nor `--allow-partial-provenance` belongs
in a production build.** They exist to get an operator unstuck (GitHub's API
unreachable, a genuinely digest-less release, a guest that crashed before
emitting its manifest) and are loud and recorded precisely so a sealed image
that used one is never mistaken for a fully-verified one.

### The guest manifest

Just before sealing, the guest emits a base64-encoded JSON blob on the console
between `RVM-MANIFEST-BEGIN` / `RVM-MANIFEST-END` markers, with `set -x` off so
no trace line can imitate a marker. The host takes the last complete pair out of
`serial.log`, keeps only base64-alphabet lines (kernel messages interleave), and
decodes it:

```json
{
  "runnerVersion": "2.331.0",
  "runnerSHA256": "…",
  "dockerVersion": "5:27.3.1-1~ubuntu.24.04~noble",
  "dockerRepository": "https://download.docker.com/linux/ubuntu noble stable",
  "kernelVersion": "6.8.0-51-generic",
  "guestAgentVersion": "runnervm-guest-agent v0.1.0 (linux/arm64)",
  "guestAgentSHA256": "…",
  "packages": ["adduser=3.137ubuntu1", "…"]
}
```

`packages` is `dpkg-query -W -f='${Package}=${Version}'` from the sealed
filesystem — the list a rebuild is diffed against. **A build whose console never
produced a usable block, or whose block decoded with no `packages`, fails
closed**: non-zero exit, unless `--allow-partial-provenance` was passed, in
which case it seals with `provenance.packages: null`, `provenance.partial:
true` and `provenance.partialReason` explaining why.

### The sealed `metadata.json`

`schemaVersion` stays **1**. `provenance` is a new optional object and every
field inside it is optional, so an image sealed before provenance existed still
decodes (`ImageMetadata.Provenance`, `Sources/RunnerCore/Models/ImageProvenance.swift`).

```json
{
  "schemaVersion": 1,
  "os": "linux",
  "architecture": "arm64",
  "diskFormat": "raw",
  "virtualDiskSizeBytes": 17179869184,
  "runnerVersion": "2.331.0",
  "guestAgentVersion": "v0.1.0-12-g3fb473c",
  "minimumHostOS": "15.0",
  "createdAt": "2026-08-26T10:00:00Z",
  "boot": { "type": "efi" },
  "capabilities": { "docker": true, "ssh": true },
  "provenance": {
    "baseImage": {
      "source": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img",
      "sha256": "sha256:ad7fac…"
    },
    "actionsRunner": {
      "version": "2.331.0",
      "sha256": "sha256:1111…",
      "url": "https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-arm64-2.331.0.tar.gz",
      "digestSource": "github-release-asset"
    },
    "guestAgent": {
      "gitCommit": "3fb473c50107af5909c377dd581e9ff8915b557c",
      "sha256": "sha256:2222…",
      "reportedVersion": "runnervm-guest-agent v0.1.0 (linux/arm64)"
    },
    "builder": {
      "gitCommit": "3fb473c50107af5909c377dd581e9ff8915b557c",
      "script": "scripts/build-ubuntu-image.sh",
      "hostOSVersion": "26.4",
      "builtAt": "2026-08-26T10:00:00Z"
    },
    "docker": {
      "repository": "https://download.docker.com/linux/ubuntu noble stable",
      "version": "5:27.3.1-1~ubuntu.24.04~noble"
    },
    "packageUpgrade": true,
    "packages": ["git=1:2.43.0-1ubuntu7", "…"],
    "kernelVersion": "6.8.0-51-generic",
    "diskSHA256": "sha256:3333…",
    "partial": false,
    "partialReason": null
  }
}
```

`provenance.actionsRunner.digestSource` is `"github-release-asset"`, `"operator"`
or `"download"` — see [Runner digest precedence](#runner-digest-precedence-and-the-two-escape-hatches)
above. `provenance.partial` is `true` only when `--allow-partial-provenance` was
needed to seal despite a missing or incomplete guest manifest, with
`provenance.partialReason` explaining why; both are absent (decode as `nil`/`false`)
on a normal, fully-verified build, and on any `metadata.json` sealed before these
fields existed.

`provenance.diskSHA256` is the **content identity the local image digest is
derived from**: `ImageStore` hashes `disk.img` into the `disk` layer digest, and
`LocalImageManifest.computeDigest` folds that layer digest together with the
sha256 of `metadata.json` to produce the `sha256:…` the daemon catalogues. Two
hosts that seal byte-identical disks *and* byte-identical metadata therefore end
up with the same image digest. (Hashing a 16 GiB sparse file costs a full read;
that is the one slow step at the end of a build.)

### Reproducing a build from a `metadata.json`

Everything the script needs is in the file:

```bash
m=/path/to/metadata.json
git checkout "$(jq -r .provenance.builder.gitCommit "$m")"
scripts/build-ubuntu-image.sh \
  --base-url    "$(jq -r .provenance.baseImage.source "$m")" \
  --base-sha256 "$(jq -r '.provenance.baseImage.sha256 | ltrimstr("sha256:")' "$m")" \
  --runner-version "$(jq -r .provenance.actionsRunner.version "$m")" \
  --runner-sha256  "$(jq -r '.provenance.actionsRunner.sha256 | ltrimstr("sha256:")' "$m")" \
  --package-upgrade "$(jq -r 'if .provenance.packageUpgrade then "yes" else "no" end' "$m")" \
  --docker-suite "$(jq -r '.provenance.docker.repository | split(" ")[1]' "$m")" \
  --out /path/to/out2
```

Then diff what came out:

```bash
diff <(jq -r '.provenance.packages[]' "$m") \
     <(jq -r '.provenance.packages[]' /path/to/out2/metadata.json)
```

Two caveats, both inherent rather than fixable here:

* **`--package-upgrade yes` is not reproducible.** It pulls whatever the Ubuntu
  archive holds today. Build with `--package-upgrade no` if you need the package
  set to be a function of the base image alone, and treat the recorded package
  list as the ground truth for what a given image actually contains.
* **`diskSHA256` will not match across two builds.** Timestamps, generated
  machine state and filesystem allocation order all differ. The package list,
  the runner digest, the base digest and the agent digest are the reproducible
  parts; the disk hash identifies *this* build's output.

### Immutable references

Provenance is only useful if a profile cannot silently change which image it
means. Pin the digest, not the tag:

```yaml
profiles:
  - name: linux
    image: ghcr.io/acme/runners/ubuntu-24@sha256:…   # not :stable
```

A tag is resolved to a digest before any VM starts and the *digest* is what
lands on the instance record (spec §21), so an incident stays reproducible even
after `:stable` moves — but the profile itself still points at a moving target,
and two hosts can be on different sides of a tag push. `runnerctl image inspect`
prints the resolved digest and the provenance summary together, which is the
pair to quote in an incident.

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

## Runner software freshness (spec §53)

The `runnerVersion` sealed into `metadata.json` is graded every six hours against
a recent window (up to 60) of published `actions/runner` releases. The 30-day
grace clock starts at the **first** release the image missed, not the newest
one GitHub has since published — a later release does not reset the clock:

| health    | meaning                                                        |
| --------- | -------------------------------------------------------------- |
| `healthy` | at or ahead of the latest release                                |
| `stale`   | behind, but the first release it missed is under 30 days old     |
| `tooOld`  | behind, and the first release it missed is 30+ days old — GitHub stops giving such a runner work |
| `unknown` | the image records no `runnerVersion`, or GitHub has not been read yet |

`runnerctl image list` shows it in the `RUNNER` column (`2.336.0 (stale)`),
`runnerctl status` counts it (`Cached  3 ready (1 stale, 0 too old)`), and
`runnerctl doctor` fails its `runner-version` check when a profile's image is
`tooOld`. Nothing here ever mutates an image — the fix is a rebuild.

```yaml
imageUpdates:
  denyTooOldRunner: true   # default false: refuse `vm create` from a tooOld image
```

With the switch off, the first `vm create` from a `tooOld` digest logs a warning
and proceeds. With it on, admission fails with `IMAGE_RUNNER_TOO_OLD` before
anything is cloned, and the orchestrator holds the profile down rather than
retrying every tick.

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

* **A sealed `metadata.json` is adopted whole or not at all.** `image import`
  reads the `metadata.json` sitting next to the disk (or the one named by
  `--metadata`) and keeps `runnerVersion`, `guestAgentVersion`, `capabilities`,
  `createdAt` and `provenance`; only `virtualDiskSizeBytes` is overwritten with
  the size the file actually has. A sibling file that describes a *different*
  guest OS is ignored with a warning and the metadata is synthesised instead —
  but an explicit `--metadata` that cannot be used is an error, because it is a
  claim the caller made. The daemon log says which path it took
  (`image metadata adopted from sealed metadata.json` /
  `image metadata synthesised`). The same facts stay readable inside the guest at
  `/etc/runnervm-image.json`.
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
  github.com). There is no offline mode; the host's own downloads are cached in
  `RUNNERVM_BUILD_CACHE`, the guest's are not.
* **The Ubuntu archive and the Docker repository are not pinned.** Only the base
  image, the runner tarball and the guest agent are. `provenance.packages`
  records what apt resolved to, which makes a drift visible after the fact but
  does not prevent it.
* x86_64 guests are not supported: Apple Virtualization is arm64-only.

## Debugging a failed build

The script fails if the guest never prints `RUNNERVM-BUILD-OK` on the console,
and dumps the tail of `serial.log`. Re-run with `--keep-build-dir` to hold on to
the builder disk, the seed and the full log. Inside the guest every provisioning
step is one `set -x` line from `/usr/local/sbin/runnervm-build.sh`, so the last
line before the failure is the command that failed.

A build that *does* reach `RUNNERVM-BUILD-OK` can still fail afterwards, at
sealing: if the host cannot recover a usable `RVM-MANIFEST` block from
`serial.log`, it exits non-zero with the log path and a hint rather than
sealing an image with unknown provenance (pass `--allow-partial-provenance` to
override, see [Verifiability and provenance](#verifiability-and-provenance)).

`--print-seed` renders the exact cloud-init user-data a build would use without
launching anything, which settles most "is the guest getting what I think it is"
questions in a second rather than in forty minutes.
`scripts/tests/build-ubuntu-image-test.sh` exercises the input verification, the
rendering, the console manifest extraction and the metadata composition — no VM,
no entitlement, no network.

Common causes: the Docker repo codename (`noble`) not matching the base image,
`apt` fighting `unattended-upgrades` for the dpkg lock (the script disables the
timers and passes `DPkg::Lock::Timeout=900`), and
`installdependencies.sh` probing `libicu80…75` before finding `libicu74` — those
`E: Unable to locate package` lines are expected and harmless.
