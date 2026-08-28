# Project status — 2026-08-27

The single-page answer to "what does RunnerVM do today, how sure are we, and what is next".
`TODO.md` is the task-level tracker; `CHANGELOG.md` lists what landed when; `docs/verification.md`
holds the evidence behind every "live" claim below.

## Next milestone

Distribution hardening (milestone D) — contract in `docs/design/distribution.md`. Goal: a fresh
Apple Silicon Mac becomes a working runner host from one `curl … | sudo bash` — pkg install,
wizard, headless LaunchDaemon, GHCR-pulled Linux images with auto-update, native managed macOS
provisioning, manual-only upgrade. Tracked in `TODO.md` "D — Distribution hardening".

## What RunnerVM is

A self-hosted GitHub Actions runner orchestrator for one Apple Silicon Mac. `runnerd` turns
GitHub Runner Scale Set demand into ephemeral Linux/arm64 VMs (Apple Virtualization.framework),
one `vmworker` process per VM, a Go guest agent inside each guest over vsock, and `runnerctl` as the
operator CLI. Images are immutable, content-addressed, APFS-cloned per instance, and can be built on
the host, pulled from an OCI registry, or imported from tart.

## Capability matrix

| Area | State | Evidence |
| --- | --- | --- |
| Ephemeral Linux/arm64 runners from scale-set demand (JIT, one job per VM) | done | live on GitHub.com, 2026-08-26 (`docs/verification.md`) |
| Autoscaling / parallel jobs honouring advertised capacity | done | live, `fanout=5` on a 3-VM host |
| Reusable VMs (`lifecycle: reusable`, cleanup, taint, retire) | done, opt-in | requires `reuse.acknowledgeSharedHost: true`; HOME reset from a pristine snapshot; unit/integration tests only — single-tenant by design |
| Host mode control (drain / resume / offline / shutdown), metrics, Prometheus endpoint | done | tests; live (`system drain --wait` on an idle host fixed 2026-08-27) |
| Runner-session recovery after `runnerd` restart (re-observe or close out, at-most-once) | done | integration (15 cases) + live restart scenarios 2026-08-27 |
| Image-build recovery keeps capacity until the worker is proven dead; fault injection at every phase | done | integration (real `fcntl` locks, frozen-daemon harness); live kill -9 run in flight at hand-off |
| Bounded base-image cache | done | unit + hardware (cache hit on rebuild) |
| Image store (content-addressed, clonefile, pins, prune, provenance) | done | tests + live |
| OCI push/pull of RunnerVM images (GHCR-compatible transport, resumable, LZ4 chunks) | done | live 2026-08-27: built image pushed to GHCR, deleted, pulled back by manifest digest, booted, ran a job |
| Remote inspect without transferring the disk (`image inspect --remote`) | done | unit (FakeRegistry) + live 2026-08-28 against `ghcr.io/cirruslabs/{ubuntu,macos-tahoe-base}:latest`, anonymously |
| Prefetch profile images at config apply / daemon start (`images.prefetch`) | done, opt-in | unit (FakeRegistry): pulls, is off by default, skips local names, survives an unresolvable reference, repeats for free |
| Publishing prebuilt images (`scripts/publish-images.sh`, `docs/published-images.md`) | script + docs done | 51 shell assertions in CI; gate ladder dry-run against the four real local images. **Nothing published yet** — the push itself is unrun |
| **Tart image import** (`image pull ghcr.io/cirruslabs/…`, read-only, spec §58) | done | live: `ghcr.io/cirruslabs/ubuntu:latest` imported; refusal paths verified |
| **In-daemon image builder** (`runnerctl image build`, Runnerfile recipes) | done | live 2026-08-27: built image ran a real GitHub job (`scripts/live-builder-e2e.sh` 5/5) |
| Shipped recipes: `ubuntu-24-minimal`, `ubuntu-24`, `-node -python -go -jvm -rust -dotnet` | done | minimal + ubuntu-24 built live; language variants parse/plan-tested only |
| Legacy host-script builder (`scripts/build-ubuntu-image.sh`) | kept, legacy | live 2026-08-26 |
| Production install (`install.sh`, launchd, `_runnervm` service account) | done | `scripts/tests/install-test.sh`; **deployed 2026-08-28 on a Mac mini** (user-scoped, no root, headless over SSH) — `docs/verification.md` "Mac mini deployment". The launchd job itself and the `_runnervm` account still need root and are unrun there |
| **macOS guests (M8)** | runtime landed + hardened, **experimental** | `MacOSVMPlatform`, per-instance machine identifier (durable write), ephemeral-only, `resources.disk` must equal the image; live 2026-08-27: Tart `macos-tahoe-base` provisioned by `scripts/provision-macos-tart.sh`, imported, one GitHub JIT job on `rvm-macos-26` (23 s cold start), VM removed after the job. Hardening pass 2026-08-28: sealed images no longer carry `admin`/`admin` or SSH, a forced stop cannot seal, the LaunchDaemon fails closed, `vmworker` fences the 2-guest ceiling itself, `scripts/qualify-macos-image.sh` cold-boots a clone as the image gate. Still open: the H3–H5 live runs (concurrency, recovery, soak) and the native IPSW builder — `docs/macos-guests.md` |
| SSH provisioning of agent-less (tart) images | macOS only, script | `scripts/provision-macos-tart.sh` (one-shot image preparation over SSH, not a runtime dependency); Linux tart imports remain inspect/re-publish only |
| GitHub App authentication | done | tests against fakes |
| CI (Swift 6.1.2 on macOS 15 + Go + shellcheck) | green | flakes fixed at the root (`74ecb12`); every hardening push green after `4f214e2` |

Test suite: 1355 Swift tests / 172 suites (`swift test`), Go guest-agent tests (`go test -race`), install-script tests 21/21, qualify-host tests 53/53.

## What the last milestone added (M8 macOS guests, 2026-08-27/28)

- Identity plumbing: `MacOSInstancePlatformSpec` in `spec.json`, `machine-identifier.bin` minted by
  `vmworker` under the worker lock and reused on restart, image minimums enforced at admission
  (`VM_MACOS_PROFILE_CPU_TOO_SMALL` / `…_MEMORY_TOO_SMALL`), Tart `cpuCountMin`/`memorySizeMin` mapped.
- `MacOSVMPlatform` (`VZMacOSBootLoader`, `VZMacPlatformConfiguration`, `isSupported` check, one
  1920×1080 display with no window); `os: macos` profiles validate, `lifecycle: reusable` refused
  for macOS; `runnerctl image import --hardware-model`.
- `scripts/provision-macos-tart.sh`: turns a Tart macOS base into a RunnerVM image (runner account,
  guest-agent LaunchDaemon, `actions/runner` osx-arm64, empty git credential helper, sealed metadata).
- Live: cold boot, restart-keeps-identity, agent over vsock, GitHub JIT job end to end. Found and
  fixed live: Tart's `/Users/runner` symlink; profile names shadowing GitHub-hosted labels
  (`PROFILE_NAME_SHADOWS_HOSTED_LABEL`).
- Hardening pass (2026-08-28), from an external review of the landed runtime. Security and
  correctness, not features: the seal-time SSH lockdown (a sealed image no longer carries the Tart
  base's `admin`/`admin` or an enabled sshd); `resources.disk` on a macOS profile must equal the
  image's own disk, because a macOS guest cannot resize its APFS container
  (`VM_MACOS_DISK_RESIZE_UNSUPPORTED`); `PROFILE_NAME_SHADOWS_HOSTED_LABEL` promoted to an error
  with an explicit `allowHostedLabelShadowing` opt-out; `DurableFile.atomicReplace` under the
  machine identifier; a forced `tart stop` can no longer seal an image; the guest-agent
  LaunchDaemon fails closed; `MacOSGuestSlot` fences the 2-guest ceiling inside `vmworker`; the
  Tart payload is content-verified end to end. Plus two drivers:
  `scripts/qualify-macos-image.sh` (cold-boot a clone as the image gate) and
  `scripts/live-macos-e2e.sh` (concurrency, recovery matrix, soak, leak invariants).

## What the previous milestone added (M14 tart import + M15 image builder)

Plan: `~/.claude/plans/act-as-senior-swift-ticklish-garden.md` (independent Codex review integrated).

- `runnerctl image pull` detects tart's OCI format (`config.v1` + `disk.v2` LZ4 chunks + `nvram.v1`)
  and converts it into a native RunnerVM image; ASIF overlays, stacked disks, `disk.v1` and amd64
  are refused before any disk byte moves. Imported images are marked `guestAgent: false`, so
  `vm create` and `FROM` refuse them with `IMAGE_NO_GUEST_AGENT`.
- `Runnerfile`: Dockerfile *syntax* (`FROM ARG ENV RUN COPY USER WORKDIR SHELL LABEL`), VM semantics —
  every `RUN` executes inside a booted builder VM through the guest agent; `COPY` reads a tar-in-ISO
  build context; no layer cache, variants chain by `FROM` a previously built image.
- Bases: a pinned Ubuntu cloud **qcow2** (converted on the host by `QCOW2Reader`, bootstrapped with a
  cloud-init seed that only installs the guest agent) or any local RunnerVM image.
- Builds run inside `runnerd` (`image_builds` table, `build-image` operation, `AdmissionQueue` so
  builds and VMs share one capacity budget, hello-verified `BuilderWorker`, every-tick recovery with
  seal replay, push as a linked operation). Operator surface: `runnerctl image build`,
  `runnerctl build list|show|log|cancel`, `status` builds line, `doctor build_*`.
- Hardening that came with it: manifest/descriptor limits and bounded LZ4 decompression, a fixed
  vmworker `hardDeadline` that a live lease used to pre-empt, `image_aliases` (mutable name → digest),
  `image import --no-guest-agent`, schema v2 (one-way upgrade).

## Known limitations

- Per-`RUN` step ceiling of 30 minutes (guest agent clamp) — split long steps.
- No step-level build cache; the chain of images *is* the cache.
- `runnerd` must be able to read the recipe and context (`_runnervm` cannot read `$HOME`); use
  `<rootDir>/share/recipes` or `<rootDir>/recipes`.
- `hdiutil makehybrid` under a LaunchDaemon is gated by `doctor build_tools` /
  `build_tools_service_context`, not yet qualified on a LaunchDaemon.
- A failed session kept for diagnosis holds its instance's cpu/memory/disk reservation until
  `diagnostics.failedInstanceRetention` (2 h default) even though its VM is now shut down; lower the
  retention on small hosts. Sessions closed only by a daemon restart destroy their VM immediately.
- `ARG` values are not secrets (build row, provenance, pushed OCI config); there is no build-time
  secret mechanism yet (`docs/design/build-secrets.md`).
- A `runnerd` restart while a scale-set message session is still open on GitHub's side was once
  observed to take ~6 minutes before `runnerd ready`, silently; retried GitHub/Actions calls are now
  logged so the next occurrence explains itself.
- `image list` shows the manifest name, so two rows can share a name after a rebuild; `image inspect
  <name>` follows the alias to the newest.
- Base-image cache (`cache/base-images`) is bounded by `build.cache` (LRU, pins live builds, honours
  the disk reserve) — but the free-space check for *image pulls* still counts compressed bytes only.
- **`image list`'s `ON DISK` column overstates what deleting an image will free.** Blobs are
  content-addressed and materialized with `clonefile`, so a derived image shares APFS blocks with
  the base it was built `FROM`; both rows report the full allocation and `du` double-counts the
  shared extents. Measured 2026-08-28: deleting `ubuntu-24` (2.9 GiB) and `ubuntu-24-minimal`
  (2.5 GiB) plus a 1.85 GiB base cache returned **3.39 GiB**, not 7.21 GiB. Plan capacity from
  `df`, not from the sum of the `ON DISK` column.
- `config validate` flags an agentless profile image only once its *tag* has been resolved locally.

## Headless hosts (added 2026-08-28)

`runnerd` now runs correctly with **no GUI login session** — the state a LaunchDaemon, or any
unattended Mac nobody has logged into, is actually in. Two things that blocked it are fixed
(free-space accounting and the image builder's configuration; see `CHANGELOG.md`), and one
long-standing assumption did not reproduce: on macOS 26.5.2 Virtualization.framework booted every
VM with the service account's **login keychain locked**, which is the premise
`packaging/launchd/README.md` uses to call the LaunchDaemon variant experimental. `runnerctl
doctor`'s `Login keychain` check is a false negative on that host. This is one host and one OS
version, so it does not by itself qualify the LaunchDaemon variant — the reboot loop below is
still unrun — but it removes the reason to prefer the LaunchAgent path by default.

Two things bite on a multi-host or multi-account Mac and are not enforced anywhere:

- **Profile names must be unique per scope across hosts.** Two daemons pointing at one repository
  with the same profile name fight over the scale set's message session (`HTTP 409
  RunnerScaleSetSessionConflictException`); the incumbent keeps it, and whoever restarts loses.
- **`--group staff` is a real exposure on a shared Mac**, not a theoretical one. Use the dedicated
  `_runnervm` group whenever root is available.

## Open verification / next steps

1. LaunchDaemon (`_runnervm`) qualification: `sudo scripts/install.sh --launchd daemon`, then the
   10-reboot / cold-power-cycle loop in `docs/qualification.md` — **not run** (skipped on the
   operator's decision; the doctor/qualify tooling for it is in place and hardware-verified).
2. `scripts/live-builder-faults.sh`: finish the kill -9 run at `staging`/`booting`/`provisioning`/`sealing` (in flight at hand-off; `queued`/`resolving` are unobservable on a warm build).
4. Reusable-lifecycle HOME reset on a real VM (unit-tested in the guest agent only).
5. Build-time secrets (`docs/design/build-secrets.md`).
6. macOS guests: the hardening pass's own live runs — `scripts/qualify-macos-image.sh` against a
   re-provisioned image (H2), then `scripts/live-macos-e2e.sh` for the 2-concurrent-guest /
   third-job-waits test (H3, blocked only by free disk on the dev host — admission reserves the
   image's full virtual size per instance), the recovery matrix (H4) and the 100-short-jobs soak
   (H5). The native IPSW builder (M8.6) comes after those, not before. See `docs/macos-guests.md`.

## Developer quick start

```sh
swift build && scripts/sign-dev.sh
make -C GuestAgent build-linux
R=$HOME/runnervm-dev; mkdir -p $R/guest-agent/linux-arm64 /tmp/rvm
cp GuestAgent/bin/linux-arm64/runnervm-guest-agent $R/guest-agent/linux-arm64/
.build/debug/runnerd --foreground --state-dir $R --socket-dir /tmp/rvm &
.build/debug/runnerctl --socket /tmp/rvm/runnerd.sock image build images/recipes/ubuntu-24-minimal --name ubuntu-24-minimal
.build/debug/runnerctl --socket /tmp/rvm/runnerd.sock image build images/recipes/ubuntu-24 --name ubuntu-24
```
