# Published images

Prebuilt RunnerVM images, published as OCI artifacts under
`ghcr.io/andrejvysny/runnervm`. A host that pulls one of these does not need the
guest-agent binary, a recipe root, or a builder VM — see [Using one](#using-one).

These are built on an Apple Silicon Mac and pushed with
[`scripts/publish-images.sh`](../scripts/publish-images.sh), either by hand or via
[`.github/workflows/publish-images.yml`](../.github/workflows/publish-images.yml) on a self-hosted
runner. There is no *hosted*-runner path that builds them and there cannot be one: GitHub-hosted
macOS runners cannot nest Virtualization.framework, so no hosted runner can boot the builder VM
([`.github/workflows/github-integration.yml`](../.github/workflows/github-integration.yml)).

## The catalogue

| Package | Guest | Virtual disk | Compressed | `actions/runner` |
| --- | --- | --- | --- | --- |
| `ubuntu-24-base` | Linux arm64 (Ubuntu 24.04 LTS) | 16.0 GiB (`17180000256` bytes) | ~2.9 GiB | 2.337.0 |

macOS is deliberately **not** published here — see [macOS guests](#macos-guests-not-published).

> **Digests are not listed here on purpose.** A tag is a moving target and a digest goes stale the
> moment an image is rebuilt. Read the current one from the registry — `runnerctl image pull
> <ref>:stable` prints the immutable `…@sha256:…` it resolved, and that is what belongs in a
> profile. The publish run's own JSON report records the same value as `pushedReference`.

### `ubuntu-24-base`

Built from [`images/recipes/ubuntu-24`](../images/recipes/ubuntu-24/Runnerfile), which is
`FROM ubuntu-24-minimal` — so it is the whole family root plus Docker, in one image:

- Ubuntu 24.04 LTS (noble) arm64, from the official dated cloud image, sha256-verified before the
  build starts;
- `actions/runner` for `linux-arm64`, unpacked at `/opt/actions-runner`, owned by `runner`
  (uid 1001), with `installdependencies.sh` already run and the release digest reconciled against
  GitHub's own asset metadata;
- Docker Engine, CLI, containerd, buildx and compose from `download.docker.com`, enabled at boot,
  with `runner` in the `docker` group;
- git, curl, wget, jq, tar/gzip/xz/zstd/unzip/zip, rsync, build-essential, python3 + pipx,
  openssh-server, dnsutils, iproute2, netcat, cloud-guest-utils — 743 packages in total;
- `git config --system credential.helper ""`, so no future package can reintroduce a helper that
  would block an ephemeral runner forever;
- `runner ALL=(ALL) NOPASSWD:ALL`;
- the RunnerVM guest agent as a systemd unit, talking to the host over vsock.

`capabilities.ssh: true` here means only that socket-activated `sshd` is installed. **No SSH keys
are provisioned and `PasswordAuthentication` is off** — nothing can authenticate until an
`authorized_keys` is injected. The control plane is vsock; SSH is a debugging convenience
(`runnerctl vm ssh`).

## macOS guests: not published

There is no `macos-26-base` package, and there will not be one. A RunnerVM macOS image is a
provisioned copy of Apple's macOS; Apple's SLA grants the right to *run* macOS VMs on Apple
hardware, not to redistribute macOS. So each host builds its own, once, from the upstream Tart base.

```bash
tart pull ghcr.io/cirruslabs/macos-tahoe-base:latest
scripts/provision-macos-tart.sh          # --help for the flags
```

`scripts/provision-macos-tart.sh` clones that base, creates a `runner` account, installs the
RunnerVM guest agent as a root LaunchDaemon and `actions/runner` for `osx-arm64`, sets
`git config --global credential.helper ""` as `runner`, then runs the **seal-time lockdown**:
rotates the base image's `admin`/`admin` password to a discarded random value, removes every
`authorized_keys`, disables `sshd` in the persistent override database and turns Remote Login off.
The sealed metadata records `capabilities.ssh: false` as the proof that ran. It ends by importing
the result into the local image store.

Two things worth knowing before you start:

- **RunnerVM can also `image pull` the Tart base directly** — `runnerctl image pull
  ghcr.io/cirruslabs/macos-tahoe-base:latest --format tart` — but that import is **read-only**. It
  carries no RunnerVM guest agent, so `capabilities.guestAgent: false` and every path that would
  boot it refuses with `IMAGE_NO_GUEST_AGENT`. It is for inspection and re-publishing, never for
  running a job. The provisioning script above is the path that produces a runnable image.
- **macOS guests are experimental.** The runtime has run real GitHub jobs, but the concurrency,
  recovery and soak runs (H3–H5) are not recorded, at most two macOS guests run per host, and
  `lifecycle: reusable` is refused. Read [`docs/macos-guests.md`](macos-guests.md) first.

The sizing and disk-contract rules below still apply to whatever that produces.

## Using one

```bash
# 1. Look before you pull: the digest to pin, the size the profile must ask for, and what
#    is inside — read from the registry, without transferring the disk.
runnerctl image inspect --remote ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable

# 2. Pull it.
runnerctl image pull ghcr.io/andrejvysny/runnervm/ubuntu-24-base:stable

# 3. Point a profile at the digest, never the tag.
```

```yaml
profiles:
  - name: ubuntu-24            # this IS the runs-on label; it must not collide with a
    scope: repo                # GitHub-hosted label (ubuntu-24.04, macos-26, ...)
    image: ghcr.io/andrejvysny/runnervm/ubuntu-24-base@sha256:…
    lifecycle: ephemeral
    resources:
      cpu: 2
      memory: 4GiB
      disk: 16GiB              # >= the image's virtual size
```

A profile may name the tag instead — RunnerVM resolves it to a digest before any VM starts, and the
*digest* is what lands on the instance record, so an incident stays reproducible. But the profile
itself then points at a moving target, and two hosts can end up on different sides of a tag push.
Pin the digest.

### Sizing the host

Concurrency is bounded by **disk**, not CPU or RAM. An instance reserves
`max(profile.resources.disk, image.virtualBytes)`:

| Guest | Free disk one VM needs |
| --- | --- |
| `ubuntu-24-base` | 16 GiB + `host.reserve.disk` — a Mac with ~62 GiB free runs about 3 |
| a locally provisioned macOS image | ~80 GiB: a macOS guest cannot resize its APFS container, so it reserves the **entire** virtual disk (46.6 GiB for the Tahoe base) on top of the ~30.6 GiB the image occupies |

`host.overcommit.disk` relaxes the reservation for guests whose disks stay sparse; read what it
trades away before enabling it.

macOS additionally demands `resources.disk` **equal** the image's virtual size exactly
(`VM_MACOS_DISK_RESIZE_UNSUPPORTED`) — for the Tahoe base that is `50000000000`, not `50GB` rounded
some other way — and refuses a profile below the image's own `minimumCPUCount` / `minimumMemoryBytes`
(2 vCPU / 4 GiB there). `runnerctl image inspect` prints the exact figures. At most two macOS guests
run per host, fenced twice ([`docs/macos-guests.md`](macos-guests.md)).

### The first pull is as slow as the image is large

Resolution and transfer happen inside `instance.create`, so without a pre-pull the first job after
a config change waits for the whole download and looks like a runner failure. Either pull
explicitly before the profile goes live:

```bash
runnerctl image pull <ref>@sha256:…      # then apply the configuration
```

…or let the daemon do it, which is the right setting for a host whose profiles all point at a
registry:

```yaml
images:
  prefetch: true    # pull every profile's registry image at config apply and at daemon start
```

Either way an interrupted pull resumes: the staging directory is kept and only chunks that never
verified are re-fetched.

## Tags

| Tag | Meaning |
| --- | --- |
| `<yyyy-mm-dd>` | the build date; immutable in practice, the tag to quote in a changelog |
| `r<version>` | which `actions/runner` is baked in, e.g. `r2.337.0` |
| `stable` | moving — points at the newest build. Never reference it from a profile. |
| `v1` | moving — the major channel; walks forward across every v1.x rebuild the same way `stable` does. Kept distinct from `stable` so a future breaking change gets a `v2` without disturbing `stable`'s meaning. |

## Automatic updates on hosts

A host does not have to notice a stale image by hand. With `images.updates.enabled: true`, it
re-resolves every tracked reference — `:stable` on a profile, or a managed macOS source — on an
interval (`images.updates.interval`, jittered by `images.updates.jitter` so a fleet does not all
check in lockstep), pulls whatever digest that tag now points at, qualifies the candidate with the
same smoke test a manual build or pull would run, and only then promotes it: the local alias is
repointed at the new digest in one atomic step.

Two invariants that follow from this, spelled out fully in
[`docs/design/distribution.md`](design/distribution.md) ("Update invariants"):

- **An update never terminates a running VM.** An existing instance keeps the digest it was created
  with; nothing forces it onto the newly promoted one.
- **A failed update never replaces the currently promoted image.** A download, verify, or
  qualification failure leaves the alias exactly where it was — the failure is recorded and retried
  on the next interval, not surfaced as an outage.

`runnerctl setup`'s wizard and `install.sh` default a fresh profile to `image: …:stable` with
`images.updates.enabled: true` — a new install stays current with no operator intervention, while
every VM already running keeps the digest it booted with until its own lifecycle recycles it.

## These images are perishable

The `actions/runner` version is sealed in at build time and graded against published releases
(`runnerctl image list`'s `RUNNER` column). Thirty days after the **first** release an image
missed, it is `tooOld` and GitHub stops giving it work — a later release does not reset that clock.
Nothing mutates an image to fix this; the fix is a rebuild and a republish.

So: rebuild and republish monthly, or on an `actions/runner` release. A puller should set

```yaml
imageUpdates:
  denyTooOldRunner: true    # refuse `vm create` from a tooOld image rather than warn
```

which fails admission before anything is cloned, instead of letting a job start on a runner GitHub
will ignore.

## Publishing (maintainer)

The automated path is
[`.github/workflows/publish-images.yml`](../.github/workflows/publish-images.yml): dispatch it by
hand (choose `package`/`recipe`/an optional extra tag) or let its monthly schedule fire. It runs on
a self-hosted, bare-metal `runnervm-publisher`-labelled machine — the same "no hosted macOS runner
can nest Virtualization.framework" constraint as everywhere else in this document, spelled out in
the workflow's own header comment — builds the recipe, derives the `r<version>` tag from the
build's own `actions/runner`, and pushes `<date>`/`r<version>`/`stable`/`v1` with
[`scripts/publish-images.sh`](../scripts/publish-images.sh), uploading its JSON report as a build
artifact. It assumes the publisher machine already has RunnerVM installed, `runnerd` running, and a
ghcr.io credential stored; it does not create any of those, and it does not do the one-time package
setup below — see the runbook.

The underlying commands, for a one-off push or to debug a workflow failure by hand:

```bash
echo "$GHCR_PAT" | runnerctl registry login ghcr.io -u <user> --password-stdin

scripts/publish-images.sh --image ubuntu-24 --package ubuntu-24-base \
  --repo ghcr.io/andrejvysny/runnervm \
  --tag "$(date -u +%Y-%m-%d)" --tag r2.337.0 --tag stable --tag v1 --dry-run
```

Drop `--dry-run` to push. The script refuses an image that is not `ready`, one with no guest agent,
a macOS image that kept its SSH credential, a `-dirty` guest-agent build, and an `actions/runner`
already graded `stale`/`tooOld`; each refusal names the flag that overrides it. The first tag
uploads every chunk, the rest reuse those blobs. (The macOS SSH refusal is kept even though no
macOS image is published from here — it is the check that would matter if one ever were.)

### First publish of a new package (operator runbook, once)

Neither the workflow above nor a bare `scripts/publish-images.sh` invocation can make a brand-new
package (`ubuntu-24-base` today) pullable on its own — someone has to do this once, by hand:

1. **Log in**, with a PAT scoped `write:packages`, on the machine that will run the publish:
   ```bash
   echo "$GHCR_PAT" | runnerctl registry login ghcr.io -u <user> --password-stdin
   ```
2. **Run the publish** — the manual command above with `--dry-run` dropped, or a dispatch of
   `publish-images.yml`.
3. **Make the package public**, in the GitHub package's settings: new packages default to
   **private**, and anonymous `runnerctl image pull` only works once it is public.
4. **Connect it to this repository**, in the same settings page: RunnerVM's manifest carries its
   own annotations plus `org.opencontainers.image.created`, not `org.opencontainers.image.source`,
   so the package↔repo link is not inferred and has to be set by hand.

Steps 3 and 4 are per-*package*, not per-push: once `ubuntu-24-base` is public and connected, every
later publish — scripted or via the workflow — reuses the same settings without repeating them.

Prove the round trip with the driver that already covers it end to end — build, real GitHub job,
push, delete the local copy, pull back by immutable digest, second job on the re-pulled image:

```bash
scripts/live-builder-e2e.sh --recipe images/recipes/ubuntu-24 --name ubuntu-24-base \
  --registry ghcr.io/andrejvysny/runnervm/ubuntu-24-base --profile ubuntu-24 …
```
