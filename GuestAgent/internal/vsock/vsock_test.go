package vsock

import (
	"errors"
	"net"
	"runtime"
	"testing"
)

func TestListenPlatform(t *testing.T) {
	switch runtime.GOOS {
	case "darwin", "linux":
		// A real AF_VSOCK bind only succeeds inside a VM guest; on a host
		// the socket call fails with EOPNOTSUPP/ENODEV. Assert only that
		// Listen never panics and never claims to be unimplemented.
		ln, err := Listen(4050)
		if err == nil {
			_ = ln.Close()
			return
		}
		if errors.Is(err, ErrNotImplemented) {
			t.Fatalf("Listen on %s must be implemented, got %v", runtime.GOOS, err)
		}
	default:
		if _, err := Listen(4050); !errors.Is(err, ErrNotImplemented) {
			t.Fatalf("Listen on %s: got %v, want ErrNotImplemented", runtime.GOOS, err)
		}
	}
}

func TestListenTCPForTests(t *testing.T) {
	ln, err := ListenTCPForTests("127.0.0.1:0")
	if err != nil {
		t.Fatalf("ListenTCPForTests: %v", err)
	}
	defer ln.Close()

	accepted := make(chan error, 1)
	go func() {
		conn, err := ln.Accept()
		if err == nil {
			conn.Close()
		}
		accepted <- err
	}()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	conn.Close()

	if err := <-accepted; err != nil {
		t.Fatalf("accept: %v", err)
	}
}
