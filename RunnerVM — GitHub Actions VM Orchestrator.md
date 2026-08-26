# RunnerVM — GitHub Actions VM Orchestrator
## Detailed Architecture and Implementation Specification

**Status:** Initial engineering specification  
**Target:** Internal production tool, designed to become publicly distributable later  
**Primary language:** Swift  
**Guest agent:** Go  
**Initial host platform:** Apple Silicon, macOS 15+  
**Initial guests:** macOS ARM64 and Ubuntu 24.04 LTS ARM64  
**Primary workload:** GitHub.com self-hosted GitHub Actions runners  
**Starting point:** Fork of `openai/tart`, aggressively refactored toward a new architecture  
**Virtualization backend:** Apple Virtualization.framework directly  
**Persistent state:** SQLite  
**Remote image storage:** OCI-compatible registries, with GHCR as the primary target  
**Default runner lifecycle:** Ephemeral VM, one VM per GitHub Actions job, scale to zero

---

# 1. Mission

Build a lightweight, reliable GitHub Actions runner orchestrator for Apple Silicon Macs.

The system MUST:

- run multiple macOS and Linux virtual machines on one Apple Silicon Mac;
- use Apple Virtualization.framework directly rather than invoking Tart;
- provision GitHub Actions runners dynamically;
- support GitHub.com repository-level and organization-level runner scopes;
- scale from zero VMs when there is no work;
- create an isolated VM for each job by default;
- destroy ephemeral VMs after their job finishes;
- optionally support reusable VMs;
- optionally maintain a warm pool;
- provide strong defaults while permitting explicit resource overrides;
- persist lifecycle and reconciliation state in SQLite;
- automatically reconcile state after daemon restart or host reboot;
- expose a local Swift CLI;
- use OCI/GHCR for image distribution;
- communicate with guests primarily through virtio sockets;
- retain SSH as a manual/debugging interface;
- collect structured logs and VM-level resource metrics;
- avoid placing long-lived GitHub credentials inside guest VMs;
- be architected so multi-host scheduling can be added later without rewriting the local VM engine.

The project is not intended to be a general-purpose desktop VM manager. It is a purpose-built CI runner infrastructure system.

---

# 2. Core product philosophy

RunnerVM should optimize for:

1. **Reproducibility**
2. **Isolation**
3. **Fast VM creation**
4. **Reliable reconciliation**
5. **Minimal host privileges**
6. **Strong observability**
7. **Simple operational model**
8. **Scale-to-zero efficiency**
9. **Explicit state machines**
10. **Future cluster readiness without premature distributed-systems complexity**

The system SHOULD prefer deterministic and boring mechanisms over highly clever abstractions.

A VM disappearing, a daemon restarting, GitHub returning `500`, a host rebooting, or an image pull failing MUST all be normal recoverable lifecycle events rather than exceptional architecture-breaking situations.

---

# 3. Important architectural decisions

## 3.1 Do not build a Tart-compatible orchestrator

Tart should be treated as:

- a useful body of proven Virtualization.framework implementation knowledge;
- a source of patterns for VM configuration;
- a possible temporary compatibility source for existing images;
- an implementation from which selected low-level behavior can initially be adapted.

RunnerVM MUST NOT preserve Tart's application/domain architecture merely because the repository is the starting point.

The target architecture is substantially different:

```text
Tart

CLI invocation
    │
    ▼
Tart VM lifecycle
    │
    ▼
VZVirtualMachine


RunnerVM

GitHub demand
    │
    ▼
runnerd
    │
    ├── Scheduler
    ├── SQLite state
    ├── Image manager
    ├── GitHub controller
    └── VM supervisor
             │
             ├── vmworker ──► VZVirtualMachine
             ├── vmworker ──► VZVirtualMachine
             └── vmworker ──► VZVirtualMachine
```

The current Tart source already cleanly demonstrates how a VM configuration is ultimately built from Virtualization.framework objects including platform, CPU, memory, storage, network devices, entropy and `VZVirtioSocketDeviceConfiguration`. 

RunnerVM should extract that knowledge into purpose-built modules rather than retain Tart's CLI-oriented object graph.

---

# 4. External API assumptions as of August 25, 2026

This section captures current external dependencies that are important enough to influence architecture.

## 4.1 GitHub runner scale sets

GitHub currently provides a Runner Scale Set Client for implementing custom autoscaling systems outside Kubernetes. Its model includes creating runner scale sets, opening a message session, long-polling for scale-set work, advertising capacity, generating JIT runner configuration, and operating ephemeral runners. GitHub explicitly describes VMs and macOS/Linux as relevant use cases. The client is currently public preview, so our integration MUST be isolated behind an abstraction that can change independently of the rest of RunnerVM.

The reference scale-set client maintains a message session, long-polls a GitHub-provided queue URL, advertises maximum capacity, handles expired queue tokens, and acknowledges processed messages. 

**Decision:** Runner Scale Sets will be the default demand plane.

RunnerVM MUST NOT require an inbound webhook endpoint merely to scale from zero.

This is particularly valuable for the initial single-Mac architecture:

```text
GitHub
   ▲
   │ outbound HTTPS only
   │
runnerd
   │
   └── no public server required
```

A webhook-based demand provider MAY be implemented later as an alternate backend.

---

## 4.2 GitHub JIT runners

GitHub supports generation of just-in-time runner configuration for both repositories and organizations. JIT configuration can be supplied to the GitHub Actions runner at startup, and the JIT runner is intended to execute a single job.

**Decision:** even reusable VMs should generally run **new JIT runner processes for individual jobs** rather than retaining one permanently registered GitHub runner.

Therefore:

```text
Reusable VM
  │
  ├── JIT runner process for job 1
  │       └── exits
  │
  ├── cleanup
  │
  ├── JIT runner process for job 2
  │       └── exits
  │
  └── ...
```

VM reuse and GitHub runner registration reuse are separate concepts.

---

## 4.3 Ephemeral runners

GitHub recommends ephemeral runners for autoscaling scenarios because they provide a cleaner one-job lifecycle. Linux self-hosted runners that execute container actions or service containers also require Docker.

This supports two product defaults:

- ephemeral VMs;
- Ubuntu images with Docker preinstalled.

---

## 4.4 Apple Virtualization.framework

Virtualization.framework provides the actual VM execution layer, including storage, networking and virtio-socket communication.

macOS guests require macOS platform metadata including the hardware model, machine identifier and auxiliary storage. Instance identity MUST be handled carefully when cloning macOS images.

The executable using Virtualization.framework requires Apple's virtualization entitlement.

Virtualization.framework does not provide a complete guest resource-monitoring abstraction; for example, host memory balloon APIs do not provide general guest memory utilization insight.

Therefore guest resource telemetry MUST primarily come from the guest agent.

---

# 5. High-level system architecture

The system consists of four executables.

```text
                     GitHub.com
                        │
                        │ HTTPS
                        ▼
                 ┌───────────────┐
                 │    runnerd    │
                 │               │
                 │ GitHub ctrl   │
                 │ scheduler     │
                 │ image mgr     │
                 │ SQLite        │
                 │ reconciliation│
                 └───────┬───────┘
                         │
                    local IPC
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
      vmworker        vmworker       vmworker
          │              │              │
          ▼              ▼              ▼
       VZ VM          VZ VM           VZ VM
          │              │              │
       vsock           vsock          vsock
          │              │              │
          ▼              ▼              ▼
     guest-agent    guest-agent    guest-agent
          │              │              │
     actions-runner actions-runner actions-runner


                 ┌──────────────┐
                 │  runnerctl   │
                 └──────┬───────┘
                        │
                  Unix socket
                        │
                        ▼
                     runnerd
```

Executables:

### `runnerd`

Long-running host daemon.

Responsibilities:

- GitHub authentication;
- GitHub scale-set management;
- demand polling;
- local scheduling;
- image pulling and caching;
- VM instance lifecycle orchestration;
- worker supervision;
- SQLite persistence;
- reconciliation;
- metrics aggregation;
- log aggregation;
- local daemon API.

`runnerd` MUST NOT itself own `VZVirtualMachine` instances.

---

### `vmworker`

Private host executable.

Exactly one process owns exactly one VM.

Responsibilities:

- construct `VZVirtualMachineConfiguration`;
- create `VZVirtualMachine`;
- start/stop VM;
- observe VM state transitions;
- own the virtio-socket device;
- expose guest-agent connectivity to `runnerd`;
- emit VM lifecycle events;
- provide process-isolated host-side resource accounting.

There MUST be a 1:1 relationship:

```text
vmworker process : VM instance
```

This is an intentional architectural invariant.

---

### `runnerctl`

Human-facing CLI.

Responsibilities:

- communicate with `runnerd`;
- display status;
- configure profiles;
- inspect VMs;
- manage images;
- access logs and metrics;
- manually SSH/exec into VMs;
- perform diagnostics.

`runnerctl` MUST NOT:

- manipulate VM files directly;
- modify SQLite directly;
- talk directly to GitHub for normal operations;
- instantiate Virtualization.framework objects.

The daemon remains the single authority.

---

### `guest-agent`

Tiny service installed inside macOS and Linux images.

Recommended implementation language: **Go**.

The host remains Swift; the guest agent does not need to.

Reasons:

- one codebase for macOS ARM64 and Linux ARM64;
- compact binaries;
- straightforward system service installation;
- no Linux Swift runtime management;
- mature networking/system metrics support;
- easier image bootstrapping;
- Tart's own architecture demonstrates that a dedicated guest agent is a practical solution.

The current Tart repository already uses a guest-agent/control-channel pattern and proxies a host Unix socket through the VM's virtio socket.  

RunnerVM should retain the idea while implementing its own protocol and lifecycle semantics.

---

# 6. Why `vmworker` must be a separate process

This is a deliberate design requirement, not an incidental implementation detail.

## 6.1 Crash isolation

If one Virtualization.framework VM gets into an abnormal state or triggers a worker failure:

```text
VM 384 crashes
       │
       ▼
vmworker 384 exits
```

Other VMs and `runnerd` continue running.

Without worker isolation:

```text
single runnerd process
   ├── VM 1
   ├── VM 2
   ├── VM 3
   └── crash affecting process
           ↓
       everything lost
```

---

## 6.2 Easier per-VM host metrics

Because every worker corresponds to one VM, macOS process statistics provide a useful host-side approximation:

```text
vmworker PID 4512
  CPU %
  resident memory
  CPU time
  I/O accounting where available
```

These are not identical to guest metrics, but they are useful operationally.

Guest-agent metrics provide the complementary in-guest view.

---

## 6.3 Better daemon upgrades and restarts

Ideally:

```text
runnerd dies
   │
VM workers continue
   │
new runnerd starts
   │
reconnects to workers
```

This enables future zero-downtime daemon upgrades and avoids unnecessarily destroying jobs because the orchestration control process restarted.

The first implementation MAY initially terminate workers if the daemon exits, but the IPC/runtime format MUST be designed to permit reconnectable workers.

The desired final behavior is worker independence from daemon lifetime.

---

## 6.4 Security isolation

Long-lived GitHub credentials remain inside `runnerd`.

A worker may temporarily see:

- a JIT configuration;
- an ephemeral operation token;
- guest bootstrap data.

A worker MUST NOT receive:

- PAT;
- GitHub App private key;
- long-lived installation token;
- GHCR credentials unless strictly necessary for a worker-local operation.

Normally all image acquisition occurs in `runnerd`, not `vmworker`.

---

# 7. Privilege model

## 7.1 Development mode

Support:

```text
runnerd --foreground
```

running as the current interactive user.

This keeps initial development simple.

---

## 7.2 Production mode

Production deployment SHOULD use:

```text
launchd
   │
   ▼
dedicated RunnerVM service account
   │
   ▼
runnerd
   │
   └── vmworker processes
```

Do not run normal workloads as `root`.

Installation itself may require administrator privileges to:

- install binaries;
- install the launch daemon;
- create the service account;
- configure state directories.

Runtime processes should use a dedicated unprivileged account.

The virtualization entitlement MUST be included wherever Apple requires it for the process creating the VM.

Prefer giving the entitlement to `vmworker`, keeping `runnerd` independent from Virtualization.framework where practical.

---

# 8. Networking model

V1 networking is deliberately simple.

## 8.1 Default

Use shared/NAT networking:

```text
Internet
   ▲
   │
macOS host
   ▲
   │ NAT
   │
VM
```

Requirements:

- outbound Internet connectivity from VM;
- VM can reach GitHub;
- VM can reach package registries;
- no inbound connections from LAN;
- no bridged networking;
- no port-forwarding subsystem in v1.

---

## 8.2 Control traffic

Primary VM control communication uses:

```text
runnerd
   │
Unix IPC
   ▼
vmworker
   │
VZVirtioSocket
   ▼
guest-agent
```

This SHOULD NOT depend on the guest acquiring an IP address.

This is important because VM readiness becomes:

```text
VM booted
   ↓
vsock guest agent responds
   ↓
ready
```

rather than:

```text
VM booted
   ↓
DHCP succeeds
   ↓
host discovers IP
   ↓
SSH succeeds
   ↓
ready
```

The former is much more deterministic.

---

## 8.3 SSH

SSH remains a secondary administrative interface.

Command:

```text
runnerctl vm ssh <instance>
```

Workflow:

```text
runnerctl
   ↓
runnerd
   ↓
guest-agent GetInfo
   ↓
guest reports IP address
   ↓
runnerctl invokes system ssh
```

SSH requirements:

- public-key authentication only;
- no default password;
- no LAN exposure;
- intended for debugging/manual inspection;
- not part of automated job lifecycle.

SSH MAY be disabled per profile.

For ephemeral production profiles it SHOULD be possible to globally disable SSH.

---

# 9. Runner lifecycle models

Support three independent concepts.

## 9.1 Ephemeral VM

Default.

```text
job demand
   ↓
create VM
   ↓
run one job
   ↓
destroy VM
```

Configuration:

```yaml
lifecycle: ephemeral
```

This is the secure and recommended default.

---

## 9.2 Reusable VM

Optional.

```text
create VM
   ↓
JIT job
   ↓
cleanup
   ↓
JIT job
   ↓
cleanup
   ↓
...
```

Configuration:

```yaml
lifecycle: reusable
```

A reusable VM MUST still use a fresh GitHub JIT runner configuration for each job by default.

Reusable VM lifecycle MUST include a cleanup phase.

At minimum, cleanup SHOULD remove:

- GitHub runner work directory;
- temporary files;
- known GitHub runner credentials/config;
- transient environment data;
- prior workspace;
- cached job-specific secrets.

Reusable mode MUST be documented as weaker isolation.

It exists for performance-sensitive trusted workloads, not as the general secure default.

---

## 9.3 Warm pool

Warm pool is orthogonal to ephemeral/reusable lifecycle.

Default:

```yaml
warmPool:
  minIdle: 0
```

Therefore true scale to zero.

Configured example:

```yaml
warmPool:
  minIdle: 2
  maxIdle: 3
  idleTTL: 20m
```

An idle warm VM MUST:

- be booted;
- have a healthy guest agent;
- NOT yet have a JIT GitHub runner config;
- NOT be registered as a stale GitHub runner.

Generate the JIT configuration only when actual work is assigned.

This makes warm instances generic compute capacity rather than pre-registered GitHub runners.

---

# 10. Runner profiles

A **RunnerProfile** is the primary scheduling/configuration unit.

Example:

```yaml
profiles:
  - name: macos-15-xcode-16
    scope: engineering
    image: ghcr.io/acme/runnervm/macos-15-xcode-16:stable

    lifecycle: ephemeral

    resources:
      cpu: 6
      memory: 12GiB
      disk: 120GiB

    warmPool:
      minIdle: 0
      maxIdle: 0

    limits:
      maxInstances: 3

    ssh:
      enabled: true

  - name: ubuntu-24
    scope: engineering
    image: ghcr.io/acme/runnervm/ubuntu-24:stable

    lifecycle: ephemeral

    resources:
      cpu: 4
      memory: 8GiB
      disk: 80GiB

    limits:
      maxInstances: 5
```

A profile determines:

- GitHub scope;
- scale set;
- VM image;
- guest OS;
- CPU;
- RAM;
- disk size;
- lifecycle;
- warm-pool policy;
- maximum local concurrency;
- optional labels/capabilities;
- SSH policy;
- job timeout policy;
- image update behavior.

---

# 11. GitHub scopes

Support:

```text
organization
repository
```

Examples:

```yaml
github:
  scopes:
    - name: engineering
      type: organization
      owner: acme
      runnerGroup: Default

    - name: project-a
      type: repository
      owner: acme
      repository: project-a
```

Internally:

```swift
enum GitHubScope {
    case organization(owner: String, runnerGroupID: Int64)
    case repository(owner: String, repository: String)
}
```

Do not spread scope-specific URL logic through the scheduler.

All GitHub API differences MUST live behind `GitHubClient`.

---

# 12. GitHub authentication

Implement an abstraction from day one:

```swift
protocol GitHubCredentialProvider {
    func credential() async throws -> GitHubCredential
}
```

Implementations:

```text
PATCredentialProvider
GitHubAppCredentialProvider
```

## Development

PAT is acceptable.

Preferred UX:

```text
runnerctl auth login --token-stdin
```

Store the token in macOS Keychain.

Also support:

```text
RUNNERVM_GITHUB_TOKEN
```

for local development/testing.

Do not place PAT directly in normal YAML configuration.

---

## Production

Use a GitHub App.

Expected architecture:

```text
GitHub App private key
       │
       ▼
runnerd
       │
       ├── signs app JWT
       │
       └── obtains installation token
                 │
                 ▼
             GitHub API
```

Short-lived installation credentials stay on the host.

Guest VMs MUST NEVER receive:

- PAT;
- GitHub App private key;
- installation token.

Guests receive only the job-specific/JIT data needed to start the runner.

---

# 13. Default GitHub demand provider

Define:

```swift
protocol GitHubDemandProvider {
    func start() async throws
    func events() -> AsyncThrowingStream<DemandEvent, Error>
    func currentDemand(for profile: RunnerProfileID) async throws -> DemandSnapshot
}
```

Primary implementation:

```text
ScaleSetDemandProvider
```

Future implementation:

```text
WorkflowJobWebhookDemandProvider
```

Possibly:

```text
ManualDemandProvider
```

for integration tests.

The rest of the scheduler MUST NOT know which demand provider is being used.

---

# 14. Scale-set mapping

Recommended rule:

```text
one RunnerProfile
        │
        ▼
one GitHub runner scale set
```

For example:

```text
RunnerProfile:
  macos-15-xcode-16
      │
      ▼
GitHub scale set:
  runnervm-macos-15-xcode-16
```

And:

```text
ubuntu-24
      │
      ▼
runnervm-ubuntu-24
```

Advantages:

- clean capacity accounting;
- easy image selection;
- resource requirements known before scheduling;
- no ambiguous mapping between labels and images;
- independent maximum concurrency;
- independent warm-pool settings.

---

# 15. Demand and scale-to-zero algorithm

The scheduler MUST reason in terms of desired capacity, not merely individual webhook/message events.

Conceptually:

```text
GitHub says:
  total jobs assigned to scale set = 3

RunnerVM currently has:
  1 suitable VM running job
  1 suitable VM starting

Needed:
  1 more VM
```

For each profile calculate:

```text
desiredTotal =
    assignedDemand
    + configuredIdleCapacity
```

Then:

```text
additionalNeeded =
    desiredTotal
    - healthyStartingRunningAndIdleInstances
```

Clamp to:

```text
0 ... effectiveProfileCapacity
```

When:

```text
assignedDemand = 0
minIdle = 0
```

then:

```text
desiredTotal = 0
```

and all unnecessary ephemeral capacity eventually disappears.

---

# 16. Host capacity calculation

No memory overcommit by default.

Suggested default host configuration:

```yaml
host:
  reserve:
    cpu: 2
    memory: 6GiB
    disk: 50GiB

  overcommit:
    cpu: 1.0
    memory: 1.0

  maxVMs: auto
```

Definitions:

```text
physicalMemoryBudget =
    hostPhysicalMemory
    - hostMemoryReserve

allocatedGuestMemory =
    sum(memoryReservation for starting/running VMs)

memoryAvailable =
    physicalMemoryBudget
    - allocatedGuestMemory
```

A new VM may be scheduled iff:

```text
vm.memory <= memoryAvailable
```

unless explicit memory overcommit is enabled.

CPU budget:

```text
cpuBudget =
    (hostLogicalCPUs - cpuReserve)
    × cpuOvercommitRatio
```

Then:

```text
allocatedVCPU + requestedVCPU <= cpuBudget
```

Default:

```text
cpuOvercommitRatio = 1.0
```

Later users may configure:

```yaml
overcommit:
  cpu: 1.5
```

Memory overcommit SHOULD remain `1.0` unless explicitly changed.

---

# 17. Disk scheduling

Do not schedule based only on configured virtual disk sizes because sparse/CoW storage makes virtual size different from physical allocation.

Track:

- guest virtual disk size;
- local allocated bytes;
- base image shared bytes;
- instance private allocated bytes;
- host free bytes.

Before creating another instance:

```text
hostFreeSpace - diskReserve >= estimatedAdditionalAllocation
```

Use conservative initial estimates.

Also impose an absolute free-space floor.

Example:

```yaml
host:
  reserve:
    disk: 50GiB
```

If free space drops beneath the floor:

- stop admitting new work;
- emit a high-priority health warning;
- prune unreferenced cached image layers where policy allows;
- never silently delete active VMs.

---

# 18. Default Linux guest

Use:

**Ubuntu 24.04 LTS ARM64**

as the default Linux runner OS.

Reasons:

- long support lifetime;
- familiar GitHub Actions environment;
- strong ARM64 ecosystem;
- straightforward cloud-image/bootstrap tooling;
- general-purpose rather than narrowly optimized.

Default image SHOULD include:

```text
GitHub Actions runner ARM64
Docker Engine
git
curl
wget
ca-certificates
jq
tar
gzip
xz
zstd
unzip
zip
rsync
openssh-server
build-essential
python3
python3-pip or pipx
common SSL/network diagnostics
guest-agent
```

Avoid trying to reproduce the entire GitHub-hosted `ubuntu-latest` software catalogue in the base image.

Instead use image tiers:

```text
ubuntu-24-base
ubuntu-24-build
ubuntu-24-mobile
...
```

The base runner should remain understandable and maintainable.

---

# 19. Docker on Linux

Docker SHOULD be installed and running because GitHub Actions container jobs, container actions and service containers depend on a container runtime on self-hosted Linux runners.

Runner user configuration must permit the GitHub runner to operate Docker.

Security note:

Membership in the Docker group is effectively highly privileged inside the guest.

That is acceptable inside an ephemeral VM because the VM is already considered disposable and untrusted from the host's perspective.

Never expose the host Docker socket into the VM.

---

# 20. VM image philosophy

Images are **immutable templates**.

Scheduler MUST never execute CI directly in a base image.

Instead:

```text
immutable image
      │
      │ APFS CoW clone
      ▼
VM instance
      │
      │ mutable job filesystem
      ▼
job
```

The image remains untouched.

---

# 21. Image identity

Remote image references may be tags:

```text
ghcr.io/acme/runners/ubuntu-24:stable
```

But before starting a VM RunnerVM MUST resolve the tag to an immutable manifest digest:

```text
ghcr.io/acme/runners/ubuntu-24
@sha256:7ab3...
```

Store the digest in the VM instance record.

Therefore a running VM always has an immutable provenance:

```text
instance
  imageDigest = sha256:...
```

This makes incidents reproducible even if `:stable` changes later.

---

# 22. Local image layout

Recommended:

```text
/Library/Application Support/RunnerVM/
    state/
        runnerd.sqlite3

    images/
        manifests/
            sha256-<digest>/
                manifest.json
                metadata.json

        blobs/
            sha256/
                ab/
                    abcdef...

    instances/
        <uuid>/
            instance.json
            disk.img
            nvram.bin
            ...

    logs/
        runnerd/
        instances/

/var/run/runnervm/
    runnerd.sock
    vm-<shortid>.sock
```

Use a deliberately short path beneath `/var/run` for Unix-domain sockets.

Tart itself contains special handling for Unix-domain socket path length limits, reinforcing the need to keep runtime socket paths short. 

---

# 23. APFS requirement

The main instance/image store SHOULD be located on APFS.

`runnerctl doctor` MUST detect:

- filesystem type;
- clone support;
- free space;
- state directory permissions.

Use an explicit APFS clone primitive when possible:

```text
clonefile(2)
```

or an equivalent clone-aware API.

If CoW cloning is unavailable:

- allow a full copy only if configured;
- emit a warning;
- expose clone mode in metrics.

Example:

```text
instance_clone_method = apfs_cow
```

versus:

```text
instance_clone_method = full_copy
```

---

# 24. Image metadata

Define project-owned metadata rather than retaining Tart's VM configuration schema.

Example:

```json
{
  "schemaVersion": 1,
  "id": "sha256:...",
  "os": "linux",
  "architecture": "arm64",
  "virtualDiskSizeBytes": 85899345920,
  "runnerVersion": "2.x.y",
  "guestAgentVersion": "0.x.y",
  "minimumHostOS": "15.0",
  "createdAt": "2026-08-25T12:00:00Z",

  "boot": {
    "type": "efi"
  },

  "capabilities": {
    "docker": true,
    "ssh": true
  }
}
```

macOS metadata additionally contains serialized data required to reconstruct the platform:

```json
{
  "os": "macos",
  "macos": {
    "hardwareModel": "...",
    "sourceVersion": "..."
  }
}
```

Do NOT store a reusable instance machine identifier in canonical image metadata.

Instance identity belongs to the instance.

---

# 25. macOS clone identity rules

For every macOS VM instance:

- generate a new `VZMacMachineIdentifier`;
- create a unique VM directory;
- use a unique auxiliary-storage file;
- generate a new locally administered MAC address;
- preserve the compatible hardware model from the image;
- clone the image's required auxiliary-storage contents into the per-instance file where needed for boot state.

Tart's current Darwin implementation stores the macOS hardware model and machine identifier and constructs a `VZMacPlatformConfiguration` with auxiliary storage. 

RunnerVM MUST separate:

```text
image-level platform compatibility
```

from:

```text
instance-level machine identity
```

This distinction should be explicit in the data model.

---

# 26. Linux VM platform

Linux guests use:

- `VZEFIBootLoader`;
- per-instance EFI variable store;
- `VZGenericPlatformConfiguration`;
- virtio block storage;
- virtio NAT network;
- virtio entropy;
- virtio socket;
- optional serial console.

Tart already implements essentially this minimal Linux platform shape and can be used as an implementation reference during the rewrite. 

Nested virtualization is OUT OF SCOPE by default.

Expose it as a future capability rather than making it part of normal runner profiles.

---

# 27. Headless VM configuration

CI runners do not need desktop virtualization peripherals.

Default VM configuration SHOULD omit:

- audio input;
- host audio output;
- clipboard sharing;
- USB pointing devices;
- keyboard;
- GUI;
- VNC;
- directory sharing.

Only configure what is required.

Conceptual Linux configuration:

```text
VZVirtualMachineConfiguration

cpuCount
memorySize

VZGenericPlatformConfiguration
VZEFIBootLoader

VZVirtioBlockDeviceConfiguration
VZVirtioNetworkDeviceConfiguration
VZVirtioEntropyDeviceConfiguration
VZVirtioSocketDeviceConfiguration

optional serial console
```

macOS:

```text
VZVirtualMachineConfiguration

cpuCount
memorySize

VZMacPlatformConfiguration
VZMacOSBootLoader

VZVirtioBlockDeviceConfiguration
VZVirtioNetworkDeviceConfiguration
VZVirtioEntropyDeviceConfiguration
VZVirtioSocketDeviceConfiguration
```

Only add a graphics device if macOS requires one for a supported configuration.

If required, configure a minimal headless-compatible display but do not expose UI.

---

# 28. VM configuration modules

Target module:

```text
VirtualizationCore
```

Suggested types:

```swift
struct VMInstanceSpec
struct VMRuntimePaths
struct HostCapabilities

protocol VMPlatformBuilder

struct MacVMPlatformBuilder
struct LinuxVMPlatformBuilder

struct VMConfigurationBuilder

final class VMRuntime
```

Important rule:

`VMConfigurationBuilder` MUST NOT depend on:

- GitHub;
- SQLite;
- OCI;
- scheduler;
- CLI.

Input:

```swift
VMInstanceSpec
ImageMetadata
VMRuntimePaths
HostCapabilities
```

Output:

```swift
VZVirtualMachineConfiguration
```

Nothing else.

---

# 29. `VMInstanceSpec`

Suggested model:

```swift
struct VMInstanceSpec: Codable, Sendable {
    let id: UUID
    let imageDigest: ImageDigest

    let os: GuestOS

    let cpuCount: Int
    let memoryBytes: UInt64
    let diskBytes: UInt64

    let networkMode: NetworkMode
    let sshEnabled: Bool

    let lifecycle: InstanceLifecycle
}
```

Do not make this a giant collection of Tart-compatible options.

RunnerVM only needs runner-oriented options.

---

# 30. VM worker IPC

Each worker exposes:

```text
/var/run/runnervm/vm-<short-id>.sock
```

Use a versioned local protocol.

Recommended initial implementation:

**length-prefixed JSON RPC over Unix-domain socket**

Why:

- easy debugging;
- no need to expose HTTP;
- straightforward versioning;
- easy test fakes;
- does not add a server framework dependency.

Envelope:

```json
{
  "version": 1,
  "requestId": "uuid",
  "method": "vm.status",
  "params": {}
}
```

Response:

```json
{
  "version": 1,
  "requestId": "uuid",
  "result": {
    "state": "running"
  }
}
```

Errors:

```json
{
  "version": 1,
  "requestId": "uuid",
  "error": {
    "code": "VM_NOT_RUNNING",
    "message": "virtual machine is not running"
  }
}
```

---

# 31. VM worker API

Initial methods:

```text
worker.hello
worker.status

vm.start
vm.requestStop
vm.forceStop
vm.state

agent.proxyStatus

worker.shutdown
```

Potential later:

```text
vm.pause
vm.resume
```

but suspend/save-state functionality is explicitly non-goal for v1.

The daemon SHOULD normally start a worker with immutable startup parameters:

```text
vmworker \
  --instance <uuid> \
  --spec <path> \
  --socket <path>
```

Worker should not be remotely reconfigured into a different VM after startup.

---

# 32. Guest agent transport

Use a fixed virtio-socket port.

Provisional:

```text
4050
```

The value MUST be centralized.

Architecture:

```text
runnerd
   │
   │ gRPC via local UDS
   ▼
vmworker proxy
   │
   │ VZVirtioSocket
   ▼
guest-agent :4050
```

`vmworker` owns access to `VZVirtioSocketDevice`.

It provides a short-lived/local bridge to the guest agent.

Tart currently follows a comparable model by bridging a Unix-domain socket to a VM virtio socket and using gRPC through the bridge.  

This is a reasonable low-risk pattern to retain conceptually.

---

# 33. Guest agent API

Use protobuf/gRPC.

Define the protocol in:

```text
Proto/guest_agent.proto
```

Generate:

- Go server bindings;
- Swift client bindings.

Initial service:

```protobuf
service GuestAgent {
  rpc Hello(HelloRequest) returns (HelloResponse);
  rpc Health(HealthRequest) returns (HealthResponse);
  rpc GetInfo(GetInfoRequest) returns (GetInfoResponse);
  rpc GetMetrics(GetMetricsRequest) returns (GetMetricsResponse);

  rpc StartRunner(StartRunnerRequest) returns (StartRunnerResponse);
  rpc RunnerStatus(RunnerStatusRequest) returns (RunnerStatusResponse);
  rpc StopRunner(StopRunnerRequest) returns (StopRunnerResponse);

  rpc Cleanup(CleanupRequest) returns (CleanupResponse);

  rpc Exec(ExecRequest) returns (ExecResponse);

  rpc Shutdown(ShutdownRequest) returns (ShutdownResponse);
}
```

Streaming may be added later:

```protobuf
rpc StreamRunnerLogs(...) returns (stream LogChunk);
```

Do not start with a huge remote-management API.

---

# 34. Guest handshake

`HelloResponse`:

```text
protocol_version
agent_version
os
architecture
hostname
boot_id
instance_id
capabilities[]
```

During image preparation, each instance must be able to obtain its intended instance ID.

Possible mechanism:

- VZ serial/virtio configuration;
- small instance metadata file created on the cloned filesystem;
- kernel command parameter for Linux;
- one-time host handshake.

Prefer the simplest mechanism that does not require mounting the guest filesystem from the host.

The agent MAY initially report a boot-generated ID while the daemon associates the connection with the worker/instance.

---

# 35. Guest health states

Agent SHOULD expose:

```text
starting
ready
degraded
shuttingDown
```

A VM is not scheduler-ready merely because Virtualization.framework reports it as running.

Required transition:

```text
VZ VM running
   ↓
guest-agent responds
   ↓
agent health = ready
   ↓
VM capacity is usable
```

---

# 36. Starting GitHub runner inside guest

`StartRunnerRequest` contains:

```text
runnerSessionId
encodedJITConfig
workDirectory
environment
optionalJobMetadata
```

The JIT configuration MUST be treated as a secret.

Requirements:

- never log the raw JIT config;
- do not store it in SQLite;
- do not store it in normal VM metadata;
- keep it in memory where practical;
- pass directly to GitHub runner startup;
- redact command-line display if process inspection could expose it.

The agent launches something conceptually equivalent to:

```text
actions-runner/run.sh --jitconfig <config>
```

following GitHub's JIT runner model.

If the GitHub runner requires the JIT config in an argument, evaluate whether local process listings make it visible and use the safest supported invocation available.

---

# 37. Runner user

GitHub job code MUST NOT run as `root`.

Create:

```text
runner
```

user in both guest types.

The guest agent itself may require elevated privileges for limited host-management tasks, but it SHOULD launch the GitHub Actions runner under `runner`.

On Linux:

```text
systemd
  guest-agent
       │
       └── launches actions runner as runner
```

On macOS:

```text
launchd
  guest-agent
       │
       └── launches actions runner as runner
```

---

# 38. Manual exec

Support:

```text
runnerctl vm exec <id> -- command...
```

through the guest agent.

This is an administration/debugging feature.

Requirements:

- disabled by policy if desired;
- output bounded or streamed;
- explicit timeout;
- never available directly from a guest to the host;
- audit log the invocation, but avoid logging secrets passed as arguments.

SSH remains preferable for extended debugging sessions.

---

# 39. Guest metrics

`GetMetrics` should collect at least:

```text
timestamp
uptime

cpu:
  logicalCount
  usagePercent
  load1
  load5
  load15

memory:
  totalBytes
  usedBytes
  availableBytes

disk:
  rootTotalBytes
  rootUsedBytes
  rootAvailableBytes

runner:
  processRunning
  pid
  cpuPercent
  rssBytes
```

Optional:

```text
network tx/rx
disk read/write throughput
```

Do not overcomplicate initial telemetry.

---

# 40. Host-side VM metrics

For each VM collect both:

## Host-observed

From `vmworker` process:

```text
worker CPU %
worker resident memory
worker process uptime
worker exit status
```

## Guest-observed

From guest agent:

```text
guest CPU %
guest memory
guest disk
load
runner process stats
```

## Configuration

```text
configured vCPU
configured memory
virtual disk size
local allocated disk bytes
```

Expose these separately.

Do not label worker RSS as "guest memory usage."

---

# 41. Lifecycle timing metrics

Record:

```text
image_pull_seconds
instance_clone_seconds
worker_start_seconds
vm_boot_to_running_seconds
vm_running_to_agent_ready_seconds
jit_generation_seconds
jit_delivery_to_runner_online_seconds
job_duration_seconds
cleanup_seconds
instance_delete_seconds
```

These will eventually identify where a warm pool has actual value.

Do not introduce warm pools based on assumptions; instrument cold start first.

---

# 42. Structured logging

Use structured JSON logs.

Suggested fields:

```json
{
  "timestamp": "...",
  "level": "info",
  "component": "scheduler",
  "message": "starting instance",

  "profile_id": "...",
  "instance_id": "...",
  "runner_session_id": "...",
  "github_job_request_id": "...",
  "operation_id": "..."
}
```

Required components:

```text
daemon
github
scheduler
image
worker-supervisor
vmworker
guest
runner
database
reconciler
metrics
```

Sensitive fields MUST be redacted centrally.

Redaction patterns MUST cover at least:

```text
Authorization
Bearer
PAT
GitHub App token
installation token
JIT config
registry password
registry access token
SSH private key
```

Do not rely on every callsite remembering to redact.

---

# 43. Metrics exposure

Initial implementation:

```text
runnerctl metrics
```

returns a snapshot.

Also support optional local HTTP metrics endpoint:

```yaml
metrics:
  prometheus:
    enabled: false
    listen: 127.0.0.1:9095
```

If enabled:

```text
GET /metrics
```

Prometheus format.

Do not require Prometheus to operate RunnerVM.

---

# 44. SQLite design

SQLite is the source of durable orchestrator state.

The filesystem is the source of VM/image bytes.

Neither alone is sufficient.

Enable:

```text
WAL mode
foreign_keys = ON
busy_timeout
```

Only `runnerd` writes the database.

CLI never directly opens it.

Use explicit schema migrations.

---

# 45. SQLite tables

## `schema_migrations`

```text
version INTEGER PRIMARY KEY
applied_at TEXT NOT NULL
```

---

## `github_scopes`

```text
id TEXT PRIMARY KEY
name TEXT UNIQUE NOT NULL

kind TEXT NOT NULL
owner TEXT NOT NULL
repository TEXT NULL

runner_group_id INTEGER NULL

enabled INTEGER NOT NULL

created_at TEXT NOT NULL
updated_at TEXT NOT NULL
```

`kind`:

```text
organization
repository
```

---

## `runner_profiles`

```text
id TEXT PRIMARY KEY
name TEXT UNIQUE NOT NULL

scope_id TEXT NOT NULL
image_reference TEXT NOT NULL

lifecycle TEXT NOT NULL

cpu_count INTEGER NOT NULL
memory_bytes INTEGER NOT NULL
disk_bytes INTEGER NOT NULL

min_idle INTEGER NOT NULL DEFAULT 0
max_idle INTEGER NOT NULL DEFAULT 0
max_instances INTEGER NULL

ssh_enabled INTEGER NOT NULL DEFAULT 1

config_json TEXT NOT NULL

enabled INTEGER NOT NULL

created_at TEXT NOT NULL
updated_at TEXT NOT NULL

FOREIGN KEY(scope_id) REFERENCES github_scopes(id)
```

---

## `scale_sets`

```text
id TEXT PRIMARY KEY

profile_id TEXT UNIQUE NOT NULL

github_scale_set_id INTEGER NULL
github_scale_set_name TEXT NOT NULL

state TEXT NOT NULL

last_message_id INTEGER NULL

created_at TEXT NOT NULL
updated_at TEXT NOT NULL

FOREIGN KEY(profile_id) REFERENCES runner_profiles(id)
```

Do not persist renewable message queue bearer secrets unless absolutely necessary.

Prefer re-establishing sessions after daemon restart.

---

## `images`

```text
digest TEXT PRIMARY KEY

canonical_reference TEXT NULL

os TEXT NOT NULL
architecture TEXT NOT NULL

schema_version INTEGER NOT NULL

metadata_json TEXT NOT NULL

local_path TEXT NOT NULL

virtual_size_bytes INTEGER NOT NULL
allocated_size_bytes INTEGER NULL

runner_version TEXT NULL
guest_agent_version TEXT NULL

state TEXT NOT NULL

created_at TEXT NOT NULL
pulled_at TEXT NULL
last_used_at TEXT NULL
```

State:

```text
pulling
ready
invalid
deleting
```

---

## `instances`

```text
id TEXT PRIMARY KEY

profile_id TEXT NOT NULL
image_digest TEXT NOT NULL

host_id TEXT NOT NULL

lifecycle TEXT NOT NULL

state TEXT NOT NULL
desired_state TEXT NOT NULL

cpu_count INTEGER NOT NULL
memory_bytes INTEGER NOT NULL
disk_bytes INTEGER NOT NULL

worker_pid INTEGER NULL
worker_generation INTEGER NOT NULL DEFAULT 0
worker_socket TEXT NULL

mac_address TEXT NULL
machine_identifier TEXT NULL

instance_path TEXT NOT NULL

created_at TEXT NOT NULL
started_at TEXT NULL
agent_ready_at TEXT NULL
stopped_at TEXT NULL
deleted_at TEXT NULL

last_seen_at TEXT NULL
failure_code TEXT NULL
failure_message TEXT NULL

FOREIGN KEY(profile_id) REFERENCES runner_profiles(id)
FOREIGN KEY(image_digest) REFERENCES images(digest)
```

---

## `runner_sessions`

```text
id TEXT PRIMARY KEY

instance_id TEXT NOT NULL
profile_id TEXT NOT NULL

github_runner_id INTEGER NULL
github_runner_name TEXT NULL
github_job_request_id TEXT NULL

state TEXT NOT NULL

jit_issued_at TEXT NULL
jit_delivered_at TEXT NULL
runner_started_at TEXT NULL
runner_online_at TEXT NULL

job_started_at TEXT NULL
job_finished_at TEXT NULL

result TEXT NULL

created_at TEXT NOT NULL
updated_at TEXT NOT NULL

FOREIGN KEY(instance_id) REFERENCES instances(id)
```

Never add:

```text
jit_config TEXT
```

to this table.

---

## `operations`

Useful for reconciliation/debugging:

```text
id TEXT PRIMARY KEY

kind TEXT NOT NULL
resource_type TEXT NOT NULL
resource_id TEXT NOT NULL

state TEXT NOT NULL

started_at TEXT NOT NULL
finished_at TEXT NULL

error_code TEXT NULL
error_message TEXT NULL
metadata_json TEXT NULL
```

Examples:

```text
pull-image
clone-instance
boot-instance
issue-jit
destroy-instance
reconcile
```

---

## `job_summaries`

Store low-frequency summary telemetry rather than high-frequency time series.

```text
id TEXT PRIMARY KEY

runner_session_id TEXT NOT NULL

peak_guest_memory_bytes INTEGER NULL
average_guest_cpu REAL NULL
peak_worker_rss_bytes INTEGER NULL

clone_duration_ms INTEGER NULL
boot_duration_ms INTEGER NULL
agent_ready_duration_ms INTEGER NULL
job_duration_ms INTEGER NULL

created_at TEXT NOT NULL
```

Do not fill SQLite with one-second metrics samples forever.

---

# 46. Instance state machine

Use explicit persisted state.

Recommended states:

```text
planned
preparing
cloning
startingWorker
startingVM
waitingForAgent
idle
configuringRunner
runnerStarting
runnerOnline
busy
cleaning
stopping
deleting
deleted

failed
orphaned
interrupted
```

Typical ephemeral path:

```text
planned
   ↓
preparing
   ↓
cloning
   ↓
startingWorker
   ↓
startingVM
   ↓
waitingForAgent
   ↓
idle
   ↓
configuringRunner
   ↓
runnerStarting
   ↓
runnerOnline
   ↓
busy
   ↓
stopping
   ↓
deleting
   ↓
deleted
```

Reusable:

```text
busy
  ↓
cleaning
  ↓
idle
```

---

# 47. Runner session state machine

Separate GitHub runner lifecycle from VM lifecycle.

```text
planned
   ↓
jitRequested
   ↓
jitIssued
   ↓
jitDelivered
   ↓
runnerStarting
   ↓
runnerOnline
   ↓
jobRunning
   ↓
completed
```

Failures:

```text
jitFailed
runnerStartFailed
runnerLost
jobInterrupted
timedOut
```

This separation is essential.

A VM may be healthy while a JIT runner session fails.

Do not collapse everything into:

```text
VMState.running
```

---

# 48. GitHub job startup sequence

Default sequence:

```text
1. GitHub scale set indicates demand.

2. runnerd records durable demand state.

3. Scheduler calculates local capacity.

4. Select compatible RunnerProfile.

5. Resolve image tag to digest.

6. Ensure digest exists locally.

7. Create Instance DB row.

8. APFS-clone image into instance directory.

9. Generate unique instance identity.

10. Spawn vmworker.

11. vmworker creates VZVirtualMachineConfiguration.

12. vmworker starts VM.

13. Wait for guest-agent readiness.

14. Only now obtain/generate JIT runner configuration.

15. Create RunnerSession row.

16. Deliver JIT config through vsock.

17. Guest agent starts GitHub Actions runner.

18. Observe runner becoming ready/assigned.

19. Job runs.

20. Observe completion/runner exit.

21. Persist job summary.

22. For ephemeral profile:
      gracefully shut down VM,
      stop worker,
      delete instance files.

23. For reusable profile:
      cleanup guest,
      return VM to idle state.

24. Recalculate capacity.
```

Important principle:

> Generate JIT configuration as late as practical.

If clone or boot fails before step 14, we avoid creating unnecessary stale GitHub runner state.

---

# 49. GitHub message acknowledgment

Scale-set events/messages MUST be handled idempotently.

General rule:

```text
receive message
   ↓
write durable local intent/state
   ↓
process or schedule it
   ↓
acknowledge appropriately
```

Do not acknowledge a critical event before sufficient local state exists to recover from a daemon crash.

Because the current scale-set client uses explicit queue message acknowledgment and supports redelivery semantics, the Swift implementation must be designed for duplicate delivery. 

Therefore every GitHub work identifier should map to an idempotency key.

---

# 50. GitHub API transport abstraction

Implement:

```swift
protocol GitHubActionsControlPlane {
    func ensureScaleSet(...)
    func createMessageSession(...)
    func nextMessage(...)
    func acknowledgeMessage(...)
    func acquireJobs(...)
    func generateJITConfig(...)
    func getRunnerState(...)
}
```

Concrete:

```text
GitHubScaleSetControlPlane
```

Do not let raw endpoint paths leak into:

- scheduler;
- database repositories;
- VM manager.

Because GitHub's scale-set client is presently public preview, this boundary is mandatory.

---

# 51. Do not embed the official Go scale-set client as the permanent architecture

The official GitHub Go library is useful as:

- API behavior reference;
- test oracle;
- protocol documentation;
- fixture source.

RunnerVM's production control plane SHOULD be native Swift.

Implement only the subset required by RunnerVM.

Do not port unrelated functionality.

If initial experimentation requires a tiny Go prototype, that is acceptable, but it should not become an architectural dependency without a compelling reason.

---

# 52. GitHub API reliability

All network operations require:

- explicit timeout;
- retry policy;
- rate-limit handling;
- `Retry-After` handling;
- exponential backoff;
- jitter;
- cancellation;
- structured error classification.

Classify errors:

```text
authentication
authorization
rateLimited
notFound
conflict
transientServer
transport
invalidResponse
permanentConfiguration
```

Never write scheduler logic that parses human-readable HTTP error strings.

---

# 53. GitHub runner software versioning

Bake the runner binary into images for fast cold starts.

Image metadata stores:

```text
runnerVersion
```

RunnerVM SHOULD periodically determine whether the installed version is still acceptable.

GitHub documents update requirements for self-hosted runners, including restrictions when automatic runner updates are disabled.

Implement a policy:

```yaml
runnerVersionPolicy:
  staleAction: warn
  maxAge: 21d
```

Later:

```yaml
staleAction: block
```

Do not automatically mutate an immutable image when a new runner release appears.

Instead:

```text
image marked stale
   ↓
new image build/publish required
```

---

# 54. OCI/GHCR architecture

OCI is a storage/transport format.

It is not the local VM domain model.

Implement module:

```text
OCIRegistry
```

Responsibilities:

- parse OCI references;
- registry auth;
- fetch manifest;
- pull blobs;
- verify digest;
- push blobs;
- push manifest;
- tag management;
- GHCR compatibility.

---

# 55. Do not make Tart OCI media types canonical

Current Tart manifests use Tart/Cirrus-specific layer types such as:

```text
application/vnd.cirruslabs.tart.config.v1
application/vnd.cirruslabs.tart.disk.v2
application/vnd.cirruslabs.tart.disk.asif.overlay.v1
application/vnd.cirruslabs.tart.nvram.v1
```



RunnerVM should define its own versioned OCI artifact schema.

Provisional:

```text
application/vnd.runnervm.config.v1+json
application/vnd.runnervm.disk.raw.v1+zstd
application/vnd.runnervm.efi.v1
application/vnd.runnervm.macos.auxiliary-storage.v1
```

Before public release, namespace these media types under the final project/vendor name.

---

# 56. OCI image manifest structure

Conceptually:

```text
OCI image manifest
   │
   ├── config JSON
   │
   ├── disk chunk 0
   ├── disk chunk 1
   ├── disk chunk 2
   │
   └── boot/platform data
```

Config JSON describes:

```text
schema version
os
architecture
disk format
disk virtual size
guest agent version
runner version
host requirements
macOS hardware model if applicable
capabilities
```

Disk blobs SHOULD be compressed and chunked.

Use content digests for every chunk.

Always verify downloaded content against OCI digest.

---

# 57. OCI cache

Implement a content-addressable local blob cache:

```text
images/blobs/sha256/<digest>
```

If two images share the same blob:

```text
store once
```

The cache should eventually support safe pruning based on references.

Pruning MUST acquire an image-store lock/reconciliation barrier so it never deletes blobs required by an active image/instance.

---

# 58. Tart image compatibility

Useful v1 migration feature:

```text
runnerctl image import-tart ...
```

or:

```text
runnerctl image pull --format tart ...
```

Implement a **read-only compatibility importer**.

Responsibilities:

```text
Tart OCI artifact
       ↓
validate
       ↓
materialize VM data
       ↓
convert metadata
       ↓
seal as RunnerVM image
```

Do not make the scheduler operate directly on Tart manifests.

Once imported:

```text
Tart compatibility ends
```

and the result behaves like a native RunnerVM image.

This allows existing macOS/Tart image ecosystems to bootstrap development without making Tart's image schema permanent.

---

# 59. Image creation strategy

Keep multiple paths open.

Define:

```swift
protocol ImageBuilder {
    func build(_ request: ImageBuildRequest) async throws -> ImageArtifact
}
```

Potential implementations:

```text
ImportedImageBuilder
LinuxCloudImageBuilder
MacIPSWImageBuilder
```

V1 SHOULD prioritize:

1. importing/pulling existing prepared images;
2. native Ubuntu builder;
3. manual sealing.

IPSW-based macOS creation can follow.

---

# 60. Linux image creation

Recommended build flow:

```text
Ubuntu 24.04 ARM64 cloud image
       ↓
create mutable VM
       ↓
cloud-init / bootstrap
       ↓
install:
  guest-agent
  actions runner
  Docker
  SSH
  baseline tools
       ↓
shutdown
       ↓
clean transient state
       ↓
seal image
       ↓
push OCI artifact
```

Provide:

```text
runnerctl image build linux ...
```

later.

Initial implementation MAY use an external preparation script while the core image format stabilizes.

---

# 61. macOS image creation

Support a future path based on:

```text
IPSW
  ↓
VZMacOSRestoreImage
  ↓
VZMacOSInstaller
  ↓
base installation
  ↓
provision agent/runner/toolchains
  ↓
seal
```

Do not require this to complete the first Linux end-to-end milestone.

The scheduler MUST remain ignorant of how an image was produced.

For macOS, initially prioritize consuming known-good prebuilt images and a sealing/conversion process.

---

# 62. Image sealing

A mutable builder VM becomes immutable only via explicit seal operation.

Example:

```text
runnerctl image seal builder-123 \
  --name macos-15-xcode-16
```

Seal steps:

```text
verify VM stopped
verify guest-agent installed
verify runner installed
remove transient runner configuration
remove known temp files
remove SSH host state if instance-specific
normalize metadata
calculate hashes
mark base files read-only
write image manifest
```

Then optionally:

```text
runnerctl image push \
  macos-15-xcode-16 \
  ghcr.io/acme/runners/macos-15-xcode-16:v1
```

---

# 63. Configuration system

Human-facing declarative configuration should use YAML.

Internally decode into strongly typed Swift models.

Example:

```yaml
version: 1

host:
  reserve:
    cpu: 2
    memory: 6GiB
    disk: 50GiB

  overcommit:
    cpu: 1.0
    memory: 1.0

  maxVMs: auto

github:
  auth:
    provider: pat
    source: keychain

  scopes:
    - name: engineering
      type: organization
      owner: acme
      runnerGroup: Default

profiles:
  - name: ubuntu-24
    scope: engineering

    image: ghcr.io/acme/runners/ubuntu-24:stable

    lifecycle: ephemeral

    resources:
      cpu: 4
      memory: 8GiB
      disk: 80GiB

    warmPool:
      minIdle: 0
      maxIdle: 0
      idleTTL: 20m

    limits:
      maxInstances: 4

    ssh:
      enabled: true

  - name: macos-15-xcode-16
    scope: engineering

    image: ghcr.io/acme/runners/macos-15-xcode-16:stable

    lifecycle: ephemeral

    resources:
      cpu: 6
      memory: 12GiB
      disk: 120GiB

    limits:
      maxInstances: 2

metrics:
  prometheus:
    enabled: false
```

---

# 64. Configuration application model

Use:

```text
runnerctl config validate config.yaml
runnerctl config apply config.yaml
```

`apply` SHOULD:

1. parse;
2. validate;
3. compute desired-state diff;
4. transact database changes;
5. trigger reconciliation.

Do not restart `runnerd` for ordinary profile configuration changes.

---

# 65. Strong defaults

Defaults:

```text
host architecture:
  arm64 only

host minimum:
  macOS 15

network:
  NAT

lifecycle:
  ephemeral

warm pool:
  0

memory overcommit:
  disabled

CPU overcommit:
  disabled

SSH:
  enabled for development
  configurable globally

scale mode:
  GitHub Runner Scale Set

Linux:
  Ubuntu 24.04 LTS ARM64

guest control:
  virtio socket

database:
  SQLite WAL

image source:
  OCI/GHCR

long-lived credentials in guest:
  forbidden
```

---

# 66. Local daemon API

`runnerctl` communicates only through:

```text
/var/run/runnervm/runnerd.sock
```

Use versioned JSON RPC.

Suggested methods:

```text
system.status
system.doctor
system.reconcile

config.get
config.apply

profile.list
profile.get

scope.list
scope.get

image.list
image.get
image.pull
image.push
image.delete
image.prune
image.importTart

instance.list
instance.get
instance.stop
instance.delete
instance.exec
instance.sshInfo

runner.list
runner.get

logs.tail

metrics.snapshot
```

Every mutation should return an operation ID for long-running actions where appropriate.

---

# 67. CLI

Provisional command structure:

```text
runnerctl status

runnerctl doctor

runnerctl config validate <file>
runnerctl config apply <file>

runnerctl scope list

runnerctl profile list
runnerctl profile show <name>

runnerctl image list
runnerctl image pull <ref>
runnerctl image push <image> <ref>
runnerctl image inspect <image>
runnerctl image prune
runnerctl image import-tart <ref>

runnerctl vm list
runnerctl vm show <id>
runnerctl vm stop <id>
runnerctl vm delete <id>
runnerctl vm ssh <id>
runnerctl vm exec <id> -- <command>
runnerctl vm logs <id>

runnerctl runner list
runnerctl runner show <session>

runnerctl metrics

runnerctl daemon reconcile

runnerctl auth login
runnerctl auth status
runnerctl auth logout
```

Naming can change, but command responsibilities should remain.

---

# 68. Recovery and reconciliation philosophy

This is one of the most important parts of the project.

The database never blindly determines reality.

The filesystem never blindly determines reality.

A worker PID never blindly determines reality.

GitHub never blindly determines local reality.

Instead:

```text
desired state
     +
database state
     +
filesystem state
     +
worker state
     +
guest state
     +
GitHub state
     =
reconciliation decision
```

---

# 69. Daemon startup reconciliation

On startup:

```text
1. Acquire single-daemon lock.

2. Open SQLite.

3. Run migrations.

4. Load configuration.

5. Detect host resources.

6. Scan known worker sockets.

7. Inspect recorded worker PIDs.

8. Reconnect to living workers.

9. Mark stale PIDs dead.

10. Scan instance directories.

11. Match filesystem instances to DB records.

12. Detect missing/corrupt instance storage.

13. Reestablish GitHub scale-set sessions.

14. Refresh demand.

15. Reconcile runner sessions.

16. Restore desired reusable instances.

17. Restore configured warm pool.

18. Schedule pending GitHub demand.

19. Queue safe garbage collection of abandoned
    ephemeral resources.
```

Each step MUST be idempotent.

---

# 70. Daemon restart during a running job

Preferred mature behavior:

```text
GitHub job running
       │
vmworker alive
       │
runnerd crashes
       │
VM continues
       │
new runnerd starts
       │
reconnects
       │
reconstructs RunnerSession
       │
continues observation
```

This should be a design goal.

It may not be required in the first implementation milestone, but the worker protocol MUST not preclude it.

---

# 71. Host reboot behavior

A host reboot is different.

The VM processes disappear.

An arbitrary GitHub Actions job cannot generally be resumed as though the machine never rebooted.

Therefore the specification MUST NOT promise:

> "resume the same in-progress GitHub job after host reboot."

Instead:

```text
host reboot
   ↓
runnerd starts
   ↓
detect previous instance was interrupted
   ↓
mark runner session interrupted
   ↓
cleanup/reconcile GitHub state
   ↓
GitHub job lifecycle handles failure/retry as applicable
```

Then:

- reusable desired VMs may be recreated/restarted;
- warm pool may be restored;
- queued demand is handled;
- stale ephemeral instance directories are cleaned.

This satisfies automatic recovery without pretending in-flight process state survives a physical reboot.

---

# 72. Worker crash recovery

If:

```text
VZ VM supposed to be running
but worker process disappears
```

then:

```text
instance.state = interrupted
```

If ephemeral and associated with an active job:

- mark runner session lost/interrupted;
- do not attempt to reuse the VM disk;
- clean after diagnostic grace period.

If idle reusable:

- restart from its disk according to policy.

If warm ephemeral:

- destroy and recreate.

---

# 73. Timeouts

Every lifecycle stage needs a timeout.

Configurable defaults:

```text
image pull timeout
clone timeout
VM boot timeout
agent-ready timeout
JIT generation timeout
runner-online timeout
job maximum runtime
graceful shutdown timeout
cleanup timeout
```

Example model:

```yaml
timeouts:
  vmBoot: 3m
  agentReady: 2m
  runnerOnline: 2m
  gracefulShutdown: 30s
```

Values need benchmarking before final production defaults.

Timeout expiration becomes a typed failure and triggers reconciliation.

---

# 74. Failure diagnostics

On VM startup failure preserve diagnostic data temporarily.

Example:

```text
instances/<uuid>/
    failure.json
    serial.log
    worker.log
```

Policy:

```yaml
diagnostics:
  failedInstanceRetention: 2h
```

Do not immediately destroy all evidence when a VM boot fails.

But successful ephemeral jobs should still clean themselves promptly.

---

# 75. Security model

Assume GitHub Actions job code is potentially hostile to the host.

Even internal repositories can execute compromised dependencies.

Therefore:

- no host directory sharing by default;
- no host Docker socket;
- no PAT in guest;
- no GitHub App key in guest;
- no OCI credential in guest;
- no host SSH private key in guest;
- no clipboard;
- no bridged network;
- no arbitrary guest-to-host control API;
- no privileged guest filesystem mounts into host;
- one job per ephemeral VM.

---

# 76. Guest-agent trust boundary

The guest is not trusted.

Even though the host controls the guest agent binary initially, a job running with sufficient guest privileges could replace or attack it.

Host-side protocol implementation MUST:

- enforce maximum frame/message sizes;
- validate every protobuf field;
- set RPC deadlines;
- handle malformed responses;
- never deserialize arbitrary executable objects;
- never interpret guest-provided paths as host filesystem paths;
- never execute host commands requested by the guest;
- never accept arbitrary guest-initiated host RPCs.

Control is host-initiated.

---

# 77. Public repository safety

Self-hosted runners and untrusted public pull-request workloads present significant risk.

Default policy:

```yaml
security:
  allowPublicRepositories: false
```

RunnerVM SHOULD reject configuration for a public repository unless explicitly permitted.

The explicit opt-in should produce a warning.

---

# 78. SSH credentials

Do not bake a reusable private key into images.

Options:

1. bake only a controlled public key;
2. provision an ephemeral authorized key at instance startup;
3. generate host-side per-instance credentials.

Recommended future design:

```text
runnerctl vm ssh
     │
     ├── runnerd generates/loads ephemeral key
     ├── guest agent installs temporary public key
     └── runnerctl launches ssh
```

V1 may use an internal development public key if necessary, but this should not become production default.

---

# 79. OCI credentials

Keep registry auth independent of GitHub Actions auth.

Possible credentials:

```text
GHCR PAT
GitHub App package credential if supported
docker credential helper
Keychain token
```

Interface:

```swift
protocol RegistryCredentialProvider
```

Never reuse abstractions in a way that accidentally passes GitHub Actions control-plane credentials into an image pull request unless that is explicitly configured.

---

# 80. Package/module layout

The current Tart package is essentially one large executable target with broad dependencies. 

RunnerVM should immediately move toward modular Swift packages/targets.

Recommended:

```text
Package.swift

Sources/

  RunnerCore/
    Models/
    StateMachines/
    IDs/
    Errors/
    Configuration/

  VirtualizationCore/
    VMConfigurationBuilder.swift
    VMRuntime.swift
    MacVMPlatform.swift
    LinuxVMPlatform.swift
    HostCapabilities.swift
    VMIdentity.swift

  Persistence/
    Database.swift
    Migrations/
    Repositories/

  ImageStore/
    ImageStore.swift
    InstanceStore.swift
    APFSClone.swift
    ImageMetadata.swift

  OCIRegistry/
    RegistryClient.swift
    OCIReference.swift
    Manifest.swift
    BlobStore.swift
    RegistryAuthentication.swift

  GitHubControl/
    GitHubHTTPClient.swift
    Authentication/
    JIT/
    ScaleSet/
    Models/

  Scheduler/
    Scheduler.swift
    CapacityCalculator.swift
    Placement.swift

  WorkerProtocol/
    Messages.swift
    Framing.swift

  GuestControl/
    Generated/
    GuestAgentClient.swift

  Metrics/
    HostMetrics.swift
    MetricRegistry.swift

  Logging/
    JSONLogHandler.swift
    Redaction.swift

  DaemonAPI/
    Protocol.swift
    Server.swift
    Client.swift

  runnerd/
    main.swift

  runnerctl/
    main.swift

  vmworker/
    main.swift


GuestAgent/

  go.mod

  cmd/
    guest-agent/

  internal/
    runner/
    metrics/
    system/
    cleanup/

Proto/
  guest_agent.proto
```

---

# 81. Dependency direction

Enforce:

```text
RunnerCore
   ▲
   │
VirtualizationCore
Persistence
ImageStore
OCIRegistry
GitHubControl
Scheduler
GuestControl
```

`RunnerCore` should be mostly Foundation-free domain logic where practical.

The scheduler should depend on protocols.

Bad:

```text
Scheduler -> concrete SQLite -> concrete GitHub URLSession -> VZVirtualMachine
```

Good:

```text
Scheduler
   ├── DemandSource
   ├── InstanceManager
   ├── CapacityProvider
   └── StateRepository
```

---

# 82. Swift concurrency

Use modern Swift structured concurrency.

Preferred stateful services:

```text
actor Orchestrator
actor InstanceManager
actor ImageManager
actor ScaleSetController
actor MetricsRegistry
```

Avoid:

- global mutable variables;
- global VM pointers;
- ad-hoc semaphores where actors solve the problem;
- callback pyramids.

Virtualization.framework operations requiring main-thread/MainActor semantics should be isolated inside `vmworker`.

Do not force the entire daemon onto MainActor.

---

# 83. Stable identifiers

Use UUIDs internally.

Types:

```swift
struct InstanceID
struct RunnerSessionID
struct RunnerProfileID
struct GitHubScopeID
struct OperationID
```

Avoid passing raw Strings everywhere.

Implement these as lightweight `RawRepresentable`, `Codable`, `Hashable`, `Sendable` wrappers.

This prevents accidental ID mixups.

---

# 84. Error model

Use typed domain errors.

Examples:

```swift
enum VMError
enum ImageError
enum GitHubControlError
enum SchedulerError
enum GuestAgentError
enum PersistenceError
enum ConfigurationError
```

Every error should provide:

```text
machine-readable code
human-readable description
retryability
optional underlying cause
```

Example:

```text
GITHUB_RATE_LIMITED
retryable = true
```

versus:

```text
IMAGE_INCOMPATIBLE_HOST
retryable = false
```

---

# 85. Scheduler abstraction for future clusters

Even though v1 has one host, introduce:

```swift
struct HostID
```

The local host uses a stable generated ID.

Every instance record has:

```text
host_id
```

Define:

```swift
protocol InstancePlacementStrategy {
    func chooseHost(...) async throws -> HostID
}
```

V1 implementation:

```text
SingleHostPlacementStrategy
```

returns:

```text
localHostID
```

Do not build networking, consensus or a controller now.

This tiny abstraction is enough to avoid hard-coding "there can only ever be one host" into the schema.

---

# 86. Future cluster architecture

Do NOT implement now, but design toward:

```text
                Controller
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
    Host agent   Host agent   Host agent
       │            │            │
      VMs          VMs          VMs
```

Each Mac should continue to have:

- local image cache;
- local VM workers;
- local state required to recover its workloads.

The central controller should later own:

- global demand;
- placement;
- global capacity.

SQLite SHOULD NOT become a remotely shared cluster database.

---

# 87. Tart refactor plan

Treat the existing codebase in three categories.

## KEEP CONCEPT / REWRITE

### VM configuration

Current:

```text
Sources/tart/VM.swift
```

Extract/rewrite into:

```text
VirtualizationCore/
    VMConfigurationBuilder.swift
    VMRuntime.swift
```

Keep knowledge around:

- platform configuration;
- storage attachment;
- NAT network device;
- entropy;
- virtio socket;
- VM validation.

Remove unrelated desktop VM functionality.

---

### macOS platform

Current:

```text
Sources/tart/Platform/Darwin.swift
```

Rewrite into:

```text
MacVMPlatform.swift
```

Retain knowledge of:

- hardware model;
- machine identifier;
- auxiliary storage;
- boot loader.

---

### Linux platform

Current:

```text
Sources/tart/Platform/Linux.swift
```

Rewrite into:

```text
LinuxVMPlatform.swift
```

Keep:

- EFI variable store;
- generic platform;
- EFI boot loader.

---

### VM directory concepts

Current Tart's VM directory includes config, disk and NVRAM/auxiliary-storage concepts. 

Rewrite into distinct types:

```text
ImageStore
InstanceStore
VMRuntimePaths
```

Do not retain `VMDirectory` as a universal abstraction for images, instances and runtime state.

---

### Control socket / guest channel

Retain architecture:

```text
UDS
 ↓
virtio socket
 ↓
guest agent
```

Rewrite implementation around the new worker model.

---

## DELETE

Remove or do not carry forward:

```text
Tart GUI
VNC
clipboard integration
audio integration
keyboard/mouse options
desktop display management
suspend/save-state features
general-purpose tart run CLI
general-purpose VM shell formatting
advanced bridged networking
softnet features
Packer-specific CLI behavior
interactive VM UI
USB/UI peripheral features
unneeded archive functionality
nested virtualization controls for v1
Tart-specific telemetry assumptions
Tart naming and branding
```

---

## REWRITE COMPLETELY

These are new RunnerVM concepts:

```text
daemon architecture
SQLite persistence
scheduler
GitHub control plane
GitHub Scale Set integration
JIT lifecycle
runner profiles
worker supervisor
guest agent protocol
image metadata
OCI artifact schema
structured logging
resource metrics
reconciliation engine
CLI
configuration
security policy
```

---

# 88. Do not preserve Tart's global dependencies accidentally

When moving code, ask for every dependency:

> Is this dependency required by RunnerVM's domain, or is it inherited from Tart?

Current Tart pulls a broad set of dependencies including argument parsing, gRPC, ANTLR, telemetry libraries and others. 

Target a substantially smaller dependency graph.

Likely justified:

```text
swift-argument-parser
swift-log
GRDB or another strong SQLite wrapper
grpc-swift
swift-protobuf
possibly SwiftNIO
small YAML parser
```

Evaluate whether each additional package is actually necessary.

---

# 89. SQLite library

Prefer a mature SQLite wrapper such as GRDB rather than hand-writing a large C API layer.

Requirements:

- migrations;
- transactions;
- Codable-friendly records;
- WAL;
- concurrency correctness;
- explicit SQL access where needed.

Hide it behind repository interfaces so the domain logic does not depend on GRDB-specific query APIs.

---

# 90. Logging library

Use:

```text
swift-log
```

with a custom structured JSON log handler.

Do not bind the domain to `os.Logger`.

`vmworker` may additionally integrate with Unified Logging, but structured files/stdout should remain consistent.

---

# 91. Configuration parser

YAML is a user interface, not a domain dependency.

Architecture:

```text
YAML
 ↓
ConfigDTO
 ↓ validation
RunnerConfiguration
```

No scheduler code should parse YAML.

---

# 92. License and provenance requirements

This must be addressed before substantial refactoring.

The current `openai/tart` repository is distributed under **FSL-1.1-ALv2**, which expressly permits internal use but places restrictions around competing uses and redistribution; it provides a future Apache 2.0 license grant after the specified future-license period. 

Older Tart versions have had different licensing terms—for example, Tart 2.32.1 carried a Fair Source license—so cherry-picking arbitrary historical files can complicate provenance. 

This is not legal advice, but engineering MUST treat provenance as a first-class concern.

---

# 93. Provenance strategy

Immediately rename the fork/project and create:

```text
PROVENANCE.md
```

Track each source file as:

```text
derived-from-tart
rewritten-from-tart
new
third-party
generated
```

Example:

```text
VirtualizationCore/MacVMPlatform.swift

Origin:
  adapted from openai/tart
  Sources/tart/Platform/Darwin.swift
  commit: <sha>

Status:
  derived
```

A genuinely new implementation:

```text
Scheduler/CapacityCalculator.swift

Origin:
  new RunnerVM implementation
```

---

# 94. Quarantine derived Tart code

During early refactoring, consider:

```text
Sources/TartLegacy/
```

or explicit provenance markers.

Goal over time:

```text
Tart-derived code
████████████████████  initial fork

██████████            after VM extraction

████                  after rewrite

█                     before public release
```

Before public distribution, perform a license/provenance audit.

Do not assume the combined derivative repository can simply be relicensed under MIT/Apache on demand.

---

# 95. Rename Tart artifacts immediately

Change:

```text
binary names
bundle identifiers
logger subsystem names
directory names
environment variable prefixes
OCI media-type namespace
CLI commands
documentation
```

Do not leave:

```text
org.cirruslabs.tart
```

as the identity of the new system.

Compatibility code can explicitly mention Tart where necessary.

---

# 96. Recommended repository migration strategy

Do not attempt a single giant rewrite.

Use phases.

```text
fork Tart
   ↓
rename project
   ↓
make existing tests pass
   ↓
introduce new modules
   ↓
move/adapt low-level VZ code
   ↓
introduce runnerd
   ↓
introduce vmworker
   ↓
make old Tart CLI unnecessary
   ↓
delete old architecture
```

Keep the repository buildable at every major step.

---

# 97. Implementation phases

## Phase 0 — Project foundation and provenance

Deliver:

```text
new project name
new bundle IDs
new package targets
PROVENANCE.md
license preserved
CI builds
format/lint
basic unit test infrastructure
```

No behavior change required yet.

---

## Phase 1 — Core domain and persistence

Implement:

```text
RunnerCore
Persistence
configuration models
SQLite migrations
runnerd skeleton
runnerctl status
daemon Unix socket
structured logs
```

Acceptance:

```text
runnerd starts
runnerctl status works
SQLite is created/migrated
config can be validated/applied
```

No VM yet.

---

## Phase 2 — `vmworker` and Linux VM engine

Implement:

```text
VirtualizationCore
vmworker
Linux platform
NAT
virtio disk
virtio socket
worker IPC
```

Acceptance:

```text
runnerctl/debug API can create
and boot one Ubuntu VM through runnerd

runnerd does not instantiate VZVirtualMachine

vmworker owns VM
```

---

## Phase 3 — Guest agent

Implement Go guest agent.

Deliver:

```text
Hello
Health
GetInfo
GetMetrics
Shutdown
Exec
```

Acceptance:

```text
VM boots
runnerd reaches agent over vsock
IP can be discovered
metrics can be read
VM can shut down gracefully
```

---

## Phase 4 — Local immutable images

Implement:

```text
ImageStore
InstanceStore
APFS clone
digest identity
image seal
image inspect
image prune
```

Acceptance:

```text
one immutable Ubuntu image
can produce many CoW instances
without mutating the base
```

---

## Phase 5 — GitHub JIT proof of concept

Implement:

```text
PAT auth
repo scope
org scope
JIT config generation
guest StartRunner
runner session tracking
```

Initially allow manual start:

```text
runnerctl debug run-jit <profile>
```

Acceptance:

```text
VM boots
JIT runner registers
one GitHub Actions job executes
runner exits
VM is destroyed
```

This proves the fundamental architecture.

---

## Phase 6 — Runner Scale Set autoscaling

Implement native Swift subset of GitHub scale-set control plane:

```text
ensure scale set
message session
long poll
capacity advertisement
demand statistics
job acquisition as required
JIT config
message acknowledgment
```

Acceptance:

```text
minIdle = 0
zero VMs running

queue workflow job

RunnerVM detects demand without inbound webhook

VM appears

job executes

VM disappears

system returns to zero
```

This is the most important end-to-end milestone.

---

## Phase 7 — Resource scheduler

Implement:

```text
CPU reservation
memory reservation
disk reserve
maxVMs
profile maxInstances
capacity advertisement
multiple concurrent VMs
```

Acceptance:

```text
five queued jobs
host only has capacity for two

GitHub is advertised appropriate capacity

two run

remaining demand waits

capacity is reused safely
```

---

## Phase 8 — macOS support

Implement:

```text
MacVMPlatform
unique machine identifier
auxiliary storage cloning
headless macOS configuration
macOS guest agent packaging
macOS actions runner
```

Bootstrap using imported/prepared images first.

Acceptance:

```text
macOS VM boots
agent ready
JIT runner executes job
ephemeral VM is destroyed
```

---

## Phase 9 — OCI/GHCR

Implement native RunnerVM OCI artifact format.

Deliver:

```text
image push
image pull
tag -> digest resolution
blob cache
digest verification
GHCR auth
```

Also implement optional Tart importer.

Acceptance:

```text
host A pushes image
host/cache is cleared
host A pulls same digest
VM boots successfully
```

Even though there is only one host operationally, test portability.

---

## Phase 10 — Warm pool

Implement:

```text
minIdle
maxIdle
idleTTL
```

Acceptance:

```text
minIdle = 2

two agent-ready VMs remain idle
without GitHub JIT registrations

job arrives
one receives JIT config immediately

after job
ephemeral instance destroyed

pool reconciles back to two
```

---

## Phase 11 — Reusable VMs

Implement explicit reusable lifecycle.

Deliver:

```text
cleaning state
cleanup RPC
job-count limit
VM age limit
failure recycle
```

Config:

```yaml
lifecycle: reusable

reuse:
  maxJobs: 10
  maxAge: 4h
```

A VM MUST be automatically recycled after either limit.

If cleanup fails:

```text
destroy VM
```

Never return a failed-cleanup VM to idle.

---

## Phase 12 — GitHub App authentication

Implement:

```text
App JWT
installation discovery/config
installation token refresh
Keychain private-key management
```

PAT remains development fallback.

---

## Phase 13 — Hardening

Implement/finalize:

```text
daemon reconnect to existing workers
host reboot reconciliation
failure injection
rate limit handling
disk pressure
secret redaction
public repo guard
metrics endpoint
diagnostics retention
image runner-version policy
```

---

## Phase 14 — Public-release preparation

Before making project public:

```text
license review
provenance audit
replace remaining unnecessary Tart-derived modules
security review
threat model
documentation
stable OCI media types
stable config schema
stable daemon API policy
remove internal credentials/examples
```

---

# 98. Testing strategy

Testing has four levels.

---

## 98.1 Pure unit tests

No VM required.

Test:

```text
capacity calculation
state-machine transitions
configuration defaults
configuration validation
OCI reference parsing
digest verification
database records
database migrations
secret redaction
timeout behavior
retry policy
idempotency keys
GitHub error classification
profile matching
warm-pool desired count
reusable lifecycle
```

Capacity math deserves especially extensive property tests.

---

## 98.2 Component integration tests

Use fakes:

```text
FakeGitHubServer
FakeDemandProvider
FakeWorker
FakeGuestAgent
temporary SQLite
temporary ImageStore
```

Test orchestration without Virtualization.framework.

Example:

```text
Fake GitHub demand = 3
capacity = 2

expect:
  exactly 2 instance starts
  no third start
  advertised capacity correct
```

---

## 98.3 Linux VM integration tests

Linux should be the fast VM integration target.

Test:

```text
boot
agent handshake
metrics
exec
shutdown
JIT runner startup
Docker action
service container
instance deletion
```

Run regularly on dedicated Apple Silicon CI hardware.

---

## 98.4 macOS VM integration tests

More expensive.

Test:

```text
clone
unique identity
boot
agent
JIT registration
job
shutdown
cleanup
```

Run on dedicated scheduled test infrastructure.

---

# 99. Failure injection matrix

Must test:

```text
runnerd killed while cloning
runnerd killed while VM running
runnerd killed after JIT config issued
vmworker killed while idle
vmworker killed while job running
guest agent fails to start
guest agent disconnects
GitHub 401
GitHub token expiry
GitHub 403
GitHub 429
GitHub 500
network timeout
message redelivery
duplicate job event
disk full during clone
disk full during job
image digest mismatch
invalid image metadata
unsupported macOS hardware model
VM boot timeout
runner online timeout
runner exits unexpectedly
job cancellation
host shutdown/reboot
SQLite busy
SQLite migration failure
stale worker PID
stale Unix socket
orphan instance directory
missing instance directory
OCI interrupted download
```

An orchestrator is only as reliable as these paths.

---

# 100. Critical idempotency tests

For any operation:

```text
create instance X
```

executing reconciliation twice must not create:

```text
X
X-copy
```

Similarly:

```text
destroy X
```

must be safe when X has already disappeared.

Examples:

```text
ensureScaleSet
ensureImage
ensureInstance
ensureWorker
ensureStopped
ensureDeleted
```

Prefer `ensure...` semantics internally over command-like assumptions.

---

# 101. Key acceptance tests

The project is not considered v1-ready until all of the following work.

## Scale to zero

Given:

```text
minIdle = 0
no queued jobs
```

expect:

```text
0 VMs
0 registered idle JIT runners
```

---

## Cold-start job

Given:

```text
0 VMs
```

when a matching GitHub job is queued:

```text
RunnerVM detects demand
creates VM
boots
starts JIT runner
executes job
destroys VM
returns to zero
```

---

## Isolation

Job A writes:

```text
/home/runner/secret-from-a
```

After Job A completes and ephemeral VM is deleted, Job B MUST NOT observe that file.

---

## Capacity

Given a host limited to two VMs and five queued jobs:

```text
never >2 active VM reservations
```

---

## Daemon restart

Restart `runnerd` while reusable/idle workers exist.

Expect:

```text
state reconciled
no duplicate VM
no duplicate GitHub runner
```

---

## Worker failure

Kill one `vmworker`.

Expect:

```text
other VMs unaffected
runnerd remains alive
instance marked interrupted
reconciliation occurs
```

---

## Secret boundary

Automated test scans:

```text
SQLite
structured logs
instance metadata
worker command line
```

and MUST NOT find the PAT/App private key.

---

## Image immutability

Hash base image before and after 10 ephemeral jobs.

Result MUST remain unchanged.

---

# 102. Performance measurements

Do not initially turn speculative numbers into hard SLOs.

Measure:

```text
image cached → clone complete
clone complete → VZ running
VZ running → agent ready
agent ready → runner online
GitHub demand → runner online
cleanup → capacity reusable
```

Collect percentiles:

```text
p50
p90
p95
p99
```

After real measurements, decide whether warm pools are worth the resource cost.

---

# 103. Operational health

`runnerctl status` should display something like:

```text
RunnerVM daemon: healthy

Host
  macOS:        15.x
  architecture: arm64
  CPUs:         12
  Memory:       64 GiB
  Free disk:    412 GiB

Capacity
  Running VMs:  2 / 4
  Reserved CPU: 10
  Reserved RAM: 20 GiB

GitHub
  Auth:         healthy
  Scopes:       2
  Scale sets:   3 healthy

Images
  Cached:       5
  Disk usage:   183 GiB

Profiles
  ubuntu-24              1 busy / 0 idle
  macos-15-xcode-16      1 busy / 0 idle

Reconciliation
  Last run:     4s ago
  Errors:       0
```

---

# 104. `runnerctl doctor`

Must check:

```text
Apple Silicon
supported host macOS
Virtualization.framework available
virtualization entitlement
state path writable
APFS clone support
sufficient free disk
SQLite integrity
daemon socket
GitHub authentication
GitHub permissions
GHCR authentication if configured
configured images available
guest image compatibility
```

Doctor should provide actionable errors.

Bad:

```text
error 37
```

Good:

```text
Image macos-15-xcode-16 uses a hardware model that
is not supported by this host macOS version.
Pull or rebuild a compatible image.
```

---

# 105. Reconciliation loop

In addition to event-driven changes, run periodic reconciliation.

Example:

```text
every 10 seconds:
  reconcile lightweight state
```

Slower operations:

```text
every few minutes:
  image/cache maintenance
  GitHub runner cleanup
  disk pressure check
```

Use jitter where many independent loops exist.

Do not rely solely on event callbacks.

Events can be lost; state can drift.

---

# 106. Scheduler fairness

V1:

```text
FIFO within profile
```

Across profiles, avoid starvation.

Simple initial algorithm:

```text
round-robin profiles with pending demand
```

respecting:

```text
profile maxInstances
host capacity
```

Future:

```text
weighted fairness
priority profiles
reserved capacity
```

Do not implement priorities until real operational need exists.

---

# 107. Cancellation

When GitHub demand disappears before VM becomes active:

```text
job canceled
   ↓
scheduler notices desired capacity dropped
```

If VM is still:

```text
planned/cloning/booting
```

cancel startup if safe and destroy it.

If JIT configuration has already been issued:

- reconcile runner state;
- ensure no stale runner remains;
- terminate guest runner if appropriate;
- destroy ephemeral VM.

Cancellation must be part of normal lifecycle.

---

# 108. Graceful shutdown of `runnerd`

On service stop:

Default production behavior SHOULD be:

```text
stop accepting new capacity
persist state
leave active vmworkers alone where reconnectable architecture allows
close GitHub message sessions
exit
```

Provide explicit maintenance command:

```text
runnerctl daemon drain
```

Drain:

```text
stop accepting new jobs
wait for active jobs
destroy idle ephemeral VMs
optionally stop reusable VMs
```

And:

```text
runnerctl daemon shutdown --force
```

for administrative cases.

---

# 109. Maintenance/drain mode

Host maintenance requires:

```text
normal
draining
offline
```

When draining:

```text
advertised new capacity = 0
```

but active jobs continue.

This will become especially important in a future cluster.

Implement locally now because it is inexpensive and operationally valuable.

---

# 110. Image garbage collection

An image can be deleted only if:

```text
no active instance references it
AND
no pending operation references it
```

Tags are not references sufficient for GC safety.

Use immutable digest references.

Pruning:

```text
runnerctl image prune
```

Policies:

```yaml
images:
  cache:
    maxSize: 500GiB
    keepRecentlyUsed: 7d
```

Do not implement aggressive GC before correct reference accounting exists.

---

# 111. Instance garbage collection

Ephemeral instance directories should normally disappear immediately after successful completion.

Failed instances may remain according to diagnostics policy.

Reconciler finds:

```text
directory exists
DB says deleted
```

and safely removes it.

For:

```text
directory exists
no DB row
```

mark as orphan first.

Do not immediately delete unknown data.

Log:

```text
orphan detected
```

and apply a grace period.

---

# 112. macOS guest-specific concerns

The macOS image should have:

```text
guest-agent launch daemon
GitHub actions runner bundle
runner account
SSH configuration if enabled
build toolchain appropriate to profile
```

Xcode profiles should identify image/toolchain explicitly:

```text
macos-15-xcode-16
macos-15-xcode-16.4
```

Do not use ambiguous:

```text
macos-latest
```

as the canonical internal image identity.

Tags like `latest` may exist as convenience aliases, but instances always pin digests.

---

# 113. macOS image compatibility

Before launching:

```text
ImageMetadata
   +
HostCapabilities
   ↓
compatibility validation
```

Check:

```text
arm64
host OS version
hardware model supported
required Virtualization.framework capabilities
```

Reject before cloning/booting if known incompatible.

---

# 114. Linux image compatibility

Validate:

```text
architecture == arm64
EFI metadata exists
disk image exists
agent version supported
runner version policy
```

Use protocol-version negotiation for agent compatibility.

---

# 115. Protocol versioning

Worker protocol:

```text
version = 1
```

Guest agent:

```text
protocolVersion = 1
```

Daemon API:

```text
version = 1
```

Image schema:

```text
schemaVersion = 1
```

OCI media types:

```text
v1
```

Do not implicitly equate these versions.

Each evolves independently.

---

# 116. Backward compatibility policy

Before public release:

```text
no compatibility guarantee
```

But migrations should still be deliberate.

After public release:

- SQLite migrations must be forward-only and tested;
- image schema changes require compatibility/import strategy;
- daemon API changes require version negotiation;
- guest agent must tolerate at least a defined N/N-1 version window.

---

# 117. Observability IDs

Every job should be traceable through:

```text
GitHub job request ID
RunnerSessionID
InstanceID
worker PID
image digest
profile ID
operation IDs
```

A log search by instance should reconstruct:

```text
demand
clone
boot
agent
JIT
job
cleanup
delete
```

without manually correlating timestamps.

---

# 118. Event model

Internal events can use Swift enums:

```swift
enum OrchestratorEvent: Sendable {
    case demandChanged(...)
    case instanceStateChanged(...)
    case workerExited(...)
    case guestReady(...)
    case runnerStateChanged(...)
    case diskPressureChanged(...)
    case configurationChanged(...)
}
```

Use events to wake reconciliation.

Do not make event ordering the only truth.

Persistent desired/current state remains authoritative.

---

# 119. Operations should be resumable where possible

Example image pull:

```text
pulling blob
daemon crashes
```

After restart:

- partial file can be resumed or discarded safely;
- final blob is never considered valid until digest verifies;
- use atomic rename after verification.

Instance clone:

- clone into temporary path;
- write DB intent;
- atomically publish completed instance directory.

Avoid half-valid resources with final names.

---

# 120. Atomic filesystem publication

Pattern:

```text
instances/.tmp/<uuid>
      ↓
build complete
      ↓
fsync relevant metadata
      ↓
rename
      ↓
instances/<uuid>
```

Similar for downloaded image blobs:

```text
blob.part
  ↓ digest verified
rename
  ↓
sha256/<digest>
```

A process crash should leave either:

- valid final object;
- clearly identifiable temporary object.

---

# 121. Resource reservation timing

Reserve scheduler resources **before** beginning expensive clone/boot work.

State:

```text
planned
```

should already consume:

```text
CPU reservation
memory reservation
estimated disk reservation
profile instance slot
```

Otherwise concurrent scheduling loops can oversubscribe the host.

Release reservation only after:

```text
instance deleted
```

or definitively failed and cleaned.

---

# 122. No hidden background state

Every significant lifecycle object should appear in:

```text
runnerctl vm list
runnerctl runner list
```

Avoid invisible "preparing task" states existing only in Swift Tasks.

If an operation matters for capacity/recovery, persist it.

---

# 123. Configuration validation

Reject at apply time:

```text
negative resources
memory < VZ minimum
CPU < platform minimum
disk smaller than image
minIdle > maxIdle
maxIdle > maxInstances
duplicate profile name
missing scope
incompatible image OS/profile
repository scope without repository
unsupported architecture
memory overcommit < 1
invalid OCI reference
```

Do not wait for the first GitHub job to discover obvious configuration errors.

---

# 124. Default resource sizing

Strong profile defaults:

### Linux

```text
CPU:    4 vCPU
Memory: 8 GiB
Disk:   80 GiB
```

### macOS

```text
CPU:    6 vCPU
Memory: 12 GiB
Disk:   120 GiB
```

These are baseline defaults, not mandatory allocations.

Allow:

```yaml
resources:
  cpu: auto
  memory: auto
```

later.

For v1, explicit resolved values stored in profile are simpler.

---

# 125. Instance naming

Human-readable runner/VM names:

```text
rvm-<profile-short>-<short-uuid>
```

Example:

```text
rvm-ubuntu24-a71c92e4
```

Do not encode secrets or full repository names unnecessarily.

GitHub runner name can match instance name for correlation.

---

# 126. Reusable VM safeguards

Reusable mode configuration:

```yaml
lifecycle: reusable

reuse:
  maxJobs: 10
  maxAge: 4h
  recycleOnFailure: true
```

Recycle immediately if:

```text
cleanup failed
guest agent degraded
runner exits abnormally
disk usage > threshold
manual taint
VM rebooted unexpectedly
```

Add:

```text
tainted = true
```

concept internally.

A tainted VM can never return to idle.

---

# 127. Warm-pool safeguards

Idle VMs consume full configured memory reservation.

Therefore:

```text
minIdle
```

must participate in capacity calculation.

Do not permit:

```text
three 16 GiB idle VMs
```

on a 32 GiB host just because they have no active job.

---

# 128. Secret lifetime

JIT secret lifecycle:

```text
runnerd receives
    ↓
memory
    ↓
encrypted local IPC where practical / protected Unix socket
    ↓
guest agent
    ↓
runner process
    ↓
discard
```

Do not persist merely to make crash recovery easier.

If `runnerd` crashes exactly after issuance and the JIT config is lost:

- reconcile;
- abandon that runner session if necessary;
- create a fresh session/config.

Prefer losing a short-lived JIT credential over persisting secrets broadly.

---

# 129. Unix socket security

All sockets under:

```text
/var/run/runnervm
```

must have restrictive ownership and modes.

Example:

```text
service-user:service-group
0700 directory
0600 sockets where feasible
```

Do not listen on TCP for internal control in v1.

---

# 130. Host shutdown integration

Handle:

```text
SIGTERM
SIGINT
launchd shutdown
```

Worker should attempt graceful guest shutdown if explicitly terminating a VM.

But do not block host shutdown indefinitely.

Config:

```text
gracefulVMShutdownTimeout = 30s
```

After timeout:

```text
force stop
```

and mark any running job interrupted.

---

# 131. Serial console

Configure a serial console for diagnostics where practical.

Store output:

```text
instance/serial.log
```

or stream to structured logs.

This is particularly useful when:

```text
guest agent never becomes ready
```

Do not require GUI inspection to debug failed boots.

---

# 132. No inbound control server

The initial deployment MUST NOT require exposing:

```text
runnerd:8080
```

to the network.

GitHub control is outbound.

CLI control is Unix socket.

VM networking is NAT.

This sharply simplifies security and deployment.

A cluster control API can be added later with explicit authentication.

---

# 133. GitHub repository vs organization runners

The same RunnerProfile abstraction should support both.

Example:

```text
organization profile
    │
    └── runner group

repository profile
    │
    └── repository scope
```

Do not create separate scheduler implementations.

Only GitHub control-plane configuration differs.

---

# 134. Runner group handling

For organization scope, resolve configured runner group to GitHub's numeric ID at validation/reconciliation time.

Store:

```text
runner_group_id
```

in persistent state.

If group disappears or access becomes invalid:

```text
scope health = degraded
```

and stop scheduling new runners for that scope.

---

# 135. Health model

Every major resource has health.

```text
HostHealth
GitHubScopeHealth
ProfileHealth
ImageHealth
InstanceHealth
WorkerHealth
GuestHealth
```

Values:

```text
healthy
degraded
unhealthy
unknown
```

`runnerctl status` should summarize.

Scheduler may refuse new work when a required dependency is unhealthy.

---

# 136. Rate limiting and backpressure

Do not create one concurrent GitHub polling loop per VM.

Scale-set controller operates per profile/scale set.

Use bounded concurrency for:

```text
image pulls
VM clones
VM boots
GitHub API requests
```

Example host config:

```yaml
limits:
  concurrentImagePulls: 2
  concurrentVMStarts: 2
```

Booting six macOS VMs simultaneously can produce poor host behavior even if final capacity would fit.

Startup concurrency is therefore separate from final VM capacity.

---

# 137. Image pull locking

If five jobs need the same uncached image:

Bad:

```text
5 independent 40 GiB downloads
```

Good:

```text
one pull operation
     │
     ├── waiter 1
     ├── waiter 2
     ├── waiter 3
     ├── waiter 4
     └── waiter 5
```

Deduplicate concurrent pulls by immutable digest/reference resolution.

---

# 138. Profile image updates

If:

```text
image: ghcr.io/acme/ubuntu:stable
```

changes from digest A to B:

Existing instances:

```text
continue using A
```

New instances:

```text
use B
```

Reusable VMs on A can be recycled according to update policy:

```yaml
imageUpdates:
  recycleReusable: true
```

Never mutate a running instance's image identity.

---

# 139. CLI output modes

Support:

```text
human
json
```

Example:

```text
runnerctl vm list --output json
```

Useful for automation.

Machine-readable JSON fields should remain more stable than human table formatting.

---

# 140. Audit events

Persist security-relevant administrative actions:

```text
config changed
VM manually stopped
VM exec invoked
VM SSH requested
auth changed
image deleted
daemon drained
```

Do not need a complex enterprise audit system in v1, but logs should clearly identify these operations.

---

# 141. Coding standards for the implementation agent

The coding agent MUST follow these rules.

1. Do not create giant manager classes.
2. Prefer protocols at external boundaries.
3. Keep Virtualization.framework completely outside scheduler/domain modules.
4. Keep GitHub endpoint details inside `GitHubControl`.
5. Keep SQLite-specific records inside `Persistence`.
6. No raw credentials in logs.
7. Every network call gets a timeout.
8. Every lifecycle operation must be cancelable where practical.
9. Every persisted state transition should happen transactionally.
10. Every filesystem object should have one owner abstraction.
11. Every migration gets a test.
12. Every state transition gets tests.
13. Every retry must be bounded or governed by reconciliation.
14. Avoid sleep-based synchronization in tests.
15. Use dependency injection rather than global singletons.
16. Prefer `AsyncSequence`/actors over callback/event-loop leakage into the domain.
17. Do not preserve Tart behavior merely for compatibility unless specifically required.
18. Add comments explaining **why**, not restating code.
19. Avoid premature abstractions for multi-host networking.
20. Keep cluster-readiness at data/interface boundaries only.

---

# 142. Coding agent workflow

For each feature:

```text
1. Read relevant architecture section.

2. Identify owning module.

3. Define/modify domain model first.

4. Add tests for desired state transitions.

5. Implement boundary interfaces/fakes.

6. Implement concrete integration.

7. Add structured logging.

8. Add failure classification.

9. Add reconciliation behavior.

10. Run unit tests.

11. Run relevant integration test.

12. Update documentation and PROVENANCE.md
    if Tart-derived code was touched.
```

A feature is not complete just because the happy path works once.

---

# 143. Definition of done for a lifecycle feature

Example: "Start VM" is complete only if:

```text
happy-path start works
duplicate start is idempotent
startup timeout handled
worker crash handled
daemon cancellation handled
state persisted
logs emitted
metrics emitted
restart reconciliation understood
tests exist
```

Apply this standard throughout the project.

---

# 144. Explicit non-goals for v1

Do NOT implement:

```text
Intel Macs
x86_64 guests
Windows
VMware
QEMU
Parallels
multiple hypervisor backends
GUI
VNC
live migration
VM snapshots as user feature
VM suspend/resume
multi-host scheduler
distributed consensus
Kubernetes
bridged networking
public daemon REST API
VPN networking
host directory sharing
USB passthrough
GPU passthrough
nested virtualization by default
general-purpose desktop VM management
GitHub Enterprise Server
GitLab runners
Buildkite agents
CircleCI
arbitrary guest architectures
```

These distract from the initial objective.

---

# 145. V1 product boundary

The first production-worthy release should feel like:

```text
Install RunnerVM on Apple Silicon Mac.

Configure GitHub credentials.

Define:
  ubuntu profile
  macOS profile

Point them to OCI images.

Run:
  runnerctl config apply

Queue GitHub workflow.

RunnerVM:
  sees demand
  clones VM
  boots it
  starts JIT runner
  runs job
  destroys VM
  returns to zero.
```

That is the product.

Everything else is secondary.

---

# 146. Recommended first end-to-end target

Do not begin with macOS.

Build this exact vertical slice first:

```text
Apple Silicon Mac
    ↓
runnerd
    ↓
SQLite
    ↓
vmworker
    ↓
Ubuntu 24.04 ARM64
    ↓
guest-agent over vsock
    ↓
GitHub JIT runner
    ↓
one repository job
    ↓
VM destroyed
```

Then add GitHub scale-set demand.

Then add macOS.

Reasons:

- Ubuntu image creation is simpler;
- Linux boot debugging is easier;
- Docker-based Actions can exercise realistic jobs;
- it validates almost all architecture except macOS platform details;
- failures are less expensive during initial iteration.

---

# 147. First implementation milestone in concrete terms

The first milestone should produce these commands:

```text
runnerctl status
runnerctl image import <local-image>
runnerctl vm create --image ubuntu
runnerctl vm list
runnerctl vm exec <id> -- uname -a
runnerctl vm metrics <id>
runnerctl vm stop <id>
runnerctl vm delete <id>
```

No GitHub yet.

This proves:

```text
daemon
database
worker
Virtualization.framework
image clone
guest agent
IPC
metrics
```

---

# 148. Second implementation milestone

Add:

```text
runnerctl github test
runnerctl debug run-jit ubuntu-24
```

A GitHub job manually routed to that profile can execute once.

This proves:

```text
GitHub authentication
JIT configuration
secret delivery
runner lifecycle
automatic cleanup
```

---

# 149. Third implementation milestone

Remove the manual trigger.

Add:

```text
Runner Scale Set
long polling
capacity
automatic scale from zero
```

At that point the core concept is validated.

---

# 150. Architecture success criterion

The project has succeeded architecturally when the following statement is true:

> `runnerd` knows about jobs, desired capacity, images and lifecycle, but does not know how to construct a `VZMacPlatformConfiguration`; `vmworker` knows how to construct and operate a VM, but does not know what GitHub organization it belongs to; the guest knows how to execute one JIT runner session, but never possesses long-lived host credentials.

That separation is the central design goal.

The desired dependency chain is:

```text
GitHub demand
      │
      ▼
orchestration
      │
      ▼
resource scheduling
      │
      ▼
VM instance lifecycle
      │
      ▼
Virtualization.framework
      │
      ▼
guest control
      │
      ▼
GitHub runner process
```

Each layer should remain independently testable and replaceable.

---

# 151. Final recommended decisions

For choices intentionally left open earlier, this specification selects:

```text
Linux:
  Ubuntu 24.04 LTS ARM64

Linux container support:
  Docker Engine preinstalled

Image model:
  immutable content-addressed bases
  APFS CoW per-job instances

Remote images:
  OCI/GHCR

Tart image compatibility:
  importer only, not canonical format

Demand:
  GitHub Runner Scale Sets

Scale-to-zero:
  default

GitHub registration:
  JIT per job

VM ownership:
  one vmworker process per VM

Guest control:
  gRPC/protobuf over virtio socket

Manual inspection:
  SSH + guest Exec

Host networking:
  NAT only

Host runtime privilege:
  dedicated unprivileged service account

Development auth:
  PAT

Production auth:
  GitHub App

Persistence:
  SQLite WAL

Memory overcommit:
  disabled by default

CPU overcommit:
  disabled by default

Metrics:
  guest + vmworker host metrics

GUI:
  none

Cluster:
  interfaces/schema prepared
  implementation deferred
```

---

# 152. Highest-risk areas to prototype early

The engineering team/coding agent should treat these as architectural spikes rather than assume them solved:

### 1. GitHub Scale Set Swift implementation

Validate:

```text
scale set creation
message session
demand statistics
capacity advertisement
JIT configuration
job lifecycle
reconnect/recovery
```

against GitHub.com.

Because this API surface is still public preview, keep it highly isolated.

### 2. macOS identity cloning

Verify experimentally that:

```text
base image
  ↓
per-instance auxiliary storage clone
  +
new VZMacMachineIdentifier
  +
new MAC
```

boots reliably across supported host/macOS combinations.

### 3. Daemon restart with running worker

Prototype worker independence early:

```text
start VM
kill runnerd
restart runnerd
reconnect to vmworker
```

If this works cleanly, the architecture gains significant resilience.

### 4. Guest-agent transport

Prove:

```text
Swift host
  ↓
UDS proxy
  ↓
VZVirtioSocket
  ↓
Go guest-agent
  ↓
gRPC
```

before implementing a large agent API.

### 5. APFS clone behavior

Benchmark:

```text
large macOS image
clonefile
physical allocation
clone latency
deletion
concurrent clones
```

because cold-start economics depend heavily on it.

---

# 153. Guidance on scope discipline

When uncertain whether a feature belongs in v1, ask:

> Does this directly improve our ability to reliably turn a GitHub job into an isolated local VM and then reclaim it?

If not, defer it.

Examples:

```text
VNC:
  no

VM snapshots:
  no

custom bridged network:
  no

beautiful VM list formatter:
  low priority

reconciliation after crash:
  yes

image digest verification:
  yes

secret redaction:
  yes

capacity calculation:
  yes

guest health:
  yes

GitHub rate-limit recovery:
  yes
```

---

# 154. Long-term direction

Once the single-host implementation is mature, the system can evolve naturally.

Current:

```text
GitHub
  ↓
runnerd
  ↓
local scheduler
  ↓
local workers
```

Future:

```text
GitHub
  ↓
controller
  ↓
global scheduler
  │
  ├── Mac host agent A
  │      └── workers
  │
  ├── Mac host agent B
  │      └── workers
  │
  └── Mac host agent C
         └── workers
```

The important point is that the future host agent can be largely the existing local implementation:

```text
ImageStore
VirtualizationCore
vmworker
GuestControl
local metrics
local reconciliation
```

The cluster layer should add placement and remote coordination rather than replace the VM runtime.

---

# 155. Final engineering directive

Start with the Tart fork, but mentally treat Tart as a temporary scaffolding layer.

Do not attempt to make "Tart plus GitHub scheduling."

Build:

> **a GitHub Actions runner orchestrator whose VM execution implementation happens to have been bootstrapped from proven Tart Virtualization.framework code.**

The two descriptions lead to very different architectures.

The intended end state is:

```text
RunnerVM domain
    │
    ├── GitHub control
    ├── scheduler
    ├── persistence
    ├── image system
    ├── reconciliation
    └── VM supervisor
             │
             ▼
      small clean VZ layer
```

rather than:

```text
Tart
  +
scheduler bolted onto it
```

The latter should be explicitly avoided.

The strongest v1 definition is:

> On an idle Apple Silicon Mac there are zero runner VMs. When GitHub assigns work to a configured RunnerVM scale set, the daemon determines capacity, materializes an immutable image into an APFS CoW instance, launches a dedicated Virtualization.framework worker, waits for a guest agent over virtio socket, creates a job-specific GitHub JIT runner configuration, runs exactly one job, records lifecycle/resource telemetry, destroys the ephemeral VM, and deterministically reconciles the system back to zero. Long-lived GitHub credentials never cross the VM boundary.

Everything in the first implementation should serve that sentence.