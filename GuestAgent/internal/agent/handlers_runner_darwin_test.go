//go:build darwin

package agent

import (
	"os"
	"strings"
	"testing"

	"github.com/runnervm/guest-agent/internal/keychain"
)

// parseEnvFile turns the env dump the stand-in run.sh wrote into a map.
func parseEnvFile(t *testing.T, path string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, line := range strings.Split(readFileString(t, path), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			out[k] = v
		}
	}
	return out
}

func countCalls(transcript, prefix string) int {
	var n int
	for _, line := range strings.Split(transcript, "\n") {
		if strings.HasPrefix(line, prefix) {
			n++
		}
	}
	return n
}

func TestStartRunnerHandsTheRunnerAFreshCIKeychain(t *testing.T) {
	h := newHarness(t, nil)
	fake := newFakeRunner(t, h)
	fake.start(t, "sess-1")

	childEnv := parseEnvFile(t, fake.envPath)
	path := childEnv[keychain.EnvKeychainPath]
	password := childEnv[keychain.EnvKeychainPassword]
	if path == "" || password == "" {
		t.Fatalf("the runner did not receive a CI keychain: %v", childEnv)
	}
	if !strings.HasSuffix(path, "/Library/Keychains/runnervm-ci.keychain-db") {
		t.Fatalf("keychain path = %q", path)
	}

	tools := readFileString(t, h.toolLog)
	for _, want := range []string{
		"security create-keychain",
		"security set-keychain-settings",
		"security unlock-keychain",
		"security list-keychains -d user -s " + path,
		"security default-keychain -d user -s " + path,
		"security show-keychain-info " + path,
	} {
		if !strings.Contains(tools, want) {
			t.Fatalf("keychain setup is missing %q:\n%s", want, tools)
		}
	}

	// The password is on the tools' argv by necessity; it must never be on
	// a log line, and neither must the argv that carries it.
	logs := h.logs.String()
	if strings.Contains(logs, password) {
		t.Fatal("the keychain password leaked into the agent log")
	}
	if strings.Contains(logs, "-p ") || strings.Contains(logs, "create-keychain -p") {
		t.Fatalf("keychain argv reached the agent log:\n%s", logs)
	}

	// Stopping the runner takes the keychain with it.
	var stop StopRunnerResult
	h.call(t, "agent.stopRunner", map[string]any{"sessionId": "sess-1", "graceMs": 2000}, &stop)
	if !stop.Stopped {
		t.Fatal("stopped = false")
	}
	tools = readFileString(t, h.toolLog)
	// Twice: the stale-file sweep before create, and the teardown.
	if n := countCalls(tools, "security delete-keychain "+path); n != 2 {
		t.Fatalf("delete-keychain ran %d times, want 2:\n%s", n, tools)
	}
}

// Fail-closed: no keychain, no runner.
func TestStartRunnerFailsWithKeychainUnavailable(t *testing.T) {
	h := newHarness(t, nil)
	failTool(t, h.root, "create-keychain")

	err := h.callErr(t, "agent.startRunner", map[string]any{
		"sessionId": "sess-1",
		"jitConfig": fakeJITConfig,
	})
	if err.Code != CodeKeychainUnavailable {
		t.Fatalf("code = %q, want %s", err.Code, CodeKeychainUnavailable)
	}
	if err.Retryable {
		t.Fatal("a broken keychain is not worth retrying on the same guest")
	}
	if pid := h.svc.runner.RunningPID(); pid != 0 {
		t.Fatalf("a runner was started anyway (pid %d)", pid)
	}
}

// host-safe-mode means the agent could not confirm it is a disposable
// guest. Rewriting the keychain search list there would wreck a
// developer's login keychain, so no keychain is prepared at all.
func TestHostSafeModeSkipsTheCIKeychain(t *testing.T) {
	h := newHarness(t, func(cfg *Config) {
		cfg.VMDetector = func() (bool, string) { return false, "test: pretending to be bare metal" }
	})
	fake := newFakeRunner(t, h)
	fake.start(t, "sess-1")

	childEnv := parseEnvFile(t, fake.envPath)
	if _, ok := childEnv[keychain.EnvKeychainPath]; ok {
		t.Fatal("a keychain was prepared in host-safe-mode")
	}
	// No transcript at all: not one keychain tool was invoked.
	if _, err := os.Stat(h.toolLog); !os.IsNotExist(err) {
		t.Fatalf("keychain tooling ran in host-safe-mode:\n%s", readFileString(t, h.toolLog))
	}
}
