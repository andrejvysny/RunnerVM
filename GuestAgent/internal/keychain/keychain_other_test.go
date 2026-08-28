//go:build !darwin

package keychain

import (
	"context"
	"testing"
)

// Off macOS the package must be inert: agent.startRunner has to behave
// exactly as it did before the CI keychain existed.
func TestPreparerIsANoOp(t *testing.T) {
	sess, err := NewPreparer(Config{RunnerHome: "/home/runner"}).Prepare(context.Background(), "sess-1")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	if len(sess.Env()) != 0 {
		t.Fatalf("Env() = %v, want no entries", sess.Env())
	}
	if err := sess.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := sess.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}

func TestSelfTestReportsNoChecks(t *testing.T) {
	checks := SelfTest(context.Background(), Config{})
	if checks == nil {
		t.Fatal("SelfTest must return an empty slice, not nil")
	}
	if len(checks) != 0 {
		t.Fatalf("checks = %v, want none", checks)
	}
}
