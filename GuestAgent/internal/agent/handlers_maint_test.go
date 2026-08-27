package agent

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// resizeDisk is deliberately unimplemented on macOS guests; the host needs a
// distinguishable code so it can skip the step instead of failing the boot.
func TestResizeDiskNotSupportedOnDarwin(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("resizeDisk is implemented on this platform; growing a real root filesystem is not a unit test")
	}
	h := newHarness(t, nil)

	err := h.callErr(t, "agent.resizeDisk", nil)
	if err.Code != CodeNotSupported {
		t.Fatalf("code = %q, want %s", err.Code, CodeNotSupported)
	}
}

func TestCleanupIsIdempotentPerEpoch(t *testing.T) {
	tempSandbox := t.TempDir()
	h := newHarness(t, func(cfg *Config) {
		cfg.CleanupTempDirs = []string{tempSandbox}
	})

	work := filepath.Join(h.runnerDir, "_work")
	writeFile(t, filepath.Join(work, "job", "artifact.txt"), "residue\n")
	junk := filepath.Join(tempSandbox, "job-temp")
	writeFile(t, filepath.Join(junk, "scratch"), "residue\n")

	var first CleanupResult
	h.call(t, "agent.cleanup", map[string]any{"epoch": 5}, &first)
	if !first.OK {
		t.Fatal("ok = false")
	}
	if !slices.Contains(first.Removed, work) {
		t.Fatalf("removed %v does not include %s", first.Removed, work)
	}
	if !slices.Contains(first.Removed, junk) {
		t.Fatalf("removed %v does not include %s", first.Removed, junk)
	}
	if _, err := os.Stat(work); !os.IsNotExist(err) {
		t.Fatalf("%s still exists: %v", work, err)
	}

	// Replaying the epoch must not touch a directory a new session created.
	writeFile(t, filepath.Join(work, "fresh.txt"), "new session\n")
	var replay CleanupResult
	h.call(t, "agent.cleanup", map[string]any{"epoch": 5}, &replay)
	if !replay.OK {
		t.Fatal("replayed epoch: ok = false")
	}
	if len(replay.Removed) != 0 {
		t.Fatalf("replayed epoch removed %v, want nothing", replay.Removed)
	}
	if _, err := os.Stat(work); err != nil {
		t.Fatalf("replayed epoch deleted a fresh %s: %v", work, err)
	}

	var next CleanupResult
	h.call(t, "agent.cleanup", map[string]any{"epoch": 6}, &next)
	if !slices.Contains(next.Removed, work) {
		t.Fatalf("epoch 6 removed %v, want %s", next.Removed, work)
	}

	// The marker must survive an agent restart, so it lives in the state dir.
	if got := readFileString(t, filepath.Join(h.stateDir, "cleanup.epoch")); got != "6\n" {
		t.Fatalf("cleanup.epoch = %q, want %q", got, "6\n")
	}
}

// A fresh harness takes its home snapshot automatically at startup (see
// Service.New / cleaner.EnsureHomeSnapshot), so a first agent.cleanup call
// must already succeed with the restore applied.
func TestCleanupSucceedsWithAutoTakenHomeSnapshot(t *testing.T) {
	h := newHarness(t, nil)

	var res CleanupResult
	h.call(t, "agent.cleanup", map[string]any{"epoch": 1}, &res)
	if !res.OK {
		t.Fatal("ok = false")
	}
}

// A VM that already ran a job in a previous agent lifetime, but never took
// a home snapshot (e.g. an agent binary predating this feature), must not
// have agent.cleanup silently skip the restore: it fails closed instead.
func TestCleanupFailsClosedWithoutHomeSnapshot(t *testing.T) {
	stateDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(stateDir, "cleanup.epoch"), []byte("1\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, func(cfg *Config) {
		cfg.StateDir = stateDir
	})

	err := h.callErr(t, "agent.cleanup", map[string]any{"epoch": 2})
	if err.Code != CodeHomeSnapshotMissing {
		t.Fatalf("code = %q, want %s", err.Code, CodeHomeSnapshotMissing)
	}
}

func TestCleanupRejectsNonPositiveEpoch(t *testing.T) {
	h := newHarness(t, nil)
	if code := h.callErr(t, "agent.cleanup", map[string]any{"epoch": 0}).Code; code != "INVALID_PARAMS" {
		t.Fatalf("code = %q, want INVALID_PARAMS", code)
	}
}

func TestShutdownRepliesThenHalts(t *testing.T) {
	h := newHarness(t, nil)

	var reply map[string]any
	h.call(t, "agent.shutdown", nil, &reply)
	if len(reply) != 0 {
		t.Fatalf("payload = %v, want {}", reply)
	}

	select {
	case <-h.poweredOff:
	case <-time.After(10 * time.Second):
		t.Fatal("the agent never powered off")
	}

	var health HealthResult
	h.call(t, "agent.health", nil, &health)
	if health.State != HealthShuttingDown {
		t.Fatalf("state = %q, want shuttingDown", health.State)
	}
}

// agent.cleanup is destructive by design: it empties the runner's home
// caches and everything it owns under /tmp. That is only safe inside a
// disposable guest, so an agent that is not root must confine itself to the
// runner directory unless the sweeps were configured explicitly.
func TestCleanupSkipsSharedPathsWhenUnprivileged(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the production sweeps are the correct behaviour")
	}
	h := newHarness(t, func(cfg *Config) {
		// nil, not empty: ask for the production defaults (/tmp, ~/.cache).
		cfg.CleanupTempDirs = nil
		cfg.CleanupHome = ""
		cfg.PruneDocker = true
	})
	writeFile(t, filepath.Join(h.runnerDir, "_work", "job", "a"), "residue\n")

	var res CleanupResult
	h.call(t, "agent.cleanup", map[string]any{"epoch": 1}, &res)

	for _, path := range res.Removed {
		if !strings.HasPrefix(path, h.runnerDir) {
			t.Fatalf("unprivileged cleanup touched %s, outside %s", path, h.runnerDir)
		}
	}
	if !strings.Contains(h.logs.String(), "skipping temp and home sweeps") {
		t.Fatal("the operator was not warned that the sweeps were skipped")
	}
}

// notInVM stands in for cfg.VMDetector on a harness that must behave as if
// it were running directly on a developer's real hardware -- the scenario
// behind the incident this rail exists to prevent.
func notInVM() (bool, string) { return false, "" }

// hostSafeModeHarness builds a harness whose Service believes it is not
// running inside a VM, so agent.cleanup/resizeDisk/shutdown must refuse.
// CleanupTempDirs/CleanupHome still point at the sandbox (never the real
// developer machine) so that if the refusal ever regressed, the test would
// fail loudly instead of touching real paths.
func hostSafeModeHarness(t *testing.T, mutate func(*Config)) *harness {
	t.Helper()
	return newHarness(t, func(cfg *Config) {
		cfg.VMDetector = notInVM
		if mutate != nil {
			mutate(cfg)
		}
	})
}

func TestCleanupRefusedOutsideVM(t *testing.T) {
	h := hostSafeModeHarness(t, nil)
	writeFile(t, filepath.Join(h.runnerDir, "_work", "job", "a"), "residue\n")

	err := h.callErr(t, "agent.cleanup", map[string]any{"epoch": 1})
	if err.Code != CodeNotSupported {
		t.Fatalf("code = %q, want %s", err.Code, CodeNotSupported)
	}
	if !strings.Contains(err.Message, "not running inside a virtual machine") {
		t.Fatalf("message = %q, want the host-safe-mode refusal", err.Message)
	}
	if _, statErr := os.Stat(filepath.Join(h.runnerDir, "_work")); statErr != nil {
		t.Fatalf("refused cleanup still touched _work: %v", statErr)
	}
}

func TestResizeDiskRefusedOutsideVM(t *testing.T) {
	h := hostSafeModeHarness(t, nil)

	err := h.callErr(t, "agent.resizeDisk", nil)
	if err.Code != CodeNotSupported {
		t.Fatalf("code = %q, want %s", err.Code, CodeNotSupported)
	}
	if !strings.Contains(err.Message, "not running inside a virtual machine") {
		t.Fatalf("message = %q, want the host-safe-mode refusal, not the platform-support one", err.Message)
	}
}

func TestShutdownRefusedOutsideVM(t *testing.T) {
	h := hostSafeModeHarness(t, nil)

	err := h.callErr(t, "agent.shutdown", nil)
	if err.Code != CodeNotSupported {
		t.Fatalf("code = %q, want %s", err.Code, CodeNotSupported)
	}
	if !strings.Contains(err.Message, "not running inside a virtual machine") {
		t.Fatalf("message = %q, want the host-safe-mode refusal", err.Message)
	}
	select {
	case <-h.poweredOff:
		t.Fatal("a refused shutdown must never power off the machine it is running on")
	case <-time.After(50 * time.Millisecond):
	}
}

// TestAllowHostDestructiveReenables verifies the override flag actually
// overrides: with AllowHostDestructive set, a Service that still cannot
// confirm it is inside a VM must run the destructive methods anyway. This
// is the "for guest image builds on real hardware only" escape hatch.
func TestAllowHostDestructiveReenables(t *testing.T) {
	h := hostSafeModeHarness(t, func(cfg *Config) {
		cfg.AllowHostDestructive = true
	})
	writeFile(t, filepath.Join(h.runnerDir, "_work", "job", "a"), "residue\n")

	var res CleanupResult
	h.call(t, "agent.cleanup", map[string]any{"epoch": 1}, &res)
	if !res.OK {
		t.Fatal("ok = false")
	}
	if _, statErr := os.Stat(filepath.Join(h.runnerDir, "_work")); !os.IsNotExist(statErr) {
		t.Fatalf("_work still exists: %v", statErr)
	}

	var reply map[string]any
	h.call(t, "agent.shutdown", nil, &reply)
	select {
	case <-h.poweredOff:
	case <-time.After(10 * time.Second):
		t.Fatal("the override did not re-enable shutdown")
	}
}

// TestHealthReportsHostSafeModeWithoutDegrading asserts the reason is purely
// informational: an otherwise-healthy Service must still answer "ready".
func TestHealthReportsHostSafeModeWithoutDegrading(t *testing.T) {
	h := hostSafeModeHarness(t, nil)

	var health HealthResult
	h.call(t, "agent.health", nil, &health)
	if health.State != HealthReady {
		t.Fatalf("state = %q, want ready (host-safe-mode must not gate readiness)", health.State)
	}
	if !slices.Contains(health.Reasons, "host-safe-mode") {
		t.Fatalf("reasons = %v, want it to include host-safe-mode", health.Reasons)
	}
}

func TestHealthOmitsHostSafeModeWhenInVM(t *testing.T) {
	h := newHarness(t, nil) // default VMDetector reports "in VM"

	var health HealthResult
	h.call(t, "agent.health", nil, &health)
	if slices.Contains(health.Reasons, "host-safe-mode") {
		t.Fatalf("reasons = %v, want no host-safe-mode entry", health.Reasons)
	}
}
