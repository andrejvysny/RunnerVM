package runner

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/runnervm/guest-agent/internal/keychain"
)

// stubKeychain stands in for the macOS preparer so the ordering and
// lifetime rules are exercised identically on a Linux CI runner and on a
// developer's Mac, without either one owning a real keychain.
type stubKeychain struct {
	env map[string]string
	err error

	mu       sync.Mutex
	prepared int
	closed   int
}

func (s *stubKeychain) Prepare(context.Context, string) (keychain.Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err != nil {
		return nil, s.err
	}
	s.prepared++
	return &stubSession{owner: s}, nil
}

func (s *stubKeychain) counts() (prepared, closed int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.prepared, s.closed
}

type stubSession struct{ owner *stubKeychain }

func (s *stubSession) Env() map[string]string { return s.owner.env }

func (s *stubSession) Close() error {
	s.owner.mu.Lock()
	defer s.owner.mu.Unlock()
	s.owner.closed++
	return nil
}

func stubEnv() map[string]string {
	return map[string]string{
		keychain.EnvKeychainPath:     "/keychains/runnervm-ci.keychain-db",
		keychain.EnvKeychainPassword: "s3cret",
	}
}

// newTestManager builds a Manager over a stand-in run.sh. The account is
// the one the test binary already runs as, so no identity switch is
// attempted and nothing is chowned.
func newTestManager(t *testing.T, script string, kc keychain.Preparer) *Manager {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "run.sh"), []byte(script), 0o755); err != nil {
		t.Fatalf("write run.sh: %v", err)
	}
	u, err := user.Current()
	if err != nil {
		t.Fatalf("user.Current: %v", err)
	}
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	m, err := New(Config{
		Dir:              dir,
		Account:          Account{Name: u.Username, UID: uid, GID: gid, Home: t.TempDir()},
		OnlineAfter:      time.Millisecond,
		KeychainPreparer: kc,
		Logger:           slog.New(slog.DiscardHandler),
	})
	if err != nil {
		t.Fatalf("runner.New: %v", err)
	}
	t.Cleanup(func() {
		if pid := m.RunningPID(); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	return m
}

func envMap(t *testing.T, env []string) map[string]string {
	t.Helper()
	out := make(map[string]string, len(env))
	for _, entry := range env {
		k, v, ok := strings.Cut(entry, "=")
		if !ok {
			t.Fatalf("malformed env entry %q", entry)
		}
		if _, dup := out[k]; dup {
			t.Fatalf("duplicate env key %q in %v", k, env)
		}
		out[k] = v
	}
	return out
}

func TestChildEnvKeepsTheKeychainOutOfTheCallersReach(t *testing.T) {
	m := newTestManager(t, "#!/bin/sh\nexit 0\n", nil)
	sess := &stubSession{owner: &stubKeychain{env: stubEnv()}}

	env := m.childEnv(StartRequest{
		SessionID: "sess-1",
		JITConfig: []byte("jit-secret"),
		Env: map[string]string{
			// Every one of these is an attempt to point the runner at a
			// keychain (or a credential) the agent did not create.
			keychain.EnvKeychainPath:     "/tmp/evil.keychain-db",
			keychain.EnvKeychainPassword: "evil",
			"RUNNERVM_CI_KEYCHAIN_EXTRA": "evil",
			jitConfigEnvVar:              "evil",
			"FOO":                        "bar",
		},
	}, sess)

	// The JIT config is appended after the sorted block, so nothing the
	// caller sends can shadow it.
	if last, want := env[len(env)-1], jitConfigEnvVar+"=jit-secret"; last != want {
		t.Fatalf("last env entry = %q, want %q", last, want)
	}
	got := envMap(t, env)
	if got[keychain.EnvKeychainPath] != stubEnv()[keychain.EnvKeychainPath] {
		t.Fatalf("%s = %q, want the agent's keychain", keychain.EnvKeychainPath, got[keychain.EnvKeychainPath])
	}
	if got[keychain.EnvKeychainPassword] != "s3cret" {
		t.Fatalf("%s = %q, want the agent's password", keychain.EnvKeychainPassword, got[keychain.EnvKeychainPassword])
	}
	if _, present := got["RUNNERVM_CI_KEYCHAIN_EXTRA"]; present {
		t.Fatal("a caller key in the reserved RUNNERVM_CI_KEYCHAIN namespace survived")
	}
	if got["FOO"] != "bar" {
		t.Fatal("an ordinary caller env entry was dropped")
	}
	for _, want := range []string{"HOME", "PATH", "USER", "TMPDIR", "RUNNERVM_SESSION"} {
		if _, ok := got[want]; !ok {
			t.Fatalf("child environment is missing %q", want)
		}
	}
}

// Without a preparer the environment must be byte-identical to what the
// agent produced before the CI keychain existed.
func TestChildEnvWithoutAKeychain(t *testing.T) {
	m := newTestManager(t, "#!/bin/sh\nexit 0\n", nil)
	for _, entry := range m.childEnv(StartRequest{SessionID: "sess-1", JITConfig: []byte("jit")}, nil) {
		if strings.HasPrefix(entry, keychain.EnvPrefix) {
			t.Fatalf("unexpected keychain entry %q", entry)
		}
	}
}

func TestStartDeletesTheKeychainWhenTheRunnerExits(t *testing.T) {
	kc := &stubKeychain{env: stubEnv()}
	m := newTestManager(t, "#!/bin/sh\nexit 0\n", kc)

	if _, err := m.Start(context.Background(), StartRequest{SessionID: "sess-1", JITConfig: []byte("jit")}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if prepared, _ := kc.counts(); prepared != 1 {
		t.Fatalf("prepared %d keychains, want 1", prepared)
	}

	waitUntil(t, "the keychain to be deleted after the runner exits", func() bool {
		_, closed := kc.counts()
		return closed == 1
	})
	if m.Status("sess-1").State != StateExited {
		t.Fatalf("state = %q, want exited", m.Status("sess-1").State)
	}
}

func TestStartFailsClosedWhenTheKeychainCannotBeBuilt(t *testing.T) {
	kc := &stubKeychain{err: errors.New("securityd is not answering")}
	m := newTestManager(t, "#!/bin/sh\nexit 0\n", kc)

	_, err := m.Start(context.Background(), StartRequest{SessionID: "sess-1", JITConfig: []byte("jit")})
	if err == nil {
		t.Fatal("Start succeeded without a keychain")
	}
	if !errors.Is(err, ErrKeychainUnavailable) {
		t.Fatalf("error %v is not ErrKeychainUnavailable", err)
	}
	if !strings.Contains(err.Error(), "securityd is not answering") {
		t.Fatalf("error %v drops the cause", err)
	}
	if pid := m.RunningPID(); pid != 0 {
		t.Fatalf("a runner was started anyway (pid %d)", pid)
	}
	// The session log is the first thing spawn creates; its absence proves
	// nothing was attempted after the keychain failed.
	if _, err := os.Stat(filepath.Join(m.cfg.Dir, "_diag", "runnervm-sess-1.log")); !os.IsNotExist(err) {
		t.Fatal("spawn ran despite the keychain failure")
	}
	// A failed start is not a started session: the id stays usable.
	if m.Status("sess-1").State != StateUnknown {
		t.Fatalf("state = %q, want unknown", m.Status("sess-1").State)
	}
}

func TestStopDeletesTheKeychainExactlyOnce(t *testing.T) {
	kc := &stubKeychain{env: stubEnv()}
	m := newTestManager(t, "#!/bin/sh\nsleep 30\n", kc)

	if _, err := m.Start(context.Background(), StartRequest{SessionID: "sess-1", JITConfig: []byte("jit")}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	stopped, err := m.Stop(context.Background(), "sess-1", 2*time.Second)
	if err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if !stopped {
		t.Fatal("stopped = false")
	}
	// Both the stop path and the exit path close the session; the keychain
	// must be deleted once, not twice, or a later session's keychain could
	// be removed underneath it.
	if _, closed := kc.counts(); closed != 1 {
		t.Fatalf("keychain closed %d times, want exactly 1", closed)
	}
}

// waitUntil polls a condition rather than sleeping a fixed interval.
func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}
