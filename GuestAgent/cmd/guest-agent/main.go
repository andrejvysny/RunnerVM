// Command guest-agent runs inside RunnerVM guests and serves the host over
// virtio-socket (guest protocol v1, Proto/guest_agent.md). The host is the
// only client; every method it exposes is host-initiated.
//
// Must not copy code from cirruslabs/tart-guest-agent (FSL).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"

	"github.com/runnervm/guest-agent/internal/agent"
	"github.com/runnervm/guest-agent/internal/rpc"
	"github.com/runnervm/guest-agent/internal/vsock"
)

// version is stamped at build time with
// -ldflags "-X main.version=<v>"; "dev" identifies an unstamped build.
var version = "dev"

const (
	// vsockPort must match RunnerCore.HostConstants.guestAgentVsockPort.
	vsockPort = 4050
	// maxStreamBytes is the per-request stream budget from Proto/envelope.md.
	maxStreamBytes = 64 << 20
	// defaultStateDir survives agent restarts but not a re-imaged guest,
	// which is exactly the lifetime of a cleanup epoch.
	defaultStateDir = "/var/lib/runnervm-guest-agent"
)

type options struct {
	port                 uint
	listen               string
	runnerDir            string
	runnerUser           string
	stateDir             string
	execAsRunner         bool
	pruneDocker          bool
	allowHostDestructive bool
	logLevel             string
	showVersion          bool
}

func main() {
	opts := parseFlags()
	if opts.showVersion {
		fmt.Printf("runnervm-guest-agent %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
		return
	}

	log, err := newLogger(opts.logLevel)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := run(opts, log); err != nil {
		log.Error("guest-agent exited", "error", err.Error())
		os.Exit(1)
	}
}

func parseFlags() options {
	var opts options
	flag.UintVar(&opts.port, "port", vsockPort, "vsock port to listen on")
	flag.StringVar(&opts.listen, "listen", "",
		"development transport instead of vsock, e.g. tcp:127.0.0.1:4051")
	flag.StringVar(&opts.runnerDir, "runner-dir", defaultRunnerDir(),
		"actions-runner installation directory")
	flag.StringVar(&opts.runnerUser, "runner-user", "runner",
		"unprivileged account the runner process runs as")
	flag.StringVar(&opts.stateDir, "state-dir", defaultStateDir,
		"directory for agent state that must survive a restart")
	flag.BoolVar(&opts.execAsRunner, "exec-as-runner", false,
		"drop agent.exec privileges to the runner account")
	flag.BoolVar(&opts.pruneDocker, "cleanup-docker", true,
		"run `docker system prune -af` during agent.cleanup when docker is present")
	flag.BoolVar(&opts.allowHostDestructive, "allow-host-destructive", false,
		"dangerous; for guest image builds on real hardware only -- run agent.cleanup/"+
			"resizeDisk/shutdown even when the agent cannot confirm it is inside a virtual machine")
	flag.StringVar(&opts.logLevel, "log-level", "info", "debug|info|warn|error")
	flag.BoolVar(&opts.showVersion, "version", false, "print the agent version and exit")
	flag.Parse()
	return opts
}

func defaultRunnerDir() string {
	if runtime.GOOS == "darwin" {
		return "/Users/runner/actions-runner"
	}
	return "/opt/actions-runner"
}

func run(opts options, log *slog.Logger) error {
	svc, err := agent.New(agent.Config{
		Version:              version,
		RunnerDir:            opts.runnerDir,
		RunnerUser:           opts.runnerUser,
		StateDir:             opts.stateDir,
		ExecAsRunner:         opts.execAsRunner,
		PruneDocker:          opts.pruneDocker,
		AllowHostDestructive: opts.allowHostDestructive,
		Logger:               log,
	})
	if err != nil {
		return err
	}

	ln, err := listen(opts)
	if err != nil {
		return err
	}
	defer ln.Close()

	srv := rpc.NewServer(agent.Protocol, rpc.Limits{MaxStreamBytes: maxStreamBytes})
	svc.Register(srv)

	// SIGTERM is how systemd and launchd stop the agent; SIGINT is the
	// developer running it in a terminal.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	account := svc.Account()
	log.Info("guest-agent listening",
		"version", version, "os", runtime.GOOS, "arch", runtime.GOARCH,
		"addr", ln.Addr().String(), "runnerDir", opts.runnerDir,
		"runnerUser", account.Name, "runnerUid", account.UID,
		"privileged", account.Privileged, "stateDir", opts.stateDir,
		"allowHostDestructive", opts.allowHostDestructive)

	err = srv.Serve(ctx, ln)
	if errors.Is(err, context.Canceled) || errors.Is(err, net.ErrClosed) {
		log.Info("guest-agent stopped")
		return nil
	}
	return err
}

// listen selects the transport. vsock is the production path; --listen
// exists because AF_VSOCK cannot be opened outside a guest, so tests and
// manual runs need a loopback stand-in.
func listen(opts options) (net.Listener, error) {
	if opts.listen == "" {
		ln, err := vsock.Listen(uint32(opts.port))
		if err != nil {
			return nil, fmt.Errorf("listen vsock:%d: %w", opts.port, err)
		}
		return ln, nil
	}
	scheme, addr, ok := strings.Cut(opts.listen, ":")
	if !ok || scheme != "tcp" || addr == "" {
		return nil, fmt.Errorf("--listen must look like tcp:host:port, got %q", opts.listen)
	}
	ln, err := vsock.ListenTCPForTests(addr)
	if err != nil {
		return nil, fmt.Errorf("listen tcp %s: %w", addr, err)
	}
	return ln, nil
}

// newLogger emits structured JSON on stderr so systemd-journald and the
// launchd log capture both index the fields.
func newLogger(level string) (*slog.Logger, error) {
	var lvl slog.Level
	switch strings.ToLower(level) {
	case "debug":
		lvl = slog.LevelDebug
	case "info":
		lvl = slog.LevelInfo
	case "warn", "warning":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		return nil, fmt.Errorf("unknown --log-level %q", level)
	}
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: lvl})), nil
}
