// Package fleet implements the GitLab fleeting InstanceGroup for RunnerVM on
// top of the daemon's fleet.* methods (Proto/fleet.md).
package fleet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/andrejvysny/RunnerVM/GuestAgent/internal/rpc"
)

const (
	daemonProtocol = "daemon"
	callTimeout    = 30 * time.Second
	dialTimeout    = 5 * time.Second
)

// Daemon error codes the plugin reacts to (Proto/fleet.md).
const codeInstanceNotReady = "FLEET_INSTANCE_NOT_READY"

type infoRequest struct {
	Profile string `json:"profile"`
}

type infoResponse struct {
	Profile      string `json:"profile"`
	GuestOS      string `json:"guestOS"`
	Arch         string `json:"arch"`
	SSHUser      string `json:"sshUser"`
	MaxInstances int64  `json:"maxInstances"`
}

type listedInstance struct {
	ID         string `json:"id"`
	State      string `json:"state"`
	LeaseUntil string `json:"leaseUntil,omitempty"`
}

type listResponse struct {
	Instances []listedInstance `json:"instances"`
}

type createRequest struct {
	Profile string `json:"profile"`
	LeaseMs int64  `json:"leaseMs"`
}

type createResponse struct {
	ID         string `json:"id"`
	LeaseUntil string `json:"leaseUntil"`
}

type deleteRequest struct {
	ID string `json:"id"`
}

type deleteResponse struct {
	ID       string `json:"id"`
	Accepted bool   `json:"accepted"`
}

type renewRequest struct {
	IDs     []string `json:"ids"`
	LeaseMs int64    `json:"leaseMs"`
}

type renewResponse struct {
	Renewed []string `json:"renewed"`
}

type connectRequest struct {
	ID        string `json:"id"`
	PublicKey string `json:"publicKey"`
}

type connectResponse struct {
	ID      string `json:"id"`
	Address string `json:"address"`
	Port    int64  `json:"port"`
	User    string `json:"user"`
	GuestOS string `json:"guestOS"`
	Arch    string `json:"arch"`
}

// client is a typed fleet.* client over runnerd.sock. It dials lazily and,
// after a transport failure (daemon restart), closes the connection and
// redials once per call.
type client struct {
	socket string

	mu sync.Mutex
	rc *rpc.Client
}

func newClient(socket string) *client { return &client{socket: socket} }

func (c *client) conn() (*rpc.Client, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.rc != nil {
		return c.rc, nil
	}
	nc, err := net.DialTimeout("unix", c.socket, dialTimeout)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", c.socket, err)
	}
	c.rc = rpc.Dial(nc, daemonProtocol)
	return c.rc, nil
}

// drop closes rc if it is still the current connection.
func (c *client) drop(rc *rpc.Client) {
	c.mu.Lock()
	if c.rc == rc {
		c.rc = nil
	}
	c.mu.Unlock()
	_ = rc.Close()
}

func (c *client) close() {
	c.mu.Lock()
	rc := c.rc
	c.rc = nil
	c.mu.Unlock()
	if rc != nil {
		_ = rc.Close()
	}
}

// call performs one request. Daemon-level errors (*rpc.RPCError) and context
// errors are returned as-is; anything else is a transport error and triggers
// one close+redial+retry. A non-idempotent request is not resent once it may
// have reached the daemon: a duplicated fleet.create would boot a VM nobody
// asked for.
func (c *client) call(ctx context.Context, method string, idempotent bool, req, resp any) error {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, callTimeout)
		defer cancel()
	}
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		var rc *rpc.Client
		rc, err = c.conn()
		if err != nil {
			if attempt == 0 {
				continue
			}
			return err
		}
		var raw json.RawMessage
		raw, err = rc.Call(ctx, method, req)
		if err == nil {
			if resp == nil {
				return nil
			}
			if uerr := json.Unmarshal(raw, resp); uerr != nil {
				return fmt.Errorf("%s: decode response: %w", method, uerr)
			}
			return nil
		}
		var rpcErr *rpc.RPCError
		if errors.As(err, &rpcErr) || ctx.Err() != nil {
			return err
		}
		c.drop(rc)
		if !idempotent {
			return err
		}
	}
	return err
}

func (c *client) info(ctx context.Context, profile string) (infoResponse, error) {
	var r infoResponse
	err := c.call(ctx, "fleet.info", true, infoRequest{Profile: profile}, &r)
	return r, err
}

func (c *client) list(ctx context.Context, profile string) ([]listedInstance, error) {
	var r listResponse
	err := c.call(ctx, "fleet.list", true, infoRequest{Profile: profile}, &r)
	return r.Instances, err
}

func (c *client) create(ctx context.Context, profile string, lease time.Duration) (createResponse, error) {
	var r createResponse
	err := c.call(ctx, "fleet.create", false, createRequest{Profile: profile, LeaseMs: lease.Milliseconds()}, &r)
	return r, err
}

func (c *client) delete(ctx context.Context, id string) (bool, error) {
	var r deleteResponse
	err := c.call(ctx, "fleet.delete", true, deleteRequest{ID: id}, &r)
	return r.Accepted, err
}

func (c *client) renew(ctx context.Context, ids []string, lease time.Duration) ([]string, error) {
	var r renewResponse
	err := c.call(ctx, "fleet.renew", true, renewRequest{IDs: ids, LeaseMs: lease.Milliseconds()}, &r)
	return r.Renewed, err
}

func (c *client) connect(ctx context.Context, id, publicKey string) (connectResponse, error) {
	var r connectResponse
	err := c.call(ctx, "fleet.connect", true, connectRequest{ID: id, PublicKey: publicKey}, &r)
	return r, err
}

func isNotReady(err error) bool {
	var rpcErr *rpc.RPCError
	return errors.As(err, &rpcErr) && rpcErr.Code == codeInstanceNotReady
}
