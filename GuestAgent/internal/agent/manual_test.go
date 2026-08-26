package agent

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"

	"github.com/runnervm/guest-agent/internal/rpc"
)

// TestManual drives a guest-agent that is already running elsewhere, e.g.
//
//	go run ./cmd/guest-agent --listen tcp:127.0.0.1:4051 \
//	    --runner-dir /tmp/rvm-fake-runner --runner-user $(whoami)
//	RUNNERVM_MANUAL_ADDR=127.0.0.1:4051 go test ./internal/agent -run TestManual -v
//
// It is skipped unless RUNNERVM_MANUAL_ADDR is set, because it needs a live
// process rather than the in-process harness the other tests use.
func TestManual(t *testing.T) {
	addr := os.Getenv("RUNNERVM_MANUAL_ADDR")
	if addr == "" {
		t.Skip("set RUNNERVM_MANUAL_ADDR=host:port to drive a running guest-agent")
	}

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatalf("dial %s: %v", addr, err)
	}
	client := rpc.Dial(conn, Protocol)
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	for _, method := range []string{"agent.hello", "agent.health", "agent.getInfo", "agent.getMetrics"} {
		payload, err := client.Call(ctx, method, nil)
		if err != nil {
			t.Fatalf("%s: %v", method, err)
		}
		t.Logf("%s => %s", method, indent(payload))
	}

	manualMutations(ctx, t, client)

	chunks, err := client.Stream(ctx, "agent.exec", ExecRequest{
		Argv:           []string{"sh", "-c", "echo manual-exec-ok; uname -a"},
		TimeoutMs:      5000,
		MaxOutputBytes: 1 << 20,
	})
	if err != nil {
		t.Fatalf("agent.exec: %v", err)
	}
	for chunk := range chunks {
		if chunk.Err != nil {
			t.Fatalf("agent.exec transport: %v", chunk.Err)
		}
		t.Logf("agent.exec chunk seq=%v end=%v payload=%s error=%+v",
			deref(chunk.Envelope.StreamSeq), deref(chunk.Envelope.End),
			chunk.Envelope.Payload, chunk.Envelope.Error)
	}
}

// manualMutations exercises the state-changing half of the catalogue
// against a live agent. It deliberately omits agent.cleanup: that method
// deletes everything the runner account owns under /tmp and empties its
// home caches, which is correct inside a disposable guest and destructive
// anywhere else. Exercise cleanup only against a real guest, by hand.
func manualMutations(ctx context.Context, t *testing.T, client *rpc.Client) {
	t.Helper()
	if os.Getenv("RUNNERVM_MANUAL_MUTATE") == "" {
		t.Log("set RUNNERVM_MANUAL_MUTATE=1 to also exercise resizeDisk/startRunner/stopRunner")
		return
	}

	sessionID := "manual-" + time.Now().UTC().Format("20060102T150405Z")
	calls := []struct {
		method  string
		payload any
	}{
		{"agent.resizeDisk", nil},
		{"agent.startRunner", map[string]any{
			"sessionId": sessionID,
			"jitConfig": "bWFudWFsLXBsYWNlaG9sZGVyLWppdC1jb25maWc=",
		}},
		{"agent.runnerStatus", RunnerStatusRequest{SessionID: sessionID}},
		{"agent.stopRunner", StopRunnerRequest{SessionID: sessionID, GraceMs: 2000}},
		{"agent.runnerStatus", RunnerStatusRequest{SessionID: sessionID}},
	}
	for _, c := range calls {
		payload, err := client.Call(ctx, c.method, c.payload)
		if err != nil {
			t.Logf("%s => error %v", c.method, err)
			continue
		}
		t.Logf("%s => %s", c.method, indent(payload))
	}
}

func indent(raw json.RawMessage) string {
	var out []byte
	var buf json.RawMessage = raw
	if b, err := json.MarshalIndent(json.RawMessage(buf), "", "  "); err == nil {
		out = b
	} else {
		out = raw
	}
	return string(out)
}

func deref[T any](p *T) any {
	if p == nil {
		return nil
	}
	return *p
}
