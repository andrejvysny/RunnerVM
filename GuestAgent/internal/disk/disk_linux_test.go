//go:build linux

package disk

import "testing"

// findMount reads the real /proc/self/mountinfo, so the parser is exercised
// against the running kernel's own output.
func TestFindMountRoot(t *testing.T) {
	m, err := findMount("/")
	if err != nil {
		t.Fatalf("findMount(/): %v", err)
	}
	if m.mountPoint != "/" || m.fsType == "" || m.source == "" {
		t.Fatalf("implausible mount entry: %+v", m)
	}
}

func TestFindMountUnknownTarget(t *testing.T) {
	if _, err := findMount("/definitely/not/a/mount/point"); err == nil {
		t.Fatal("expected an error for an unmounted path")
	}
}
