# RunnerVM

Linux ARM64 GitHub Actions runners hosted as Apple Virtualization.framework VMs on
Apple Silicon — scale-to-zero, no shared cloud infrastructure.

RunnerVM is a self-hosted runner orchestrator for a single Mac host: `runnerd` runs
ephemeral (and, later, reusable) guest VMs on demand as GitHub Actions jobs arrive.

- `runnerd` — the host daemon: config, scheduling, GitHub scale-set demand, SQLite state.
- `vmworker` — one process per VM; the only binary that links `Virtualization.framework`
  and carries the `com.apple.security.virtualization` entitlement.
- `runnerctl` — the CLI, talking to `runnerd` over a Unix-domain socket.
- `GuestAgent/` — the Go agent that runs inside each guest (systemd/launchd packaged).

## Getting started

```sh
swift build
scripts/sign-dev.sh              # ad-hoc sign vmworker for local development
.build/debug/runnerctl doctor    # check this host is ready
```

For a production install (release binaries, launchd packaging, dedicated service
account) see [`docs/install.md`](docs/install.md).

## Status

See [`docs/status.md`](docs/status.md) for the full capability matrix and
[`CHANGELOG.md`](CHANGELOG.md) for what landed when.

- Supported guest: Linux/arm64 only. macOS guests are not implemented; `runnerctl config
  validate` (and `config apply`) reject `os: macos` with `GUEST_OS_UNSUPPORTED`.
- Live end-to-end proven on GitHub.com (Linux/arm64 ephemeral runner, full job; autoscaling with
  parallel jobs) — see [docs/verification.md](docs/verification.md).
- Images: build them on the host with `runnerctl image build` and the shipped `Runnerfile` recipes
  ([docs/image-build.md](docs/image-build.md); bootstrap ~4 min, derived ~1 min, verified live),
  pull RunnerVM images from any OCI registry, or import tart images read-only
  (`runnerctl image pull ghcr.io/cirruslabs/ubuntu:latest` — inspect/re-publish only, no guest agent).
- Recommended production lifecycle: `ephemeral` — one job per VM, then destroy. `reusable`
  exists but ephemeral is the mode this project is validated against.
- CI is green on `master` (Swift 6.1.2 / macOS 15, Go, shellcheck).

## Building images

```sh
runnerctl image build images/recipes/ubuntu-24-minimal --name ubuntu-24-minimal   # from the Ubuntu cloud image
runnerctl image build images/recipes/ubuntu-24 --name ubuntu-24                   # FROM ubuntu-24-minimal, adds Docker
runnerctl image build ./my-recipe --name my-image --arg NODE_MAJOR=22             # your own Runnerfile
```

## Documentation

- [`RunnerVM — GitHub Actions VM Orchestrator.md`](<RunnerVM — GitHub Actions VM Orchestrator.md>) — the full architecture/implementation spec.
- [`docs/status.md`](docs/status.md) — current capability matrix, limitations, next steps; [`CHANGELOG.md`](CHANGELOG.md).
- [`TODO.md`](TODO.md) — milestone tracking, spike findings, open questions.
- [`docs/install.md`](docs/install.md), [`docs/images.md`](docs/images.md) (legacy host-script image
  build), [`docs/image-build.md`](docs/image-build.md) (in-daemon `runnerctl image build`),
  [`docs/state_machines.md`](docs/state_machines.md).
- [`Proto/`](Proto) — the daemon/worker/guest wire protocols.

## Provenance

RunnerVM ports selected know-how from `openai/tart` (FSL-1.1-ALv2) and
`actions/scaleset` (MIT) under the terms in [`PROVENANCE.md`](PROVENANCE.md); see
also [`NOTICE`](NOTICE). Everything else is original to this project.
