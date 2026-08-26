# RunnerVM guest agent

Runs inside RunnerVM guests and serves the host over virtio-socket (guest
protocol v1, see `../Proto/guest_agent.md`). Cross-built on a macOS host for
the guest it will run in (`make build-linux`, `make build-darwin`).

## Security rails: destructive methods only run inside a VM

`agent.cleanup`, `agent.resizeDisk` and `agent.shutdown` are destructive by
design: cleanup empties the runner account's home caches and everything it
owns under the shared temp directories, resizeDisk grows the root
filesystem, shutdown halts the OS. That is correct and expected inside a
throwaway RunnerVM guest. It is not correct anywhere else -- most notably
when a developer runs the `guest-agent` binary directly on their own Mac
while iterating on it, which is exactly how these rails ended up here: a
`agent.cleanup` call exercised against the host, not a guest, deleted a
developer's home caches and `/private/tmp` entries.

Two independent rails guard against this, deliberately overlapping ("belt
and braces") rather than relying on either one alone:

1. **Non-root guard** (`internal/agent/service.go`, `New`). If the resolved
   runner account is not privileged (not root) and `CleanupTempDirs` was
   left at its zero value (`nil`, i.e. "use the production defaults"), the
   agent refuses to guess: it sets `CleanupTempDirs` to an empty slice,
   disables `docker system prune`, and -- unless `CleanupHome` was set
   explicitly -- leaves the home sweep target empty too. A warning is
   logged once at startup. This only fires for the *default* configuration;
   an operator who explicitly sets `CleanupTempDirs`/`CleanupHome` is
   assumed to know what they are doing.

2. **Host-safe-mode** (`internal/system.InVirtualMachine`,
   `internal/agent/service.go`, `internal/agent/handlers_maint.go`). At
   startup the agent asks the kernel whether it is actually running inside
   a hypervisor guest:

   - **darwin**: `sysctl kern.hv_vmm_present` (via `unix.SysctlUint32`).
     `== 1` means the kernel is a hypervisor guest, including under Apple's
     own Virtualization.framework -- how RunnerVM boots macOS guests on
     Apple Silicon hosts.
   - **linux**: in order, first match wins --
     1. `/sys/class/dmi/id/sys_vendor` or `product_name` contains both
        `"Apple"` and `"Virtualization"` (Apple's Virtualization.framework
        stamps SMBIOS with vendor `Apple Inc.` and product `Apple
        Virtualization Generic Platform` for Linux guests -- how RunnerVM
        boots Linux guests on Apple Silicon hosts).
     2. `/sys/hypervisor/type` exists (kernel-level hypervisor detection,
        e.g. Xen).
     3. `systemd-detect-virt --vm` exits 0 (2s timeout; fallback for
        QEMU/KVM and anything else that leaves neither of the above).

   If none of that confirms a VM, and `--allow-host-destructive` was not
   passed, the agent enters **host-safe-mode**: `agent.cleanup`,
   `agent.resizeDisk` and `agent.shutdown` all immediately return

   ```
   NOT_SUPPORTED: refused: agent is not running inside a virtual machine
   (pass --allow-host-destructive to override)
   ```

   without touching disk. `agent.health` includes `"host-safe-mode"` in its
   `reasons` array so the host/operator can see why -- this is purely
   informational and does **not** change the reported `state`; an otherwise
   healthy agent still answers `ready`.

   A false result from the detector means "could not confirm this is a
   VM", not "definitely bare metal": the code always prefers the safe
   refusal over a confident guess.

### Dev-mode flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--allow-host-destructive` | `false` | Disables host-safe-mode. **Dangerous; for guest image builds on real hardware only.** Lets `agent.cleanup`/`resizeDisk`/`shutdown` run even when the agent cannot confirm it is inside a VM. Does not affect the non-root guard above. |
| `--listen tcp:host:port` | unset (uses `AF_VSOCK`) | Development transport: `AF_VSOCK` cannot be opened outside a guest, so local runs and the test harness dial loopback TCP instead. |

When developing the agent directly on a Mac, prefer `--listen` against a
sandboxed `--runner-dir`/`--state-dir` over reaching for
`--allow-host-destructive`; only pass the latter for the guest-image build
pipeline running on real (non-virtualized) build hardware, where there is
no guest to protect and the destructive methods are the point.

## Tests

`go test ./...` never exercises the real halt/resize/cleanup paths against
this machine: `PowerOff` is injected as a no-op in the test harness
(`internal/agent/harness_test.go`), and `CleanupTempDirs`/`CleanupHome` are
pointed at `t.TempDir()` sandboxes, never real `/tmp` or `$HOME`. The
harness also defaults `Config.VMDetector` to report "in VM" so the ordinary
cleanup/resizeDisk/shutdown tests exercise real behaviour regardless of
whether the suite happens to run on a developer Mac or a VM-based CI
runner; tests of host-safe-mode itself override the detector explicitly
(see `TestCleanupRefusedOutsideVM` and friends in
`internal/agent/handlers_maint_test.go`).
