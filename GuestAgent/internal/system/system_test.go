package system

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestIdentityFacts(t *testing.T) {
	if Hostname() == "" {
		t.Fatal("Hostname returned an empty string")
	}
	if id, err := BootID(); err != nil || id == "" {
		t.Fatalf("BootID = %q, %v", id, err)
	}
	if k, err := KernelVersion(); err != nil || k == "" {
		t.Fatalf("KernelVersion = %q, %v", k, err)
	}
	up, err := UptimeSeconds()
	if err != nil || up <= 0 {
		t.Fatalf("UptimeSeconds = %d, %v", up, err)
	}
}

func TestDiskUsage(t *testing.T) {
	u, err := DiskUsage(t.TempDir())
	if err != nil {
		t.Fatalf("DiskUsage: %v", err)
	}
	if u.TotalBytes <= 0 || u.AvailableBytes < 0 || u.UsedBytes < 0 {
		t.Fatalf("implausible usage: %+v", u)
	}
	if u.UsedBytes > u.TotalBytes {
		t.Fatalf("used %d exceeds total %d", u.UsedBytes, u.TotalBytes)
	}
}

func TestMemoryUsage(t *testing.T) {
	m, err := MemoryUsage()
	if err != nil {
		t.Fatalf("MemoryUsage: %v", err)
	}
	if m.TotalBytes <= 0 {
		t.Fatalf("total = %d, want > 0", m.TotalBytes)
	}
	if m.UsedBytes+m.AvailableBytes != m.TotalBytes {
		t.Fatalf("used %d + available %d != total %d", m.UsedBytes, m.AvailableBytes, m.TotalBytes)
	}
}

func TestLoadAverageIsPlausible(t *testing.T) {
	l1, l5, l15, err := LoadAverage()
	if err != nil {
		t.Fatalf("LoadAverage: %v", err)
	}
	for i, v := range []float64{l1, l5, l15} {
		if v < 0 || v > 10000 {
			t.Fatalf("load[%d] = %v is implausible", i, v)
		}
	}
}

func TestSampleCPUPercentIsBounded(t *testing.T) {
	got := SampleCPUPercent(context.Background(), 20*time.Millisecond)
	if got < 0 || got > 100 {
		t.Fatalf("SampleCPUPercent = %v, want 0..100", got)
	}
}

func TestSampleProcessFindsThisProcess(t *testing.T) {
	cpu, rss := SampleProcess(context.Background(), os.Getpid(), 20*time.Millisecond)
	if cpu < 0 {
		t.Fatalf("cpuPercent = %v", cpu)
	}
	if rss <= 0 {
		t.Fatalf("rssBytes = %d, want > 0 for a live process", rss)
	}
}

func TestSampleProcessOnMissingPID(t *testing.T) {
	cpu, rss := SampleProcess(context.Background(), 0, time.Millisecond)
	if cpu != 0 || rss != 0 {
		t.Fatalf("SampleProcess(0) = %v/%d, want 0/0", cpu, rss)
	}
}

func TestListProcessesIncludesSelf(t *testing.T) {
	procs, err := ListProcesses()
	if err != nil {
		t.Fatalf("ListProcesses: %v", err)
	}
	self := os.Getpid()
	for _, p := range procs {
		if p.PID == self {
			if p.PGID <= 0 {
				t.Fatalf("own pgid = %d", p.PGID)
			}
			return
		}
	}
	t.Fatalf("process listing of %d entries does not contain pid %d", len(procs), self)
}

func TestIPAddressesExcludeLoopback(t *testing.T) {
	for _, addr := range IPAddresses() {
		if addr == "127.0.0.1" || addr == "::1" {
			t.Fatalf("loopback address %q must not be reported", addr)
		}
	}
}

func TestIsVirtualBridgeInterface(t *testing.T) {
	for name, want := range map[string]bool{
		"enp0s1": false, "eth0": false, "en0": false,
		"docker0": true, "br-1a2b3c": true, "veth12ab": true, "virbr0": true, "cni0": true,
	} {
		if got := isVirtualBridgeInterface(name); got != want {
			t.Errorf("isVirtualBridgeInterface(%q) = %v, want %v", name, got, want)
		}
	}
}
