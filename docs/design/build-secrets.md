# Design: build-time secrets for `runnerctl image build`

Status: **design only** — not implemented. `ARG` is explicitly non-secret
([docs/image-build.md](../image-build.md), "Build arguments are not secrets"); this document fixes
what a real secret mechanism must guarantee before anyone implements one, so the first
implementation does not quietly become a second, leakier `--arg`.

## Surface

```sh
runnerctl image build recipe/ --secret NPM_TOKEN=...            # value from the argument
runnerctl image build recipe/ --secret-file NPM_TOKEN=/path     # value read by runnerctl
```

```dockerfile
RUN --mount=type=secret,id=NPM_TOKEN \
    npm config set //registry/:_authToken="$(cat /run/secrets/NPM_TOKEN)" && npm ci
```

`--secret NAME=VALUE` is accepted for parity with other tools but documented as the worse form
(shell history, `ps`); `--secret-file` is the recommended one. Only `RUN` steps that name the
secret in `--mount=type=secret,id=NAME` see it, as a file under `/run/secrets/NAME` inside the
guest, mode 0400, owned by the step's user.

## Invariants (all of them, or it is not a secret)

| # | Invariant | How |
| --- | --- | --- |
| 1 | Never in SQLite | The build row records only the secret *names* (`secret_names_json`), never values; `BuildInfoDTO.secrets` is a name list. |
| 2 | Never in provenance | `ImageMetadata.Provenance.Recipe` gains `secretNames: [String]?` and nothing else; the value is not hashed into any digest the image carries. |
| 3 | Never in OCI metadata | Follows from 2: the pushed config blob embeds `ImageMetadata`. |
| 4 | Never in logs | The value never enters a log call site; `Redactor.standard` still applies as defence in depth, and the guest's `agent.exec` request carrying the value is marked `singleShot`+unlogged like `startRunner`. |
| 5 | Never in the status API | `build.get`/`build.list` expose names only; `build.log` output is the step's own output — a recipe that `cat`s its secret leaks it itself, which is documented. |
| 6 | Never in child argv | The value travels `runnerctl → runnerd` inside the `image.build` RPC payload over the uid-checked Unix socket, and `runnerd → guest` inside a dedicated `agent.putSecret` (or the `exec` request's `stdin`), never as a command-line argument to `tar`, `hdiutil`, `vmworker` or the guest shell. |
| 7 | Scoped to the intended `RUN` | `runnerd` writes the value into the guest immediately before the step that mounts it and removes it immediately after (`agent.exec` post-step hook or an explicit `agent.dropSecret`), so a later step, the probe, and the sealed disk never see it. |
| 8 | Removed from temporary storage | Guest side: a tmpfs mount (`/run/secrets`), never the disk that gets sealed; `runnerd` side: held in memory for the duration of the build only, cleared on terminal state, never spilled to the build directory. |
| 9 | Not re-delivered after a restart | Like the JIT config: a daemon restart mid-build loses the value on purpose; the build fails with `BUILD_SECRET_LOST` rather than resuming without it. |

## Pieces

- `ImageBuildRequest.secrets: [String: String]` (values), separated from `args` so the persistence
  layer cannot accidentally serialise it with the row; `Sources/Orchestration/Build/BuildSecrets.swift`
  holds them in the `ImageBuilder` actor keyed by build id.
- Recipe planner: `RUN --mount=type=secret,id=NAME` parsed into `RecipeStep.secretMounts`;
  `RECIPE_UNKNOWN_SECRET` when a step mounts a name the request did not supply, `RECIPE_UNUSED_SECRET`
  warning for the reverse.
- Guest agent: `agent.putSecret {name, bytes}` writes to `/run/secrets/<name>` on a tmpfs the
  agent mounts at startup; `agent.dropSecret {name}` unlinks it. Both refused in host-safe-mode.
- `BuildExecPump`: put → exec → drop, with drop in a `defer` so a failed step still clears it.
- Sealing: the seal script asserts `/run/secrets` is empty or absent before hashing the disk.

## Explicitly out of scope

- Secrets for `COPY` (copy the file in a `RUN` from the mount instead).
- Persisting secrets across daemon restarts.
- Any registry-side secret store; values come from the operator's shell/file each time.
