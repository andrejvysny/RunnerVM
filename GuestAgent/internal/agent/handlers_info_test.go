package agent

import (
	"encoding/json"
	"path/filepath"
	"runtime"
	"slices"
	"testing"
	"time"
)

func TestHello(t *testing.T) {
	h := newHarness(t, nil)

	var got HelloResult
	h.call(t, "agent.hello", nil, &got)

	if got.ProtocolVersion != 1 {
		t.Fatalf("protocolVersion = %d, want 1", got.ProtocolVersion)
	}
	if got.AgentVersion != "test" {
		t.Fatalf("agentVersion = %q, want test", got.AgentVersion)
	}
	if got.OS != runtime.GOOS || got.Arch != runtime.GOARCH {
		t.Fatalf("os/arch = %s/%s, want %s/%s", got.OS, got.Arch, runtime.GOOS, runtime.GOARCH)
	}
	if got.Hostname == "" {
		t.Fatal("hostname is empty")
	}
	if got.BootID == "" {
		t.Fatal("bootId is empty")
	}
	for _, want := range []string{"exec", "metrics", "runner", "resizeDisk", "cleanup", "shutdown"} {
		if !slices.Contains(got.Capabilities, want) {
			t.Fatalf("capabilities %v missing %q", got.Capabilities, want)
		}
	}
}

func TestHealthReady(t *testing.T) {
	h := newHarness(t, nil)

	var got HealthResult
	h.call(t, "agent.health", nil, &got)

	if got.State != HealthReady {
		t.Fatalf("state = %q (reasons %v), want ready", got.State, got.Reasons)
	}
	if got.Reasons == nil {
		t.Fatal("reasons must be [] rather than null")
	}
}

// A guest whose runner is not installed yet must report "starting" during
// the boot grace window, with an actionable reason, not "ready".
func TestHealthStartingWhenRunnerMissing(t *testing.T) {
	h := newHarness(t, func(cfg *Config) {
		cfg.RunnerDir = filepath.Join(t.TempDir(), "not-installed")
	})

	var got HealthResult
	h.call(t, "agent.health", nil, &got)

	if got.State != HealthStarting {
		t.Fatalf("state = %q, want starting", got.State)
	}
	if len(got.Reasons) == 0 {
		t.Fatal("expected at least one reason")
	}
}

func TestGetInfo(t *testing.T) {
	h := newHarness(t, nil)

	var got InfoResult
	h.call(t, "agent.getInfo", nil, &got)

	if got.IPAddresses == nil {
		t.Fatal("ipAddresses must be [] rather than null")
	}
	if got.UptimeSec <= 0 {
		t.Fatalf("uptimeSec = %d, want > 0", got.UptimeSec)
	}
	if got.Kernel == "" {
		t.Fatal("kernel is empty")
	}
}

// getInfo must surface the runner version from the plain-text marker the
// actions-runner package ships, without paying a .NET start-up.
func TestGetInfoRunnerVersion(t *testing.T) {
	h := newHarness(t, nil)
	writeFile(t, filepath.Join(h.runnerDir, "bin", "runnerversion"), "2.319.1\n")

	var got InfoResult
	h.call(t, "agent.getInfo", nil, &got)
	if got.RunnerVersion != "2.319.1" {
		t.Fatalf("runnerVersion = %q, want 2.319.1", got.RunnerVersion)
	}
}

// The host decodes counts as Int64, so every count in the metrics payload
// must serialise as a JSON integer, never as 1.2e+09.
func TestGetMetricsShape(t *testing.T) {
	h := newHarness(t, nil)

	var raw map[string]json.RawMessage
	h.call(t, "agent.getMetrics", nil, &raw)

	ts := decodeString(t, raw, "timestamp")
	if _, err := time.Parse(time.RFC3339, ts); err != nil {
		t.Fatalf("timestamp %q is not RFC 3339: %v", ts, err)
	}
	if ts[len(ts)-1] != 'Z' {
		t.Fatalf("timestamp %q must be UTC with a Z suffix", ts)
	}
	assertInteger(t, raw, "uptimeSec")

	for section, intFields := range map[string][]string{
		"cpu":    {"logicalCount"},
		"memory": {"totalBytes", "usedBytes", "availableBytes"},
		"disk":   {"rootTotalBytes", "rootUsedBytes", "rootAvailableBytes"},
		"runner": {"pid", "rssBytes"},
	} {
		var sub map[string]json.RawMessage
		if err := json.Unmarshal(raw[section], &sub); err != nil {
			t.Fatalf("decode %s: %v", section, err)
		}
		for _, field := range intFields {
			assertInteger(t, sub, field)
		}
	}

	var cpu CPUProbe
	if err := json.Unmarshal(raw["cpu"], &cpu); err != nil {
		t.Fatalf("decode cpu: %v", err)
	}
	if cpu.LogicalCount <= 0 {
		t.Fatalf("cpu.logicalCount = %d, want > 0", cpu.LogicalCount)
	}
	if cpu.UsagePercent < 0 || cpu.UsagePercent > 100 {
		t.Fatalf("cpu.usagePercent = %v, want 0..100", cpu.UsagePercent)
	}

	var mem struct {
		TotalBytes int64 `json:"totalBytes"`
	}
	if err := json.Unmarshal(raw["memory"], &mem); err != nil {
		t.Fatalf("decode memory: %v", err)
	}
	if mem.TotalBytes <= 0 {
		t.Fatalf("memory.totalBytes = %d, want > 0", mem.TotalBytes)
	}
}

// CPUProbe mirrors the cpu section for assertions.
type CPUProbe struct {
	LogicalCount int64   `json:"logicalCount"`
	UsagePercent float64 `json:"usagePercent"`
	Load1        float64 `json:"load1"`
	Load5        float64 `json:"load5"`
	Load15       float64 `json:"load15"`
}

func TestUnknownMethodIsRejected(t *testing.T) {
	h := newHarness(t, nil)
	if code := h.callErr(t, "agent.nope", nil).Code; code != "UNKNOWN_METHOD" {
		t.Fatalf("code = %q, want UNKNOWN_METHOD", code)
	}
}

// Strict payload decoding catches host/guest field drift on the first call
// instead of silently ignoring a misspelled field.
func TestUnknownPayloadFieldIsRejected(t *testing.T) {
	h := newHarness(t, nil)
	err := h.callErr(t, "agent.runnerStatus", map[string]any{"session": "s1"})
	if err.Code != "INVALID_PARAMS" {
		t.Fatalf("code = %q, want INVALID_PARAMS", err.Code)
	}
}
