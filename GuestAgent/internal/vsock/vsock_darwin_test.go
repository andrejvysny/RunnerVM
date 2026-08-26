//go:build darwin

package vsock

import (
	"net"
	"testing"
)

// TestSockaddrVMMarshal pins the wire layout of struct sockaddr_vm. It is
// the only part of the Darwin listener that can be tested off a guest: a
// real AF_VSOCK socket cannot be created on a macOS host.
func TestSockaddrVMMarshal(t *testing.T) {
	got := newSockaddrVM(cidAny, 4050).marshal()
	want := [sizeofSockaddrVM]byte{
		12,         // svm_len
		40,         // svm_family = AF_VSOCK
		0x00, 0x00, // svm_reserved1
		0xd2, 0x0f, 0x00, 0x00, // svm_port  = 4050, host (little-endian) order
		0xff, 0xff, 0xff, 0xff, // svm_cid   = VMADDR_CID_ANY
	}
	if got != want {
		t.Fatalf("marshal() = % x, want % x", got, want)
	}
}

func TestSockaddrVMMarshalHostCID(t *testing.T) {
	got := newSockaddrVM(2, 1).marshal() // VMADDR_CID_HOST, port 1
	if got[0] != sizeofSockaddrVM || got[1] != afVSOCK {
		t.Fatalf("header = %v/%v, want %v/%v", got[0], got[1], sizeofSockaddrVM, afVSOCK)
	}
	if got[4] != 1 || got[8] != 2 {
		t.Fatalf("port/cid encoded wrong: % x", got)
	}
}

func TestAddrImplementsNetAddr(t *testing.T) {
	var a net.Addr = Addr{CID: 3, Port: 4050}
	if a.Network() != "vsock" || a.String() != "vsock(3):4050" {
		t.Fatalf("unexpected addr %s/%s", a.Network(), a.String())
	}
}
