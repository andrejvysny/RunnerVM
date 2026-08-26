package rpc

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestWriteFrameRejectsZeroLength(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteFrame(&buf, nil); err == nil {
		t.Fatal("expected error writing a zero-length frame")
	}
	if buf.Len() != 0 {
		t.Fatalf("expected nothing written on error, got %d bytes", buf.Len())
	}
}

func TestReadFrameRejectsZeroLength(t *testing.T) {
	var buf bytes.Buffer
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], 0)
	buf.Write(header[:])

	if _, err := ReadFrame(&buf, FrameCapGuest); err == nil {
		t.Fatal("expected error reading a zero-length frame")
	}
}

func TestReadFrameRejectsOverCap(t *testing.T) {
	var buf bytes.Buffer
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], FrameCapGuest+1)
	buf.Write(header[:])
	// No body bytes supplied: ReadFrame must reject based on the length
	// prefix alone, without attempting to read (FrameCapGuest+1) bytes.

	if _, err := ReadFrame(&buf, FrameCapGuest); err == nil {
		t.Fatal("expected error reading an over-cap frame")
	}
}

func TestReadFrameAcceptsExactlyCap(t *testing.T) {
	var buf bytes.Buffer
	body := bytes.Repeat([]byte{'x'}, FrameCapGuest)
	if err := WriteFrame(&buf, body); err != nil {
		t.Fatalf("WriteFrame: %v", err)
	}
	got, err := ReadFrame(&buf, FrameCapGuest)
	if err != nil {
		t.Fatalf("ReadFrame: %v", err)
	}
	if len(got) != FrameCapGuest {
		t.Fatalf("got %d bytes, want %d", len(got), FrameCapGuest)
	}
}

func TestFrameRoundTrip(t *testing.T) {
	cases := [][]byte{
		[]byte("a"),
		[]byte(`{"protocol":"guest","version":1,"kind":"cancel","requestId":"r"}`),
		bytes.Repeat([]byte{0xFF}, 1<<16),
	}

	var buf bytes.Buffer
	for _, c := range cases {
		if err := WriteFrame(&buf, c); err != nil {
			t.Fatalf("WriteFrame(%d bytes): %v", len(c), err)
		}
	}
	for _, want := range cases {
		got, err := ReadFrame(&buf, FrameCapGuest)
		if err != nil {
			t.Fatalf("ReadFrame: %v", err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("round trip mismatch: got %d bytes, want %d bytes", len(got), len(want))
		}
	}
	if buf.Len() != 0 {
		t.Fatalf("expected buffer drained, %d bytes remain", buf.Len())
	}
}

func TestReadFrameShortRead(t *testing.T) {
	var buf bytes.Buffer
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], 10)
	buf.Write(header[:])
	buf.WriteString("short") // fewer than the declared 10 bytes

	if _, err := ReadFrame(&buf, FrameCapGuest); err == nil {
		t.Fatal("expected error on truncated frame body")
	}
}
