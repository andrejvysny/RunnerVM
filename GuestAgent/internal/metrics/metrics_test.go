package metrics

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestCollectPopulatesEverySection(t *testing.T) {
	snap := Collect(context.Background(), Options{
		RootPath:  t.TempDir(),
		RunnerPID: os.Getpid(),
		Window:    20 * time.Millisecond,
	})

	if _, err := time.Parse(time.RFC3339, snap.Timestamp); err != nil {
		t.Fatalf("timestamp %q: %v", snap.Timestamp, err)
	}
	if !strings.HasSuffix(snap.Timestamp, "Z") {
		t.Fatalf("timestamp %q must be UTC", snap.Timestamp)
	}
	if snap.UptimeSec <= 0 {
		t.Fatalf("uptimeSec = %d", snap.UptimeSec)
	}
	if snap.CPU.LogicalCount <= 0 {
		t.Fatalf("cpu.logicalCount = %d", snap.CPU.LogicalCount)
	}
	if snap.Memory.TotalBytes <= 0 || snap.Disk.RootTotalBytes <= 0 {
		t.Fatalf("memory/disk not populated: %+v %+v", snap.Memory, snap.Disk)
	}
	if !snap.Runner.ProcessRunning || snap.Runner.PID != int64(os.Getpid()) {
		t.Fatalf("runner section = %+v", snap.Runner)
	}
	if snap.Runner.RSSBytes <= 0 {
		t.Fatalf("runner.rssBytes = %d, want > 0 for a live process", snap.Runner.RSSBytes)
	}
	if len(snap.Warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", snap.Warnings)
	}
}

// With no runner running the section must still be present and zeroed, so
// the host never has to handle a missing key.
func TestCollectWithoutRunner(t *testing.T) {
	snap := Collect(context.Background(), Options{Window: time.Millisecond})
	if snap.Runner.ProcessRunning || snap.Runner.PID != 0 ||
		snap.Runner.CPUPercent != 0 || snap.Runner.RSSBytes != 0 {
		t.Fatalf("runner section = %+v, want zeroed", snap.Runner)
	}

	b, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// warnings is the only omitempty field in the snapshot; everything
	// else is part of the contract on every call.
	for _, key := range []string{`"timestamp"`, `"uptimeSec"`, `"cpu"`, `"memory"`, `"disk"`, `"runner"`} {
		if !strings.Contains(string(b), key) {
			t.Fatalf("payload %s is missing %s", b, key)
		}
	}
}

// A cancelled context must not hang the collector on its sampling window.
func TestCollectHonoursCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	done := make(chan Snapshot, 1)
	go func() { done <- Collect(ctx, Options{Window: 10 * time.Second}) }()
	select {
	case snap := <-done:
		if snap.CPU.UsagePercent != 0 {
			t.Fatalf("cancelled sample reported %v%%", snap.CPU.UsagePercent)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Collect ignored a cancelled context")
	}
}
