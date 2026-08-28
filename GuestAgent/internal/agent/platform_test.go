package agent

import (
	"slices"
	"testing"
)

// The base list is what the host has always seen; platform additions are
// appended, never interleaved, so an older host reading the prefix still
// understands it.
func TestCapabilitiesAppendThePlatformAdditionsToTheBaseList(t *testing.T) {
	if len(capabilities) != len(baseCapabilities)+len(platformCapabilities()) {
		t.Fatalf("capabilities = %v, want %v plus %v", capabilities, baseCapabilities, platformCapabilities())
	}
	for i, want := range baseCapabilities {
		if capabilities[i] != want {
			t.Fatalf("capabilities[%d] = %q, want %q (base order must stay stable)", i, capabilities[i], want)
		}
	}
	// agent.selfTest is registered unconditionally, so every platform must
	// advertise it -- off macOS it simply answers with no checks.
	if !slices.Contains(capabilities, "selfTest") {
		t.Fatalf("capabilities %v must advertise selfTest on every platform", capabilities)
	}
}
