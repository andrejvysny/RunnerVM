package fleet

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/andrejvysny/RunnerVM/GuestAgent/internal/rpc"
	"github.com/hashicorp/go-hclog"
	"gitlab.com/gitlab-org/fleeting/fleeting/provider"
)

type fakeInstance struct {
	state string
	ready bool
}

// fakeDaemon serves fleet.* on a unix socket with the real rpc.Server.
type fakeDaemon struct {
	t      *testing.T
	socket string

	mu        sync.Mutex
	instances map[string]*fakeInstance
	nextID    int
	maxCreate int // create fails after this many (0 = unlimited)
	created   int
	guestOS   string
	keys      map[string]string // id -> last installed public key
	calls     map[string]int

	ln     net.Listener
	cancel context.CancelFunc
	done   chan struct{}
	conns  *connTracker
}

type connTracker struct {
	net.Listener
	mu    sync.Mutex
	conns []net.Conn
}

func (c *connTracker) Accept() (net.Conn, error) {
	conn, err := c.Listener.Accept()
	if err == nil {
		c.mu.Lock()
		c.conns = append(c.conns, conn)
		c.mu.Unlock()
	}
	return conn, err
}

func (c *connTracker) closeAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, conn := range c.conns {
		_ = conn.Close()
	}
	c.conns = nil
}

func newFakeDaemon(t *testing.T) *fakeDaemon {
	t.Helper()
	dir, err := os.MkdirTemp("", "rvm")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	d := &fakeDaemon{
		t: t, socket: filepath.Join(dir, "d.sock"),
		instances: map[string]*fakeInstance{}, keys: map[string]string{},
		calls: map[string]int{}, guestOS: "macos",
	}
	d.start()
	t.Cleanup(d.stop)
	return d
}

func rpcErr(code string) error { return &rpc.RPCError{Code: code, Message: code} }

func decode[T any](req rpc.Envelope) T {
	var v T
	_ = json.Unmarshal(req.Payload, &v)
	return v
}

func (d *fakeDaemon) handle(srv *rpc.Server, method string, fn func(rpc.Envelope) (any, error)) {
	srv.Handle(method, rpc.IdempotentMutation, func(_ context.Context, req rpc.Envelope) (any, error) {
		d.mu.Lock()
		defer d.mu.Unlock()
		d.calls[method]++
		return fn(req)
	})
}

func (d *fakeDaemon) start() {
	srv := rpc.NewServer("daemon", rpc.Limits{})
	d.handle(srv, "fleet.info", func(rpc.Envelope) (any, error) {
		return infoResponse{Profile: "p", GuestOS: d.guestOS, Arch: "arm64", SSHUser: "runner", MaxInstances: 2}, nil
	})
	d.handle(srv, "fleet.list", func(rpc.Envelope) (any, error) {
		out := listResponse{Instances: []listedInstance{}}
		for id, in := range d.instances {
			out.Instances = append(out.Instances, listedInstance{ID: id, State: in.state})
		}
		return out, nil
	})
	d.handle(srv, "fleet.create", func(rpc.Envelope) (any, error) {
		if d.maxCreate > 0 && d.created >= d.maxCreate {
			return nil, rpcErr("CAPACITY")
		}
		d.created++
		d.nextID++
		id := fmt.Sprintf("i-%d", d.nextID)
		d.instances[id] = &fakeInstance{state: "creating"}
		return createResponse{ID: id, LeaseUntil: "2026-01-01T00:00:00Z"}, nil
	})
	d.handle(srv, "fleet.delete", func(req rpc.Envelope) (any, error) {
		r := decode[deleteRequest](req)
		delete(d.instances, r.ID)
		return deleteResponse{ID: r.ID, Accepted: true}, nil
	})
	d.handle(srv, "fleet.renew", func(req rpc.Envelope) (any, error) {
		r := decode[renewRequest](req)
		out := renewResponse{Renewed: []string{}}
		for _, id := range r.IDs {
			if _, ok := d.instances[id]; ok {
				out.Renewed = append(out.Renewed, id)
			}
		}
		return out, nil
	})
	d.handle(srv, "fleet.connect", func(req rpc.Envelope) (any, error) {
		r := decode[connectRequest](req)
		in, ok := d.instances[r.ID]
		if !ok {
			return nil, rpcErr("FLEET_INSTANCE_NOT_FOUND")
		}
		if !in.ready {
			return nil, rpcErr("FLEET_INSTANCE_NOT_READY")
		}
		d.keys[r.ID] = r.PublicKey
		return connectResponse{ID: r.ID, Address: "192.168.64.7", Port: 22, User: "runner", GuestOS: d.guestOS, Arch: "arm64"}, nil
	})

	ln, err := net.Listen("unix", d.socket)
	if err != nil {
		d.t.Fatal(err)
	}
	d.conns = &connTracker{Listener: ln}
	d.ln = ln
	ctx, cancel := context.WithCancel(context.Background())
	d.cancel = cancel
	d.done = make(chan struct{})
	go func() {
		defer close(d.done)
		_ = srv.Serve(ctx, d.conns)
	}()
}

// stop simulates a daemon exit: listener and every open connection close.
func (d *fakeDaemon) stop() {
	if d.cancel == nil {
		return
	}
	d.cancel()
	d.conns.closeAll()
	<-d.done
	d.cancel = nil
}

func (d *fakeDaemon) restart() {
	d.stop()
	d.start()
}

func (d *fakeDaemon) callCount(m string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.calls[m]
}

func (d *fakeDaemon) setReady(id string) {
	d.mu.Lock()
	d.instances[id].ready = true
	d.instances[id].state = "running"
	d.mu.Unlock()
}

// newGroup builds an initialised group. The returned channel is the renewer
// clock: a second send is only accepted after the first renewal pass ended.
func newGroup(t *testing.T, d *fakeDaemon, mutate func(*InstanceGroup), settings provider.Settings) (*InstanceGroup, chan time.Time) {
	t.Helper()
	g := &InstanceGroup{Socket: d.socket, Profile: "p"}
	if mutate != nil {
		mutate(g)
	}
	ch := make(chan time.Time)
	g.newTicker = func(time.Duration) (<-chan time.Time, func()) { return ch, func() {} }
	if _, err := g.Init(context.Background(), hclog.NewNullLogger(), settings); err != nil {
		t.Fatalf("Init: %v", err)
	}
	t.Cleanup(func() { _ = g.Shutdown(context.Background()) })
	return g, ch
}
