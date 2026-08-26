//go:build linux

package system

import "testing"

// classifyDMI and classifyHypervisorType are the pure decisions behind
// inVirtualMachine on linux; both are tested by feeding strings instead of
// pointing at the real /sys tree.
func TestClassifyDMI(t *testing.T) {
	cases := []struct {
		name            string
		vendor, product string
		want            bool
	}{
		{"apple virtualization framework", "Apple Inc.", "Apple Virtualization Generic Platform", true},
		{"virtualization word split across fields", "Apple Inc.", "Virtualization Generic Platform", true},
		{"apple only", "Apple Inc.", "MacBookPro18,1", false},
		{"virtualization only", "QEMU", "Standard PC (Virtualization)", false},
		{"neither", "Dell Inc.", "PowerEdge R640", false},
		{"empty", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, evidence := classifyDMI(tc.vendor, tc.product)
			if got != tc.want {
				t.Fatalf("classifyDMI(%q, %q) = %v, want %v", tc.vendor, tc.product, got, tc.want)
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

func TestClassifyHypervisorType(t *testing.T) {
	cases := []struct {
		name    string
		content string
		exists  bool
		want    bool
	}{
		{"content present", "xen", true, true},
		{"exists but unreadable content (classic Xen)", "", true, true},
		{"absent", "", false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, evidence := classifyHypervisorType(tc.content, tc.exists)
			if got != tc.want {
				t.Fatalf("classifyHypervisorType(%q, %v) = %v, want %v", tc.content, tc.exists, got, tc.want)
			}
			if got && evidence == "" {
				t.Fatal("a positive detection must carry evidence")
			}
		})
	}
}

// TestReadTrimmedMissingFile documents that a missing/unreadable path is
// treated as "no evidence" rather than an error: every caller in this
// package only wants a best-effort string.
func TestReadTrimmedMissingFile(t *testing.T) {
	if got := readTrimmed("/nonexistent/path/for/system-package-tests"); got != "" {
		t.Fatalf("readTrimmed(missing) = %q, want empty", got)
	}
}

// TestInVirtualMachineDoesNotPanic exercises the real detection chain
// (DMI files, /sys/hypervisor/type, systemd-detect-virt); the result is
// environment-dependent so only its shape is asserted.
func TestInVirtualMachineDoesNotPanic(t *testing.T) {
	ok, evidence := InVirtualMachine()
	if ok && evidence == "" {
		t.Fatal("a positive detection must carry evidence")
	}
}
