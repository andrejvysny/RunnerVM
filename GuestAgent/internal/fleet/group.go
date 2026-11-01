package fleet

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/hashicorp/go-hclog"
	"gitlab.com/gitlab-org/fleeting/fleeting/provider"
)

const (
	defaultSocket = "/var/run/runnervm/runnerd.sock"
	defaultLease  = 10 * time.Minute
	minLease      = time.Minute
	maxLease      = 24 * time.Hour
)

// InstanceGroup is the RunnerVM fleeting provider. The exported fields are
// the plugin_config keys gitlab-runner passes in.
//
// use_static_credentials is not supported: the guest address is only known
// after fleet.connect, which needs a per-instance public key.
type InstanceGroup struct {
	Socket  string `json:"socket"`
	Profile string `json:"profile"`
	Lease   string `json:"lease"`

	log      hclog.Logger
	cli      *client
	leaseDur time.Duration
	settings provider.ConnectorConfig
	guestOS  string
	arch     string
	sshUser  string

	// newTicker is the renewer clock; tests replace it.
	newTicker func(d time.Duration) (<-chan time.Time, func())

	mu    sync.Mutex
	owned map[string]struct{} // live instance ids whose lease we renew
	keys  map[string]keyPair  // instance id -> installed key

	connectMu sync.Mutex // serialises key generation + fleet.connect

	cancel context.CancelFunc
	wg     sync.WaitGroup
}

var _ provider.InstanceGroup = (*InstanceGroup)(nil)

func realTicker(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTicker(d)
	return t.C, t.Stop
}

func (g *InstanceGroup) Init(ctx context.Context, logger hclog.Logger, settings provider.Settings) (provider.ProviderInfo, error) {
	if g.Profile == "" {
		return provider.ProviderInfo{}, errors.New("plugin_config: profile is required")
	}
	if g.Socket == "" {
		g.Socket = defaultSocket
	}
	g.leaseDur = defaultLease
	if g.Lease != "" {
		d, err := time.ParseDuration(g.Lease)
		if err != nil {
			return provider.ProviderInfo{}, fmt.Errorf("plugin_config: invalid lease %q: %w", g.Lease, err)
		}
		g.leaseDur = d
	}
	if g.leaseDur < minLease || g.leaseDur > maxLease {
		return provider.ProviderInfo{}, fmt.Errorf("plugin_config: lease %s out of range %s..%s", g.leaseDur, minLease, maxLease)
	}
	if logger == nil {
		logger = hclog.NewNullLogger()
	}
	g.log = logger
	g.settings = settings.ConnectorConfig
	g.cli = newClient(g.Socket)
	g.owned = make(map[string]struct{})
	g.keys = make(map[string]keyPair)
	if g.newTicker == nil {
		g.newTicker = realTicker
	}

	info, err := g.cli.info(ctx, g.Profile)
	if err != nil {
		g.cli.close()
		return provider.ProviderInfo{}, fmt.Errorf("fleet.info: %w", err)
	}
	g.guestOS, g.arch, g.sshUser = info.GuestOS, info.Arch, info.SSHUser

	rctx, cancel := context.WithCancel(context.Background())
	g.cancel = cancel
	ticks, stop := g.newTicker(g.leaseDur / 3)
	g.wg.Add(1)
	go func() {
		defer stop()
		g.renewLoop(rctx, ticks)
	}()

	return provider.ProviderInfo{ID: "runnervm/" + g.Profile, MaxSize: int(info.MaxInstances)}, nil
}

func (g *InstanceGroup) Update(ctx context.Context, fn func(instance string, state provider.State)) error {
	items, err := g.cli.list(ctx, g.Profile)
	if err != nil {
		return fmt.Errorf("fleet.list: %w", err)
	}
	for _, it := range items {
		st := mapState(it.State)
		if st == provider.StateDeleting || st == provider.StateDeleted {
			g.forget(it.ID)
		} else {
			g.adopt(it.ID)
		}
		fn(it.ID, st)
	}
	return nil
}

func mapState(s string) provider.State {
	switch st := provider.State(s); st {
	case provider.StateCreating, provider.StateRunning, provider.StateDeleting,
		provider.StateDeleted, provider.StateTimeout:
		return st
	}
	return provider.StateRunning
}

func (g *InstanceGroup) Increase(ctx context.Context, n int) (int, error) {
	for i := 0; i < n; i++ {
		r, err := g.cli.create(ctx, g.Profile, g.leaseDur)
		if err != nil {
			return i, fmt.Errorf("fleet.create: %w", err)
		}
		g.adopt(r.ID)
	}
	return n, nil
}

func (g *InstanceGroup) Decrease(ctx context.Context, instances []string) ([]string, error) {
	var succeeded []string
	var errs []error
	for _, id := range instances {
		ok, err := g.cli.delete(ctx, id)
		if err != nil {
			errs = append(errs, fmt.Errorf("fleet.delete %s: %w", id, err))
			continue
		}
		if ok {
			succeeded = append(succeeded, id)
			g.forget(id)
		}
	}
	return succeeded, errors.Join(errs...)
}

func (g *InstanceGroup) ConnectInfo(ctx context.Context, id string) (provider.ConnectInfo, error) {
	if g.settings.UseStaticCredentials {
		return provider.ConnectInfo{}, errors.New("use_static_credentials is not supported by fleeting-plugin-runnervm")
	}
	g.connectMu.Lock()
	defer g.connectMu.Unlock()

	g.mu.Lock()
	kp, cached := g.keys[id]
	g.mu.Unlock()
	if !cached {
		var err error
		kp.authorized, kp.pem, err = generateKey()
		if err != nil {
			return provider.ConnectInfo{}, err
		}
	}
	// Always call fleet.connect: it is also the only source of the address.
	// Resending a cached key is a harmless idempotent reinstall.
	r, err := g.cli.connect(ctx, id, kp.authorized)
	if err != nil {
		if isNotReady(err) {
			return provider.ConnectInfo{}, fmt.Errorf("instance %s not ready: %w", id, err)
		}
		return provider.ConnectInfo{}, fmt.Errorf("fleet.connect %s: %w", id, err)
	}
	if !cached {
		g.mu.Lock()
		g.keys[id] = kp
		g.mu.Unlock()
	}

	cc := g.settings
	cc.OS = goOS(firstNonEmpty(r.GuestOS, g.guestOS))
	cc.Arch = firstNonEmpty(r.Arch, g.arch)
	cc.Protocol = provider.ProtocolSSH
	cc.ProtocolPort = int(r.Port)
	cc.Username = firstNonEmpty(g.settings.Username, r.User, g.sshUser)
	cc.Key = kp.pem
	return provider.ConnectInfo{
		ConnectorConfig: cc,
		ID:              id,
		ExternalAddr:    r.Address,
		InternalAddr:    r.Address,
	}, nil
}

func (g *InstanceGroup) Heartbeat(ctx context.Context, id string) error {
	renewed, err := g.cli.renew(ctx, []string{id}, g.leaseDur)
	if err != nil {
		return fmt.Errorf("fleet.renew: %w", err)
	}
	for _, r := range renewed {
		if r == id {
			return nil
		}
	}
	g.forget(id)
	return provider.ErrInstanceUnhealthy
}

func (g *InstanceGroup) Suspend(context.Context, []string) ([]string, error) {
	return nil, provider.ErrSuspendResumeNotSupported
}

func (g *InstanceGroup) Resume(context.Context, []string) ([]string, error) {
	return nil, provider.ErrSuspendResumeNotSupported
}

// Shutdown stops the renewer. It deliberately leaves instances alone:
// gitlab-runner's delete_instances_on_shutdown goes through Decrease.
func (g *InstanceGroup) Shutdown(context.Context) error {
	if g.cancel != nil {
		g.cancel()
		g.wg.Wait()
	}
	if g.cli != nil {
		g.cli.close()
	}
	return nil
}

func (g *InstanceGroup) adopt(id string) {
	g.mu.Lock()
	g.owned[id] = struct{}{}
	g.mu.Unlock()
}

func (g *InstanceGroup) forget(id string) {
	g.mu.Lock()
	delete(g.owned, id)
	delete(g.keys, id)
	g.mu.Unlock()
}

func (g *InstanceGroup) ownedIDs() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	ids := make([]string, 0, len(g.owned))
	for id := range g.owned {
		ids = append(ids, id)
	}
	return ids
}

// goOS maps the daemon's guestOS vocabulary to Go GOOS names.
func goOS(s string) string {
	if s == "macos" {
		return "darwin"
	}
	return s
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
