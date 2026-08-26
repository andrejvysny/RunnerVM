# RunnerVM — Verification record

What has actually been exercised, and how. Updated 2026-08-26.

## Live end-to-end (Linux/arm64) — PASS

Proven on **`andrejvysny/github-managed-runners`** (public repo), host macOS 26.4 (Apple Silicon),
against **GitHub.com** (not a fake):

1. Built a runner image with `scripts/build-ubuntu-image.sh` from the Ubuntu 24.04 arm64 cloud
   image (qcow2 → raw), full provenance: actions/runner `2.337.0` (sha256 from the GitHub release
   **asset digest**), docker-ce `29.7.2`, 749 packages, guest agent `110c9e4`, sealed disk sha256.
2. `runnerd --foreground` applied the config, authenticated the PAT, and registered a repository
   **Runner Scale Set** `runnervm-ubuntu-24` (GitHub scale-set id 1, label **`ubuntu-24`**).
3. Dispatched `.github/workflows/runnervm-selftest.yml` (`runs-on: ubuntu-24`).
4. Observed the full path in `runnerctl`:

   ```
   JobAvailable (msg 100000001) → VM create → guest agent (vsock) → JIT config
   → runner online (rvm-ubuntu24-7f314b82, id 2) → jobRunning → completed
   → VM stopping → deleted → demand 0
   ```

5. **All 12 job steps green**: host/OS facts, `systemctl is-active runnervm-guest-agent`,
   `docker info` + `docker run --rm alpine`, `actions/checkout`, `actions/setup-go`,
   `go build ./cmd/guest-agent` + `go test ./internal/rpc/...`, summary, and the runner's own
   Set up / Post / Complete steps. Run concluded **success**; the ephemeral VM was destroyed and
   `runnerctl vm list` returned empty.

### Bugs found and fixed during live bring-up

| # | Symptom | Cause | Fix (commit) |
|---|---------|-------|--------------|
| 1 | Job sat `queued`, scale set never received demand | Scale set registered with the prefixed scale-set name as its **label**; GitHub keeps labels from creation, so `runs-on: <profile>` never matched | Label = **profile name** (`row.name`); the `runnervm-` prefix only namespaces the scale-set *name*. `runs-on: <profile>` in all workflows/docs (`b9ab328`) |
| 2 | CI red on Swift 6.1.2 (green on dev 6.3.3) | `VMRuntime.start/stop` async overlays and `withSessionRefresh<T>` / `gated<T>` / `mapTransportErrors<T>` sent non-`Sendable` values across an isolation boundary | Completion-handler APIs; `T: Sendable` bounds (`04b0f29`, `b9ab328`) |
| 3 | Builder VM stopped ~1 s after boot, empty serial | Base was a bare ext4 rootfs (the Ubuntu cloud **`.tar.gz`**), which EFI cannot boot | `require_partition_table` rejects non-GPT / qcow2 bases early; use the qcow2 `.img` → raw (`04b0f29`) |
| 4 | CI red on 6.1.2 | `OCIRegistryTests` sparse-disk island offsets: untyped `0` not inferred as the tuple's `UInt64` on 6.1.2 | Annotate `0 as UInt64` (`29e8e17`) |

**Lesson recorded:** the dev host runs Swift 6.3.3; CI's Swift 6.1.2 is stricter about
sending/inference. Treat a green CI run as the authoritative build gate, not a local `swift build`.

## Automated tests — PASS (local)

- Swift: **935 tests / 127 suites** pass (`swift test`). Note: after `ImageMetadata` grew a
  `Provenance` field, a stale shared `.build` produced a SIGSEGV in `ImageMetadata.init(from:)`;
  `swift package clean` resolves it.
- Go guest agent: `go vet` + `go test -race ./...` (70 tests) pass.
- Shell: `shellcheck` + `bash -n` clean; `scripts/tests/build-ubuntu-image-test.sh` (52) and
  `scripts/tests/install-test.sh` (10) pass.
- Workflows: `actionlint` clean.

## CI (`.github/workflows/ci.yml`) — GREEN target

Jobs: `swift` (Xcode 16.4 / Swift 6.1.2 — build + test + sign vmworker + entitlement verify +
probe), `lint` (shellcheck, bash, actionlint, both bash test suites), `go` (vet, gofmt, race,
darwin cross-build). Least-privilege `permissions: contents: read`, SHA-pinned actions.

The first hardening pushes were blocked by a **GitHub Actions major outage** on 2026-08-26 (runs
`startup_failure`/`queued` with zero jobs, including GitHub's own Dependabot). Once Actions
recovered, the Swift job surfaced the 6.1.2 issues in the table above; they are fixed. Latest
commit's CI is the authoritative check for full green.

## Not yet verified (needs hardware time / dedicated org)

- `scripts/qualify-host.sh` cold-boot / power-cut qualification (needs the Mac mini itself).
- `scripts/live-github-e2e.sh` full scenario matrix (cancel, daemon-restart-mid-job, redelivery,
  65-min long job, concurrency, queue overflow) — the single-job happy path above is proven; the
  rest need a dedicated org/repo and dedicated time.
- External log shipping (Vector / Fluent Bit configs ship; a real pipeline is not stood up).

## Guest OS support

- **Linux/arm64: supported and proven** (above).
- **macOS guests: not implemented.** Config validation rejects `os: macos` with
  `GUEST_OS_UNSUPPORTED`. See `docs/macos-guests.md` for the milestone plan and status.
