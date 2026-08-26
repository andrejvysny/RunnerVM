// Package agent wires the guest protocol v1 method catalogue onto an
// rpc.Server. It owns no transport: main.go decides whether the listener is
// AF_VSOCK (production) or TCP (development and tests).
package agent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/runnervm/guest-agent/internal/cleanup"
	"github.com/runnervm/guest-agent/internal/metrics"
	"github.com/runnervm/guest-agent/internal/rpc"
	"github.com/runnervm/guest-agent/internal/runner"
	"github.com/runnervm/guest-agent/internal/system"
)

// Guest protocol identity, per Proto/envelope.md.
const (
	Protocol        = "guest"
	ProtocolVersion = 1
)

// Health states reported by agent.health.
const (
	HealthStarting     = "starting"
	HealthReady        = "ready"
	HealthDegraded     = "degraded"
	HealthShuttingDown = "shuttingDown"
)

// startupGrace is how long a failing self-check is reported as "starting"
// rather than "degraded". The runner and docker are installed by the image,
// but a cold boot can still race the agent by a few seconds.
const startupGrace = 30 * time.Second

// defaultShutdownDelay gives the rpc server time to flush the shutdown
// response frame before the kernel halts.
const defaultShutdownDelay = 500 * time.Millisecond

// capabilities advertises which optional method families this build serves.
var capabilities = []string{"exec", "metrics", "runner", "resizeDisk", "cleanup", "shutdown"}

// Config configures a Service. Only RunnerDir and StateDir are required;
// everything else has a production-sane default.
type Config struct {
	// Version is the agent build version reported by agent.hello.
	Version string
	// RunnerDir is the actions-runner installation directory.
	RunnerDir string
	// RunnerUser is the unprivileged account the runner runs as.
	RunnerUser string
	// StateDir holds agent state that must survive a restart (cleanup epoch).
	StateDir string
	// RootPath is the filesystem reported as "disk" and grown by
	// agent.resizeDisk; overridable so tests never touch the real root.
	RootPath string
	// ExecAsRunner drops agent.exec privileges to the runner account.
	// Off by default: agent.exec is a host-initiated admin tool.
	ExecAsRunner bool
	// CleanupTempDirs overrides cleanup.DefaultTempDirs. Leave nil for the
	// production defaults; see the dev-mode guard in New.
	CleanupTempDirs []string
	// CleanupHome overrides the home directory whose caches agent.cleanup
	// empties; empty means the runner account's own home.
	CleanupHome string
	// CleanupExtraPaths are additional cleanup targets.
	CleanupExtraPaths []string
	// PruneDocker enables `docker system prune` during agent.cleanup.
	PruneDocker bool
	// MetricsWindow is the CPU sampling window for agent.getMetrics.
	MetricsWindow time.Duration
	// RunnerOnlineAfter is how long the runner must survive before
	// runnerStatus reports "online" instead of "starting".
	RunnerOnlineAfter time.Duration
	// ShutdownDelay is the pause between replying to agent.shutdown and
	// halting; tests set it long and cancel instead.
	ShutdownDelay time.Duration
	// PowerOff is the halt action, injectable so tests cannot shut down a
	// developer's machine.
	PowerOff func(context.Context) error
	// AllowHostDestructive disables host-safe-mode: agent.cleanup,
	// agent.resizeDisk and agent.shutdown run even when the agent cannot
	// confirm it is inside a VM. Dangerous; for guest image builds on real
	// hardware only.
	AllowHostDestructive bool
	// VMDetector overrides system.InVirtualMachine, the check host-safe-mode
	// is based on. Nil means system.InVirtualMachine; tests set this so
	// they never depend on (or are penalised by) the real hardware they
	// happen to run on.
	VMDetector func() (inVM bool, evidence string)
	Logger     *slog.Logger
}

// Service implements the guest protocol v1 method catalogue.
type Service struct {
	cfg     Config
	log     *slog.Logger
	account runner.Account
	runner  *runner.Manager
	cleaner *cleanup.Cleaner
	bootID  string
	started time.Time

	// hostSafeMode is true when the agent could not confirm it is running
	// inside a VM (and AllowHostDestructive was not set): agent.cleanup,
	// agent.resizeDisk and agent.shutdown refuse to run. Set once in New
	// and never mutated, so it is safe to read without the mutex.
	hostSafeMode bool

	mu           sync.Mutex
	shuttingDown bool
	everReady    bool
}

// New builds a Service. Resolving the runner account here means a
// misconfigured --runner-user fails at startup rather than on the first
// agent.startRunner from the host.
func New(cfg Config) (*Service, error) {
	if cfg.RunnerDir == "" {
		return nil, errors.New("agent: RunnerDir is required")
	}
	if cfg.StateDir == "" {
		return nil, errors.New("agent: StateDir is required")
	}
	if cfg.RunnerUser == "" {
		cfg.RunnerUser = "runner"
	}
	if cfg.RootPath == "" {
		cfg.RootPath = "/"
	}
	if cfg.MetricsWindow <= 0 {
		cfg.MetricsWindow = metrics.DefaultWindow
	}
	if cfg.ShutdownDelay <= 0 {
		cfg.ShutdownDelay = defaultShutdownDelay
	}
	if cfg.PowerOff == nil {
		cfg.PowerOff = system.PowerOff
	}
	log := cfg.Logger
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}

	account, err := runner.LookupAccount(cfg.RunnerUser)
	if err != nil {
		return nil, err
	}
	mgr, err := runner.New(runner.Config{
		Dir:         cfg.RunnerDir,
		Account:     account,
		OnlineAfter: cfg.RunnerOnlineAfter,
		Logger:      log,
	})
	if err != nil {
		return nil, err
	}
	cleanupHome := cfg.CleanupHome
	if cleanupHome == "" {
		cleanupHome = account.Home
	}
	// Safety rail. agent.cleanup deletes everything the runner owns in the
	// shared temp directories and empties its home caches. That is correct
	// in a throwaway guest, where the agent is root and the runner account
	// owns nothing but job residue. On a developer machine the same
	// defaults would erase the operator's own /tmp and ~/.cache, so the
	// destructive sweeps are opt-in whenever the agent is not root.
	if !account.Privileged && cfg.CleanupTempDirs == nil {
		log.Warn("cleanup: agent is not root; skipping temp and home sweeps",
			"hint", "set CleanupTempDirs/CleanupHome explicitly to enable them")
		cfg.CleanupTempDirs = []string{}
		cfg.PruneDocker = false // would delete the operator's own images
		if cfg.CleanupHome == "" {
			cleanupHome = ""
		}
	}
	cleaner, err := cleanup.New(cleanup.Config{
		RunnerDir:   cfg.RunnerDir,
		StateDir:    cfg.StateDir,
		RunnerHome:  cleanupHome,
		RunnerUID:   account.UID,
		TempDirs:    cfg.CleanupTempDirs,
		ExtraPaths:  cfg.CleanupExtraPaths,
		PruneDocker: cfg.PruneDocker,
		Logger:      log,
	})
	if err != nil {
		return nil, err
	}

	bootID, err := system.BootID()
	if err != nil {
		// A guest without a readable boot id is still serviceable; the
		// host only uses it to notice an unexpected reboot.
		log.Warn("boot id unavailable", "error", err.Error())
	}

	// Second safety rail, independent of the non-root check above: even a
	// root agent must not run agent.cleanup/resizeDisk/shutdown on real
	// hardware. This is what caught the incident that motivated it -- a
	// developer running the agent binary directly on their Mac, as root,
	// is privileged by the check above but is not a disposable guest.
	detectVM := cfg.VMDetector
	if detectVM == nil {
		detectVM = system.InVirtualMachine
	}
	inVM, evidence := detectVM()
	hostSafeMode := !cfg.AllowHostDestructive && !inVM
	if hostSafeMode {
		log.Warn("host-safe-mode: refusing agent.cleanup/resizeDisk/shutdown",
			"reason", "could not confirm the agent is running inside a virtual machine",
			"evidence", evidence,
			"hint", "pass --allow-host-destructive to override for guest image builds on real hardware")
	}

	return &Service{
		cfg:          cfg,
		log:          log,
		account:      account,
		runner:       mgr,
		cleaner:      cleaner,
		bootID:       bootID,
		started:      time.Now(),
		hostSafeMode: hostSafeMode,
	}, nil
}

// Register installs every guest protocol v1 method on srv.
func (s *Service) Register(srv *rpc.Server) {
	srv.Handle("agent.hello", rpc.ReadOnly, s.handleHello)
	srv.Handle("agent.health", rpc.ReadOnly, s.handleHealth)
	srv.Handle("agent.getInfo", rpc.ReadOnly, s.handleGetInfo)
	srv.Handle("agent.getMetrics", rpc.ReadOnly, s.handleGetMetrics)
	srv.Handle("agent.resizeDisk", rpc.IdempotentMutation, s.handleResizeDisk)
	srv.Handle("agent.startRunner", rpc.SingleShot, s.handleStartRunner)
	srv.Handle("agent.runnerStatus", rpc.ReadOnly, s.handleRunnerStatus)
	srv.Handle("agent.stopRunner", rpc.IdempotentMutation, s.handleStopRunner)
	srv.Handle("agent.cleanup", rpc.IdempotentMutation, s.handleCleanup)
	srv.Handle("agent.shutdown", rpc.SingleShot, s.handleShutdown)
	srv.HandleStream("agent.exec", s.handleExec)
}

// Account is the resolved runner identity; main.go logs it at startup.
func (s *Service) Account() runner.Account { return s.account }

// selfCheck runs the readiness probes behind agent.health, returning one
// human-readable reason per failure.
func (s *Service) selfCheck() []string {
	var reasons []string
	if err := s.runner.SelfCheck(); err != nil {
		reasons = append(reasons, err.Error())
	}
	if _, err := runner.LookupAccount(s.cfg.RunnerUser); err != nil {
		reasons = append(reasons, err.Error())
	}
	if err := probeWritable(s.cfg.StateDir); err != nil {
		reasons = append(reasons, err.Error())
	}
	return reasons
}

// probeWritable verifies the agent can persist state, which cleanup epochs
// depend on for idempotency.
func probeWritable(dir string) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("state dir %s: %w", dir, err)
	}
	probe := filepath.Join(dir, ".writable")
	if err := os.WriteFile(probe, []byte("ok"), 0o600); err != nil {
		return fmt.Errorf("state dir %s is not writable: %w", dir, err)
	}
	return os.Remove(probe)
}
