// Package system reads host facts the guest agent reports to runnerd:
// identity (hostname, boot id, kernel), liveness (uptime), addressing,
// resource usage and process listings, plus OS power-off. Every fact that
// differs per kernel lives in system_linux.go / system_darwin.go behind an
// unexported function of the same name.
package system

import (
	"context"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// Usage is a filesystem's capacity, in bytes.
type Usage struct {
	TotalBytes     int64
	UsedBytes      int64
	AvailableBytes int64
}

// Memory is system RAM accounting, in bytes. AvailableBytes is what the
// kernel believes is obtainable without swapping (Linux MemAvailable,
// macOS free+inactive+speculative+purgeable pages).
type Memory struct {
	TotalBytes     int64
	UsedBytes      int64
	AvailableBytes int64
}

// Process is one entry of a system process listing, reduced to the fields
// the runner-busy heuristic needs.
type Process struct {
	PID     int
	PGID    int
	Command string
}

// Hostname returns the kernel hostname, or "unknown" if it cannot be read;
// the agent must always be able to answer agent.hello.
func Hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown"
	}
	return h
}

// BootID returns an identifier that changes on every boot. The host uses it
// to detect that a guest restarted underneath a still-open session.
func BootID() (string, error) { return bootID() }

// UptimeSeconds returns whole seconds since boot.
func UptimeSeconds() (int64, error) { return uptimeSeconds() }

// KernelVersion returns a one-line kernel identification string.
func KernelVersion() (string, error) { return kernelVersion() }

// DiskUsage returns capacity for the filesystem holding path.
func DiskUsage(path string) (Usage, error) { return diskUsage(path) }

// MemoryUsage returns system RAM accounting.
func MemoryUsage() (Memory, error) { return memoryUsage() }

// LoadAverage returns the 1/5/15-minute run-queue averages.
func LoadAverage() (load1, load5, load15 float64, err error) { return loadAverage() }

// ListProcesses enumerates running processes with their process-group ids.
func ListProcesses() ([]Process, error) { return listProcesses() }

// CPUCount returns the number of logical CPUs visible to the guest.
func CPUCount() int { return runtime.NumCPU() }

// SampleCPUPercent returns whole-system CPU utilisation in percent (0..100)
// measured over window. It blocks for window on platforms that need two
// samples. Errors are reported as 0 rather than failing the whole metrics
// call: partial telemetry beats none.
func SampleCPUPercent(ctx context.Context, window time.Duration) float64 {
	return sampleCPUPercent(ctx, window)
}

// SampleProcess returns a process's CPU utilisation in percent (100 == one
// fully-busy core) over window, and its resident set size in bytes. A
// missing process yields (0, 0).
func SampleProcess(ctx context.Context, pid int, window time.Duration) (cpuPercent float64, rssBytes int64) {
	return sampleProcess(ctx, pid, window)
}

// PowerOff asks the OS to halt. It returns the error of the last command
// tried; on success the process is usually killed before it can return.
func PowerOff(ctx context.Context) error { return powerOff(ctx) }

// InVirtualMachine reports whether the process is running inside a
// hypervisor guest, plus a short human-readable evidence string describing
// how it decided. The agent uses this to refuse destructive operations
// (agent.cleanup, agent.resizeDisk, agent.shutdown) when it looks like it is
// actually running on someone's real hardware, e.g. a developer's Mac
// instead of a throwaway RunnerVM guest. A false result means "could not
// confirm this is a VM", not "definitely bare metal": prefer the safe
// refusal over a confident guess.
func InVirtualMachine() (bool, string) { return inVirtualMachine() }

// IPAddresses returns the guest's non-loopback unicast addresses in interface
// order (kernel ifindex, so the primary NIC comes before container bridges),
// IPv4 before IPv6 within an interface. runnerctl uses the first entry for SSH.
func IPAddresses() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out, v6 []string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if isVirtualBridgeInterface(iface.Name) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP.IsLoopback() || ipNet.IP.IsLinkLocalUnicast() {
				continue
			}
			if ipNet.IP.IsGlobalUnicast() || ipNet.IP.IsPrivate() {
				if ipNet.IP.To4() != nil {
					out = append(out, ipNet.IP.String())
				} else {
					v6 = append(v6, ipNet.IP.String())
				}
			}
		}
		out = append(out, v6...)
		v6 = v6[:0]
	}
	return out
}

// isVirtualBridgeInterface reports interfaces created by container runtimes;
// their addresses are never reachable from the host and must not win SSH.
func isVirtualBridgeInterface(name string) bool {
	for _, prefix := range []string{"docker", "br-", "veth", "virbr", "cni", "podman", "flannel"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

// runCommand executes argv with a deadline and returns its trimmed stdout.
// Used for the few facts no kernel interface exposes cheaply (docker
// version, macOS `ps`), never for anything on the hot path.
func runCommand(ctx context.Context, timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return "", err
	}
	return string(trimSpace(out)), nil
}

func trimSpace(b []byte) []byte {
	start := 0
	for start < len(b) && isSpace(b[start]) {
		start++
	}
	end := len(b)
	for end > start && isSpace(b[end-1]) {
		end--
	}
	return b[start:end]
}

// nullTerminated converts a fixed-size C string field (uname, sysctl) into
// a Go string, stopping at the first NUL.
func nullTerminated(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// sleepCtx waits for d, reporting false if ctx was cancelled first. Metric
// sampling windows are the only place the agent deliberately blocks.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return true
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// clampPercent bounds a whole-system percentage to [0,100] and rounds it to
// two decimals so the JSON stays short and stable.
func clampPercent(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return roundPercent(v)
}

// roundPercent rounds to two decimals without clamping: a single process
// may legitimately exceed 100% on a multi-core guest.
func roundPercent(v float64) float64 {
	if v < 0 {
		return 0
	}
	return float64(int64(v*100+0.5)) / 100
}
