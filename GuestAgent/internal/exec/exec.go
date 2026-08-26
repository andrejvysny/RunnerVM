// Package exec runs a bounded, streamed command inside the guest on behalf
// of the host (agent.exec). It is an administration and debugging tool: the
// host is trusted, the guest is not, so every invocation carries an
// explicit timeout and output budget.
package exec

import (
	"context"
	"errors"
	"fmt"
	"io"
	osexec "os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Stream names carried in each emitted chunk.
const (
	StreamStdout = "stdout"
	StreamStderr = "stderr"
)

// chunkSize bounds one emitted chunk. 32 KiB keeps a base64 chunk payload
// (~44 KiB) far below the 4 MiB guest frame cap.
const chunkSize = 32 << 10

// defaultTimeout applies when the caller omits timeoutMs; no exec may run
// unbounded, because a disconnected host would otherwise leak a process.
const defaultTimeout = 60 * time.Second

// maxTimeout caps what a caller may ask for.
const maxTimeout = 30 * time.Minute

// Sentinel failures the RPC layer maps onto protocol error codes.
var (
	ErrTimeout     = errors.New("exec: timeout exceeded")
	ErrOutputLimit = errors.New("exec: output limit exceeded")
	ErrInvalidArgv = errors.New("exec: argv must be non-empty")
)

// Chunk is one streamed piece of command output. Data marshals to base64
// because JSON cannot carry arbitrary bytes.
type Chunk struct {
	Stream string `json:"stream"`
	Data   []byte `json:"data"`
}

// Request is one agent.exec invocation.
type Request struct {
	Argv           []string
	Cwd            string
	Env            map[string]string
	TimeoutMs      int64
	MaxOutputBytes int64
}

// Options are the process-level policies the agent applies to every exec.
type Options struct {
	// Credential drops privileges for the child; nil runs as the agent
	// (root in production), which is the default for an admin tool.
	Credential *syscall.Credential
	// BaseEnv is the environment the request's Env is merged into.
	BaseEnv map[string]string
}

// Run executes req, calling emit for each output chunk in order, and
// returns the child's exit code. emit is invoked from a single goroutine,
// so a non-concurrency-safe sink is safe to write to.
//
// A non-zero exit is not an error: it is reported through exitCode. Errors
// are reserved for the agent failing to honour the contract (spawn failure,
// timeout, output cap).
func Run(ctx context.Context, req Request, opt Options, emit func(Chunk) error) (int, error) {
	if len(req.Argv) == 0 || req.Argv[0] == "" {
		return -1, ErrInvalidArgv
	}

	timeout := time.Duration(req.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	if timeout > maxTimeout {
		timeout = maxTimeout
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := osexec.Command(req.Argv[0], req.Argv[1:]...)
	cmd.Dir = req.Cwd
	cmd.Env = mergeEnv(opt.BaseEnv, req.Env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Credential: opt.Credential}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return -1, fmt.Errorf("exec: stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return -1, fmt.Errorf("exec: stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return -1, fmt.Errorf("exec: start %q: %w", req.Argv[0], err)
	}
	pgid := cmd.Process.Pid

	chunks := make(chan Chunk, 16)
	var readers sync.WaitGroup
	readers.Add(2)
	go pump(&readers, stdout, StreamStdout, chunks)
	go pump(&readers, stderr, StreamStderr, chunks)
	go func() {
		readers.Wait()
		close(chunks)
	}()

	// The child is killed by process group, not pid: a shell command that
	// forked helpers must not outlive the exec.
	var killOnce sync.Once
	kill := func() {
		killOnce.Do(func() { _ = syscall.Kill(-pgid, syscall.SIGKILL) })
	}
	watchDone := make(chan struct{})
	defer func() { close(watchDone) }()
	go func() {
		select {
		case <-runCtx.Done():
			kill()
		case <-watchDone:
		}
	}()

	var (
		sent     int64
		limitHit bool
		emitErr  error
	)
	for chunk := range chunks {
		if limitHit || emitErr != nil {
			continue // drain so the readers can finish and Wait can reap
		}
		if req.MaxOutputBytes > 0 {
			remaining := req.MaxOutputBytes - sent
			if remaining <= 0 {
				limitHit = true
				kill()
				continue
			}
			if int64(len(chunk.Data)) > remaining {
				chunk.Data = chunk.Data[:remaining]
				limitHit = true
			}
		}
		sent += int64(len(chunk.Data))
		if len(chunk.Data) > 0 {
			if err := emit(chunk); err != nil {
				emitErr = err
				kill()
				continue
			}
		}
		if limitHit {
			kill()
		}
	}

	waitErr := cmd.Wait()
	exitCode := exitCodeOf(waitErr)

	switch {
	case emitErr != nil:
		return exitCode, emitErr
	case limitHit:
		return exitCode, fmt.Errorf("%w (%d bytes)", ErrOutputLimit, req.MaxOutputBytes)
	case errors.Is(runCtx.Err(), context.DeadlineExceeded):
		return exitCode, fmt.Errorf("%w after %s", ErrTimeout, timeout)
	case ctx.Err() != nil:
		return exitCode, ctx.Err()
	}
	return exitCode, nil
}

// pump reads one output stream into fixed-size chunks. Read errors end the
// stream: the pipe closing is the normal termination path.
func pump(wg *sync.WaitGroup, r io.Reader, stream string, out chan<- Chunk) {
	defer wg.Done()
	buf := make([]byte, chunkSize)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			out <- Chunk{Stream: stream, Data: data}
		}
		if err != nil {
			return
		}
	}
}

func exitCodeOf(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *osexec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

// mergeEnv renders base overlaid with overrides as a sorted KEY=VALUE
// slice. Sorting keeps exec output reproducible across runs.
func mergeEnv(base, overrides map[string]string) []string {
	merged := make(map[string]string, len(base)+len(overrides))
	for k, v := range base {
		merged[k] = v
	}
	for k, v := range overrides {
		if k == "" || strings.ContainsAny(k, "=\x00") {
			continue
		}
		merged[k] = v
	}
	keys := make([]string, 0, len(merged))
	for k := range merged {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, k+"="+merged[k])
	}
	return out
}
