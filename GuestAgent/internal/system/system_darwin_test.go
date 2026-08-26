//go:build darwin

package system

import "testing"

// classifyHVVMMPresent is the pure decision behind inVirtualMachine on
// darwin; it is tested by feeding raw sysctl values instead of stubbing the
// syscall, per the package's existing convention for OS-specific facts.
func TestClassifyHVVMMPresent(t *testing.T) {
	cases := []struct {
		name string
		v    uint32
		want bool
	}{
		{"present", 1, true},
		{"absent", 0, false},
		{"unexpected value", 2, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, evidence := classifyHVVMMPresent(tc.v)
			if got != tc.want {
				t.Fatalf("classifyHVVMMPresent(%d) = %v, want %v", tc.v, got, tc.want)
			}
			if got && evidence == "" {
				t.Fatal("a positive detection must carry evidence")
			}
			if !got && evidence != "" {
				t.Fatalf("a negative detection must carry no evidence, got %q", evidence)
			}
		})
	}
}

// TestInVirtualMachineDoesNotPanic exercises the real sysctl call; the
// result is environment-dependent (CI runners, dev Macs, real VMs all
// differ) so only its shape is asserted.
func TestInVirtualMachineDoesNotPanic(t *testing.T) {
	ok, evidence := InVirtualMachine()
	if ok && evidence == "" {
		t.Fatal("a positive detection must carry evidence")
	}
}
