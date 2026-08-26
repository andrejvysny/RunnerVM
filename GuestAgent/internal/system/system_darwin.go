//go:build darwin

package system

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// psTimeout bounds the `ps` invocations macOS needs for per-process CPU:
// Darwin exposes no /proc, and host_processor_info requires cgo.
const psTimeout = 2 * time.Second

// darwinLoadScale is the fallback FSCALE when the vm.loadavg sysctl blob is
// shorter than expected; Darwin has used 2048 since the NeXT era.
const darwinLoadScale = 2048

func bootID() (string, error) {
	// kern.bootsessionuuid is regenerated on every boot, which is exactly
	// the semantics of Linux's random/boot_id.
	return unix.Sysctl("kern.bootsessionuuid")
}

func uptimeSeconds() (int64, error) {
	tv, err := unix.SysctlTimeval("kern.boottime")
	if err != nil {
		return 0, err
	}
	up := time.Since(time.Unix(tv.Sec, int64(tv.Usec)*1000))
	if up < 0 {
		return 0, nil
	}
	return int64(up.Seconds()), nil
}

func kernelVersion() (string, error) {
	var u unix.Utsname
	if err := unix.Uname(&u); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s %s %s",
		nullTerminated(u.Sysname[:]), nullTerminated(u.Release[:]), nullTerminated(u.Machine[:])), nil
}

func diskUsage(path string) (Usage, error) {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return Usage{}, err
	}
	bs := int64(st.Bsize)
	return Usage{
		TotalBytes:     int64(st.Blocks) * bs,
		UsedBytes:      int64(st.Blocks-st.Bfree) * bs,
		AvailableBytes: int64(st.Bavail) * bs,
	}, nil
}

func memoryUsage() (Memory, error) {
	total, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return Memory{}, err
	}
	available := vmStatAvailable()
	if available > int64(total) {
		available = int64(total)
	}
	return Memory{
		TotalBytes:     int64(total),
		UsedBytes:      int64(total) - available,
		AvailableBytes: available,
	}, nil
}

// vmStatAvailable approximates Linux's MemAvailable from `vm_stat`: pages
// that can be handed out without swapping (free + reclaimable).
func vmStatAvailable() int64 {
	out, err := runCommand(context.Background(), psTimeout, "vm_stat")
	if err != nil {
		return 0
	}
	pageSize := int64(4096)
	var pages int64
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "Mach Virtual Memory Statistics") {
			if _, rest, ok := strings.Cut(line, "page size of "); ok {
				if n, err := strconv.ParseInt(strings.Fields(rest)[0], 10, 64); err == nil {
					pageSize = n
				}
			}
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "Pages free", "Pages inactive", "Pages speculative", "Pages purgeable":
			pages += parsePageCount(value)
		}
	}
	return pages * pageSize
}

func parsePageCount(v string) int64 {
	n, err := strconv.ParseInt(strings.TrimSuffix(strings.TrimSpace(v), "."), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// loadAverage decodes `struct loadavg { fixpt_t ldavg[3]; long fscale; }`
// from the vm.loadavg sysctl. On arm64 the long is 8-byte aligned, so
// fscale sits at offset 16.
func loadAverage() (float64, float64, float64, error) {
	raw, err := unix.SysctlRaw("vm.loadavg")
	if err != nil {
		return 0, 0, 0, err
	}
	if len(raw) < 12 {
		return 0, 0, 0, errors.New("system: vm.loadavg sysctl too short")
	}
	scale := float64(darwinLoadScale)
	if len(raw) >= 24 {
		if fscale := binary.LittleEndian.Uint64(raw[16:24]); fscale > 0 {
			scale = float64(fscale)
		}
	}
	load := func(i int) float64 {
		return float64(binary.LittleEndian.Uint32(raw[i*4:i*4+4])) / scale
	}
	return load(0), load(1), load(2), nil
}

func listProcesses() ([]Process, error) {
	out, err := runCommand(context.Background(), psTimeout, "ps", "-axo", "pid=,pgid=,comm=")
	if err != nil {
		return nil, err
	}
	var procs []Process
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		pgid, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil {
			continue
		}
		// comm is the executable path; keep the basename so callers can
		// match "Runner.Worker" the same way they do on Linux.
		command := strings.Join(fields[2:], " ")
		if i := strings.LastIndexByte(command, '/'); i >= 0 {
			command = command[i+1:]
		}
		procs = append(procs, Process{PID: pid, PGID: pgid, Command: command})
	}
	return procs, nil
}

// sampleCPUPercent sums the decayed per-process CPU shares `ps` reports and
// normalises by core count. It is an approximation: an exact figure needs
// host_processor_info, which needs cgo, which the guest agent avoids so it
// can be cross-built from any host.
func sampleCPUPercent(ctx context.Context, window time.Duration) float64 {
	out, err := runCommand(ctx, psTimeout, "ps", "-A", "-o", "%cpu=")
	if err != nil {
		return 0
	}
	var sum float64
	for _, line := range strings.Split(out, "\n") {
		v, err := strconv.ParseFloat(strings.TrimSpace(line), 64)
		if err != nil {
			continue
		}
		sum += v
	}
	cores := float64(CPUCount())
	if cores <= 0 {
		return 0
	}
	return clampPercent(sum / cores)
}

func sampleProcess(ctx context.Context, pid int, window time.Duration) (float64, int64) {
	if pid <= 0 {
		return 0, 0
	}
	out, err := runCommand(ctx, psTimeout, "ps", "-o", "%cpu=,rss=", "-p", strconv.Itoa(pid))
	if err != nil {
		return 0, 0
	}
	fields := strings.Fields(out)
	if len(fields) < 2 {
		return 0, 0
	}
	cpu, _ := strconv.ParseFloat(fields[0], 64)
	rssKiB, _ := strconv.ParseInt(fields[1], 10, 64)
	return roundPercent(cpu), rssKiB * 1024
}

func powerOff(ctx context.Context) error {
	_, err := runCommand(ctx, 10*time.Second, "shutdown", "-h", "now")
	return err
}

// inVirtualMachine asks XNU directly: kern.hv_vmm_present is set whenever
// the kernel is running as a hypervisor guest, including under Apple's own
// Virtualization.framework (how RunnerVM boots macOS guests on Apple
// Silicon hosts).
func inVirtualMachine() (bool, string) {
	v, err := unix.SysctlUint32("kern.hv_vmm_present")
	if err != nil {
		return false, ""
	}
	return classifyHVVMMPresent(v)
}

// classifyHVVMMPresent is the pure decision behind inVirtualMachine, split
// out so it can be unit-tested by feeding it values instead of stubbing the
// sysctl syscall.
func classifyHVVMMPresent(v uint32) (bool, string) {
	if v == 1 {
		return true, "sysctl kern.hv_vmm_present=1"
	}
	return false, ""
}
