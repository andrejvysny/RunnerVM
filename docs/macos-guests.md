# macOS guest runners — status and milestone plan

**Status: not implemented.** Config validation rejects `os: macos` with `GUEST_OS_UNSUPPORTED`.
This document is the plan to change that. It is a **separate milestone (M8)**, deliberately kept
out of the v1 Linux scope by both production-readiness reviews.

## Why it is not just "flip a flag"

The Linux path boots a raw GPT disk through EFI with a cloud-init seed. macOS on
Virtualization.framework is a different platform with no equivalent:

| Concern | Linux (done) | macOS (to build) |
|---------|--------------|------------------|
| Platform | `VZGenericPlatformConfiguration` + EFI + per-instance NVRAM | `VZMacPlatformConfiguration` (hardware model, machine identifier, **auxiliary storage**) |
| Boot loader | `VZEFIBootLoader` | `VZMacOSBootLoader` (no NVRAM) |
| Graphics | none (headless serial) | `VZMacGraphicsDeviceConfiguration` required even headless |
| Provisioning | cloud-init NoCloud seed | **no cloud-init** — install from an IPSW via `VZMacOSInstaller`, then automate first boot |
| Image source | Ubuntu cloud image (qcow2→raw) | Apple **IPSW** restore (`VZMacOSRestoreImage`), ~16–19 GB download, 30–60 min restore |
| Guest agent delivery | baked into the image by the builder VM | must be injected into a fresh macOS install and set to run at login/boot |
| Runner | `actions/runner` linux-arm64 | `actions/runner` osx-arm64 |
| Concurrency | host RAM/CPU bound | **hard cap of 2 concurrent macOS guests** per host (framework limit) |

The guest agent already cross-compiles for `darwin/arm64` and has `AF_VSOCK` + a launchd unit
(`GuestAgent/packaging/launchd`), so the *agent* side is largely ready. The unbuilt work is the
**host platform path** and **automated provisioning** of a fresh macOS install.

## Planned structure (from the readiness review)

```
VMPlatformBuilder
├── LinuxVMPlatform   (exists — VMConfigurationBuilder today)
└── MacOSVMPlatform   (to build)
```

Do **not** force the Linux EFI builder to handle macOS.

## Milestone steps

1. **Platform builder** — `MacOSVMPlatform`: `VZMacPlatformConfiguration` with a persisted
   `VZMacHardwareModel`, `VZMacMachineIdentifier`, and `VZMacAuxiliaryStorage`; `VZMacOSBootLoader`;
   a headless `VZMacGraphicsDeviceConfiguration`; virtio block + vsock. Store hardware model +
   machine identifier in `ImageMetadata.macOSPlatform` (the field already exists) and per instance.
2. **Restore/installer** — a `macos image build` path that fetches the macOS **Tahoe (26)** IPSW
   (or accepts `--ipsw <path>`), validates it against
   `VZMacOSConfigurationRequirements`, runs `VZMacOSInstaller`, and seals the installed disk +
   aux storage + hardware model as a RunnerVM image.
3. **First-boot provisioning** — inject the guest agent + `actions/runner` osx-arm64 and a launchd
   job into the installed system (via a scripted setup over the VZ console / a provisioning volume),
   so a cloned instance comes up, the agent connects over vsock, and JIT registration works exactly
   like Linux.

   - **Required**: after the `runner` account exists, reset its git credential helper as that
     user — `sudo -H -u runner git config --global credential.helper ""` (empty override, not
     `--unset-all`; an empty value resets git's whole accumulated helper list, `--unset-all` only
     removes one entry and leaves a lower-precedence default underneath). Must run as `runner`
     with `HOME=/Users/runner`, not as root — the guest agent's admin exec path defaults to root
     (`GuestAgent/packaging/launchd/com.runnervm.guest-agent.plist`,
     `GuestAgent/internal/agent/handlers_exec.go`), but the actual CI job always runs as the
     dropped-privilege `runner` account with its own `HOME`
     (`GuestAgent/cmd/guest-agent/main.go`, `GuestAgent/internal/runner/manager.go`); running this
     as root would write `/var/root/.gitconfig` and leave `/Users/runner/.gitconfig` untouched.
     `actions/checkout` never needs persisted credentials (token injected via `extraheader`), so
     this alone fully prevents a Keychain-backed credential helper from ever being invoked — the
     same class of hang a real incident hit on a different, manually-managed macOS runner (a
     locked login keychain + a helper trying to write to it blocks forever with no timeout, no UI
     to answer the prompt).
   - **Explicitly open, not solved by the above**: making the guest's login keychain itself usable
     on a headless boot, for any *other* keychain-touching tool a job might run (`codesign`,
     `notarytool`, etc.). `security set-keychain-settings` does not solve this on its own — this
     repo's own launchd docs (`packaging/launchd/README.md`) already record that a keychain
     configured that way "will not survive a reboot without a login" for a headless account, the
     same unsolved problem noted there for the *host* LaunchDaemon path. A cloned macOS guest that
     never gets an interactive login has no obvious mechanism to produce an unlocked runner
     keychain in the first place. If M8 ends up needing keychain-backed guest tooling, this needs
     its own spike (does a usable runner keychain exist at all on a cold-booted clone with no GUI
     login? how would it be created/unlocked?) with a cold-boot validation test — don't assume a
     one-line `security` call solves it.
4. **Validation gate** — extend `HostConstants.supportedGuestOS` to include `.macos` **only** once
   1–3 are real; keep `GUEST_OS_UNSUPPORTED` until then. Enforce the 2-guest cap
   (`HostConstants.macOSGuestLimit`, already validated) at admission.
5. **Verify** — a `macos-15/26` profile boots, the agent connects, a JIT runner registers, an
   Xcode/`xcodebuild` workflow runs, the VM is destroyed after the job; cold-boot + daemon-restart
   cases covered like Linux. Include a private-repo `actions/checkout` as the real `runner`
   account and confirm it completes without ever invoking a credential helper or blocking on UI —
   the concrete proof step 3's credential-helper fix actually closes the hang class.

## Host facts (this machine, 2026-08-26)

- Host: macOS **26.4 (Tahoe)**, Apple Silicon — can host macOS guests.
- Free disk: ~154 GiB — enough for a minimal macOS install + IPSW; **tight** once Xcode is added.
- Cost to verify: one ~16–19 GB IPSW download + a 30–60 min `VZMacOSInstaller` restore, per image.

## Recommendation

Keep macOS guests as this separate milestone. Ship and operate the **Linux** pilot first (proven
end-to-end — see `docs/verification.md`), then build M8 against a dedicated block of time because
of the download/restore cost and the fresh-install provisioning work.
