# macOS guest runners (M8)

**Status: runtime landed and proven once live (M8.0–M8.4), not yet qualified.** `os: macos`
profiles validate, `vmworker` boots a macOS guest from a `VZMacPlatformConfiguration`, every
instance has its own machine identifier, and on 2026-08-27 a Tart-derived macOS 26.6.2 image ran a
real GitHub Actions job end to end on this host (23 s cold start, VM removed afterwards — evidence in
`docs/verification.md` "M8"). Open: two concurrent guests + third-job-waits, crash/restart recovery
and the 100-job soak (M8.5), the native IPSW builder (M8.6). Track progress in `TODO.md` ("M8").
Treat macOS as **experimental** until M8.5 is recorded.

## Shape of the milestone

macOS is another *guest platform*, not another runner subsystem. Everything above the VM —
scheduler, JIT registration, ephemeral lifecycle, autoscaling, recovery, image store, OCI transport,
guest-agent protocol — is reused unchanged. Only `vmworker` (the one binary that links
Virtualization.framework) knows about `VZMacHardwareModel`, `VZMacMachineIdentifier`,
`VZMacAuxiliaryStorage`, `VZMacPlatformConfiguration` and `VZMacOSBootLoader`.

The order is deliberate: **boot a known-good, pre-provisioned macOS image and run a GitHub job
first; build RunnerVM's own IPSW-based image pipeline last.** Those are two separate hard problems
and the first one is the one that proves the runtime.

| Step | What | Where |
|------|------|-------|
| M8.0 | green baseline — done | `a771905` (a flaky poll made event-driven) |
| M8.1 | identity plumbing — done | `MacOSInstancePlatformSpec`, `VMInstanceSpec.macos`, `machine-identifier.bin`, `MacOSMachineIdentity`, image minimums, admission checks |
| M8.2 | platform builder — done live | `MacOSVMPlatform`, `HostConstants.supportedGuestOS` includes `.macos`, ephemeral-only rule, `image import --hardware-model` |
| M8.3 | guest agent over vsock — **done live** | `scripts/provision-macos-tart.sh` prepares a Tart base image (runner user, agent LaunchDaemon, `actions/runner` osx-arm64) |
| M8.4 | GitHub JIT job end to end — **done live** | `runs-on: rvm-macos-26` (the profile name; never name a profile like a GitHub-hosted label) |
| M8.5 | concurrency + recovery | two guests, third blocked by the scheduler, crash/restart, 100 short jobs |
| M8.6 | native IPSW builder | `runnerctl image build-macos`, a separate builder from the Runnerfile one |

## Identity model

Three Apple objects, three different owners:

| Object | Owner | RunnerVM home |
|--------|-------|---------------|
| `VZMacHardwareModel` — which virtual Mac the installed OS supports | the **image** | `ImageMetadata.macos.hardwareModel` (opaque base64; decoded only in `vmworker`) |
| `VZMacAuxiliaryStorage` — NVRAM-like mutable state tied to the hardware model | image template, **cloned per instance** | image `nvram` layer → `instances/<id>/nvram.bin` |
| `VZMacMachineIdentifier` — the guest's ECID | the **instance** | `instances/<id>/machine-identifier.bin`, minted by `vmworker` on first boot after it holds `worker.lock`, reused on every restart, never sealed into an image |

Apple documents that two concurrently running VMs must not share a machine identifier; the
per-instance file plus the lock is what guarantees they never do. Clone A ≠ clone B; restart of
A = A. `ImageMetadata` never carries instance identity (spec §24), which is also why a Tart
import keeps the hardware model but drops Tart's `ecid` and MAC.

The image additionally records `macos.minimumCPUCount` / `macos.minimumMemoryBytes` (from
`VZMacOSConfigurationRequirements`, or Tart's `cpuCountMin`/`memorySizeMin`). A profile sized below
them is refused at `create` with `VM_MACOS_PROFILE_CPU_TOO_SMALL` /
`VM_MACOS_PROFILE_MEMORY_TOO_SMALL` before any row or clone exists, instead of a bare
`VZVirtualMachineConfiguration validation failed` later.

## Platform configuration

`MacOSVMPlatform` (VirtualizationCore) builds: `VZMacOSBootLoader`; `VZMacPlatformConfiguration`
with the decoded hardware model (`isSupported` is checked — a restore image can describe hardware
this host cannot run, surfaced as `VM_MACOS_HARDWARE_MODEL_UNSUPPORTED`), the instance's auxiliary
storage and machine identifier; and **one virtual display (1920×1080 @ 80 ppi) with no window**.
Apple's configuration API permits an empty graphics array, but Apple's own macOS samples and Tart
both configure a display even when running headless, so RunnerVM does the same. "No GUI window on
the host" ≠ "no virtual GPU in the guest". Booting without any display is a later experiment, not
an M8 blocker. The rest (virtio block with `.cached`, NAT network with a per-instance MAC, vsock,
entropy, serial port) is the shared `VMConfigurationBuilder` path Linux uses.

## Concurrency cap

RunnerVM runs at most **two** concurrent macOS guests per host (`HostConstants.macOSGuestLimit`),
enforced at admission and in advertised capacity. That number matches Apple's standard macOS
license allowance (two additional macOS instances per Apple-branded Mac already running macOS)
and the supported Virtualization.framework operating model; it is a policy default, not a
framework error RunnerVM waits for. Consequence: a warm idle macOS VM permanently consumes half
the host's macOS capacity, so `minIdle: 0` is the default and cold-start latency is measured before
anyone opts into a warm pool.

## Ephemeral only (v1)

`lifecycle: reusable` with `os: macos` is rejected (`PROFILE_MACOS_REUSABLE_UNSUPPORTED`). A macOS
job leaves far more state than a Linux one — login/temporary keychains, code-signing identities,
provisioning profiles, `~/Library/Developer`, DerivedData, SwiftPM and git credential caches,
simulator state — and resetting `$HOME` does not cover it. Reusable macOS can be qualified
separately later.

## Guest side

The Go guest agent already runs on darwin/arm64 with a native `AF_VSOCK` listener and ships a
LaunchDaemon (`GuestAgent/packaging/launchd/com.runnervm.guest-agent.plist`, root). The runner
itself runs as the unprivileged `runner` account from `/Users/runner/actions-runner`. vsock stays the
control plane: no IP discovery, no SSH keys, no network dependency for host→guest management.
SSH remains optional and useful for image development.

Provisioning of the bootstrap image (M8.3) is done over SSH **once, at image-build time**, by
`scripts/provision-macos-tart.sh` against a Tart base VM:

- create `runner`, install the agent + LaunchDaemon, install `actions/runner` osx-arm64 (host-verified
  sha256), Xcode Command Line Tools if absent;
- **required**: `sudo -H -u runner git config --global credential.helper ""` — as `runner`, with
  `HOME=/Users/runner`, an empty override (not `--unset-all`). `actions/checkout` injects its token
  via `http.extraheader`, so no credential helper is ever needed, and a Keychain-backed helper on a
  headless guest blocks forever with no prompt to answer (a real incident on a manually managed
  macOS runner). Done at provisioning time, not per job;
- **explicitly open**: a usable login keychain on a cold-booted, never-logged-in clone for tools
  such as `codesign`/`notarytool`. Signing material must be injected per job (temporary keychain
  created and destroyed inside the job) rather than baked into the image; whether that works
  headless needs its own spike with a cold-boot test.

Xcode is image-level state (`macos-26-base`, `macos-26-xcode-26.x`, …), never installed per job.

## Native image builder (M8.6, later)

`VZMacOSRestoreImage` → `mostFeaturefulSupportedConfiguration` → disk + auxiliary storage +
installer machine identifier → `VZMacOSInstaller` → first boot → account + agent bootstrap →
everything else over the vsock RPC channel → seal. `VZMacOSInstaller` only puts macOS on a disk;
Setup Assistant automation, account creation and agent bootstrap are the hard, brittle part and
are why this is a separate `MacOSRestoreImageBuilder`, not `if os == .macos` branches inside the
Linux Runnerfile builder. Until then the Tart base image is the compatibility oracle.

## Qualification gate (before "supported")

cold boot · unsupported hardware model gives a typed error · agent over vsock, no SSH · unique
machine ids across clones, stable across restart · two concurrent guests, third blocked by the
scheduler · ephemeral JIT job · public and private checkout · `xcodebuild`/SwiftPM · credential
helper never invoked · cancellation/timeout · vmworker crash + runnerd restart recovery · drain ·
OCI push/pull/boot · Tart import → job · 100 short jobs · no leaked instances, runners or processes.

## Host facts (this machine, 2026-08-27)

macOS 26 (Tahoe) on Apple Silicon; Apple's catalog offers 26.6.2 (25G83), minimum 2 vCPU / 4 GiB
for its most featureful configuration. `VZMacOSRestoreImage.fetchLatestSupported` needs the
virtualization entitlement (sign a probe with `Resources/vmworker-dev.entitlements`). Free disk was
74 GiB at M8 start — one Tart base image (~27 GB compressed) fits; Xcode images will not until
space is reclaimed.
