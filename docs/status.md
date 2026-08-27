# Project status — 2026-08-27

The single-page answer to "what does RunnerVM do today, how sure are we, and what is next".
`TODO.md` is the task-level tracker; `CHANGELOG.md` lists what landed when; `docs/verification.md`
holds the evidence behind every "live" claim below.

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
| Reusable VMs (`lifecycle: reusable`, cleanup, taint, retire) | done | unit/integration tests against fakes only |
| Host mode control (drain / resume / offline / shutdown), metrics, Prometheus endpoint | done | tests; manual round trip |
| Image store (content-addressed, clonefile, pins, prune, provenance) | done | tests + live |
| OCI push/pull of RunnerVM images (GHCR-compatible transport, resumable, LZ4 chunks) | done | tests against `FakeRegistry`; live pull of a tart image on 2026-08-27 exercises the same transport |
| **Tart image import** (`image pull ghcr.io/cirruslabs/…`, read-only, spec §58) | done | live: `ghcr.io/cirruslabs/ubuntu:latest` imported; refusal paths verified |
| **In-daemon image builder** (`runnerctl image build`, Runnerfile recipes) | done | live: `ubuntu-24-minimal` 3m43s cold, `ubuntu-24` 1m16s, VM boots to `idle` in 5 s |
| Shipped recipes: `ubuntu-24-minimal`, `ubuntu-24`, `-node -python -go -jvm -rust -dotnet` | done | minimal + ubuntu-24 built live; language variants parse/plan-tested only |
| Legacy host-script builder (`scripts/build-ubuntu-image.sh`) | kept, legacy | live 2026-08-26 |
| Production install (`install.sh`, launchd, `_runnervm` service account) | done | `scripts/tests/install-test.sh`; not yet run on a dedicated Mac mini |
| macOS guests | not implemented | `os: macos` rejected (`GUEST_OS_UNSUPPORTED`); plan in `docs/macos-guests.md` |
| SSH provisioning of agent-less (tart) images as build bases | not implemented | tart imports are inspect/re-publish only |
| GitHub App authentication | done | tests against fakes |
| CI (Swift 6.1.2 on macOS 15 + Go + shellcheck) | green | run 33063743404 on `0c15077`; two timing-sensitive suites still flake under load occasionally |

Test suite: 1206 Swift tests / 155 suites (`swift test`), 70 Go tests, install-script tests 21/21.

## What the last milestone added (M14 tart import + M15 image builder)

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
- `hdiutil makehybrid` under a LaunchDaemon is gated by `doctor build_tools`, not yet qualified.
- `image list` shows the manifest name, so two rows can share a name after a rebuild; `image inspect
  <name>` follows the alias to the newest.
- Base-image cache (`cache/base-images`) is bounded by `build.cache` (LRU, pins live builds, honours
  the disk reserve) — but the free-space check for *image pulls* still counts compressed bytes only.
- `config validate` flags an agentless profile image only once its *tag* has been resolved locally.

## Open verification / next steps

1. Run a real GitHub job on a `runnerctl image build`-produced image (needs a PAT/App on the host).
2. Qualify the production LaunchDaemon path on a dedicated Mac mini (`docs/qualification.md`),
   including `image build` as `_runnervm`.
3. `--push` of a built image to GHCR with a real token (transport proven only against fakes + tart pull).
4. De-flake `RunnerSessionTests` / `ReusableLifecycleTests` under CI load.
5. macOS guests (M8) — tart macOS import already parses; needs the platform builder + SSH provisioning.

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
