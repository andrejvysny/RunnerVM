//go:build !linux && !darwin

package vsock

import "net"

// Listen is unsupported on GOOS values other than linux/darwin.
func Listen(port uint32) (net.Listener, error) {
	return nil, ErrNotImplemented
}
