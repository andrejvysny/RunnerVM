package agent

import (
	"context"
	"errors"
	"syscall"

	guestexec "github.com/runnervm/guest-agent/internal/exec"
	"github.com/runnervm/guest-agent/internal/rpc"
)

// handleExec streams a command's output as chunks and finishes with a
// payload carrying the exit code. The rpc server appends the terminal
// end:true chunk once this returns, carrying an error when the exec was
// cut short by the timeout or the output cap.
func (s *Service) handleExec(ctx context.Context, req rpc.Envelope, sink *rpc.Sink) error {
	var p ExecRequest
	if err := decodePayload(req.Payload, &p); err != nil {
		return err
	}
	if len(p.Argv) == 0 {
		return errInvalidParams("argv must be a non-empty array")
	}

	s.log.Info("exec", "argv0", p.Argv[0], "argc", len(p.Argv),
		"timeoutMs", p.TimeoutMs, "maxOutputBytes", p.MaxOutputBytes)

	exitCode, err := guestexec.Run(ctx, guestexec.Request{
		Argv:           p.Argv,
		Cwd:            p.Cwd,
		Env:            p.Env,
		TimeoutMs:      p.TimeoutMs,
		MaxOutputBytes: p.MaxOutputBytes,
	}, guestexec.Options{
		Credential: s.execCredential(),
		BaseEnv:    s.execBaseEnv(),
	}, func(c guestexec.Chunk) error {
		return sink.Send(ExecChunk{Stream: c.Stream, Data: c.Data})
	})

	switch {
	case errors.Is(err, guestexec.ErrTimeout):
		return errCode(rpc.CodeDeadline, err, false)
	case errors.Is(err, guestexec.ErrOutputLimit):
		return errCode(CodeOutputLimit, err, false)
	case errors.Is(err, guestexec.ErrInvalidArgv):
		return errCode(rpc.CodeInvalidParams, err, false)
	case errors.Is(err, context.Canceled):
		return err // the server turns this into CANCELLED
	case err != nil:
		return errInternal(err)
	}
	return sink.Send(ExecResult{ExitCode: int64(exitCode)})
}

// execCredential decides whether agent.exec drops privileges. The default
// is root, because exec exists to administer the guest; --exec-as-runner
// exists for images where that is too much authority.
func (s *Service) execCredential() *syscall.Credential {
	if !s.cfg.ExecAsRunner {
		return nil
	}
	return s.account.Credential()
}

// execBaseEnv gives the command a usable environment: a daemon's inherited
// environment has no HOME and often no PATH.
func (s *Service) execBaseEnv() map[string]string {
	home := "/root"
	user := "root"
	if s.cfg.ExecAsRunner {
		home, user = s.account.Home, s.account.Name
	}
	return map[string]string{
		"PATH":    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME":    home,
		"USER":    user,
		"LOGNAME": user,
		"TMPDIR":  "/tmp",
	}
}
