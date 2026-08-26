package exec

import (
	"slices"
	"testing"
)

func TestMergeEnvOverridesAndSorts(t *testing.T) {
	got := mergeEnv(
		map[string]string{"PATH": "/bin", "HOME": "/root"},
		map[string]string{"HOME": "/home/runner", "EXTRA": "1"},
	)
	want := []string{"EXTRA=1", "HOME=/home/runner", "PATH=/bin"}
	if !slices.Equal(got, want) {
		t.Fatalf("mergeEnv = %v, want %v", got, want)
	}
}

// Keys that cannot be represented in an environment block are dropped
// rather than corrupting the child's environment.
func TestMergeEnvDropsUnrepresentableKeys(t *testing.T) {
	got := mergeEnv(nil, map[string]string{"": "x", "A=B": "y", "C\x00D": "z", "OK": "1"})
	if !slices.Equal(got, []string{"OK=1"}) {
		t.Fatalf("mergeEnv = %v, want [OK=1]", got)
	}
}
