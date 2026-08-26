package rpc

import (
	"encoding/binary"
	"fmt"
	"io"
	"math"
)

// FrameCapGuest is the maximum frame length, in bytes, accepted on the
// guest protocol (see ../../../Proto/envelope.md).
const FrameCapGuest = 4 << 20 // 4 MiB

// frameHeaderLen is the size of the uint32 big-endian length prefix.
const frameHeaderLen = 4

// WriteFrame writes b as a length-prefixed frame: a uint32 big-endian byte
// count followed by b itself.
func WriteFrame(w io.Writer, b []byte) error {
	if len(b) == 0 {
		return fmt.Errorf("rpc: cannot write a zero-length frame")
	}
	if uint64(len(b)) > math.MaxUint32 {
		return fmt.Errorf("rpc: frame of %d bytes exceeds uint32 length prefix", len(b))
	}

	var header [frameHeaderLen]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(b)))
	if _, err := w.Write(header[:]); err != nil {
		return fmt.Errorf("rpc: write frame header: %w", err)
	}
	if _, err := w.Write(b); err != nil {
		return fmt.Errorf("rpc: write frame body: %w", err)
	}
	return nil
}

// ReadFrame reads one length-prefixed frame from r. A length of 0 or
// greater than maxLen is an error; on any error the caller must close the
// underlying connection rather than continue reading (the stream position
// is no longer trustworthy).
func ReadFrame(r io.Reader, maxLen uint32) ([]byte, error) {
	var header [frameHeaderLen]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}

	length := binary.BigEndian.Uint32(header[:])
	if length == 0 {
		return nil, fmt.Errorf("rpc: zero-length frame")
	}
	if length > maxLen {
		return nil, fmt.Errorf("rpc: frame length %d exceeds cap %d", length, maxLen)
	}

	buf := make([]byte, length)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, fmt.Errorf("rpc: read frame body: %w", err)
	}
	return buf, nil
}
