package agent

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeJITConfig stands in for the GitHub ephemeral registration blob. It is
// a distinctive string so a leak into the agent log is unmistakable.
const fakeJITConfig = "eyJydW5uZXJ2bS10ZXN0LWppdC1zZWNyZXQtZG8tbm90LWxvZyI6dHJ1ZX0="

type fakeRunner struct {
	h        *harness
	envPath  string
	pidPath  string
	fifoPath string
	ready    <-chan error
}

// newFakeRunner prepares the environment the stand-in run.sh needs. The
// FIFO gives the test a rendezvous with the child instead of polling.
func newFakeRunner(t *testing.T, h *harness) *fakeRunner {
	t.Helper()
	f := &fakeRunner{
		h:        h,
		envPath:  filepath.Join(h.root, "child.env"),
		pidPath:  filepath.Join(h.root, "child.pid"),
		fifoPath: filepath.Join(h.root, "ready.fifo"),
	}
	if err := syscall.Mkfifo(f.fifoPath, 0o600); err != nil {
		t.Fatalf("mkfifo: %v", err)
	}
	f.ready = openForRead(f.fifoPath)

	// The stand-in script blocks in `sleep`; without this the test binary
	// would leave an orphaned process group behind on every run.
	t.Cleanup(func() {
		if pid := h.svc.runner.RunningPID(); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	return f
}

func (f *fakeRunner) env() map[string]string {
	return map[string]string{
		"RUNNERVM_TEST_ENV":  f.envPath,
		"RUNNERVM_TEST_PID":  f.pidPath,
		"RUNNERVM_TEST_FIFO": f.fifoPath,
	}
}

// start issues agent.startRunner and blocks until the child signals it is
// running.
func (f *fakeRunner) start(t *testing.T, sessionID string) StartRunnerResult {
	t.Helper()
	var res StartRunnerResult
	f.h.call(t, "agent.startRunner", map[string]any{
		"sessionId": sessionID,
		"jitConfig": fakeJITConfig,
		"env":       f.env(),
		"labels":    []string{"self-hosted", "linux"},
	}, &res)
	f.awaitReady(t)
	return res
}

func (f *fakeRunner) awaitReady(t *testing.T) {
	t.Helper()
	select {
	case err := <-f.ready:
		if err != nil {
			t.Fatalf("fake runner readiness: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for the fake runner to signal readiness")
	}
}

// openForRead opens a FIFO in the background; the open itself blocks until
// the writer appears, which is the synchronisation point.
func openForRead(path string) <-chan error {
	ch := make(chan error, 1)
	go func() {
		f, err := os.Open(path)
		if err != nil {
			ch <- err
			return
		}
		defer f.Close()
		buf := make([]byte, 16)
		_, err = f.Read(buf)
		ch <- err
	}()
	return ch
}

func TestStartRunnerPassesJITConfigThroughEnvAndNeverLogsIt(t *testing.T) {
	h := newHarness(t, nil)
	fake := newFakeRunner(t, h)

	res := fake.start(t, "sess-1")
	if res.PID <= 0 {
		t.Fatalf("pid = %d, want > 0", res.PID)
	}
	if _, err := time.Parse(time.RFC3339, res.StartedAt); err != nil {
		t.Fatalf("startedAt %q is not RFC 3339: %v", res.StartedAt, err)
	}

	childEnv := readFileString(t, fake.envPath)
	if !strings.Contains(childEnv, "ACTIONS_RUNNER_INPUT_JITCONFIG="+fakeJITConfig) {
		t.Fatal("the JIT config did not reach the child through the environment")
	}
	for _, want := range []string{"HOME=", "PATH=", "USER=", "TMPDIR=", "RUNNERVM_LABELS=self-hosted,linux"} {
		if !strings.Contains(childEnv, want) {
			t.Fatalf("child environment is missing %q:\n%s", want, childEnv)
		}
	}
	if strings.Contains(h.logs.String(), fakeJITConfig) {
		t.Fatal("the JIT config leaked into the agent log")
	}

	logPath := filepath.Join(h.runnerDir, "_diag", "runnervm-sess-1.log")
	info, err := os.Stat(logPath)
	if err != nil {
		t.Fatalf("session log %s: %v", logPath, err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("session log mode = %o, want 600", perm)
	}
}

func TestStartRunnerDuplicateSession(t *testing.T) {
	h := newHarness(t, nil)
	fake := newFakeRunner(t, h)
	fake.start(t, "sess-1")

	err := h.callErr(t, "agent.startRunner", map[string]any{
		"sessionId": "sess-1",
		"jitConfig": fakeJITConfig,
	})
	if err.Code != CodeAlreadyStarted {
		t.Fatalf("code = %q, want %s", err.Code, CodeAlreadyStarted)
	}
}

func TestStartRunnerSecondSessionIsBusy(t *testing.T) {
	h := newHarness(t, nil)
	fake := newFakeRunner(t, h)
	fake.start(t, "sess-1")

	err := h.callErr(t, "agent.startRunner", map[string]any{
		"sessionId": "sess-2",
		"jitConfig": fakeJITConfig,
	})
	if err.Code != "BUSY" {
		t.Fatalf("code = %q, want BUSY", err.Code)
	}
	if !err.Retryable {
		t.Fatal("BUSY must be marked retryable")
	}
}

// A session id becomes a filename, so traversal attempts are rejected
// before anything touches the filesystem.
func TestStartRunnerRejectsUnsafeSessionID(t *testing.T) {
	h := newHarness(t, nil)
	for _, id := range []string{"../escape", "a/b", "", strings.Repeat("x", 200)} {
		err := h.callErr(t, "agent.startRunner", map[string]any{
			"sessionId": id,
			"jitConfig": fakeJITConfig,
		})
		if err.Code != "INVALID_PARAMS" {
			t.Fatalf("sessionId %q: code = %q, want INVALID_PARAMS", id, err.Code)
		}
	}
}

func TestRunnerStatusLifecycle(t *testing.T) {
	h := newHarness(t, func(cfg *Config) { cfg.RunnerOnlineAfter = time.Millisecond })
	fake := newFakeRunner(t, h)
	started := fake.start(t, "sess-1")

	var unknown RunnerStatusResult
	h.call(t, "agent.runnerStatus", map[string]any{"sessionId": "other"}, &unknown)
	if unknown.State != "unknown" {
		t.Fatalf("state = %q, want unknown", unknown.State)
	}

	var online RunnerStatusResult
	h.call(t, "agent.runnerStatus", map[string]any{"sessionId": "sess-1"}, &online)
	if online.State != "online" {
		t.Fatalf("state = %q, want online", online.State)
	}
	if online.PID == nil || *online.PID != started.PID {
		t.Fatalf("pid = %v, want %d", online.PID, started.PID)
	}

	// A Worker_*.log newer than the session start is the fallback busy
	// signal for guests where the process listing is unavailable.
	writeFile(t, filepath.Join(h.runnerDir, "_diag", "Worker_20260825-120000-utc.log"), "job\n")
	var busy RunnerStatusResult
	h.call(t, "agent.runnerStatus", map[string]any{"sessionId": "sess-1"}, &busy)
	if busy.State != "busy" {
		t.Fatalf("state = %q, want busy", busy.State)
	}
}

func TestStopRunnerKillsTheProcessGroup(t *testing.T) {
	h := newHarness(t, nil)
	fake := newFakeRunner(t, h)
	started := fake.start(t, "sess-1")

	var stop StopRunnerResult
	h.call(t, "agent.stopRunner", map[string]any{"sessionId": "sess-1", "graceMs": 2000}, &stop)
	if !stop.Stopped {
		t.Fatal("stopped = false, want true")
	}

	// Stop returns once the leader is reaped and the rest of the group has
	// been signalled; the kernel delivers those signals asynchronously, so
	// the group's disappearance is awaited as a condition, not assumed.
	waitGroupGone(t, int(started.PID))

	var status RunnerStatusResult
	h.call(t, "agent.runnerStatus", map[string]any{"sessionId": "sess-1"}, &status)
	if status.State != "exited" {
		t.Fatalf("state = %q, want exited", status.State)
	}
	if status.ExitCode == nil {
		t.Fatal("exitCode must be reported for an exited session")
	}
	if status.ExitedAt == "" {
		t.Fatal("exitedAt must be reported for an exited session")
	}
}

// stopRunner is an idempotent mutation: an unknown session is a no-op, not
// an error, so a retrying host never sees a spurious failure.
func TestStopRunnerUnknownSession(t *testing.T) {
	h := newHarness(t, nil)
	var stop StopRunnerResult
	h.call(t, "agent.stopRunner", map[string]any{"sessionId": "nope"}, &stop)
	if stop.Stopped {
		t.Fatal("stopped = true for an unknown session")
	}
}

// waitGroupGone blocks until no process remains in pgid. It polls on a
// condition rather than sleeping a fixed interval, so it returns as soon as
// the kernel has reaped the group.
func waitGroupGone(t *testing.T, pgid int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if err := syscall.Kill(-pgid, 0); err == syscall.ESRCH {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("process group %d still exists after stopRunner", pgid)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func readFileString(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}
