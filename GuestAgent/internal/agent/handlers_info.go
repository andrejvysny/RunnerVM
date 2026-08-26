package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/runnervm/guest-agent/internal/metrics"
	"github.com/runnervm/guest-agent/internal/rpc"
	"github.com/runnervm/guest-agent/internal/system"
)

// probeTimeout bounds the external version probes behind agent.getInfo.
// The host calls getInfo on the boot path, so a wedged docker daemon must
// not stall VM readiness.
const probeTimeout = 2 * time.Second

func (s *Service) handleHello(ctx context.Context, req rpc.Envelope) (any, error) {
	return HelloResult{
		ProtocolVersion: ProtocolVersion,
		AgentVersion:    s.cfg.Version,
		OS:              runtime.GOOS,
		Arch:            runtime.GOARCH,
		Hostname:        system.Hostname(),
		BootID:          s.bootID,
		Capabilities:    capabilities,
	}, nil
}

// handleHealth re-runs the self-check on every call: the host polls health
// while waiting for the guest to become usable, so a cached answer would
// defeat the readiness gate.
func (s *Service) handleHealth(ctx context.Context, req rpc.Envelope) (any, error) {
	s.mu.Lock()
	shuttingDown := s.shuttingDown
	s.mu.Unlock()
	if shuttingDown {
		return HealthResult{State: HealthShuttingDown, Reasons: []string{}}, nil
	}

	reasons := s.selfCheck()
	state := HealthReady
	if len(reasons) == 0 {
		s.mu.Lock()
		s.everReady = true
		s.mu.Unlock()
	} else {
		s.mu.Lock()
		everReady := s.everReady
		s.mu.Unlock()
		// Before the first ready answer, a failing probe usually means the
		// image is still finishing boot; after it, something broke.
		if !everReady && time.Since(s.started) < startupGrace {
			state = HealthStarting
		} else {
			state = HealthDegraded
		}
	}

	// host-safe-mode is informational, not a readiness failure: it does not
	// change state, it only tells the host why the destructive methods are
	// refused.
	if s.hostSafeMode {
		reasons = append(reasons, "host-safe-mode")
	}
	if reasons == nil {
		reasons = []string{}
	}
	return HealthResult{State: state, Reasons: reasons}, nil
}

func (s *Service) handleGetInfo(ctx context.Context, req rpc.Envelope) (any, error) {
	uptime, err := system.UptimeSeconds()
	if err != nil {
		s.log.Warn("uptime unavailable", "error", err.Error())
	}
	kernel, err := system.KernelVersion()
	if err != nil {
		s.log.Warn("kernel version unavailable", "error", err.Error())
	}

	addrs := system.IPAddresses()
	if addrs == nil {
		addrs = []string{}
	}
	return InfoResult{
		IPAddresses:   addrs,
		UptimeSec:     uptime,
		Kernel:        kernel,
		RunnerVersion: s.runnerVersion(ctx),
		DockerVersion: dockerVersion(ctx),
	}, nil
}

func (s *Service) handleGetMetrics(ctx context.Context, req rpc.Envelope) (any, error) {
	return metrics.Collect(ctx, metrics.Options{
		RootPath:  s.cfg.RootPath,
		RunnerPID: s.runner.RunningPID(),
		Window:    s.cfg.MetricsWindow,
	}), nil
}

// runnerVersion prefers the plain-text version file the actions-runner
// package ships, because invoking Runner.Listener costs a .NET start-up on
// a call the host makes during boot.
func (s *Service) runnerVersion(ctx context.Context) string {
	if b, err := os.ReadFile(filepath.Join(s.cfg.RunnerDir, "bin", "runnerversion")); err == nil {
		if v := strings.TrimSpace(string(b)); v != "" {
			return v
		}
	}
	listener := filepath.Join(s.cfg.RunnerDir, "bin", "Runner.Listener")
	if _, err := os.Stat(listener); err != nil {
		return ""
	}
	out, err := probe(ctx, listener, "--version")
	if err != nil {
		return ""
	}
	return out
}

func dockerVersion(ctx context.Context) string {
	out, err := probe(ctx, "docker", "version", "--format", "{{.Server.Version}}")
	if err != nil {
		return ""
	}
	return out
}

// probe runs a short-lived informational command and returns its trimmed
// first line; any failure means "unknown", never an RPC error.
func probe(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return "", err
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	return strings.TrimSpace(line), nil
}
