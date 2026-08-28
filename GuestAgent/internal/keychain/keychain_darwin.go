//go:build darwin

package keychain

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// keychainFileName is the per-VM CI keychain, created under
// <RunnerHome>/Library/Keychains. The .keychain-db suffix selects the
// modern (v2) format; a bare .keychain name would create a legacy one.
const keychainFileName = "runnervm-ci.keychain-db"

// commandTimeout bounds a single tool invocation. `security` talks to
// securityd, which can wedge; a runner start must fail rather than hang.
const commandTimeout = 30 * time.Second

type darwinPreparer struct{ cfg Config }

func newPreparer(cfg Config) Preparer { return &darwinPreparer{cfg: cfg} }

// Prepare creates a fresh, empty, unlocked keychain and makes it the only
// entry in the runner account's search list. It is fail-closed: any step
// that does not exit 0 aborts the whole preparation, and the caller must
// not start a runner without a keychain.
func (p *darwinPreparer) Prepare(ctx context.Context, sessionID string) (Session, error) {
	if p.cfg.RunnerHome == "" {
		return nil, errors.New("keychain: RunnerHome is required")
	}
	path := filepath.Join(p.cfg.RunnerHome, "Library", "Keychains", keychainFileName)
	if err := p.ensureDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	password, err := newPassword()
	if err != nil {
		return nil, err
	}
	sess := &darwinSession{cfg: p.cfg, path: path, password: password}

	// Best effort: a keychain file left behind by a crashed previous run
	// would make create-keychain fail, and its password died with that run,
	// so deleting it is the only useful move. A missing file errors here
	// and is ignored.
	_ = sess.run(ctx, "delete-keychain", path)

	steps := [][]string{
		{"create-keychain", "-p", password, path},
		// No -l/-u/-t: the CI keychain must never auto-lock or time out, or
		// a long job would start failing to sign halfway through.
		{"set-keychain-settings", path},
		{"unlock-keychain", "-p", password, path},
		// The search list is replaced, not extended: a RunnerVM guest image
		// has no login keychain to preserve, and leaving anything else
		// searchable would let a job reach a keychain it does not own.
		{"list-keychains", "-d", "user", "-s", path},
		{"default-keychain", "-d", "user", "-s", path},
		// Proof the keychain exists and is readable as the runner account,
		// rather than trusting the exit codes above.
		{"show-keychain-info", path},
	}
	for _, args := range steps {
		if err := sess.run(ctx, args...); err != nil {
			_ = sess.Close()
			return nil, err
		}
	}

	p.cfg.Logger.Info("ci keychain ready", "sessionId", sessionID, "path", path)
	return sess, nil
}

// ensureDir creates ~/Library/Keychains for the runner account. When the
// agent is root the directory must end up owned by the runner, or every
// `security` call below (which runs as the runner) fails on permissions.
func (p *darwinPreparer) ensureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("keychain: create %s: %w", dir, err)
	}
	if c := p.cfg.Credential; c != nil {
		if err := os.Chown(dir, int(c.Uid), int(c.Gid)); err != nil {
			return fmt.Errorf("keychain: chown %s: %w", dir, err)
		}
	}
	return nil
}

// darwinSession is one prepared keychain.
type darwinSession struct {
	cfg      Config
	path     string
	password string

	once sync.Once
	err  error
}

func (s *darwinSession) Env() map[string]string {
	return map[string]string{
		EnvKeychainPath:     s.path,
		EnvKeychainPassword: s.password,
	}
}

// Close deletes the keychain. It runs at most once; later calls repeat the
// first result, so the runner manager can close on both the exit path and
// the stop path without deleting somebody else's keychain.
func (s *darwinSession) Close() error {
	s.once.Do(func() {
		// A fresh context: the keychain must be deleted even when the RPC
		// that owned the runner has already been cancelled.
		ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
		defer cancel()
		s.err = s.run(ctx, "delete-keychain", s.path)
		if s.err == nil {
			s.cfg.Logger.Info("ci keychain deleted", "path", s.path)
		}
	})
	return s.err
}

func (s *darwinSession) run(ctx context.Context, args ...string) error {
	_, err := run(ctx, s.cfg, s.cfg.SecurityPath, s.password, args...)
	return err
}

// run executes one keychain tool invocation and returns its stdout.
//
// SECURITY: the keychain password is passed on argv because `security` has
// no way to read one from stdin, which makes the argv itself secret. It is
// therefore NEVER logged -- only the tool name and its subcommand are --
// and `secret` is redacted out of whatever the tool wrote to stderr before
// that text reaches a log line or an RPC error message. (argv is still
// visible to a `ps` inside this guest for the lifetime of the call; the
// guest is single-tenant and thrown away after one job, which is the same
// trust boundary the JIT config already relies on.)
func run(ctx context.Context, cfg Config, tool, secret string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()

	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	name := filepath.Base(tool)
	cfg.Logger.Debug("keychain: running tool", "tool", name, "subcommand", sub)

	cmd := exec.CommandContext(ctx, tool, args...)
	cmd.Env = toolEnv(cfg)
	if cfg.Credential != nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: cfg.Credential}
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr

	stdout, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return "", fmt.Errorf("keychain: %s %s: %s", name, sub, redact(detail, secret))
	}
	return string(stdout), nil
}

// toolEnv is the environment the keychain tools run with. It is built
// explicitly: `security` resolves the user domain from HOME, and the agent
// itself is a daemon whose environment says nothing about the runner
// account.
func toolEnv(cfg Config) []string {
	env := make([]string, 0, 2)
	if cfg.RunnerHome != "" {
		env = append(env, "HOME="+cfg.RunnerHome)
	}
	if cfg.User != "" {
		env = append(env, "USER="+cfg.User)
	}
	return env
}

// redact removes a secret from text that is about to be logged or returned
// to the host.
func redact(text, secret string) string {
	if secret == "" {
		return text
	}
	return strings.ReplaceAll(text, secret, "<redacted>")
}
