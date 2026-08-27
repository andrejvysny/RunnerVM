# Building images with `runnerctl image build`

The in-daemon image builder (spec §59–§62, plan M14/M15) turns a `Runnerfile` — a small,
Dockerfile-flavoured recipe — into a sealed RunnerVM image, entirely inside `runnerd`. There is no
container runtime involved: every instruction runs for real, as root, inside a throwaway VM booted
from the recipe's base image, over the same vsock control channel a running instance uses. This is
the modern way to build images; the older, host-script pipeline
(`scripts/build-ubuntu-image.sh`, [docs/images.md](images.md)) still exists and is documented
there as **legacy**.

```
recipe (Runnerfile) + build args ──▶ RecipePlanner ──▶ steps [RUN/COPY, in order]
base (cloud image | local image | registry ref) ──▶ builder VM disk ──┐
build context (COPY sources) ──▶ context.iso ─────────────────────────┤
                                                                       ▼
                                                      vmworker boots the VM
                                                      each step runs over agent.exec
                                                      poweroff ──▶ seal ──▶ images/
```

## What a Runnerfile is

A `Runnerfile` is Dockerfile line syntax (`\`-continuation, `#` comments, `# escape=`/`# syntax=`
directives tolerated as comments) parsed by `Sources/ImageBuild/RecipeParser.swift` into a
sequence of instructions. It targets a VM disk, not a container filesystem, so the instruction set
is deliberately smaller than a Dockerfile's:

| Instruction | Accepted | VM semantics |
| --- | --- | --- |
| `FROM` | yes | Names the base disk. See [FROM forms](#from-forms) below. Exactly one per recipe; must be the first non-`ARG` instruction. |
| `ARG` | yes | Declares a build argument and its default. Folded into the interpolation scope at plan time — not a step the builder runs. `RUNNER_VERSION`, `RUNNER_SHA256` and `RUNNER_SUDO` are resolved specially; see [below](#runner_versionlatest-resolution). |
| `ENV` | yes | Folds into the interpolation scope *and* becomes part of every later `RUN`/`COPY` step's process environment (`agent.exec`'s `env`). Not a step of its own. |
| `RUN` | yes | Executes over `agent.exec` inside the guest, as root (or as `USER`, if set). Shell form (`RUN cmd ...`) runs under the current `SHELL` (default `/bin/sh -c`); exec form (`RUN ["cmd", "arg"]`) runs `argv` directly with **no shell and no `$PATH` lookup** — `argv[0]` must be an absolute path (`RECIPE_EXEC_ARGV_NOT_ABSOLUTE` otherwise). `--timeout=<duration>` overrides `build.stepTimeout` for that one step. |
| `COPY` | yes | Materializes files from the build context into the guest. Compiled to a shell script run over `agent.exec` (`BuildScripts.copy`), not a real filesystem layer — there is no `--from=` (multi-stage), and source globs (`*?[`) are rejected (`RECIPE_COPY_GLOB_UNSUPPORTED`): list files or directories explicitly. `--chown=user:group` is supported. A source path that resolves outside the build context is refused (`RECIPE_COPY_PATH_ESCAPES_CONTEXT`). |
| `USER` | yes | Folds state: every later `RUN`/`COPY` step's argv is wrapped in `runuser -u <user> --` until the next `USER`. |
| `WORKDIR` | yes | Folds state (relative to the previous `WORKDIR`) **and** emits one synthetic `mkdir -p <dir>` step — visible in the log, but excluded from the `[step/total]` progress count and from `totalSteps`. |
| `SHELL` | yes | Sets the argv prefix shell-form `RUN` steps use (default `["/bin/sh", "-c"]`). Requires JSON array form; `argv[0]` must be absolute (`RECIPE_SHELL_NOT_ABSOLUTE` otherwise). |
| `LABEL` | yes | Folds into the image's provenance metadata. `dev.runnervm.image.name` also sets the local name the sealed image is registered under when `--name` is not given. |
| `CMD`, `ENTRYPOINT` | **rejected** | A RunnerVM image has no container entrypoint — the guest agent starts `actions/runner`. Use `RUN` to install software. |
| `EXPOSE` | **rejected** | RunnerVM images are VM disks; guest networking belongs to the OS, not a published port. |
| `VOLUME` | **rejected** | No container volume layer — use `RUN mkdir` on the VM disk directly. |
| `ONBUILD` | **rejected** | Recipes are not layered like container images — inline the instruction instead. |
| `HEALTHCHECK` | **rejected** | Instances are health-checked by the guest agent, not a container healthcheck. |
| `STOPSIGNAL` | **rejected** | No container init to signal. |
| `ADD` | **rejected** | `ADD`'s remote-fetch/auto-extract behavior has no guest-side equivalent — use `COPY` plus `RUN` to fetch/extract explicitly. |
| `MAINTAINER` | **rejected** | Obsolete — use `LABEL`. |

A rejected instruction fails the parse immediately with `RECIPE_UNSUPPORTED_INSTRUCTION` and the
one-line reason above; an instruction the parser has never heard of is `RECIPE_UNKNOWN_INSTRUCTION`.
Heredocs (`<<EOF`) and `COPY --from=` are always `RECIPE_HEREDOC_UNSUPPORTED` /
`RECIPE_COPY_FROM_UNSUPPORTED`.

### `FROM` forms

```
FROM ubuntu-24                                                              # a local image, by name or sha256:<hex>
FROM ghcr.io/acme/runners/ubuntu-24@sha256:...                              # an OCI registry reference
FROM cloud-image:https://cloud-images.ubuntu.com/.../noble-server-cloudimg-arm64.img \
  --sha256=<64 lowercase hex> --disk=16GiB                                  # a stock cloud disk
```

`cloud-image:` is the only form that *bootstraps* a family from nothing: it fetches the URL (or an
absolute local path), verifies it against `--sha256` before doing anything else
(`BUILD_BASE_DIGEST_MISMATCH` on a mismatch), converts it to a raw disk if it is qcow2, and refuses
anything that isn't a GPT-partitioned whole disk (`BUILD_BASE_NOT_PARTITIONED` — cloud vendors also
publish bare-rootfs tarballs that look plausible until the VM fails to boot). `--disk=<ByteSize>`
sets the image's virtual disk size when not overridden by `--disk` on `runnerctl image build`
itself or `build.diskBytes`. The converted raw disk is cached under
`<rootDir>/cache/base-images/base-<sha256>.raw` (see [Bootstrap flow](#bootstrap-flow)); the
downloaded/converted digest is always re-verified against a cache hit's sidecar before it is
trusted.

A local-image or registry `FROM` is a *derived* build: it must resolve to a Linux image that
already carries a RunnerVM guest agent (`BUILD_BASE_NO_GUEST_AGENT` otherwise — a build cannot
reach a VM it cannot talk to), and inherits that image's guest agent and cloud-init seed rather
than needing its own.

## Bootstrap flow

A `cloud-image:` build is the only one that runs cloud-init at all:

1. **Fetch + verify + convert.** `BaseImageCache` downloads (or copies, for a local `/` path) the
   URL, verifies the whole file against `--sha256`, converts qcow2 → raw with the embedded
   `QCOW2Reader` (no `qemu-img` dependency), and caches the raw disk plus a JSON sidecar
   (`{sourceSHA256, rawSHA256, virtualSize}`) so a second build from the same digest costs nothing
   — the sidecar is re-validated (file size vs. recorded size) on every hit, not just trusted.
2. **Stage.** The cached raw disk is APFS-cloned into the build's own directory
   (`<stateDir>/builds/<id>/vm/`), grown to the requested disk size, and a cloud-init NoCloud seed
   ISO (`BuildSeed`) is generated and attached: a minimal `user-data`/`meta-data` that creates the
   `runner` account, masks the serial getty (so `build.log`'s console capture survives past the
   login banner), regenerates SSH host keys on first boot, and installs the guest agent binary +
   its systemd unit from the seed's own `cidata` volume — no network fetch inside the guest for any
   of that.
3. **Boot.** `vmworker` boots the VM from the staged disk (plus the seed and, if any `COPY` step
   exists, a read-only `context.iso`); the builder waits for the guest agent to answer over vsock.
4. **Provision.** Every `RUN`/`COPY` step runs over `agent.exec`, in source order, each logged to
   `build.log` as `--- [n/total] <instruction>` before it starts.
5. **Seal.** The guest is powered off; the builder hashes the disk, folds in the recipe's `LABEL`s
   and the resolved `RUNNER_VERSION`/`RUNNER_SHA256` as provenance, and registers the result as a
   new local image — the same content-addressed store `image import`/`image pull` write into.

A *derived* build (local-image or registry `FROM`) skips steps 1–2's cloud-init entirely: it clones
the parent image's disk directly and boots straight into step 3, since the parent already carries
everything cloud-init would have set up.

### `RUNNER_VERSION=latest` resolution

A recipe that declares `ARG RUNNER_VERSION` (every shipped bootstrap recipe does — see
`images/recipes/ubuntu-24-minimal/Runnerfile`) gets it resolved **before the builder VM boots**, on
the host, exactly like `scripts/build-ubuntu-image.sh` does it: the literal string `latest` (the
default, an empty override, or no override at all) asks the daemon's cached view of the newest
published `actions/runner` release; anything else is an operator pin, used as given. The resolved
version — never the string `latest` — is what reaches the guest.

If the recipe also declares `ARG RUNNER_SHA256`, the digest is reconciled against GitHub's own
release asset metadata before a byte is downloaded inside the guest:

* no pin (`RUNNER_SHA256` unset/empty): GitHub's release asset digest is trusted, recorded as
  `digestSource: "github-release-asset"`.
* a pin that **agrees** with GitHub's digest: the operator's pin wins, `digestSource: "operator"`.
* a pin that **disagrees**: `BUILD_RUNNER_DIGEST_MISMATCH` — the build refuses to guess which one
  is right.
* no pin, and GitHub has no digest for that release's asset: `BUILD_RUNNER_DIGEST_UNAVAILABLE`.
  There is no `--allow-unverified-runner` escape hatch here (unlike the legacy script) — pin
  `RUNNER_SHA256` explicitly if this happens.

`BUILD_RUNNER_VERSION_UNRESOLVED` means the daemon could not learn the latest release at all (no
GitHub credential yet, or GitHub unreachable) — pin `--arg RUNNER_VERSION=<version>` to build
offline from a known-good version.

## Build lifecycle

```
queued → resolving → staging → booting → provisioning → sealing → succeeded
                                                                  ↘ failed
   (any non-terminal state) ─────────────────────────────────────↘ cancelled
```

`queued` is capacity admission (`build.maxConcurrent`, default 1, shares the host's one
`AdmissionQueue` with `vm create`); the rest of the ladder is one state per stage in
[Bootstrap flow](#bootstrap-flow) above (a derived build still passes through `staging`/`booting`,
just without cloud-init). `runnerctl build show <id>` reports the current
`step`/`instruction` while `provisioning`. A build that fails or is cancelled leaves its
`failureCode`/`failureMessage` on the row for `build show`/`build list --output json` to read;
`runnerctl image build` (when waiting) prints the same pair as `runnerctl: <code>: <message>` and
exits 1.

### Restart semantics

An in-flight build does **not** survive a `runnerd` restart, and never resumes from a checkpoint.
On every reconcile tick the daemon looks for a non-terminal `image_builds` row with no live task
behind it (a crash, or a `start` whose task never began) and:

* if the build had already reached `sealing` and the disk was hashed and registered as an image
  before the crash, the **registration is replayed** — the build is marked `succeeded` without
  re-running anything (the guest disk itself is gone, so re-sealing is impossible, but the image
  content it already produced is not lost);
* otherwise the build is marked `failed` with `BUILD_INTERRUPTED`, its base-image pin is released,
  and its worker/directory are cleaned up.

Either way, `system.drain`/`system.shutdown` treat a running build exactly like a running instance
(`HostModeControl.activeWork()`): a drain waits for it to finish before advertising a clean stop.

## Walkthrough

The shipped recipes under `images/recipes/` form one family, each built on the last — this is
recipe chaining, not a builder feature: a later recipe's `FROM` just names the local image name the
one before it registered under.

```bash
# 1. bootstrap the family root: fetches + verifies the Ubuntu cloud disk, resolves the runner
#    version, installs baseline packages + the runner + the guest agent (~4 min cold cache on an
#    M-series Mac, measured 2026-08-27; network-bound)
runnerctl image build images/recipes/ubuntu-24-minimal --name ubuntu-24-minimal

# 2. adds Docker Engine on top
runnerctl image build images/recipes/ubuntu-24 --name ubuntu-24

# 3. adds a language runtime on top of that (node, go, python, jvm, dotnet, rust — pick one)
runnerctl image build images/recipes/ubuntu-24-node --name ubuntu-24-node

runnerctl image inspect ubuntu-24-node
```

`runnerctl image build` defaults to the current directory and to a file named `Runnerfile`, so
`runnerctl image build images/recipes/ubuntu-24-node` and
`runnerctl image build images/recipes/ubuntu-24-node/Runnerfile` are the same call. `--wait` (the
default) tails `build.log` to stdout, renders `[n/total] <instruction>` progress to stderr while
it's a terminal, and once the build succeeds prints the same table `runnerctl image inspect`
prints; `--no-wait` returns the build id immediately and `runnerctl build show <id>` / `build log
<id> --follow` pick up the rest. Every `--arg KEY=VALUE` maps to one `ARG` the recipe declares
(`RECIPE_UNKNOWN_ARGUMENT` for anything it doesn't); `--push <ref>` publishes the sealed image to a
registry as soon as it lands, same credential chain as `runnerctl image push`.

### Custom recipe with `COPY` and `.runnerignore`

```dockerfile
# my-recipe/Runnerfile
FROM ubuntu-24-node

COPY scripts/ /opt/ci-tools/
COPY --chown=runner:runner config/npmrc /home/runner/.npmrc

RUN chmod +x /opt/ci-tools/*.sh
```

The build context is `my-recipe/` (the recipe's own directory, unless `--context <dir>` names a
different one) and is only packed at all when the recipe has at least one `COPY` step — a recipe
with none pays nothing for context packing. A `.runnerignore` file at the context root works like a
minimal `.gitignore` (`#` comments, `/`-anchored and `**`-style patterns, `!` negation,
directory-only `trailing/`); `.git/` is always excluded. Anything a tar member has no business
being — a device node, a FIFO, a socket, a hard link, a symlink that resolves outside the context —
is refused outright (`BUILD_CONTEXT_UNSAFE_ENTRY`) rather than silently skipped, since the context
lands inside a VM that runs recipe-authored commands as root.

```
# my-recipe/.runnerignore
*.log
/node_modules/
!important.log
```

## Limits and configuration

```yaml
build:
  cpuCount: 4                # builder VM vCPUs
  memoryBytes: 4294967296    # 4GiB
  diskBytes: 17179869184     # 16GiB; a cloud-image FROM's own --disk=, or --disk on the CLI, wins
  timeout: 60m               # whole-build wall clock
  stepTimeout: 30m           # per RUN/COPY step; the guest agent clamps agent.exec at 30m anyway,
                             # so a longer value here is silently ineffective (BUILD_STEP_TIMEOUT_TOO_LONG)
  maxConcurrent: 1           # shares the host's one AdmissionQueue with `vm create` (0-4)
  cacheDir: null             # nil uses RunnerPaths.baseImageCacheDir (<rootDir>/cache/base-images)
  guestAgentPath: null       # nil resolves the bundled guest agent (see below)
  recipeFileName: Runnerfile
  maxContextBytes: 1073741824   # 1GiB
  maxLogBytes: 67108864         # 64MiB; a step that would exceed it fails BUILD_STEP_OUTPUT_TOO_LARGE
  maxSteps: 256                 # BUILD_TOO_MANY_STEPS beyond this

images:
  limits:
    maxVirtualDiskBytes: 549755813888   # 512GiB
    maxLayers: 4096
```

`images.limits` is **not** a build-specific setting — it bounds an OCI manifest an `image pull`/
`image import --format tart` accepts (`ArtifactLimits`, `Sources/OCIRegistry/Artifact/`), which is
a different disk-size ceiling than anything the builder itself enforces. A build's own output disk
is only bounded by `build.diskBytes`/`--disk`/a `cloud-image:` `FROM`'s `--disk=`, and by ordinary
host disk pressure at admission time.

`--cpus`/`--memory`/`--disk`/`--timeout`/`--no-cache` on `runnerctl image build` override the
matching `build:` default for that one build; `--no-cache` ignores a cached `FROM cloud-image:`
base and re-downloads/re-converts it.

### Guest agent resolution

`BuildSeed.resolveAgent` looks for the Linux guest-agent binary the boot seed installs, in order:
`build.guestAgentPath` (an operator override), the `RUNNERVM_GUEST_AGENT` environment variable,
then `<rootDir>/guest-agent/linux-arm64/runnervm-guest-agent` — the path
`scripts/install.sh` populates (`make -C GuestAgent build-linux`, unless `--skip-guest-agent`).
`runnerctl doctor`'s `build_guest_agent` check reports exactly this search order and which paths it
tried. A bootstrap build with none of these fails `BUILD_GUEST_AGENT_MISSING` before ever touching
the base image.

### Recipe root and the `_runnervm` permission caveat

`runnerd` reads the recipe file and its build context **itself**, as whatever user runs the daemon
(`_runnervm` in a production install) — not as the operator invoking `runnerctl`. A recipe under a
human user's home directory is very often unreadable to `_runnervm`; `runnerctl image build` warns
on stderr when the invoking uid differs from the daemon socket's owner uid, but the daemon's own
`BUILD_RECIPE_UNREADABLE` (which names the path and the daemon's uid) is the authoritative answer.

The recommended fix is to keep recipes under the recipe root `scripts/install.sh` installs and
owns: `<rootDir>/share/recipes/` (`root:_runnervm`, `0755`/`0644` — readable by the daemon group,
writable by neither the daemon nor an unprivileged user). `runnerctl doctor`'s `build_recipes` check
warns when this directory does not exist yet; it is not required — pointing `image build` at any
readable Runnerfile directly always works.

## Logs

`build.log` (the transcript `runnerctl build log`/`image build --wait` tail) lives at
`<stateDir>/logs/builds/<id>/build.log` (`RunnerPaths.buildLogFile`), capped at `build.maxLogBytes`
and outliving the build's own VM directory, which is removed once the build reaches a terminal
state. `runnerctl build show <id>` reports the exact path.

## Known limitations

* **30-minute step ceiling.** The guest agent silently clamps every `agent.exec` timeout at 30
  minutes; `build.stepTimeout`/`RUN --timeout=` longer than that is caught at validation
  (`BUILD_STEP_TIMEOUT_TOO_LONG`) rather than just being quietly ineffective.
* **No layer cache.** Every build re-runs every step from its `FROM` forward — there is no
  Dockerfile-style per-instruction cache, and no partial-rebuild-from-a-changed-step. Chaining
  recipes (bootstrap → docker → language) is the only reuse mechanism: rebuild the smallest recipe
  that actually changed and re-run everything downstream of it.
* **`hdiutil` under a LaunchDaemon is unverified.** Both the boot seed and (when a recipe has
  `COPY` steps) the build context are rendered with `hdiutil makehybrid`. The experimental
  LaunchDaemon install path already carries an analogous open question for Virtualization.framework
  itself — no automatically-unlocked login keychain outside a GUI session (see
  [docs/install.md](install.md#choosing-a-launchd-variant-plan-spike-s3)) — and `hdiutil` has a
  similar reputation for headless launchd contexts. `runnerctl doctor`'s `build_tools` check runs a
  real `hdiutil makehybrid` smoke test on every invocation specifically so this is caught on that
  host, ahead of time, rather than assumed either way.
* **The base image cache is unbounded.** `<rootDir>/cache/base-images/` is never swept by
  `image prune` or any retention policy — it only grows. Clear it by hand if disk space matters.
* **x86_64 guests are not supported.** Apple Virtualization is arm64-only, same as every other
  RunnerVM guest.
