//go:build !darwin

package agent

import (
	"strings"
	"testing"
)

// A Linux guest has no keychain: "ciKeychain" must not be advertised, but
// agent.selfTest stays callable.
func TestPlatformCapabilitiesOffDarwin(t *testing.T) {
	if got, want := strings.Join(platformCapabilities(), ","), "selfTest"; got != want {
		t.Fatalf("platformCapabilities() = %s, want %s", got, want)
	}
}

func TestNoKeychainPreparerOffDarwin(t *testing.T) {
	if newKeychainPreparer(keychainTestConfig()) != nil {
		t.Fatal("agent.startRunner must keep its pre-keychain behaviour off macOS")
	}
}
