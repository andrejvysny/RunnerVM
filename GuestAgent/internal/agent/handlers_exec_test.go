package agent

import (
	"strings"
	"testing"
)

func TestExecStreamsStdoutAndExitCode(t *testing.T) {
	h := newHarness(t, nil)

	got := h.stream(t, "agent.exec", map[string]any{
		"argv":           []string{"echo", "hi"},
		"timeoutMs":      5000,
		"maxOutputBytes": 1 << 20,
	})
	if got.err != nil {
		t.Fatalf("terminal error: %+v", got.err)
	}
	if string(got.stdout) != "hi\n" {
		t.Fatalf("stdout = %q, want %q", got.stdout, "hi\n")
	}
	if got.exitCode == nil || *got.exitCode != 0 {
		t.Fatalf("exitCode = %v, want 0", got.exitCode)
	}
}

func TestExecSeparatesStderrAndReportsNonZeroExit(t *testing.T) {
	h := newHarness(t, nil)

	got := h.stream(t, "agent.exec", map[string]any{
		"argv":      []string{"sh", "-c", "echo out; echo err >&2; exit 7"},
		"timeoutMs": 5000,
	})
	if got.err != nil {
		t.Fatalf("terminal error: %+v", got.err)
	}
	if string(got.stdout) != "out\n" {
		t.Fatalf("stdout = %q", got.stdout)
	}
	if string(got.stderr) != "err\n" {
		t.Fatalf("stderr = %q", got.stderr)
	}
	// A non-zero exit is a result, not a protocol error.
	if got.exitCode == nil || *got.exitCode != 7 {
		t.Fatalf("exitCode = %v, want 7", got.exitCode)
	}
}

func TestExecHonoursCwdAndEnv(t *testing.T) {
	h := newHarness(t, nil)

	got := h.stream(t, "agent.exec", map[string]any{
		"argv":      []string{"sh", "-c", "pwd; echo $RUNNERVM_MARKER"},
		"cwd":       h.stateDir,
		"env":       map[string]string{"RUNNERVM_MARKER": "marker-value"},
		"timeoutMs": 5000,
	})
	if got.err != nil {
		t.Fatalf("terminal error: %+v", got.err)
	}
	out := string(got.stdout)
	if !strings.Contains(out, "marker-value") {
		t.Fatalf("env did not reach the child: %q", out)
	}
	if !strings.Contains(out, "state") {
		t.Fatalf("cwd was not honoured: %q", out)
	}
}

func TestExecTimeoutKillsTheCommand(t *testing.T) {
	h := newHarness(t, nil)

	got := h.stream(t, "agent.exec", map[string]any{
		"argv":      []string{"sleep", "5"},
		"timeoutMs": 200,
	})
	if got.err == nil {
		t.Fatal("expected a terminal error")
	}
	if got.err.Code != "DEADLINE" {
		t.Fatalf("code = %q, want DEADLINE", got.err.Code)
	}
	if got.exitCode != nil {
		t.Fatalf("a timed-out exec must not report an exit code, got %d", *got.exitCode)
	}
}

func TestExecOutputCapTerminatesTheStream(t *testing.T) {
	h := newHarness(t, nil)

	got := h.stream(t, "agent.exec", map[string]any{
		"argv":           []string{"yes"},
		"timeoutMs":      20000,
		"maxOutputBytes": 1024,
	})
	if got.err == nil {
		t.Fatal("expected a terminal error")
	}
	if got.err.Code != CodeOutputLimit {
		t.Fatalf("code = %q, want %s", got.err.Code, CodeOutputLimit)
	}
	if len(got.stdout) > 1024 {
		t.Fatalf("streamed %d bytes, want at most 1024", len(got.stdout))
	}
}

func TestExecRejectsEmptyArgv(t *testing.T) {
	h := newHarness(t, nil)

	got := h.stream(t, "agent.exec", map[string]any{"argv": []string{}, "timeoutMs": 1000})
	if got.err == nil || got.err.Code != "INVALID_PARAMS" {
		t.Fatalf("terminal error = %+v, want INVALID_PARAMS", got.err)
	}
}
