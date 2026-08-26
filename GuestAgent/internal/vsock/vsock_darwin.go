//go:build darwin

package vsock

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"syscall"
	"time"
	"unsafe"
)

// Darwin AF_VSOCK constants. macOS exposes VM sockets to guests running
// under Virtualization.framework, but neither the standard library nor
// golang.org/x/sys knows the address family, so the sockaddr is marshalled
// and passed to bind(2)/accept(2) by hand.
const (
	// afVSOCK is AF_VSOCK from <sys/socket.h>.
	afVSOCK = 40
	// cidAny is VMADDR_CID_ANY from <sys/vsock.h>: bind on any context id.
	cidAny = uint32(0xffffffff)
	// sizeofSockaddrVM is sizeof(struct sockaddr_vm), which is packed.
	sizeofSockaddrVM = 12
	// listenBacklog is deliberately small: only vmworker connects, and it
	// holds at most a couple of bridged connections at a time.
	listenBacklog = 16
)

// sockaddrVM mirrors `struct sockaddr_vm` from <sys/vsock.h>:
//
//	struct sockaddr_vm {
//	    __uint8_t   svm_len;        /* total length */
//	    sa_family_t svm_family;     /* AF_VSOCK */
//	    __uint16_t  svm_reserved1;
//	    __uint32_t  svm_port;       /* host byte order */
//	    __uint32_t  svm_cid;        /* host byte order */
//	} __attribute__((__packed__));
type sockaddrVM struct {
	Len      uint8
	Family   uint8
	Reserved uint16
	Port     uint32
	CID      uint32
}

// marshal renders the sockaddr in the kernel's expected layout. svm_port
// and svm_cid are documented as host byte order, and every Darwin target is
// little-endian, so the encoding is fixed rather than runtime-detected.
func (sa sockaddrVM) marshal() [sizeofSockaddrVM]byte {
	var b [sizeofSockaddrVM]byte
	b[0] = sa.Len
	b[1] = sa.Family
	binary.LittleEndian.PutUint16(b[2:4], sa.Reserved)
	binary.LittleEndian.PutUint32(b[4:8], sa.Port)
	binary.LittleEndian.PutUint32(b[8:12], sa.CID)
	return b
}

func newSockaddrVM(cid, port uint32) sockaddrVM {
	return sockaddrVM{Len: sizeofSockaddrVM, Family: afVSOCK, Port: port, CID: cid}
}

// Addr is the net.Addr of a vsock endpoint.
type Addr struct {
	CID  uint32
	Port uint32
}

func (a Addr) Network() string { return "vsock" }

func (a Addr) String() string { return fmt.Sprintf("vsock(%d):%d", a.CID, a.Port) }

// Listen opens an AF_VSOCK listener on the guest's local port, accepting
// connections from any context id (the host bridge is the only peer).
func Listen(port uint32) (net.Listener, error) {
	fd, err := syscall.Socket(afVSOCK, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("vsock: socket(AF_VSOCK): %w", err)
	}

	// The listener is registered with the runtime poller, so it must be
	// non-blocking; O_CLOEXEC keeps it out of spawned runner processes.
	syscall.CloseOnExec(fd)
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock: set nonblocking: %w", err)
	}

	sa := newSockaddrVM(cidAny, port).marshal()
	if _, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd),
		uintptr(unsafe.Pointer(&sa[0])), uintptr(len(sa))); errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock: bind port %d: %w", port, errno)
	}
	if err := syscall.Listen(fd, listenBacklog); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock: listen: %w", err)
	}

	f := os.NewFile(uintptr(fd), fmt.Sprintf("vsock:%d", port))
	if f == nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock: os.NewFile rejected fd %d", fd)
	}
	return &listener{f: f, addr: Addr{CID: cidAny, Port: port}}, nil
}

// listener adapts a raw AF_VSOCK socket to net.Listener. Accept goes
// through the file's SyscallConn so it parks in the runtime poller instead
// of pinning an OS thread, and so Close unblocks a pending Accept.
type listener struct {
	f    *os.File
	addr Addr
}

func (l *listener) Accept() (net.Conn, error) {
	rc, err := l.f.SyscallConn()
	if err != nil {
		return nil, &net.OpError{Op: "accept", Net: "vsock", Addr: l.addr, Err: err}
	}

	var (
		nfd    int
		peer   Addr
		opErr  error
		called bool
	)
	rawErr := rc.Read(func(fd uintptr) bool {
		nfd, peer, opErr = rawAccept(int(fd))
		if opErr == syscall.EAGAIN || opErr == syscall.EINTR {
			return false // not ready: let the poller wait for readability
		}
		called = true
		return true
	})
	if rawErr != nil {
		return nil, &net.OpError{Op: "accept", Net: "vsock", Addr: l.addr, Err: rawErr}
	}
	if !called || opErr != nil {
		if opErr == nil {
			opErr = syscall.EINVAL
		}
		return nil, &net.OpError{Op: "accept", Net: "vsock", Addr: l.addr, Err: opErr}
	}
	return newConn(nfd, l.addr, peer)
}

func (l *listener) Close() error { return l.f.Close() }

func (l *listener) Addr() net.Addr { return l.addr }

// rawAccept issues accept(2) with a sockaddr_vm-sized buffer. syscall.Accept
// cannot be used: it decodes the peer address and rejects unknown families.
func rawAccept(fd int) (int, Addr, error) {
	var raw [sizeofSockaddrVM]byte
	salen := uint32(len(raw))
	r0, _, errno := syscall.Syscall(syscall.SYS_ACCEPT, uintptr(fd),
		uintptr(unsafe.Pointer(&raw[0])), uintptr(unsafe.Pointer(&salen)))
	if errno != 0 {
		return -1, Addr{}, errno
	}
	peer := Addr{}
	if salen >= sizeofSockaddrVM {
		peer.Port = binary.LittleEndian.Uint32(raw[4:8])
		peer.CID = binary.LittleEndian.Uint32(raw[8:12])
	}
	return int(r0), peer, nil
}

// newConn wraps an accepted descriptor. net.FileConn is tried first so the
// connection is a first-class *net.netFD where the runtime supports it;
// Darwin's net package rejects AF_VSOCK today, so the fd-backed fallback is
// the path actually taken.
func newConn(fd int, local, remote Addr) (net.Conn, error) {
	syscall.CloseOnExec(fd)
	// Darwin's accept(2) inherits the listener's O_NONBLOCK, but say so
	// explicitly: os.NewFile only registers non-blocking fds with the
	// poller, and without the poller there are no deadlines.
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	// A vanished peer must surface as EPIPE on write, not as a process
	// signal (the host bridge disappears whenever vmworker exits).
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_NOSIGPIPE, 1)

	f := os.NewFile(uintptr(fd), remote.String())
	if f == nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("vsock: os.NewFile rejected accepted fd %d", fd)
	}
	if c, err := net.FileConn(f); err == nil {
		_ = f.Close() // net.FileConn dups; the original is redundant
		return c, nil
	}
	return &conn{f: f, local: local, remote: remote}, nil
}

// conn is a net.Conn over a pollable socket descriptor. *os.File already
// provides poller-backed reads, writes and deadlines; only the addressing
// and the net.Conn method set are missing.
type conn struct {
	f      *os.File
	local  Addr
	remote Addr
}

func (c *conn) Read(b []byte) (int, error)  { return c.f.Read(b) }
func (c *conn) Write(b []byte) (int, error) { return c.f.Write(b) }
func (c *conn) Close() error                { return c.f.Close() }
func (c *conn) LocalAddr() net.Addr         { return c.local }
func (c *conn) RemoteAddr() net.Addr        { return c.remote }

func (c *conn) SetDeadline(t time.Time) error      { return c.f.SetDeadline(t) }
func (c *conn) SetReadDeadline(t time.Time) error  { return c.f.SetReadDeadline(t) }
func (c *conn) SetWriteDeadline(t time.Time) error { return c.f.SetWriteDeadline(t) }
