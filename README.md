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

- Supported guest: Linux/arm64 only. macOS guests are not implemented; `runnerctl config
  validate` (and `config apply`) reject `os: macos` with `GUEST_OS_UNSUPPORTED`.
- Live end-to-end proven on GitHub.com (Linux/arm64 ephemeral runner, full job) — see
  [docs/verification.md](docs/verification.md). macOS guests: see [docs/macos-guests.md](docs/macos-guests.md).
- Recommended production lifecycle: `ephemeral` — one job per VM, then destroy. `reusable`
  exists but ephemeral is the mode this project is validated against.

## Documentation

- [`RunnerVM — GitHub Actions VM Orchestrator.md`](<RunnerVM — GitHub Actions VM Orchestrator.md>) — the full architecture/implementation spec.
- [`TODO.md`](TODO.md) — milestone tracking, spike findings, open questions.
- [`docs/install.md`](docs/install.md), [`docs/images.md`](docs/images.md), [`docs/state_machines.md`](docs/state_machines.md).
- [`Proto/`](Proto) — the daemon/worker/guest wire protocols.

## Provenance

RunnerVM ports selected know-how from `openai/tart` (FSL-1.1-ALv2) and
`actions/scaleset` (MIT) under the terms in [`PROVENANCE.md`](PROVENANCE.md); see
also [`NOTICE`](NOTICE). Everything else is original to this project.
