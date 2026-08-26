// Package runner supervises the GitHub Actions runner process inside the
// guest: one single-shot session per VM, started as the unprivileged
// `runner` account with its own process group.
package runner

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/user"
	"strconv"
	"strings"
	"syscall"
)

// Account is the resolved unix identity the runner process gets.
type Account struct {
	Name   string
	UID    int
	GID    int
	Groups []uint32
	Home   string
	// Privileged reports whether the agent itself runs as root and can
	// therefore switch identity when spawning the runner.
	Privileged bool
}

// ErrUnprivileged is returned when the agent is not root and the requested
// runner account is somebody else: dropping privileges is impossible, and
// silently running the runner as the agent's own user would be a lie.
var ErrUnprivileged = errors.New("runner: agent is not root and cannot switch to another user")

// LookupAccount resolves name to a unix identity.
//
// Development mode: when the agent is not root, the only accepted name is
// the account the agent already runs as. No setuid is attempted and
// Credential returns nil, which is what makes the handler tests runnable on
// a developer's macOS host.
func LookupAccount(name string) (Account, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return Account{}, fmt.Errorf("runner: lookup user %q: %w", name, err)
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return Account{}, fmt.Errorf("runner: non-numeric uid %q: %w", u.Uid, err)
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return Account{}, fmt.Errorf("runner: non-numeric gid %q: %w", u.Gid, err)
	}

	acct := Account{
		Name:       u.Username,
		UID:        uid,
		GID:        gid,
		Home:       u.HomeDir,
		Privileged: os.Geteuid() == 0,
		Groups:     supplementaryGroups(u, gid),
	}
	if !acct.Privileged && uid != os.Geteuid() {
		return Account{}, fmt.Errorf("%w (agent uid %d, requested %q uid %d)",
			ErrUnprivileged, os.Geteuid(), name, uid)
	}
	return acct, nil
}

// Credential is the SysProcAttr credential for spawning the runner, or nil
// in development mode where no identity switch happens.
func (a Account) Credential() *syscall.Credential {
	if !a.Privileged {
		return nil
	}
	return &syscall.Credential{
		Uid:    uint32(a.UID),
		Gid:    uint32(a.GID),
		Groups: a.Groups,
	}
}

// supplementaryGroups returns the account's secondary groups (notably
// `docker`). os/user resolves them without cgo on Linux; where it cannot,
// /etc/group is parsed directly rather than losing docker access silently.
func supplementaryGroups(u *user.User, primary int) []uint32 {
	ids, err := u.GroupIds()
	if err == nil {
		return parseGroupIDs(ids, primary)
	}
	return groupsFromEtcGroup(u.Username, primary)
}

func parseGroupIDs(ids []string, primary int) []uint32 {
	out := make([]uint32, 0, len(ids)+1)
	seen := map[int]bool{}
	for _, id := range ids {
		gid, err := strconv.Atoi(id)
		if err != nil || seen[gid] {
			continue
		}
		seen[gid] = true
		out = append(out, uint32(gid))
	}
	if !seen[primary] {
		out = append(out, uint32(primary))
	}
	return out
}

func groupsFromEtcGroup(username string, primary int) []uint32 {
	f, err := os.Open("/etc/group")
	if err != nil {
		return []uint32{uint32(primary)}
	}
	defer f.Close()

	var ids []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		// name:passwd:gid:member,member
		parts := strings.Split(scanner.Text(), ":")
		if len(parts) < 4 {
			continue
		}
		for _, member := range strings.Split(parts[3], ",") {
			if member == username {
				ids = append(ids, parts[2])
			}
		}
	}
	return parseGroupIDs(ids, primary)
}
