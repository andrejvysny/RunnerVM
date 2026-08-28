package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/runnervm/guest-agent/internal/keychain"
	"github.com/runnervm/guest-agent/internal/rpc"
	"github.com/runnervm/guest-agent/internal/vsock"
)

// harness runs a Service behind the real framing server over a loopback TCP
// listener. AF_VSOCK cannot be opened outside a guest, and the transport is
// irrelevant to the method catalogue, so the tests exercise the same
// rpc.Server/rpc.Client pair the host will use.
type harness struct {
	svc        *Service
	client     *rpc.Client
	cfg        Config
	runnerDir  string
	stateDir   string
	root       string
	logs       *syncBuffer
	poweredOff chan struct{}
	// toolLog collects the argv of every stubbed macOS keychain tool call.
	toolLog string
}

func newHarness(t *testing.T, mutate func(*Config)) *harness {
	t.Helper()

	root := t.TempDir()
	runnerDir := filepath.Join(root, "actions-runner")
	stateDir := filepath.Join(root, "state")
	for _, d := range []string{runnerDir, stateDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}
	writeRunScript(t, runnerDir, defaultRunScript)

	logs := &syncBuffer{}
	poweredOff := make(chan struct{})
	var once sync.Once
	toolLog := filepath.Join(root, "keychain-tools.log")

	cfg := Config{
		Version:    "test",
		RunnerDir:  runnerDir,
		RunnerUser: currentUsername(t),
		StateDir:   stateDir,
		RootPath:   root,
		// Empty (not nil) keeps the cleaner away from the real /tmp, and a
		// sandbox home keeps it away from the developer's ~/.cache.
		CleanupTempDirs: []string{},
		CleanupHome:     filepath.Join(root, "runner-home"),
		MetricsWindow:   20 * time.Millisecond,
		ShutdownDelay:   time.Millisecond,
		// The suite runs on developer Macs and CI runners, neither of which
		// this test package is allowed to assume is a VM. Default to "yes,
		// this is a VM" so cleanup/resizeDisk/shutdown tests exercise their
		// real behaviour; tests of host-safe-mode itself override this.
		VMDetector: func() (bool, string) { return true, "test-harness" },
		PowerOff: func(context.Context) error {
			once.Do(func() { close(poweredOff) })
			return nil
		},
		// The macOS keychain tooling is stubbed for the whole suite. The
		// real /usr/bin/security would run against the account the test
		// binary belongs to, and `list-keychains -s` / `default-keychain -s`
		// rewrite that account's login keychain search list -- not a thing a
		// unit test may do to the machine it runs on.
		SecurityPath: writeToolStub(t, root, "security", toolLog),
		OpenSSLPath:  writeToolStub(t, root, "openssl", toolLog),
		CodesignPath: writeToolStub(t, root, "codesign", toolLog),
		Logger:       slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
	}
	if mutate != nil {
		mutate(&cfg)
	}

	svc, err := New(cfg)
	if err != nil {
		t.Fatalf("agent.New: %v", err)
	}
	srv := rpc.NewServer(Protocol, rpc.Limits{MaxStreamBytes: 64 << 20})
	svc.Register(srv)

	ln, err := vsock.ListenTCPForTests("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = srv.Serve(ctx, ln)
	}()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		cancel()
		t.Fatalf("dial: %v", err)
	}
	client := rpc.Dial(conn, Protocol)

	t.Cleanup(func() {
		_ = client.Close()
		cancel()
		<-served
	})

	return &harness{
		svc: svc, client: client, cfg: cfg,
		runnerDir: runnerDir, stateDir: stateDir, root: root,
		logs: logs, poweredOff: poweredOff, toolLog: toolLog,
	}
}

// writeToolStub creates an inert stand-in for one macOS keychain tool. It
// appends its argv to logPath and exits 0, unless a marker file named
// fail-<tool> or fail-<subcommand> exists next to it, which makes it exit 1.
func writeToolStub(t *testing.T, dir, name, logPath string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	script := "#!/bin/sh\n" +
		"printf '" + name + " %s\\n' \"$*\" >> '" + logPath + "'\n" +
		"if [ -f '" + filepath.Join(dir, "fail-"+name) + "' ]; then exit 1; fi\n" +
		"if [ -f '" + filepath.Join(dir, "fail-") + "'\"$1\" ]; then exit 1; fi\n" +
		"exit 0\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write %s stub: %v", name, err)
	}
	return path
}

// keychainTestConfig is a keychain.Config that names no real tool, for the
// platform tests that only care whether a preparer is built at all.
func keychainTestConfig() keychain.Config {
	return keychain.Config{RunnerHome: "/nonexistent", SecurityPath: "/nonexistent"}
}

// failTool makes the named stub (or, with a subcommand, that one call) exit
// non-zero on its next invocation.
func failTool(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "fail-"+name), nil, 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
}

// call issues a unary request and decodes the response payload into dst.
func (h *harness) call(t *testing.T, method string, payload any, dst any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	raw, err := h.client.Call(ctx, method, payload)
	if err != nil {
		t.Fatalf("%s: %v", method, err)
	}
	if dst == nil {
		return
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		t.Fatalf("%s: decode payload %s: %v", method, raw, err)
	}
}

// callErr issues a unary request expecting a protocol error, and returns it.
func (h *harness) callErr(t *testing.T, method string, payload any) *rpc.RPCError {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	raw, err := h.client.Call(ctx, method, payload)
	if err == nil {
		t.Fatalf("%s: expected an error, got payload %s", method, raw)
	}
	var rpcErr *rpc.RPCError
	if !errors.As(err, &rpcErr) {
		t.Fatalf("%s: expected *rpc.RPCError, got %T: %v", method, err, err)
	}
	return rpcErr
}

// streamResult is one collected agent.exec stream.
type streamResult struct {
	stdout   []byte
	stderr   []byte
	exitCode *int64
	err      *rpc.ErrorPayload
}

// stream runs a streaming method to completion, collecting chunk payloads.
func (h *harness) stream(t *testing.T, method string, payload any) streamResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	chunks, err := h.client.Stream(ctx, method, payload)
	if err != nil {
		t.Fatalf("%s: %v", method, err)
	}

	var out streamResult
	for chunk := range chunks {
		if chunk.Err != nil {
			t.Fatalf("%s: transport error: %v", method, chunk.Err)
		}
		env := chunk.Envelope
		if env.Error != nil {
			out.err = env.Error
		}
		if len(env.Payload) == 0 {
			continue
		}
		var probe struct {
			Stream   string `json:"stream"`
			Data     []byte `json:"data"`
			ExitCode *int64 `json:"exitCode"`
		}
		if err := json.Unmarshal(env.Payload, &probe); err != nil {
			t.Fatalf("%s: decode chunk %s: %v", method, env.Payload, err)
		}
		switch {
		case probe.ExitCode != nil:
			out.exitCode = probe.ExitCode
		case probe.Stream == "stdout":
			out.stdout = append(out.stdout, probe.Data...)
		case probe.Stream == "stderr":
			out.stderr = append(out.stderr, probe.Data...)
		}
	}
	return out
}

func currentUsername(t *testing.T) string {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatalf("user.Current: %v", err)
	}
	return u.Username
}

// defaultRunScript is a stand-in for the actions runner's run.sh: it records
// its environment, signals readiness through a FIFO, then blocks so the
// session stays alive until the test stops it.
const defaultRunScript = `#!/bin/sh
env > "$RUNNERVM_TEST_ENV"
echo "$$" > "$RUNNERVM_TEST_PID"
echo ready > "$RUNNERVM_TEST_FIFO"
sleep 300
`

func writeRunScript(t *testing.T, dir, body string) {
	t.Helper()
	path := filepath.Join(dir, "run.sh")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write run.sh: %v", err)
	}
}

// syncBuffer collects agent log output for assertions that a secret never
// reaches the log.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}
