# Repository Guidelines

## Project Overview

RunnerVM: self-hosted GitHub Actions runner orchestrator for a single Apple Silicon Mac host. Runs ephemeral Linux/arm64 guest VMs via Apple Virtualization.framework, scale-to-zero, driven by GitHub scale-set demand. Three languages: Swift 6 (main harness), Go (in-guest agent), Bash (ops scripts).

## Architecture & Data Flow

**Executables** (thin; composition root is `Sources/Orchestration/DaemonRuntime.swift`):
- `runnerd` (`Sources/runnerd/RunnerD.swift`, `@main`) — foreground daemon; DaemonLock (single instance), SQLite migration, serves `runnerd.sock`, 10s reconcile timer.
- `runnerctl` (`Sources/runnerctl/`) — CLI over `runnerd.sock` (doctor, VM/image/scale-set/system commands).
- `vmworker` (`Sources/vmworker/main.swift`) — one process per VM; only binary linking Virtualization.framework + entitlement.
- `GuestAgent/cmd/guest-agent` (Go) — runs inside the guest, serves vsock RPC.

**Data flow**: `runnerctl` → Unix-socket JSON-RPC (`RPC`/`DaemonAPI`) → `Orchestrator` actor. Orchestrator consumes GitHub scale-set demand events (`GitHubControl` DemandProvider AsyncStream) + 10s Reconciler tick → `Scheduler` (pure capacity math) → `InstanceManager` creates VMs (`ImageStore` APFS-clone staging from OCI-registry images) → spawns `vmworker` → `VirtualizationCore` boots Linux VM, VsockBridge connects `GuestControl.GuestAgentClient` ↔ in-guest Go agent → `RunnerSessionManager` registers ephemeral GitHub runner, observes runner exit → instance destroyed.

**Key invariants**:
- Layering enforced by `Package.swift` dependency DAG: `RunnerCore`/`ImageBuild`/`Scheduler` are pure (no I/O); only `VirtualizationCore` imports Virtualization; `Orchestration` on top; executables thin.
- Scheduling truth lives in SQLite (GRDB repositories), not actor memory — orchestrator re-reads repository rows every pass; every decision is a row transition guarded by state machines (`InstanceState`, `RunnerSessionState`, `ImageBuildState`) with `StateTransitionError`.
- Wire-protocol parity: `Proto/fixtures/envelopes.json` golden fixtures shared by Swift `RPCTests` and Go `internal/rpc` tests; integer fields are int64-on-wire.

## Key Directories

- `Sources/` — 20 Swift targets (see layering above). Notable: `RPC/` (custom JSON-RPC: Envelope, FrameCodec, 16MB/4MB frame caps), `Persistence/` (GRDB records/repositories/migrations), `GitHubControl/` (API client, keychain credentials), `ImageStore/` (APFS clone, QCOW2, disk layout), `ConfigLoader/` (YAML), `RunnerLogging/` (JSON logs, Redactor).
- `GuestAgent/` — Go module `github.com/runnervm/guest-agent` (go 1.26, dep mdlayher/vsock); `internal/{agent,rpc,vsock,exec,runner,metrics,disk,cleanup,system}`; Makefile.
- `Proto/` — wire protocol specs (`daemon_api.md`, `guest_agent.md`, `worker_protocol.md`, `envelope.md`) + fixtures.
- `scripts/` — `install.sh`, `sign-dev.sh`, `build-ubuntu-image.sh` (legacy), `qualify-host.sh`, `live-github-e2e.sh`, `scripts/tests/`.
- `docs/` — install, image-build (Runnerfile reference), logging, qualification, live-integration, `db_schema_v{1,2,3}.sql`, e2e workflow.
- `Tests/` — Swift tests, one dir per module.
- `packaging/launchd/` — launchd plist templates.
- Ignore `.claude/worktrees/` — stale agent copies.

## Development Commands

```bash
swift build                                   # build all targets (macOS 15+, Xcode 16.4)
scripts/sign-dev.sh                           # REQUIRED after build before running VMs locally (ad-hoc codesign vmworker)
swift test --parallel                         # all Swift tests
swift test --filter RPCTests                  # per-module
.build/debug/runnerctl doctor                 # health checks against local daemon

make -C GuestAgent test                       # go test ./... -count=1
make -C GuestAgent build-linux                # static linux arm64+amd64 (CGO_ENABLED=0)
make -C GuestAgent all                        # fmt-check + vet + test + build

bash scripts/tests/install-test.sh            # script unit tests (also run in CI)
```

Production install: `scripts/install.sh --launchd agent --config <file>` (see `docs/install.md`). Image build: `runnerctl image build images/recipes/ubuntu-24-minimal --name ... --arg NODE_MAJOR=22`.

## Code Conventions & Common Patterns

- **Swift 6 strict concurrency**: actors for stateful services (`Orchestrator`, `DaemonRuntime`); structured Tasks for event consumption; `AsyncStream` for events; injected `@Sendable` clocks (`now: @Sendable () -> Date`) for testability.
- **Typed errors**: `RunnerError` protocol (`code`+`message`) with per-domain types in `RunnerCore/Errors/`; RPC failures returned in-fabric as `RPCErrorPayload`; backoff/hold-down (`startHoldDown`) instead of hot retries.
- **DI**: constructor injection of repository protocols (`any HostRepository`); test seams in `DaemonRuntime.Options` (`WorkerLauncher`, `RegistryClientFactory`, `DemandMode`); `Testing/` fake submodules in `GitHubControl`/`GuestControl`.
- **Typed IDs**: `HostID`, `RunnerProfileID`, `InstanceID` (`RunnerCore/IDs.swift`) — no raw String IDs in domain code.
- **Reconcile steps**: `ReconcileStep` protocol; `CompositeReconcileStep` runs all steps even if one throws.
- **Formatting**: `.swiftformat` (indent 2, maxwidth 110) — not yet enforced, ~250 files predate rules; gofmt for Go. Match file-local style until bulk format lands.
- Go: package-internal tests, platform-split files (`*_darwin_test.go`/`*_linux_test.go`).

## Important Files

- `Package.swift` — target graph + layering rules (read before adding targets/imports).
- `Sources/Orchestration/DaemonRuntime.swift` + `Orchestrator.swift` — composition root and core loop.
- `Sources/RunnerCore/StateMachines/` — legal state transitions.
- `Sources/Persistence/Migrations/Migrator.swift` + `docs/db_schema_v*.sql` — SQLite schema (one-way migrations; do not downgrade).
- `Resources/vmworker.entitlements` (prod) / `vmworker-dev.entitlements` (dev) — Virtualization entitlement; signing is fail-closed.
- `Proto/*.md` — wire contracts; update when touching `RPC`/`WorkerProtocol`/`GuestControl`/Go `internal/rpc`.
- `docs/image-build.md` — Runnerfile (Dockerfile subset; CMD/ENTRYPOINT etc. rejected with `RECIPE_*` errors).

## Runtime/Tooling Preferences

- macOS 15+, Xcode 16.4 (hardcoded in CI; `sudo xcode-select -s /Applications/Xcode_16.4.app`).
- SwiftPM (`swift build`/`swift test`); lockfile `Package.resolved` committed. No npm/pnpm/uv/cargo.
- Go 1.26 for GuestAgent (version from `GuestAgent/go.mod`).
- vmworker must be codesigned with the Virtualization entitlement before any local VM run — always `scripts/sign-dev.sh` after `swift build`.
- CI: `.github/workflows/ci.yml` (swift / lint(shellcheck+actionlint+bash tests) / go(-race)); all actions pinned by SHA.

## Testing & QA

- **Swift**: SwiftPM test targets in `Tests/<Module>Tests/` mirror `Sources/<Module>`; each dir has `TestSupport.swift` (Signal/Latch async actors, temp unix sockets — keep paths <104 bytes for `sun_path`, in-memory GRDB). Event-driven waiting only; no sleeps.
- **Go**: `go test ./... -count=1` (CI adds `-race`); loopback-TCP harness replaces AF_VSOCK on host (`GuestAgent/internal/agent/harness_test.go`).
- **Bash**: `scripts/tests/*.sh` dry-run harnesses with `ok()`/`no()`/`expect_contains`.
- **No coverage tooling** — correctness via `-race`, parallel Swift tests, and golden fixtures.
- **Live E2E** (opt-in, not CI default): `scripts/live-github-e2e.sh` against real GitHub.com; needs `gh`, `jq`, `RUNNERVM_E2E_OWNER/REPO/GITHUB_TOKEN`; workflow `docs/e2e/test-repo-workflow.yml` installed in test repo. See `docs/live-integration.md`.
