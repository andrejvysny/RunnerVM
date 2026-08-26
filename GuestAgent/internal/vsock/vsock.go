// Package vsock provides a net.Listener abstraction over AF_VSOCK for the
// guest agent, with a platform-specific Listen implementation per GOOS.
package vsock

import (
	"errors"
	"net"
)

// ErrNotImplemented is returned by Listen on platforms without a working
// AF_VSOCK implementation yet.
var ErrNotImplemented = errors.New("vsock: not implemented on this platform")

// ListenTCPForTests returns a TCP listener on addr (e.g. "127.0.0.1:0") as
// a loopback stand-in for vsock in unit tests, which cannot open real
// AF_VSOCK sockets outside a VM guest.
func ListenTCPForTests(addr string) (net.Listener, error) {
	return net.Listen("tcp", addr)
}
