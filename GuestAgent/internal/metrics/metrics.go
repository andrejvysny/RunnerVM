// Package metrics assembles the guest telemetry snapshot returned by
// agent.getMetrics, in the shape fixed by spec §39. Every count is int64
// so the Swift side decodes it as Int64; percentages and load averages are
// the only floating-point fields.
package metrics

import (
	"context"
	"sync"
	"time"

	"github.com/runnervm/guest-agent/internal/system"
)

// DefaultWindow is the sampling window for CPU utilisation. It is short
// enough that agent.getMetrics stays well inside a host poll interval and
// long enough to smooth out a single scheduler tick.
const DefaultWindow = 200 * time.Millisecond

// Snapshot is the agent.getMetrics result payload.
type Snapshot struct {
	Timestamp string   `json:"timestamp"`
	UptimeSec int64    `json:"uptimeSec"`
	CPU       CPU      `json:"cpu"`
	Memory    Memory   `json:"memory"`
	Disk      Disk     `json:"disk"`
	Runner    Runner   `json:"runner"`
	Warnings  []string `json:"warnings,omitempty"`
}

// CPU is whole-guest processor telemetry. UsagePercent is 0..100 across all
// cores; the load averages are the raw kernel values.
type CPU struct {
	LogicalCount int64   `json:"logicalCount"`
	UsagePercent float64 `json:"usagePercent"`
	Load1        float64 `json:"load1"`
	Load5        float64 `json:"load5"`
	Load15       float64 `json:"load15"`
}

// Memory is system RAM accounting in bytes.
type Memory struct {
	TotalBytes     int64 `json:"totalBytes"`
	UsedBytes      int64 `json:"usedBytes"`
	AvailableBytes int64 `json:"availableBytes"`
}

// Disk is capacity of the filesystem holding the guest root.
type Disk struct {
	RootTotalBytes     int64 `json:"rootTotalBytes"`
	RootUsedBytes      int64 `json:"rootUsedBytes"`
	RootAvailableBytes int64 `json:"rootAvailableBytes"`
}

// Runner is the actions-runner process slice of the snapshot. PID is 0 and
// CPUPercent/RSSBytes are 0 when no runner is running.
type Runner struct {
	ProcessRunning bool    `json:"processRunning"`
	PID            int64   `json:"pid"`
	CPUPercent     float64 `json:"cpuPercent"`
	RSSBytes       int64   `json:"rssBytes"`
}

// Options selects what a Collect call measures.
type Options struct {
	// RootPath is the filesystem whose capacity is reported as "disk".
	RootPath string
	// RunnerPID is the actions-runner process to sample, or 0 for none.
	RunnerPID int
	// Window is the CPU sampling window; zero means DefaultWindow.
	Window time.Duration
}

// Collect gathers one snapshot. It never fails: a source that cannot be
// read contributes zeroes and a warning string, because losing the whole
// telemetry call over one unreadable file is worse than a partial answer.
func Collect(ctx context.Context, opts Options) Snapshot {
	if opts.RootPath == "" {
		opts.RootPath = "/"
	}
	if opts.Window <= 0 {
		opts.Window = DefaultWindow
	}

	snap := Snapshot{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		CPU:       CPU{LogicalCount: int64(system.CPUCount())},
		Runner:    Runner{ProcessRunning: opts.RunnerPID > 0, PID: int64(opts.RunnerPID)},
	}
	var warn warnings

	// The system and process CPU samples share one wall-clock window, so
	// they run concurrently rather than costing 2x Window.
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		snap.CPU.UsagePercent = system.SampleCPUPercent(ctx, opts.Window)
	}()
	if opts.RunnerPID > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			snap.Runner.CPUPercent, snap.Runner.RSSBytes = system.SampleProcess(ctx, opts.RunnerPID, opts.Window)
		}()
	}

	if up, err := system.UptimeSeconds(); err != nil {
		warn.add("uptime: " + err.Error())
	} else {
		snap.UptimeSec = up
	}
	if l1, l5, l15, err := system.LoadAverage(); err != nil {
		warn.add("loadavg: " + err.Error())
	} else {
		snap.CPU.Load1, snap.CPU.Load5, snap.CPU.Load15 = l1, l5, l15
	}
	if mem, err := system.MemoryUsage(); err != nil {
		warn.add("memory: " + err.Error())
	} else {
		snap.Memory = Memory{
			TotalBytes:     mem.TotalBytes,
			UsedBytes:      mem.UsedBytes,
			AvailableBytes: mem.AvailableBytes,
		}
	}
	if du, err := system.DiskUsage(opts.RootPath); err != nil {
		warn.add("disk: " + err.Error())
	} else {
		snap.Disk = Disk{
			RootTotalBytes:     du.TotalBytes,
			RootUsedBytes:      du.UsedBytes,
			RootAvailableBytes: du.AvailableBytes,
		}
	}

	wg.Wait()
	snap.Warnings = warn.list
	return snap
}

type warnings struct{ list []string }

func (w *warnings) add(s string) { w.list = append(w.list, s) }
