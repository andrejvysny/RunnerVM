package runner

import (
	"errors"
	"os"
	"os/user"
	"testing"
)

// Development mode: a non-root agent may only "run as" the account it
// already is. This is what lets the handler tests run on a developer's
// machine without sudo.
func TestLookupAccountAcceptsSelfWhenUnprivileged(t *testing.T) {
	u, err := user.Current()
	if err != nil {
		t.Fatalf("user.Current: %v", err)
	}

	acct, err := LookupAccount(u.Username)
	if err != nil {
		t.Fatalf("LookupAccount(%q): %v", u.Username, err)
	}
	if acct.Name != u.Username {
		t.Fatalf("name = %q, want %q", acct.Name, u.Username)
	}
	if acct.UID != os.Getuid() {
		t.Fatalf("uid = %d, want %d", acct.UID, os.Getuid())
	}

	// No setuid is attempted when the agent is not root, so the child gets
	// the agent's own identity rather than a credential the kernel would
	// reject with EPERM.
	if os.Geteuid() != 0 && acct.Credential() != nil {
		t.Fatal("an unprivileged agent must not set a process credential")
	}
	if acct.Privileged != (os.Geteuid() == 0) {
		t.Fatalf("privileged = %v, geteuid = %d", acct.Privileged, os.Geteuid())
	}
}

func TestLookupAccountRejectsAnotherUserWhenUnprivileged(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: switching to another account is legitimate")
	}
	target := "nobody"
	if _, err := user.Lookup(target); err != nil {
		t.Skipf("no %q account on this host: %v", target, err)
	}

	if _, err := LookupAccount(target); !errors.Is(err, ErrUnprivileged) {
		t.Fatalf("LookupAccount(%q) = %v, want ErrUnprivileged", target, err)
	}
}

func TestLookupAccountRejectsUnknownUser(t *testing.T) {
	if _, err := LookupAccount("runnervm-no-such-account"); err == nil {
		t.Fatal("expected an error for an unknown account")
	}
}

// The primary gid must always be present, even when the account has no
// supplementary groups, or the spawned process would lose its own group.
func TestParseGroupIDsAlwaysIncludesPrimary(t *testing.T) {
	got := parseGroupIDs([]string{"20", "20", "bogus"}, 501)
	want := map[uint32]bool{20: true, 501: true}
	if len(got) != len(want) {
		t.Fatalf("groups = %v, want %v", got, want)
	}
	for _, g := range got {
		if !want[g] {
			t.Fatalf("unexpected gid %d in %v", g, got)
		}
	}
}
