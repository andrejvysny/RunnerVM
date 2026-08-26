//go:build linux

package disk

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/runnervm/guest-agent/internal/system"
)

// commandTimeout bounds each external tool; growpart and resize2fs are
// fast, and a hang here would block the host's boot sequence.
const commandTimeout = 60 * time.Second

// growpartNoChange is growpart's exit status when the partition already
// fills the disk. Older cloud-utils releases signal the same condition with
// "NOCHANGE" on stdout and status 1.
const growpartNoChange = 2

func resize(ctx context.Context, log *slog.Logger, rootPath string) (Result, error) {
	before, err := system.DiskUsage(rootPath)
	if err != nil {
		return Result{}, fmt.Errorf("disk: statfs %s: %w", rootPath, err)
	}

	mount, err := findMount(rootPath)
	if err != nil {
		return Result{}, err
	}
	log.Info("resizing root filesystem",
		"mount", mount.mountPoint, "source", mount.source, "fstype", mount.fsType)

	if err := growPartition(ctx, log, mount.source); err != nil {
		return Result{}, err
	}
	if err := growFilesystem(ctx, mount); err != nil {
		return Result{}, err
	}

	after, err := system.DiskUsage(rootPath)
	if err != nil {
		return Result{}, fmt.Errorf("disk: statfs %s after resize: %w", rootPath, err)
	}
	// Comparing capacity before and after is the only signal that survives
	// tool-specific "already at max" reporting differences.
	return Result{Grown: after.TotalBytes > before.TotalBytes, RootBytes: after.TotalBytes}, nil
}

type mountEntry struct {
	mountPoint string
	source     string
	fsType     string
}

// findMount locates target in /proc/self/mountinfo. The format is
//
//	ID PARENT MAJ:MIN ROOT MOUNTPOINT OPTS [OPTIONAL...] - FSTYPE SOURCE SUPEROPTS
//
// where the "-" separator is required because the optional fields are
// variable in number.
func findMount(target string) (mountEntry, error) {
	b, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return mountEntry{}, fmt.Errorf("disk: read mountinfo: %w", err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 10 || fields[4] != target {
			continue
		}
		sep := -1
		for i := 6; i < len(fields); i++ {
			if fields[i] == "-" {
				sep = i
				break
			}
		}
		if sep < 0 || sep+2 >= len(fields) {
			continue
		}
		return mountEntry{mountPoint: fields[4], fsType: fields[sep+1], source: fields[sep+2]}, nil
	}
	return mountEntry{}, fmt.Errorf("disk: no mountinfo entry for %s", target)
}

// growPartition extends the partition backing dev. A missing growpart is
// tolerated: images built with a full-size partition still need the
// filesystem step, and failing here would make resizeDisk useless on them.
func growPartition(ctx context.Context, log *slog.Logger, dev string) error {
	parent, partNum, err := partitionOf(ctx, dev)
	if err != nil {
		log.Warn("skipping partition growth", "device", dev, "reason", err.Error())
		return nil
	}
	out, code, err := run(ctx, "growpart", parent, partNum)
	switch {
	case err == nil:
		log.Info("growpart grew partition", "device", parent, "partition", partNum)
		return nil
	case errors.Is(err, exec.ErrNotFound):
		log.Warn("growpart not installed; relying on existing partition size")
		return nil
	case code == growpartNoChange || strings.Contains(out, "NOCHANGE"):
		log.Info("partition already at full size", "device", parent, "partition", partNum)
		return nil
	default:
		return fmt.Errorf("disk: growpart %s %s: %w (%s)", parent, partNum, err, out)
	}
}

// partitionOf splits /dev/vda1 into ("/dev/vda", "1"). The parent disk name
// comes from lsblk rather than string surgery, so nvme0n1p1 and dm devices
// resolve correctly.
func partitionOf(ctx context.Context, dev string) (parent, number string, err error) {
	pkname, _, err := run(ctx, "lsblk", "-no", "pkname", dev)
	if err != nil {
		return "", "", fmt.Errorf("lsblk pkname: %w", err)
	}
	pkname = strings.TrimSpace(pkname)
	if pkname == "" {
		return "", "", errors.New("device is not a partition")
	}
	base := dev[strings.LastIndexByte(dev, '/')+1:]
	digits := strings.TrimLeft(strings.TrimPrefix(base, pkname), "p")
	if digits == "" {
		return "", "", fmt.Errorf("cannot derive partition number from %q", dev)
	}
	return "/dev/" + pkname, digits, nil
}

// growFilesystem runs the online-grow tool for the filesystem in question.
// All of them are no-ops when the filesystem already fills its partition.
func growFilesystem(ctx context.Context, m mountEntry) error {
	var argv []string
	switch m.fsType {
	case "ext2", "ext3", "ext4":
		argv = []string{"resize2fs", m.source}
	case "xfs":
		argv = []string{"xfs_growfs", m.mountPoint}
	case "btrfs":
		argv = []string{"btrfs", "filesystem", "resize", "max", m.mountPoint}
	default:
		return fmt.Errorf("disk: no online grow tool for filesystem %q", m.fsType)
	}
	if out, _, err := run(ctx, argv[0], argv[1:]...); err != nil {
		return fmt.Errorf("disk: %s: %w (%s)", argv[0], err, out)
	}
	return nil
}

// run executes an external tool, returning its combined output and exit
// status alongside the error so callers can distinguish "already done"
// exit codes from real failures.
func run(ctx context.Context, name string, args ...string) (string, int, error) {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	code := 0
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	}
	return strings.TrimSpace(string(out)), code, err
}
