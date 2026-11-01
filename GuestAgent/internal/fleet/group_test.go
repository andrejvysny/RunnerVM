package fleet

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/hashicorp/go-hclog"
	"gitlab.com/gitlab-org/fleeting/fleeting/provider"
	"golang.org/x/crypto/ssh"
)

var bg = context.Background()

func TestInitInfo(t *testing.T) {
	d := newFakeDaemon(t)
	g := &InstanceGroup{Socket: d.socket, Profile: "p"}
	info, err := g.Init(bg, hclog.NewNullLogger(), provider.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer g.Shutdown(bg)
	if info.ID != "runnervm/p" || info.MaxSize != 2 {
		t.Fatalf("info = %+v", info)
	}
	if g.leaseDur != 10*time.Minute {
		t.Fatalf("default lease = %s", g.leaseDur)
	}
}

func TestInitValidation(t *testing.T) {
	d := newFakeDaemon(t)
	for name, g := range map[string]*InstanceGroup{
		"missing profile": {Socket: d.socket},
		"bad lease":       {Socket: d.socket, Profile: "p", Lease: "soon"},
		"lease too short": {Socket: d.socket, Profile: "p", Lease: "30s"},
		"lease too long":  {Socket: d.socket, Profile: "p", Lease: "25h"},
		"no daemon":       {Socket: d.socket + ".nope", Profile: "p"},
	} {
		if _, err := g.Init(bg, hclog.NewNullLogger(), provider.Settings{}); err == nil {
			t.Errorf("%s: Init succeeded, want error", name)
		}
	}
}

func TestUpdateMapsStates(t *testing.T) {
	d := newFakeDaemon(t)
	d.instances["a"] = &fakeInstance{state: "creating"}
	d.instances["b"] = &fakeInstance{state: "running"}
	d.instances["c"] = &fakeInstance{state: "deleted"}
	d.instances["e"] = &fakeInstance{state: "weird"}
	g, _ := newGroup(t, d, nil, provider.Settings{})

	got := map[string]provider.State{}
	if err := g.Update(bg, func(id string, s provider.State) { got[id] = s }); err != nil {
		t.Fatal(err)
	}
	want := map[string]provider.State{"a": provider.StateCreating, "b": provider.StateRunning, "c": provider.StateDeleted, "e": provider.StateRunning}
	for id, s := range want {
		if got[id] != s {
			t.Errorf("%s = %q, want %q", id, got[id], s)
		}
	}
	owned := map[string]bool{}
	for _, id := range g.ownedIDs() {
		owned[id] = true
	}
	if !owned["a"] || !owned["b"] || !owned["e"] || owned["c"] {
		t.Fatalf("owned = %v", owned)
	}
}

func TestIncreasePartial(t *testing.T) {
	d := newFakeDaemon(t)
	d.maxCreate = 2
	g, _ := newGroup(t, d, nil, provider.Settings{})

	n, err := g.Increase(bg, 3)
	if n != 2 || err == nil {
		t.Fatalf("Increase = %d, %v; want 2 + error", n, err)
	}
	if len(g.ownedIDs()) != 2 {
		t.Fatalf("owned = %v", g.ownedIDs())
	}
}

func TestDecreaseIdempotent(t *testing.T) {
	d := newFakeDaemon(t)
	g, _ := newGroup(t, d, nil, provider.Settings{})
	if _, err := g.Increase(bg, 1); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		ok, err := g.Decrease(bg, []string{"i-1", "unknown"})
		if err != nil || len(ok) != 2 {
			t.Fatalf("Decrease #%d = %v, %v", i, ok, err)
		}
	}
	if len(g.ownedIDs()) != 0 {
		t.Fatalf("owned = %v", g.ownedIDs())
	}
}

func TestConnectInfo(t *testing.T) {
	d := newFakeDaemon(t)
	g, _ := newGroup(t, d, nil, provider.Settings{ConnectorConfig: provider.ConnectorConfig{Timeout: time.Minute}})
	if _, err := g.Increase(bg, 1); err != nil {
		t.Fatal(err)
	}

	if _, err := g.ConnectInfo(bg, "i-1"); err == nil || !strings.Contains(err.Error(), "not ready") {
		t.Fatalf("not-ready err = %v", err)
	}
	if len(g.keys) != 0 {
		t.Fatal("key cached on failed connect")
	}

	d.setReady("i-1")
	ci, err := g.ConnectInfo(bg, "i-1")
	if err != nil {
		t.Fatal(err)
	}
	// macos -> darwin, daemon-provided address/port/user.
	if ci.OS != "darwin" || ci.Arch != "arm64" || ci.Protocol != provider.ProtocolSSH ||
		ci.ProtocolPort != 22 || ci.Username != "runner" || ci.InternalAddr != "192.168.64.7" ||
		ci.ExternalAddr != "192.168.64.7" || ci.ID != "i-1" || ci.Timeout != time.Minute {
		t.Fatalf("ConnectInfo = %+v", ci.ConnectorConfig)
	}
	signer, err := ssh.ParsePrivateKey(ci.Key)
	if err != nil {
		t.Fatalf("private key: %v", err)
	}
	installed := d.keys["i-1"]
	if !strings.HasSuffix(installed, " runnervm-fleeting") || strings.ContainsAny(installed, "\n") {
		t.Fatalf("installed key = %q", installed)
	}
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(installed))
	if err != nil {
		t.Fatal(err)
	}
	if string(pub.Marshal()) != string(signer.PublicKey().Marshal()) {
		t.Fatal("installed public key does not match returned private key")
	}

	// Cached: same key returned and re-installed.
	ci2, err := g.ConnectInfo(bg, "i-1")
	if err != nil || string(ci2.Key) != string(ci.Key) || d.keys["i-1"] != installed {
		t.Fatalf("second ConnectInfo not served from cache: %v", err)
	}

	// Plugin restart: new group, empty cache => fresh key installed.
	g2, _ := newGroup(t, d, nil, provider.Settings{})
	ci3, err := g2.ConnectInfo(bg, "i-1")
	if err != nil {
		t.Fatal(err)
	}
	if string(ci3.Key) == string(ci.Key) || d.keys["i-1"] == installed {
		t.Fatal("restarted plugin reused the old key")
	}
}

func TestConnectInfoUsernameOverrideAndGuestOS(t *testing.T) {
	d := newFakeDaemon(t)
	d.guestOS = "linux"
	g, _ := newGroup(t, d, nil, provider.Settings{ConnectorConfig: provider.ConnectorConfig{Username: "ci"}})
	g.Increase(bg, 1)
	d.setReady("i-1")
	ci, err := g.ConnectInfo(bg, "i-1")
	if err != nil || ci.OS != "linux" || ci.Username != "ci" {
		t.Fatalf("ConnectInfo = %+v, %v", ci.ConnectorConfig, err)
	}
}

func TestConnectInfoStaticCredentialsUnsupported(t *testing.T) {
	d := newFakeDaemon(t)
	g, _ := newGroup(t, d, nil, provider.Settings{ConnectorConfig: provider.ConnectorConfig{UseStaticCredentials: true}})
	if _, err := g.ConnectInfo(bg, "i-1"); err == nil {
		t.Fatal("want error")
	}
}

func TestHeartbeat(t *testing.T) {
	d := newFakeDaemon(t)
	g, _ := newGroup(t, d, nil, provider.Settings{})
	g.Increase(bg, 1)
	if err := g.Heartbeat(bg, "i-1"); err != nil {
		t.Fatal(err)
	}
	if err := g.Heartbeat(bg, "gone"); !errors.Is(err, provider.ErrInstanceUnhealthy) {
		t.Fatalf("err = %v, want ErrInstanceUnhealthy", err)
	}
}

func TestSuspendResumeUnsupported(t *testing.T) {
	g := &InstanceGroup{}
	if _, err := g.Suspend(bg, nil); !errors.Is(err, provider.ErrSuspendResumeNotSupported) {
		t.Fatal(err)
	}
	if _, err := g.Resume(bg, nil); !errors.Is(err, provider.ErrSuspendResumeNotSupported) {
		t.Fatal(err)
	}
}

func TestRenewerDropsUnknownIDs(t *testing.T) {
	d := newFakeDaemon(t)
	g, ticks := newGroup(t, d, nil, provider.Settings{})
	g.Increase(bg, 2)
	d.mu.Lock()
	delete(d.instances, "i-2") // daemon reaped it
	d.mu.Unlock()

	ticks <- time.Now()
	ticks <- time.Now() // accepted only once the first pass finished
	if got := g.ownedIDs(); len(got) != 1 || got[0] != "i-1" {
		t.Fatalf("owned = %v, want [i-1]", got)
	}
	if d.callCount("fleet.renew") < 1 {
		t.Fatal("renewer never called fleet.renew")
	}
}

func TestShutdownStopsRenewerAndKeepsInstances(t *testing.T) {
	d := newFakeDaemon(t)
	g, ticks := newGroup(t, d, nil, provider.Settings{})
	g.Increase(bg, 1)
	if err := g.Shutdown(bg); err != nil {
		t.Fatal(err)
	}
	select {
	case ticks <- time.Now():
		t.Fatal("renewer still running after Shutdown")
	default:
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.instances["i-1"]; !ok {
		t.Fatal("Shutdown deleted an instance")
	}
	if d.calls["fleet.delete"] != 0 {
		t.Fatal("Shutdown called fleet.delete")
	}
}

func TestRedialAfterDaemonRestart(t *testing.T) {
	d := newFakeDaemon(t)
	g, _ := newGroup(t, d, nil, provider.Settings{})
	if _, err := g.Increase(bg, 1); err != nil {
		t.Fatal(err)
	}
	d.restart()
	if err := g.Update(bg, func(string, provider.State) {}); err != nil {
		t.Fatalf("Update after restart: %v", err)
	}
}
