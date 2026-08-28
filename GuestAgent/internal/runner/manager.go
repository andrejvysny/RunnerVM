package runner

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	osexec "os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/runnervm/guest-agent/internal/keychain"
	"github.com/runnervm/guest-agent/internal/system"
)

// Runner session states reported by agent.runnerStatus.
const (
	StateStarting = "starting"
	StateOnline   = "online"
	StateBusy     = "busy"
	StateExited   = "exited"
	StateUnknown  = "unknown"
)

// jitConfigEnvVar is how actions/runner accepts an ephemeral registration.
// The runner reads it in CommandSettings; passing it on argv would leak the
// credential to every process listing in the guest.
const jitConfigEnvVar = "ACTIONS_RUNNER_INPUT_JITCONFIG"

// workerProcessName is the child the runner forks per job; its presence is
// the primary "busy" signal.
const workerProcessName = "Runner.Worker"

// defaultOnlineAfter is how long a runner must survive before the agent
// stops calling it "starting"; below this a crash-looping runner would be
// reported as healthy.
const defaultOnlineAfter = 2 * time.Second

// defaultPath is used when the agent's own PATH is empty (systemd units
// start with a minimal environment). The runner needs a usable PATH to find
// git, docker and the shell.
const defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// sessionIDPattern constrains session ids because they become filenames.
var sessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// Errors distinguishable by the RPC layer for protocol error codes.
var (
	ErrAlreadyStarted = errors.New("runner: session already started")
	ErrBusy           = errors.New("runner: another session is running")
	ErrInvalidSession = errors.New("runner: invalid sessionId")
	// ErrKeychainUnavailable means the per-VM CI keychain could not be
	// created. The runner is not started: a job that signs with whatever
	// keychain happens to be lying around is the leak this prevents.
	ErrKeychainUnavailable = errors.New("runner: ci keychain unavailable")
)

// Config configures a Manager.
type Config struct {
	// Dir is the actions-runner installation directory.
	Dir string
	// Account is the identity the runner process runs as.
	Account Account
	// StartScript is the launcher inside Dir; defaults to "run.sh".
	StartScript string
	// OnlineAfter overrides the starting→online dwell time (tests).
	OnlineAfter time.Duration
	// KeychainPreparer creates the per-VM CI keychain handed to the runner
	// through the environment (macOS). Nil disables the feature entirely,
	// which is the Linux-guest behaviour.
	KeychainPreparer keychain.Preparer
	Logger           *slog.Logger
}

// StartRequest is one agent.startRunner call. JITConfig is a secret: it is
// never logged, never written to disk, and is zeroed once handed to the
// child process.
type StartRequest struct {
	SessionID string
	JITConfig []byte
	WorkDir   string
	Env       map[string]string
	Labels    []string
}

// StartResult is the agent.startRunner reply.
type StartResult struct {
	PID       int
	StartedAt time.Time
}

// Status is one agent.runnerStatus reply. ExitCode and ExitedAt are set
// only in StateExited.
type Status struct {
	State    string
	PID      int
	ExitCode *int
	ExitedAt *time.Time
}

// Manager owns at most one runner session for the lifetime of the guest.
type Manager struct {
	cfg Config
	log *slog.Logger

	mu      sync.Mutex
	current *session
}

type session struct {
	id        string
	pid       int
	startedAt time.Time
	logPath   string
	done      chan struct{}

	// keychain is the session's CI keychain, deleted once the runner is
	// gone. Nil when the platform has none.
	keychain     keychain.Session
	keychainOnce sync.Once

	exited   bool
	exitCode int
	exitedAt time.Time
}

// New validates cfg and returns a Manager. It does not touch the runner
// directory: a guest image may install the runner after the agent starts.
func New(cfg Config) (*Manager, error) {
	if cfg.Dir == "" {
		return nil, errors.New("runner: Dir is required")
	}
	if cfg.StartScript == "" {
		cfg.StartScript = "run.sh"
	}
	if cfg.OnlineAfter <= 0 {
		cfg.OnlineAfter = defaultOnlineAfter
	}
	log := cfg.Logger
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Manager{cfg: cfg, log: log}, nil
}

// SelfCheck reports whether the guest is provisioned well enough to start a
// runner. It feeds agent.health.
func (m *Manager) SelfCheck() error {
	script := filepath.Join(m.cfg.Dir, m.cfg.StartScript)
	info, err := os.Stat(script)
	if err != nil {
		return fmt.Errorf("runner: %s: %w", script, err)
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("runner: %s is not executable", script)
	}
	return nil
}

// Start launches the runner for sessionID. It is single-shot per session:
// re-starting the same id always fails, and a second id is rejected while
// the first session is still alive.
func (m *Manager) Start(ctx context.Context, req StartRequest) (StartResult, error) {
	if !sessionIDPattern.MatchString(req.SessionID) {
		return StartResult{}, fmt.Errorf("%w: %q", ErrInvalidSession, req.SessionID)
	}
	if len(req.JITConfig) == 0 {
		return StartResult{}, errors.New("runner: jitConfig is required")
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	if cur := m.current; cur != nil {
		if cur.id == req.SessionID {
			return StartResult{}, ErrAlreadyStarted
		}
		if !cur.exited {
			return StartResult{}, fmt.Errorf("%w: session %q is %s", ErrBusy, cur.id, StateOnline)
		}
	}

	sess, err := m.spawn(ctx, req)
	if err != nil {
		return StartResult{}, err
	}
	m.current = sess

	m.log.Info("runner started",
		"sessionId", sess.id, "pid", sess.pid, "log", sess.logPath,
		"labels", strings.Join(req.Labels, ","))
	return StartResult{PID: sess.pid, StartedAt: sess.startedAt}, nil
}

// spawn does the privileged work of Start. The caller holds m.mu.
func (m *Manager) spawn(ctx context.Context, req StartRequest) (*session, error) {
	script := filepath.Join(m.cfg.Dir, m.cfg.StartScript)
	if err := m.SelfCheck(); err != nil {
		return nil, err
	}
	if req.WorkDir != "" {
		if err := m.ensureDir(req.WorkDir, 0o755); err != nil {
			return nil, err
		}
	}
	kc, err := m.prepareKeychain(ctx, req.SessionID)
	if err != nil {
		return nil, err
	}
	// Every failure between here and a successful fork must take the
	// keychain with it; only a live runner is allowed to own one.
	spawned := false
	defer func() {
		if !spawned && kc != nil {
			_ = kc.Close()
		}
	}()

	logFile, logPath, err := m.openSessionLog(req.SessionID)
	if err != nil {
		return nil, err
	}
	defer logFile.Close() // the child keeps its own descriptor

	cmd := osexec.Command(script)
	cmd.Dir = m.cfg.Dir
	if req.WorkDir != "" {
		cmd.Dir = req.WorkDir
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Stdin = nil
	cmd.Env = m.childEnv(req, kc)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		// Own process group so stopRunner can signal the runner and every
		// job process it forked with a single kill(-pgid).
		Setpgid:    true,
		Credential: m.cfg.Account.Credential(),
	}

	startErr := cmd.Start()
	// The JIT config lives in two places after this point: the caller's
	// buffer (zeroed here) and the env string handed to the kernel by
	// execve (unreachable from Go, and gone with the child's address
	// space). Go strings are immutable, so the env slot is dropped rather
	// than overwritten.
	zero(req.JITConfig)
	for i := range cmd.Env {
		if strings.HasPrefix(cmd.Env[i], jitConfigEnvVar+"=") {
			cmd.Env[i] = jitConfigEnvVar + "=<redacted>"
		}
	}
	if startErr != nil {
		return nil, fmt.Errorf("runner: start %s: %w", script, startErr)
	}

	sess := &session{
		id:        req.SessionID,
		pid:       cmd.Process.Pid,
		startedAt: time.Now().UTC(),
		logPath:   logPath,
		done:      make(chan struct{}),
		keychain:  kc,
	}
	spawned = true
	go m.reap(sess, cmd)
	return sess, nil
}

// prepareKeychain creates the CI keychain this session's runner signs with.
// It is fail-closed: no keychain, no runner.
func (m *Manager) prepareKeychain(ctx context.Context, sessionID string) (keychain.Session, error) {
	if m.cfg.KeychainPreparer == nil {
		return nil, nil
	}
	kc, err := m.cfg.KeychainPreparer.Prepare(ctx, sessionID)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrKeychainUnavailable, err)
	}
	return kc, nil
}

// closeKeychain deletes the session's CI keychain. Both the exit path and
// the stop path call it, so it runs at most once.
func (s *session) closeKeychain(log *slog.Logger) {
	if s.keychain == nil {
		return
	}
	s.keychainOnce.Do(func() {
		if err := s.keychain.Close(); err != nil {
			log.Warn("ci keychain cleanup failed", "sessionId", s.id, "error", err.Error())
		}
	})
}

// reap records the runner's exit so runnerStatus can report it after the
// process is gone.
func (m *Manager) reap(sess *session, cmd *osexec.Cmd) {
	err := cmd.Wait()
	code := 0
	if err != nil {
		var exitErr *osexec.ExitError
		if errors.As(err, &exitErr) {
			code = exitErr.ExitCode()
		} else {
			code = -1
		}
	}

	m.mu.Lock()
	sess.exited = true
	sess.exitCode = code
	sess.exitedAt = time.Now().UTC()
	m.mu.Unlock()
	// The keychain must not outlive the process that was signing with it.
	sess.closeKeychain(m.log)
	close(sess.done)

	m.log.Info("runner exited", "sessionId", sess.id, "pid", sess.pid, "exitCode", code)
}

// Status reports the state of sessionID. An unknown id is never an error:
// the host may poll a session this guest never received.
func (m *Manager) Status(sessionID string) Status {
	m.mu.Lock()
	sess := m.current
	if sess == nil || sess.id != sessionID {
		m.mu.Unlock()
		return Status{State: StateUnknown}
	}
	pid, startedAt, logDir := sess.pid, sess.startedAt, m.cfg.Dir
	if sess.exited {
		code, at := sess.exitCode, sess.exitedAt
		m.mu.Unlock()
		return Status{State: StateExited, PID: pid, ExitCode: &code, ExitedAt: &at}
	}
	m.mu.Unlock()

	if time.Since(startedAt) < m.cfg.OnlineAfter {
		return Status{State: StateStarting, PID: pid}
	}
	if isBusy(pid, filepath.Join(logDir, "_diag"), startedAt) {
		return Status{State: StateBusy, PID: pid}
	}
	return Status{State: StateOnline, PID: pid}
}

// Stop terminates sessionID's process group: SIGTERM, then SIGKILL after
// grace. It reports whether the agent has seen that session's process end.
func (m *Manager) Stop(ctx context.Context, sessionID string, grace time.Duration) (bool, error) {
	m.mu.Lock()
	sess := m.current
	if sess == nil || sess.id != sessionID {
		m.mu.Unlock()
		return false, nil // nothing known about this session: no-op
	}
	if sess.exited {
		m.mu.Unlock()
		return true, nil
	}
	pid, done := sess.pid, sess.done
	m.mu.Unlock()
	// reap() closes it as soon as it observes the exit, but stopRunner must
	// not answer the host while the keychain could still be readable.
	defer sess.closeKeychain(m.log)

	m.log.Info("stopping runner", "sessionId", sessionID, "pid", pid, "graceMs", grace.Milliseconds())
	_ = syscall.Kill(-pid, syscall.SIGTERM)

	if waitFor(ctx, done, grace) {
		// The leader is reaped, but a job process it forked may still be
		// draining. Nothing in the group may outlive the session, so the
		// remainder is killed unconditionally.
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		return true, nil
	}
	m.log.Warn("runner ignored SIGTERM, killing process group", "sessionId", sessionID, "pid", pid)
	_ = syscall.Kill(-pid, syscall.SIGKILL)

	// SIGKILL is not refusable; bound the wait anyway so a wedged wait4
	// cannot hold the RPC open forever.
	return waitFor(ctx, done, 5*time.Second), nil
}

// RunningPID returns the live runner pid, or 0 when none is running. The
// metrics collector uses it to attribute per-process CPU and RSS.
func (m *Manager) RunningPID() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.current == nil || m.current.exited {
		return 0
	}
	return m.current.pid
}

func waitFor(ctx context.Context, done <-chan struct{}, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-done:
		return true
	case <-t.C:
		return false
	case <-ctx.Done():
		return false
	}
}

// isBusy reports whether a job is executing: either the runner's process
// group contains a Runner.Worker child, or the runner wrote a Worker_*.log
// after the session started (the log survives a worker that already exited,
// which keeps a job's tail end from looking idle).
func isBusy(pgid int, diagDir string, startedAt time.Time) bool {
	if procs, err := system.ListProcesses(); err == nil {
		for _, p := range procs {
			if p.PGID == pgid && p.PID != pgid && strings.Contains(p.Command, workerProcessName) {
				return true
			}
		}
	}
	entries, err := os.ReadDir(diagDir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), "Worker_") {
			continue
		}
		info, err := e.Info()
		if err == nil && info.ModTime().After(startedAt) {
			return true
		}
	}
	return false
}

// openSessionLog creates the per-session stdout/stderr capture file. Mode
// 0600 and runner ownership keep job output away from other guest accounts.
func (m *Manager) openSessionLog(sessionID string) (*os.File, string, error) {
	diag := filepath.Join(m.cfg.Dir, "_diag")
	if err := m.ensureDir(diag, 0o755); err != nil {
		return nil, "", err
	}
	path := filepath.Join(diag, "runnervm-"+sessionID+".log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, "", fmt.Errorf("runner: open session log: %w", err)
	}
	m.chown(path)
	return f, path, nil
}

func (m *Manager) ensureDir(path string, mode os.FileMode) error {
	if err := os.MkdirAll(path, mode); err != nil {
		return fmt.Errorf("runner: create %s: %w", path, err)
	}
	m.chown(path)
	return nil
}

// chown hands a path to the runner account. It is a no-op in development
// mode, where the agent is already running as that account.
func (m *Manager) chown(path string) {
	if !m.cfg.Account.Privileged {
		return
	}
	if err := os.Chown(path, m.cfg.Account.UID, m.cfg.Account.GID); err != nil {
		m.log.Warn("chown failed", "path", path, "error", err.Error())
	}
}

// childEnv builds the runner's environment explicitly rather than
// inheriting the agent's: a systemd/launchd daemon environment is not a
// login environment, and the runner needs HOME, PATH and TMPDIR to work.
func (m *Manager) childEnv(req StartRequest, kc keychain.Session) []string {
	acct := m.cfg.Account
	path := os.Getenv("PATH")
	if path == "" {
		path = defaultPath
	}
	home := acct.Home
	if home == "" {
		home = filepath.Join("/home", acct.Name)
	}
	tmp := "/tmp"

	// RUNNER_ALLOW_RUNASROOT is deliberately absent: run.sh must keep
	// refusing to run as root, which is a second line of defence behind
	// the credential switch.
	env := map[string]string{
		"PATH":             path,
		"HOME":             home,
		"USER":             acct.Name,
		"LOGNAME":          acct.Name,
		"TMPDIR":           tmp,
		"RUNNERVM_SESSION": req.SessionID,
	}
	if len(req.Labels) > 0 {
		env["RUNNERVM_LABELS"] = strings.Join(req.Labels, ",")
	}
	if req.WorkDir != "" {
		env["RUNNER_WORKDIR"] = req.WorkDir
	}
	// The CI keychain lands before the caller's entries, and the loop below
	// drops anything in its reserved namespace, so a host request can never
	// redirect the runner at a keychain the agent did not create.
	if kc != nil {
		for k, v := range kc.Env() {
			env[k] = v
		}
	}
	for k, v := range req.Env {
		if k == "" || strings.ContainsAny(k, "=\x00") || k == jitConfigEnvVar {
			continue // reject unrepresentable keys and secret smuggling
		}
		if strings.HasPrefix(k, keychain.EnvPrefix) {
			continue // reserved: see the keychain merge above
		}
		env[k] = v
	}

	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys) // deterministic env ordering aids debugging
	out := make([]string, 0, len(keys)+1)
	for _, k := range keys {
		out = append(out, k+"="+env[k])
	}
	// Appended last so no caller-supplied entry can shadow it.
	return append(out, jitConfigEnvVar+"="+string(req.JITConfig))
}

func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
