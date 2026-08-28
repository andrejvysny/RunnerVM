//go:build darwin

package agent

import (
	"strings"
	"testing"
)

// A macOS guest signs, so it advertises the per-VM CI keychain as well.
func TestPlatformCapabilitiesOnDarwin(t *testing.T) {
	if got, want := strings.Join(platformCapabilities(), ","), "ciKeychain,selfTest"; got != want {
		t.Fatalf("platformCapabilities() = %s, want %s", got, want)
	}
}

func TestKeychainPreparerExistsOnDarwin(t *testing.T) {
	if newKeychainPreparer(keychainTestConfig()) == nil {
		t.Fatal("a macOS guest must get a keychain preparer")
	}
}
