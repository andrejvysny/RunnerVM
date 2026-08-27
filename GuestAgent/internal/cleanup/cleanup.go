// Package cleanup erases job residue from a guest between runner sessions
// (agent.cleanup). Cleanup is keyed by an epoch supplied by the host and is
// idempotent: replaying an epoch the guest already processed does nothing,
// so a retried RPC cannot delete a fresh session's files.
package cleanup

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// epochFileName holds the last epoch processed, under Config.StateDir.
const epochFileName = "cleanup.epoch"

// dockerTimeout bounds `docker system prune`, which can take a while on a
// guest with a large image cache but must not hang the RPC forever.
const dockerTimeout = 5 * time.Minute

// ErrHomeSnapshotMissing is wrapped by the error Run returns when it is
// configured to restore RunnerHome (HomeSnapshotPath is set) but no
// pristine snapshot exists yet. Cleanup fails closed here rather than
// silently reporting {ok:true} while a prior job's credentials survive.
var ErrHomeSnapshotMissing = errors.New("cleanup: home snapshot missing")

// DefaultHomeRelPaths are the caches a job typically fills in the runner's
// home directory.
var DefaultHomeRelPaths = []string{".cache", ".npm", ".yarn/cache", ".nuget/packages", ".gradle/caches"}

// DefaultTempDirs are swept for entries owned by the runner account.
var DefaultTempDirs = []string{"/tmp", "/var/tmp"}

// Config describes what a cleanup pass removes. Every path is explicit so
// tests can point the cleaner at a sandbox instead of the real /tmp.
type Config struct {
	RunnerDir string
	StateDir  string
	// RunnerHome is the runner account's home directory.
	RunnerHome string
	// RunnerUID selects which temp-directory entries are removed, and becomes
	// the owner RestoreHome chowns RunnerHome itself to.
	RunnerUID int
	// RunnerGID is RunnerHome's group after a RestoreHome pass.
	RunnerGID int
	// TempDirs defaults to DefaultTempDirs when nil.
	TempDirs []string
	// HomeRelPaths defaults to DefaultHomeRelPaths when nil.
	HomeRelPaths []string
	// ExtraPaths are removed verbatim.
	ExtraPaths []string
	// PruneDocker enables `docker system prune -af` when docker is present.
	PruneDocker bool
	// HomeSnapshotPath is where the pristine-HOME baseline (see home.go)
	// lives. Empty disables home-restore entirely: Run falls back to the
	// HomeRelPaths sweep only, which is what every Cleaner built before this
	// field existed still gets.
	HomeSnapshotPath string
	Logger           *slog.Logger
}

// Result is the agent.cleanup reply. Removed lists the paths this call
// actually deleted; it is empty for a replayed epoch.
type Result struct {
	OK      bool
	Removed []string
}

// Cleaner performs epoch-guarded cleanup passes.
type Cleaner struct {
	cfg Config
	log *slog.Logger
}

// New returns a Cleaner, applying the default path lists.
func New(cfg Config) (*Cleaner, error) {
	if cfg.RunnerDir == "" {
		return nil, errors.New("cleanup: RunnerDir is required")
	}
	if cfg.StateDir == "" {
		return nil, errors.New("cleanup: StateDir is required")
	}
	if cfg.TempDirs == nil {
		cfg.TempDirs = DefaultTempDirs
	}
	if cfg.HomeRelPaths == nil {
		cfg.HomeRelPaths = DefaultHomeRelPaths
	}
	log := cfg.Logger
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Cleaner{cfg: cfg, log: log}, nil
}

// Run performs cleanup for epoch. Epochs at or below the last processed one
// are no-ops reported as ok.
func (c *Cleaner) Run(ctx context.Context, epoch int64) (Result, error) {
	last, err := c.lastEpoch()
	if err != nil {
		return Result{}, err
	}
	if epoch <= last {
		c.log.Info("cleanup skipped: epoch already applied", "epoch", epoch, "lastEpoch", last)
		return Result{OK: true}, nil
	}

	removed := c.sweep(ctx)
	restored, err := c.restoreHome()
	if err != nil {
		return Result{}, err
	}
	if restored != "" {
		removed = append(removed, restored)
	}
	if err := c.writeEpoch(epoch); err != nil {
		return Result{}, err
	}
	c.log.Info("cleanup complete", "epoch", epoch, "removedCount", len(removed))
	return Result{OK: true, Removed: removed}, nil
}

// restoreHome resets RunnerHome to the pristine snapshot taken before any
// job ran, so a credential a job wrote under HOME cannot survive into the
// next session on a reused VM. Disabled (a silent no-op) when the Cleaner
// was not configured with a HomeSnapshotPath; otherwise fails closed if the
// snapshot is missing, rather than reporting {ok:true} while HOME still
// carries the previous job's residue.
func (c *Cleaner) restoreHome() (string, error) {
	if c.cfg.RunnerHome == "" || c.cfg.HomeSnapshotPath == "" {
		return "", nil
	}
	if _, err := os.Stat(c.cfg.HomeSnapshotPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("%w: %s", ErrHomeSnapshotMissing, c.cfg.HomeSnapshotPath)
		}
		return "", fmt.Errorf("cleanup: stat home snapshot: %w", err)
	}
	if err := RestoreHome(c.cfg.RunnerHome, c.cfg.HomeSnapshotPath, c.cfg.RunnerUID, c.cfg.RunnerGID); err != nil {
		return "", fmt.Errorf("cleanup: restore home: %w", err)
	}
	return "home:restored", nil
}

// EnsureHomeSnapshot takes the one-time pristine-HOME baseline RestoreHome
// restores into, if RunnerHome/HomeSnapshotPath are configured and no
// snapshot exists yet. It is meant to run once, at agent startup: a
// snapshot is only ever taken before the first job (no cleanup epoch
// recorded yet), because once a job has run, HOME is no longer pristine and
// a later restart must not silently baseline whatever state a job left it
// in.
func (c *Cleaner) EnsureHomeSnapshot() error {
	if c.cfg.RunnerHome == "" || c.cfg.HomeSnapshotPath == "" {
		return nil
	}
	if _, err := os.Stat(c.cfg.HomeSnapshotPath); err == nil {
		return nil // already have one
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("cleanup: stat home snapshot: %w", err)
	}
	last, err := c.lastEpoch()
	if err != nil {
		return err
	}
	if last > 0 {
		c.log.Warn("cleanup: no home snapshot but a job already ran; refusing to baseline a dirty HOME",
			"lastEpoch", last)
		return nil
	}
	if err := os.MkdirAll(c.cfg.StateDir, 0o750); err != nil {
		return fmt.Errorf("cleanup: create state dir: %w", err)
	}
	if err := os.MkdirAll(c.cfg.RunnerHome, 0o700); err != nil {
		return fmt.Errorf("cleanup: create runner home: %w", err)
	}
	if err := SnapshotHome(c.cfg.RunnerHome, c.cfg.HomeSnapshotPath); err != nil {
		return fmt.Errorf("cleanup: snapshot home: %w", err)
	}
	c.log.Info("cleanup: took pristine home snapshot", "home", c.cfg.RunnerHome)
	return nil
}

// sweep deletes every configured target, collecting the paths it removed.
// Individual failures are logged and skipped: a locked file must not abort
// the rest of the pass.
func (c *Cleaner) sweep(ctx context.Context) []string {
	var removed []string

	for _, name := range []string{"_work", "_diag"} {
		removed = append(removed, c.remove(filepath.Join(c.cfg.RunnerDir, name))...)
	}
	if c.cfg.RunnerHome != "" {
		for _, rel := range c.cfg.HomeRelPaths {
			removed = append(removed, c.remove(filepath.Join(c.cfg.RunnerHome, rel))...)
		}
	}
	for _, dir := range c.cfg.TempDirs {
		removed = append(removed, c.sweepTemp(dir)...)
	}
	for _, p := range c.cfg.ExtraPaths {
		removed = append(removed, c.remove(p)...)
	}
	if c.cfg.PruneDocker {
		if pruned := c.pruneDocker(ctx); pruned != "" {
			removed = append(removed, pruned)
		}
	}
	return removed
}

// sweepTemp removes the runner's own entries from a shared temp directory,
// leaving root- and system-owned files (systemd sockets, X11 locks) intact.
func (c *Cleaner) sweepTemp(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var removed []string
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		info, err := os.Lstat(path)
		if err != nil {
			continue
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(st.Uid) != c.cfg.RunnerUID {
			continue
		}
		removed = append(removed, c.remove(path)...)
	}
	return removed
}

// remove deletes path if it exists, returning it when something was there.
func (c *Cleaner) remove(path string) []string {
	if _, err := os.Lstat(path); err != nil {
		return nil // absent: nothing to report, cleanup stays idempotent
	}
	if err := os.RemoveAll(path); err != nil {
		c.log.Warn("cleanup could not remove path", "path", path, "error", err.Error())
		return nil
	}
	return []string{path}
}

func (c *Cleaner) pruneDocker(ctx context.Context) string {
	if _, err := exec.LookPath("docker"); err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, dockerTimeout)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "docker", "system", "prune", "-af").CombinedOutput(); err != nil {
		c.log.Warn("docker prune failed", "error", err.Error(), "output", strings.TrimSpace(string(out)))
		return ""
	}
	return "docker:system-prune"
}

func (c *Cleaner) epochPath() string { return filepath.Join(c.cfg.StateDir, epochFileName) }

func (c *Cleaner) lastEpoch() (int64, error) {
	b, err := os.ReadFile(c.epochPath())
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("cleanup: read epoch: %w", err)
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		// A corrupt marker must not wedge cleanup forever; treat it as
		// "never cleaned" and let this pass rewrite it.
		c.log.Warn("cleanup epoch file is unreadable; treating as 0", "path", c.epochPath())
		return 0, nil
	}
	return n, nil
}

// writeEpoch persists the marker atomically so a crash mid-write cannot
// leave a truncated value that replays cleanup against a live session.
func (c *Cleaner) writeEpoch(epoch int64) error {
	if err := os.MkdirAll(c.cfg.StateDir, 0o750); err != nil {
		return fmt.Errorf("cleanup: create state dir: %w", err)
	}
	tmp := c.epochPath() + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.FormatInt(epoch, 10)+"\n"), 0o640); err != nil {
		return fmt.Errorf("cleanup: write epoch: %w", err)
	}
	if err := os.Rename(tmp, c.epochPath()); err != nil {
		return fmt.Errorf("cleanup: commit epoch: %w", err)
	}
	return nil
}
