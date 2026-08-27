package agent

import (
	"context"
	"errors"
	"time"

	"github.com/runnervm/guest-agent/internal/cleanup"
	"github.com/runnervm/guest-agent/internal/disk"
	"github.com/runnervm/guest-agent/internal/rpc"
)

func (s *Service) handleResizeDisk(ctx context.Context, req rpc.Envelope) (any, error) {
	if s.hostSafeMode {
		return nil, errHostSafeMode()
	}
	var p emptyResult
	if err := decodePayload(req.Payload, &p); err != nil {
		return nil, err
	}

	result, err := disk.Resize(ctx, s.log, s.cfg.RootPath)
	if errors.Is(err, disk.ErrNotSupported) {
		return nil, errCode(CodeNotSupported, err, false)
	}
	if err != nil {
		return nil, errInternal(err)
	}
	return ResizeDiskResult{Grown: result.Grown, RootBytes: result.RootBytes}, nil
}

func (s *Service) handleCleanup(ctx context.Context, req rpc.Envelope) (any, error) {
	if s.hostSafeMode {
		return nil, errHostSafeMode()
	}
	var p CleanupRequest
	if err := decodePayload(req.Payload, &p); err != nil {
		return nil, err
	}
	if p.Epoch <= 0 {
		return nil, errInvalidParams("epoch must be a positive integer")
	}

	result, err := s.cleaner.Run(ctx, p.Epoch)
	if errors.Is(err, cleanup.ErrHomeSnapshotMissing) {
		return nil, errCode(CodeHomeSnapshotMissing, err, false)
	}
	if err != nil {
		return nil, errInternal(err)
	}
	removed := result.Removed
	if removed == nil {
		removed = []string{}
	}
	return CleanupResult{OK: result.OK, Removed: removed}, nil
}

// handleShutdown answers first and halts afterwards: the host needs the
// response frame to distinguish "agent accepted the shutdown" from "the
// connection dropped", which are different failure modes for vmworker.
func (s *Service) handleShutdown(ctx context.Context, req rpc.Envelope) (any, error) {
	if s.hostSafeMode {
		return nil, errHostSafeMode()
	}
	var p emptyResult
	if err := decodePayload(req.Payload, &p); err != nil {
		return nil, err
	}

	s.mu.Lock()
	already := s.shuttingDown
	s.shuttingDown = true
	s.mu.Unlock()
	if already {
		return emptyResult{}, nil // idempotent: a retried shutdown is fine
	}

	s.log.Info("shutdown requested", "delay", s.cfg.ShutdownDelay.String())
	time.AfterFunc(s.cfg.ShutdownDelay, func() {
		// Detached from the request context, which is cancelled as soon as
		// the response is written.
		if err := s.cfg.PowerOff(context.Background()); err != nil {
			s.log.Error("power off failed", "error", err.Error())
		}
	})
	return emptyResult{}, nil
}
