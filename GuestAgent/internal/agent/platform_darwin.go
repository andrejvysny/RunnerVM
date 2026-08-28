//go:build darwin

package agent

import "github.com/runnervm/guest-agent/internal/keychain"

// platformCapabilities are the agent.hello capabilities a macOS guest adds
// to the base list: "ciKeychain" for the per-VM signing keychain
// agent.startRunner sets up, "selfTest" for the proof that it works.
func platformCapabilities() []string { return []string{"ciKeychain", "selfTest"} }

// newKeychainPreparer gives macOS guests a real per-VM CI keychain.
func newKeychainPreparer(cfg keychain.Config) keychain.Preparer { return keychain.NewPreparer(cfg) }
