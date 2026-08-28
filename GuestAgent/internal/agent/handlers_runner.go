package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/runnervm/guest-agent/internal/rpc"
	"github.com/runnervm/guest-agent/internal/runner"
)

// defaultStopGrace is the SIGTERM→SIGKILL delay when the host omits
// graceMs. The actions runner needs a few seconds to finish uploading logs.
const defaultStopGrace = 15 * time.Second

func (s *Service) handleStartRunner(ctx context.Context, req rpc.Envelope) (any, error) {
	var p StartRunnerRequest
	if err := decodePayload(req.Payload, &p); err != nil {
		return nil, err
	}
	if p.SessionID == "" {
		return nil, errInvalidParams("sessionId is required")
	}
	jit, err := unquoteJSONString(p.JITConfig)
	if err != nil {
		return nil, errInvalidParams("jitConfig must be a JSON string")
	}
	if len(jit) == 0 {
		return nil, errInvalidParams("jitConfig is required")
	}
	// The secret exists in three places: this slice, the decoded payload
	// buffer, and the execve environment. The first two are wiped here;
	// the third dies with the child's address space. Nothing is logged.
	defer func() {
		wipe(jit)
		wipe(p.JITConfig)
		wipe(req.Payload)
	}()

	result, err := s.runner.Start(ctx, runner.StartRequest{
		SessionID: p.SessionID,
		JITConfig: jit,
		WorkDir:   p.WorkDir,
		Env:       p.Env,
		Labels:    p.Labels,
	})
	if err != nil {
		return nil, mapRunnerError(err)
	}
	return StartRunnerResult{
		PID:       int64(result.PID),
		StartedAt: result.StartedAt.UTC().Format(time.RFC3339),
	}, nil
}

func (s *Service) handleRunnerStatus(ctx context.Context, req rpc.Envelope) (any, error) {
	var p RunnerStatusRequest
	if err := decodePayload(req.Payload, &p); err != nil {
		return nil, err
	}
	if p.SessionID == "" {
		return nil, errInvalidParams("sessionId is required")
	}

	st := s.runner.Status(p.SessionID)
	out := RunnerStatusResult{State: st.State}
	if st.PID > 0 {
		pid := int64(st.PID)
		out.PID = &pid
	}
	if st.ExitCode != nil {
		code := int64(*st.ExitCode)
		out.ExitCode = &code
	}
	if st.ExitedAt != nil {
		out.ExitedAt = st.ExitedAt.UTC().Format(time.RFC3339)
	}
	return out, nil
}

func (s *Service) handleStopRunner(ctx context.Context, req rpc.Envelope) (any, error) {
	var p StopRunnerRequest
	if err := decodePayload(req.Payload, &p); err != nil {
		return nil, err
	}
	if p.SessionID == "" {
		return nil, errInvalidParams("sessionId is required")
	}
	grace := time.Duration(p.GraceMs) * time.Millisecond
	if grace <= 0 {
		grace = defaultStopGrace
	}

	stopped, err := s.runner.Stop(ctx, p.SessionID, grace)
	if err != nil {
		return nil, errInternal(err)
	}
	return StopRunnerResult{Stopped: stopped}, nil
}

func mapRunnerError(err error) error {
	switch {
	case errors.Is(err, runner.ErrAlreadyStarted):
		return errCode(CodeAlreadyStarted, err, false)
	case errors.Is(err, runner.ErrBusy):
		return errCode(rpc.CodeBusy, err, true)
	case errors.Is(err, runner.ErrInvalidSession):
		return errCode(rpc.CodeInvalidParams, err, false)
	case errors.Is(err, runner.ErrKeychainUnavailable):
		// Not retryable: a guest that cannot build a keychain will not
		// manage it on the next call either, so the host should replace the
		// VM rather than spin.
		return errCode(CodeKeychainUnavailable, err, false)
	default:
		return errInternal(err)
	}
}

// unquoteJSONString converts a raw JSON string literal to bytes without
// producing a Go string in the common case: Go strings are immutable, so a
// secret that becomes one can never be wiped, only dropped.
func unquoteJSONString(raw json.RawMessage) ([]byte, error) {
	if len(raw) < 2 || raw[0] != '"' || raw[len(raw)-1] != '"' {
		return nil, fmt.Errorf("agent: not a JSON string")
	}
	body := raw[1 : len(raw)-1]
	for _, c := range body {
		if c == '\\' {
			// Escapes are unexpected for a base64 JIT config, but decode
			// them correctly rather than corrupting the credential.
			var s string
			if err := json.Unmarshal(raw, &s); err != nil {
				return nil, err
			}
			return []byte(s), nil
		}
	}
	return body, nil
}

func wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
