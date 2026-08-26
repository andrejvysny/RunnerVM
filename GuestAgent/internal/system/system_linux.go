//go:build linux

package system

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// dmiSysVendorPath and dmiProductNamePath are the SMBIOS strings the
// firmware/hypervisor publishes; dmiHypervisorTypePath exists only when the
// kernel itself detected a paravirtualized hypervisor. Variables so tests
// can point them at a fixture instead of the real /sys tree.
var (
	dmiSysVendorPath    = "/sys/class/dmi/id/sys_vendor"
	dmiProductNamePath  = "/sys/class/dmi/id/product_name"
	dmiHypervisorType   = "/sys/hypervisor/type"
	detectVirtCLIWindow = 2 * time.Second
)

// userHZ is the kernel's CPU-accounting tick rate exposed through /proc.
// It is a compile-time constant of the kernel ABI (CONFIG_HZ is separate)
// and has been 100 on every Linux/arm64 and Linux/amd64 build since 2.6.
const userHZ = 100

func bootID() (string, error) {
	b, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func uptimeSeconds() (int64, error) {
	b, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return 0, errors.New("system: /proc/uptime is empty")
	}
	secs, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, err
	}
	return int64(secs), nil
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
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return Memory{}, err
	}
	var total, available int64
	for _, line := range strings.Split(string(b), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch key {
		case "MemTotal":
			total = parseKiB(value)
		case "MemAvailable":
			available = parseKiB(value)
		}
	}
	if total == 0 {
		return Memory{}, errors.New("system: MemTotal missing from /proc/meminfo")
	}
	return Memory{TotalBytes: total, UsedBytes: total - available, AvailableBytes: available}, nil
}

// parseKiB reads a "  1234 kB" /proc/meminfo value into bytes.
func parseKiB(v string) int64 {
	fields := strings.Fields(v)
	if len(fields) == 0 {
		return 0
	}
	n, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0
	}
	return n * 1024
}

func loadAverage() (float64, float64, float64, error) {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, 0, err
	}
	fields := strings.Fields(string(b))
	if len(fields) < 3 {
		return 0, 0, 0, errors.New("system: malformed /proc/loadavg")
	}
	l1, _ := strconv.ParseFloat(fields[0], 64)
	l5, _ := strconv.ParseFloat(fields[1], 64)
	l15, _ := strconv.ParseFloat(fields[2], 64)
	return l1, l5, l15, nil
}

func listProcesses() ([]Process, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	out := make([]Process, 0, len(entries))
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue // non-numeric /proc entry
		}
		b, err := os.ReadFile(filepath.Join("/proc", e.Name(), "stat"))
		if err != nil {
			continue // process exited between readdir and read
		}
		comm, pgid, ok := parseProcStat(string(b))
		if !ok {
			continue
		}
		out = append(out, Process{PID: pid, PGID: pgid, Command: comm})
	}
	return out, nil
}

// parseProcStat extracts comm (field 2) and pgrp (field 5) from a
// /proc/<pid>/stat line. comm is parenthesised and may itself contain
// spaces and parentheses, so the split point is the LAST ')'.
func parseProcStat(s string) (comm string, pgid int, ok bool) {
	openIdx := strings.IndexByte(s, '(')
	closeIdx := strings.LastIndexByte(s, ')')
	if openIdx < 0 || closeIdx < openIdx {
		return "", 0, false
	}
	comm = s[openIdx+1 : closeIdx]
	rest := strings.Fields(s[closeIdx+1:])
	// rest[0] = state, rest[1] = ppid, rest[2] = pgrp.
	if len(rest) < 3 {
		return "", 0, false
	}
	pgid, err := strconv.Atoi(rest[2])
	if err != nil {
		return "", 0, false
	}
	return comm, pgid, true
}

// procCPUTicks returns a process's cumulative utime+stime in USER_HZ ticks.
func procCPUTicks(pid int) (uint64, error) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, err
	}
	closeParen := strings.LastIndexByte(string(b), ')')
	if closeParen < 0 {
		return 0, errors.New("system: malformed proc stat")
	}
	rest := strings.Fields(string(b)[closeParen+1:])
	// rest[0]=state ... rest[11]=utime, rest[12]=stime (fields 14 and 15).
	if len(rest) < 13 {
		return 0, errors.New("system: short proc stat")
	}
	utime, err1 := strconv.ParseUint(rest[11], 10, 64)
	stime, err2 := strconv.ParseUint(rest[12], 10, 64)
	if err1 != nil || err2 != nil {
		return 0, errors.New("system: unparsable cpu ticks")
	}
	return utime + stime, nil
}

func procRSS(pid int) int64 {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/statm", pid))
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(b))
	if len(fields) < 2 {
		return 0
	}
	pages, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	return pages * int64(os.Getpagesize())
}

// cpuTotals returns cumulative (busy, total) jiffies from /proc/stat's
// aggregate "cpu" line.
func cpuTotals() (busy, total uint64, err error) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, err
	}
	line, _, _ := strings.Cut(string(b), "\n")
	fields := strings.Fields(line)
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0, errors.New("system: malformed /proc/stat")
	}
	var idle uint64
	for i, f := range fields[1:] {
		v, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			continue
		}
		total += v
		if i == 3 || i == 4 { // idle, iowait
			idle += v
		}
	}
	return total - idle, total, nil
}

func sampleCPUPercent(ctx context.Context, window time.Duration) float64 {
	busy0, total0, err := cpuTotals()
	if err != nil || !sleepCtx(ctx, window) {
		return 0
	}
	busy1, total1, err := cpuTotals()
	if err != nil || total1 <= total0 {
		return 0
	}
	return clampPercent(float64(busy1-busy0) / float64(total1-total0) * 100)
}

func sampleProcess(ctx context.Context, pid int, window time.Duration) (float64, int64) {
	if pid <= 0 {
		return 0, 0
	}
	rss := procRSS(pid)
	t0, err := procCPUTicks(pid)
	if err != nil || !sleepCtx(ctx, window) {
		return 0, rss
	}
	t1, err := procCPUTicks(pid)
	if err != nil || t1 < t0 {
		return 0, rss
	}
	elapsedTicks := window.Seconds() * userHZ
	if elapsedTicks <= 0 {
		return 0, rss
	}
	return roundPercent(float64(t1-t0) / elapsedTicks * 100), rss
}

func powerOff(ctx context.Context) error {
	// systemd guests: systemctl is authoritative and unmounts cleanly.
	if _, err := runCommand(ctx, 10*time.Second, "systemctl", "poweroff"); err == nil {
		return nil
	}
	_, err := runCommand(ctx, 10*time.Second, "shutdown", "-h", "now")
	return err
}

// inVirtualMachine tries three independent signals, cheapest and most
// specific first: DMI strings the firmware/hypervisor publishes, the
// kernel's own hypervisor detection, and finally systemd-detect-virt for
// hypervisors that leave neither of the first two behind.
func inVirtualMachine() (bool, string) {
	vendor := readTrimmed(dmiSysVendorPath)
	product := readTrimmed(dmiProductNamePath)
	if ok, evidence := classifyDMI(vendor, product); ok {
		return true, evidence
	}
	if ok, evidence := classifyHypervisorType(readTrimmed(dmiHypervisorType), statExists(dmiHypervisorType)); ok {
		return true, evidence
	}
	if ok, evidence := detectVirtCLI(context.Background()); ok {
		return true, evidence
	}
	return false, ""
}

// classifyDMI is the pure decision behind the DMI half of inVirtualMachine.
// Apple's Virtualization.framework -- how RunnerVM boots Linux guests on
// Apple Silicon hosts -- stamps SMBIOS with vendor "Apple Inc." and product
// "Apple Virtualization Generic Platform". Both substrings are required so
// an unrelated machine that happens to mention just one of them (e.g. some
// other "Apple ..." OEM string) does not false-positive.
func classifyDMI(vendor, product string) (bool, string) {
	combined := vendor + " " + product
	if strings.Contains(combined, "Apple") && strings.Contains(combined, "Virtualization") {
		return true, fmt.Sprintf("dmi: vendor=%q product=%q", vendor, product)
	}
	return false, ""
}

// classifyHypervisorType is the pure decision behind the /sys/hypervisor/type
// half of inVirtualMachine: the file's mere existence means the kernel
// detected a paravirtualized hypervisor (Xen classically leaves no readable
// content, so exists must be checked independently of content).
func classifyHypervisorType(content string, exists bool) (bool, string) {
	if content != "" {
		return true, fmt.Sprintf("/sys/hypervisor/type=%q", content)
	}
	if exists {
		return true, "/sys/hypervisor/type exists"
	}
	return false, ""
}

// detectVirtCLI shells out to systemd-detect-virt as a last resort, for
// hypervisors that leave neither DMI strings nor /sys/hypervisor/type
// behind (e.g. QEMU/KVM during local development without OVMF's SMBIOS
// injection). Bounded so a missing or wedged binary cannot stall startup.
func detectVirtCLI(ctx context.Context) (bool, string) {
	ctx, cancel := context.WithTimeout(ctx, detectVirtCLIWindow)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemd-detect-virt", "--vm").Output()
	if err != nil {
		return false, "" // absent binary or "none" (exit 1): not a VM
	}
	kind := strings.TrimSpace(string(out))
	if kind == "" || kind == "none" {
		return false, ""
	}
	return true, fmt.Sprintf("systemd-detect-virt: %s", kind)
}

func readTrimmed(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func statExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
