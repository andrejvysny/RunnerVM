//go:build !darwin

package agent

import "github.com/runnervm/guest-agent/internal/keychain"

// platformCapabilities advertises agent.selfTest, which is callable
// everywhere (it just has nothing to report off macOS). "ciKeychain" is
// deliberately absent: a Linux guest signs nothing.
func platformCapabilities() []string { return []string{"selfTest"} }

// newKeychainPreparer returns nil so agent.startRunner behaves exactly as
// it did before the CI keychain existed.
func newKeychainPreparer(keychain.Config) keychain.Preparer { return nil }
