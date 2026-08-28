// Package keychain creates the throwaway macOS keychain a GitHub Actions
// job signs with. Each VM gets its own: created empty immediately before
// the runner starts, unlocked with a password only this agent knows, handed
// to the runner through the environment, and deleted the moment the runner
// exits. Nothing signed by one job is reachable from the next, and no
// keychain survives the guest.
//
// The implementation is macOS-only; on every other platform NewPreparer
// returns a preparer that does nothing, so the runner package can call it
// unconditionally.
package keychain

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"syscall"
)

// Environment variables the runner process receives on macOS. The password
// is in the environment because that is the only channel `security` and
// `codesign` can be driven from inside a job step; it is worthless outside
// this VM, which is destroyed with the keychain.
const (
	// EnvKeychainPath names the keychain file.
	EnvKeychainPath = "RUNNERVM_CI_KEYCHAIN"
	// EnvKeychainPassword unlocks it.
	EnvKeychainPassword = "RUNNERVM_CI_KEYCHAIN_PASSWORD"
	// EnvPrefix is reserved by the agent: a caller-supplied env entry whose
	// key starts with it is dropped by agent.startRunner, so a host request
	// can never point the runner at a keychain the agent did not create.
	EnvPrefix = "RUNNERVM_CI_KEYCHAIN"
)

// Default absolute paths of the macOS tools the keychain is built with.
// They are absolute so nothing on PATH can shadow them.
const (
	DefaultSecurityPath = "/usr/bin/security"
	DefaultOpenSSLPath  = "/usr/bin/openssl"
	DefaultCodesignPath = "/usr/bin/codesign"
)

// passwordBytes is the entropy behind the keychain password; it is
// hex-encoded, so the password itself is twice as many characters.
const passwordBytes = 32

// Session is one prepared keychain. Env is merged into the runner's
// environment; Close deletes the keychain and is safe to call more than
// once.
type Session interface {
	Env() map[string]string
	Close() error
}

// Preparer creates a Session per runner session id.
type Preparer interface {
	Prepare(ctx context.Context, sessionID string) (Session, error)
}

// Check is one agent.selfTest result row.
type Check struct {
	Name   string
	OK     bool
	Detail string
}

// Config configures a Preparer and SelfTest. Only RunnerHome is required;
// the tool paths exist so tests can point at stubs instead of driving the
// real macOS keychain of whoever runs the suite.
type Config struct {
	// RunnerHome is the runner account's home directory. The keychain is
	// created under <RunnerHome>/Library/Keychains and every tool runs with
	// HOME set to it.
	RunnerHome string
	// User is the runner account name, exported as USER to the tools.
	User string
	// SecurityPath, OpenSSLPath and CodesignPath default to the constants
	// above when empty.
	SecurityPath string
	OpenSSLPath  string
	CodesignPath string
	// Credential is the identity the tools run as; nil means "the account
	// the agent already runs as" (development mode, see runner.Account).
	Credential *syscall.Credential
	Logger     *slog.Logger
}

// withDefaults fills in the production tool paths and a no-op logger.
func (c Config) withDefaults() Config {
	if c.SecurityPath == "" {
		c.SecurityPath = DefaultSecurityPath
	}
	if c.OpenSSLPath == "" {
		c.OpenSSLPath = DefaultOpenSSLPath
	}
	if c.CodesignPath == "" {
		c.CodesignPath = DefaultCodesignPath
	}
	if c.Logger == nil {
		c.Logger = slog.New(slog.DiscardHandler)
	}
	return c
}

// NewPreparer returns the platform's keychain preparer.
func NewPreparer(cfg Config) Preparer { return newPreparer(cfg.withDefaults()) }

// SelfTest proves that a certificate injected into a RunnerVM-created
// keychain can actually sign code, which is the one property the whole
// feature exists for and the one thing a boot-time health probe cannot
// infer. It runs entirely in a temporary keychain and directory, never the
// session keychain, and returns one Check per step in execution order,
// stopping at the first failure. On non-macOS guests it returns no checks.
func SelfTest(ctx context.Context, cfg Config) []Check {
	return selfTest(ctx, cfg.withDefaults())
}

// newPassword returns a fresh hex-encoded keychain password.
func newPassword() (string, error) {
	buf := make([]byte, passwordBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("keychain: read random: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
