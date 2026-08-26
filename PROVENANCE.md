# Provenance

The scale-set control plane is a native Swift port of the subset of `github.com/actions/scaleset`
(v0.4.0, MIT) that RunnerVM needs. Behaviour was ported from the reference client; no Go code was
copied. Derived files carry a header:

```
// Ported from github.com/actions/scaleset@v0.4.0 (MIT) <file> — see PROVENANCE.md.
```

RunnerVM bootstraps selected Virtualization.framework / OCI know-how from `openai/tart`
(commit `16d186c`, v2.36.0, licensed FSL-1.1-ALv2). Tart's application architecture is **not** carried
over. Every file derived from Tart carries a header:

```
// Derived from openai/tart@16d186c <original path> — FSL-1.1-ALv2. See PROVENANCE.md.
```

Statuses: `new` (RunnerVM original), `derived` (adapted from Tart, header required),
`rewritten` (concept from Tart, no code copied), `third-party` (SwiftPM/Go dependency), `generated`.

| Path | Status | Origin |
|---|---|---|
| Package.swift | new | — |
| Sources/RunnerCore/** | new | — |
| Sources/VirtualizationCore/HostCapabilities.swift | rewritten | concept: tart `VMConfig.swift:164-190` (min/max clamping) |
| Sources/VirtualizationCore/LinuxVMPlatform.swift | derived | tart `Sources/tart/Platform/Linux.swift` |
| Sources/VirtualizationCore/VMConfigurationBuilder.swift | derived | tart `Sources/tart/VM.swift:315-461` (`craftConfiguration`), desktop devices removed |
| Sources/VirtualizationCore/{VMInstanceSpec,VMPlatformBuilder,SpecDigest,WorkerLock}.swift | new | — |
| Sources/VirtualizationCore/VMRuntime.swift | rewritten | concept: tart `VM.swift` (main-queue VM ownership, `connect(toPort:)`) |
| Sources/VirtualizationCore/{VsockBridge,SocketRelay,UnixSocketAcceptor}.swift | rewritten | concept: tart `ControlSocket.swift` (UDS⇄vsock proxy); POSIX relay, no NIO, no code copied |
| Sources/vmworker/** | new | — (SpikeBoot.swift is throwaway S1 spike) |
| Sources/ImageStore/SHA256Hasher.swift | derived | tart `Sources/tart/OCI/Digest.swift` (4 MiB streaming SHA-256 loop) |
| Sources/ImageStore/APFSClone.swift | rewritten | concept: tart `Commands/Clone.swift:10-16` (APFS CoW), `VMDirectory.swift:207-217` |
| Sources/ImageStore/{ImageStore,InstanceStore,LocalImageManifest,VMInstanceLayout,ImageSealer,DiskAccounting,WorkerLock,FileSystem}.swift | rewritten | concept: tart `ContentStore.swift` (content addressing, verify-then-rename) |
| Sources/runnerd/**, Sources/runnerctl/** | new | — |
| GuestAgent/** | new | Must not copy from cirruslabs/tart-guest-agent (FSL). |
| Resources/*.entitlements | rewritten | concept: tart `Resources/tart-dev.entitlements` |
| scripts/sign-dev.sh | rewritten | concept: tart `scripts/run-signed.sh` |
| Sources/GitHubControl/ScaleSet/ActionsScaleSetClient.swift | rewritten | protocol from `github.com/actions/scaleset@v0.4.0` `client.go` (MIT); Swift port, no code copied |
| Sources/GitHubControl/ScaleSet/ActionsServiceConnection.swift | rewritten | scaleset `client.go` (token exchange, request builder), `common_client.go` (user agent) |
| Sources/GitHubControl/ScaleSet/ActionsServiceURL.swift | rewritten | scaleset `client.go` (endpoint paths, JWT `exp`), `config.go` (config-URL parsing) |
| Sources/GitHubControl/ScaleSet/ActionsServiceWire.swift | rewritten | scaleset `types.go` (wire shapes) |
| Sources/GitHubControl/ScaleSet/ActionsMessageSession.swift | rewritten | scaleset `session_client.go` (session lifecycle, long poll, ack, acquire) |
| Sources/GitHubControl/ScaleSet/ScaleSetMessageDecoder.swift | rewritten | scaleset `client.go` (`parseRunnerScaleSetMessageResponse`) |
| Sources/GitHubControl/ScaleSet/ActionsErrorMapper.swift | rewritten | scaleset `errors.go` (HTTP error decoding) |
| Sources/GitHubControl/Testing/FakeActions{Service,Routes}.swift | new | test double; behaviour mirrors scaleset `internal/testserver/server.go` |
| Sources/OCIRegistry/Client/HTTPStreaming.swift | derived | tart `Sources/tart/Fetcher.swift` (URLSession → `AsyncThrowingStream`, cookies off); timeouts and backpressure added |
| Sources/OCIRegistry/Client/RegistryClient.swift | derived | tart `OCI/Registry.swift:206-304` (ping, manifest GET/PUT, `blobExists`, ranged `pullBlob`), 401-retry flow from `:441` |
| Sources/OCIRegistry/Client/RegistryBlobUpload.swift | derived | tart `OCI/Registry.swift:206-264` (chunked PATCH/PUT push, `uploadLocationFromResponse`) |
| Sources/OCIRegistry/Auth/WWWAuthenticate.swift | derived | tart `OCI/WWWAuthenticate.swift` (quote-aware directive split) |
| Sources/OCIRegistry/Auth/RegistryAuthenticator.swift | derived | tart `OCI/Registry.swift:326-441`, `OCI/Authentication.swift`, `OCI/AuthenticationKeeper.swift` |
| Sources/OCIRegistry/Auth/EnvironmentRegistryCredentials.swift | derived | tart `Credentials/EnvironmentCredentialsProvider.swift`; variables renamed `RUNNERVM_REGISTRY_*` |
| Sources/OCIRegistry/Auth/DockerConfigCredentials.swift | derived | tart `Credentials/DockerConfigCredentialsProvider.swift`; helper subprocess given a timeout |
| Sources/OCIRegistry/Auth/KeychainRegistryCredentials.swift | derived | tart `Credentials/KeychainCredentialsProvider.swift`; read-only, store injectable |
| Sources/OCIRegistry/Layerizer/ContentDigest.swift | derived | tart `OCI/Digest.swift` (4 MiB streaming SHA-256, ranged hash) |
| Sources/OCIRegistry/Layerizer/DiskLayerizer.swift | derived | tart `OCI/Layerizer/DiskV2.swift:25-92` (chunked push) and `:94-262` (pre-truncate, per-chunk resume) |
| Sources/OCIRegistry/Layerizer/SparseDiskWriter.swift | derived | tart `OCI/Layerizer/DiskV2.swift:263-299` (`zeroSkippingWrite`, `F_PUNCHHOLE`) |
| Sources/OCIRegistry/Layerizer/LZ4Codec.swift | derived | tart `OCI/Layerizer/DiskV2.swift` (Apple `Compression` LZ4 stream idiom); compression streamed to a staging file instead of mmap |
| Sources/OCIRegistry/Artifact/{OCIManifest,RunnerVMArtifact,RunnerVMImageTransfer}.swift | rewritten | concept: tart `OCI/Manifest.swift` (descriptor + per-chunk annotation pattern). Media types, annotation keys and config schema are RunnerVM's own (spec §55) |
| Sources/OCIRegistry/Reference/OCIReference.swift | new | — (wraps `RunnerCore.ImageReference`; tart's ANTLR grammar deliberately not carried) |
| Sources/OCIRegistry/{OCIRegistry,Client/RegistryError,Client/RegistryRequest,Layerizer/NVRAMLayer,Layerizer/TransferProgress,Auth/RegistryCredential}.swift | new | — |
| Sources/OCIRegistry/Testing/FakeRegistry*.swift | new | test double; behaviour mirrors the OCI Distribution v2 spec and GHCR's 4 MB upload-chunk cap |

Before public distribution: audit this table, confirm each `derived` file's FSL change date, and
re-evaluate relicensing. Not legal advice.
