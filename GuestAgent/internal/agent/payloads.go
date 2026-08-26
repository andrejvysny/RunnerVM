package agent

import (
	"bytes"
	"encoding/json"
	"io"
)

// This file is the single source of truth for the guest protocol's payload
// shapes. Field names and types must stay identical to Proto/guest_agent.md
// because the Swift host client is written against that document.

// HelloResult answers agent.hello.
type HelloResult struct {
	ProtocolVersion int64    `json:"protocolVersion"`
	AgentVersion    string   `json:"agentVersion"`
	OS              string   `json:"os"`
	Arch            string   `json:"arch"`
	Hostname        string   `json:"hostname"`
	BootID          string   `json:"bootId"`
	Capabilities    []string `json:"capabilities"`
}

// HealthResult answers agent.health. Reasons is always present (possibly
// empty) so the host never has to distinguish null from [].
type HealthResult struct {
	State   string   `json:"state"`
	Reasons []string `json:"reasons"`
}

// InfoResult answers agent.getInfo. The two version fields are omitted
// when the corresponding software is not installed.
type InfoResult struct {
	IPAddresses   []string `json:"ipAddresses"`
	UptimeSec     int64    `json:"uptimeSec"`
	Kernel        string   `json:"kernel"`
	RunnerVersion string   `json:"runnerVersion,omitempty"`
	DockerVersion string   `json:"dockerVersion,omitempty"`
}

// ResizeDiskResult answers agent.resizeDisk.
type ResizeDiskResult struct {
	Grown     bool  `json:"grown"`
	RootBytes int64 `json:"rootBytes"`
}

// StartRunnerRequest is the agent.startRunner payload. JITConfig stays a
// raw JSON string so the secret can be unquoted into a byte slice and
// zeroed after the spawn, instead of becoming an immutable Go string.
type StartRunnerRequest struct {
	SessionID string            `json:"sessionId"`
	JITConfig json.RawMessage   `json:"jitConfig"`
	WorkDir   string            `json:"workDir,omitempty"`
	Env       map[string]string `json:"env,omitempty"`
	Labels    []string          `json:"labels,omitempty"`
}

// StartRunnerResult answers agent.startRunner. StartedAt is RFC 3339 UTC.
type StartRunnerResult struct {
	PID       int64  `json:"pid"`
	StartedAt string `json:"startedAt"`
}

// RunnerStatusRequest is the agent.runnerStatus payload.
type RunnerStatusRequest struct {
	SessionID string `json:"sessionId"`
}

// RunnerStatusResult answers agent.runnerStatus. PID is omitted when no
// process is known; ExitCode/ExitedAt appear only in state "exited".
type RunnerStatusResult struct {
	State    string `json:"state"`
	PID      *int64 `json:"pid,omitempty"`
	ExitCode *int64 `json:"exitCode,omitempty"`
	ExitedAt string `json:"exitedAt,omitempty"`
}

// StopRunnerRequest is the agent.stopRunner payload. GraceMs is the delay
// between SIGTERM and SIGKILL of the runner's process group.
type StopRunnerRequest struct {
	SessionID string `json:"sessionId"`
	GraceMs   int64  `json:"graceMs,omitempty"`
}

// StopRunnerResult answers agent.stopRunner. Stopped is true when the agent
// has seen the session's process end.
type StopRunnerResult struct {
	Stopped bool `json:"stopped"`
}

// CleanupRequest is the agent.cleanup payload. Epoch is monotonic per VM;
// replaying an epoch is a no-op.
type CleanupRequest struct {
	Epoch int64 `json:"epoch"`
}

// CleanupResult answers agent.cleanup.
type CleanupResult struct {
	OK      bool     `json:"ok"`
	Removed []string `json:"removed"`
}

// ExecRequest is the agent.exec payload.
type ExecRequest struct {
	Argv           []string          `json:"argv"`
	Cwd            string            `json:"cwd,omitempty"`
	Env            map[string]string `json:"env,omitempty"`
	TimeoutMs      int64             `json:"timeoutMs,omitempty"`
	MaxOutputBytes int64             `json:"maxOutputBytes,omitempty"`
}

// ExecChunk is one agent.exec output chunk. Data is base64 in JSON.
type ExecChunk struct {
	Stream string `json:"stream"`
	Data   []byte `json:"data"`
}

// ExecResult is the last payload-bearing agent.exec chunk. The rpc server
// appends an empty end:true chunk after it (or an error-bearing one when
// the exec failed), so the host reads chunks until end and takes exitCode
// from the final payload.
type ExecResult struct {
	ExitCode int64 `json:"exitCode"`
}

// emptyResult is the payload for methods that return {}.
type emptyResult struct{}

func newByteReader(b []byte) io.Reader { return bytes.NewReader(b) }
