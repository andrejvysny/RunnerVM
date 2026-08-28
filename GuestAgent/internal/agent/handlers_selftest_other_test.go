//go:build !darwin

package agent

import "testing"

// A Linux guest signs nothing; the method stays callable so the host needs
// no per-platform branch.
func TestSelfTestHasNothingToProveOffDarwin(t *testing.T) {
	h := newHarness(t, nil)

	var res SelfTestResult
	h.call(t, "agent.selfTest", nil, &res)

	if len(res.Checks) != 0 {
		t.Fatalf("checks = %+v, want none", res.Checks)
	}
}
