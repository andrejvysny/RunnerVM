package cleanup

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func newCleaner(t *testing.T, mutate func(*Config)) (*Cleaner, Config) {
	t.Helper()
	root := t.TempDir()
	cfg := Config{
		RunnerDir:  filepath.Join(root, "actions-runner"),
		StateDir:   filepath.Join(root, "state"),
		RunnerHome: filepath.Join(root, "home"),
		RunnerUID:  os.Getuid(),
		TempDirs:   []string{},
	}
	if mutate != nil {
		mutate(&cfg)
	}
	c, err := New(cfg)
	if err != nil {
		t.Fatalf("cleanup.New: %v", err)
	}
	return c, cfg
}

func mkfile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunRemovesRunnerAndHomeCaches(t *testing.T) {
	c, cfg := newCleaner(t, nil)
	mkfile(t, filepath.Join(cfg.RunnerDir, "_work", "job", "a"))
	mkfile(t, filepath.Join(cfg.RunnerDir, "_diag", "Worker_1.log"))
	mkfile(t, filepath.Join(cfg.RunnerHome, ".cache", "pip", "wheel"))
	mkfile(t, filepath.Join(cfg.RunnerHome, ".npm", "_cacache", "x"))
	// A path outside the configured list must survive.
	keep := filepath.Join(cfg.RunnerHome, ".ssh", "id_ed25519")
	mkfile(t, keep)

	res, err := c.Run(context.Background(), 1)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.OK {
		t.Fatal("ok = false")
	}
	for _, want := range []string{
		filepath.Join(cfg.RunnerDir, "_work"),
		filepath.Join(cfg.RunnerDir, "_diag"),
		filepath.Join(cfg.RunnerHome, ".cache"),
		filepath.Join(cfg.RunnerHome, ".npm"),
	} {
		if !slices.Contains(res.Removed, want) {
			t.Fatalf("removed %v is missing %s", res.Removed, want)
		}
		if _, err := os.Stat(want); !os.IsNotExist(err) {
			t.Fatalf("%s survived cleanup", want)
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("cleanup deleted an unconfigured path: %v", err)
	}
}

// The temp sweep must only take the runner's own entries: /tmp is shared
// with system daemons whose sockets would break if removed.
func TestSweepTempOnlyTakesRunnerOwnedEntries(t *testing.T) {
	tempDir := t.TempDir()
	c, _ := newCleaner(t, func(cfg *Config) {
		cfg.TempDirs = []string{tempDir}
	})
	mine := filepath.Join(tempDir, "mine")
	mkfile(t, filepath.Join(mine, "scratch"))

	res, err := c.Run(context.Background(), 1)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !slices.Contains(res.Removed, mine) {
		t.Fatalf("removed %v is missing %s", res.Removed, mine)
	}

	// Re-point the cleaner at a uid that owns nothing here.
	other, _ := newCleaner(t, func(cfg *Config) {
		cfg.TempDirs = []string{tempDir}
		cfg.RunnerUID = os.Getuid() + 12345
	})
	mkfile(t, filepath.Join(tempDir, "other", "scratch"))
	res2, err := other.Run(context.Background(), 1)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if slices.Contains(res2.Removed, filepath.Join(tempDir, "other")) {
		t.Fatal("cleanup removed an entry owned by a different uid")
	}
}

func TestEpochGuard(t *testing.T) {
	c, cfg := newCleaner(t, nil)
	mkfile(t, filepath.Join(cfg.RunnerDir, "_work", "a"))

	if _, err := c.Run(context.Background(), 7); err != nil {
		t.Fatalf("Run(7): %v", err)
	}
	mkfile(t, filepath.Join(cfg.RunnerDir, "_work", "b"))

	// Both an equal and a lower epoch are replays and must do nothing.
	for _, epoch := range []int64{7, 3} {
		res, err := c.Run(context.Background(), epoch)
		if err != nil {
			t.Fatalf("Run(%d): %v", epoch, err)
		}
		if len(res.Removed) != 0 {
			t.Fatalf("Run(%d) removed %v, want nothing", epoch, res.Removed)
		}
	}
	if _, err := os.Stat(filepath.Join(cfg.RunnerDir, "_work", "b")); err != nil {
		t.Fatalf("a replayed epoch deleted fresh state: %v", err)
	}
}

// A truncated or hand-edited marker must not wedge cleanup forever.
func TestCorruptEpochMarkerIsTreatedAsZero(t *testing.T) {
	c, cfg := newCleaner(t, nil)
	if err := os.MkdirAll(cfg.StateDir, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg.StateDir, epochFileName), []byte("garbage"), 0o640); err != nil {
		t.Fatal(err)
	}
	mkfile(t, filepath.Join(cfg.RunnerDir, "_work", "a"))

	res, err := c.Run(context.Background(), 1)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(res.Removed) == 0 {
		t.Fatal("cleanup did nothing after a corrupt epoch marker")
	}
}
