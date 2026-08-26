// Package disk grows the guest root filesystem to fill a disk image that
// the host enlarged before boot (agent.resizeDisk). The operation is
// idempotent: it reports grown=false when the filesystem was already at
// full size.
package disk

import (
	"context"
	"errors"
	"log/slog"
)

// ErrNotSupported is returned on platforms where the agent cannot grow the
// root filesystem (macOS guests in v1).
var ErrNotSupported = errors.New("disk: resize is not supported on this platform")

// Result is the agent.resizeDisk reply.
type Result struct {
	// Grown reports whether this call changed the filesystem size.
	Grown bool
	// RootBytes is the root filesystem capacity after the call.
	RootBytes int64
}

// Resize grows the filesystem mounted at rootPath to fill its partition.
func Resize(ctx context.Context, log *slog.Logger, rootPath string) (Result, error) {
	if rootPath == "" {
		rootPath = "/"
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return resize(ctx, log, rootPath)
}
