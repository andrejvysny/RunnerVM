//go:build linux

package vsock

import (
	"net"

	mdvsock "github.com/mdlayher/vsock"
)

// Listen opens an AF_VSOCK listener on the guest's local port. On Linux
// this uses the kernel AF_VSOCK socket family via github.com/mdlayher/vsock.
func Listen(port uint32) (net.Listener, error) {
	return mdvsock.Listen(port, nil)
}
