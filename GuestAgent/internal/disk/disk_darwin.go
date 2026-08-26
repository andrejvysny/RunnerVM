//go:build darwin

package disk

import (
	"context"
	"log/slog"
)

// resize is unimplemented on macOS guests: APFS containers grow on demand
// and the supported path (`diskutil apfs resizeContainer`) needs an
// interactive-safe recovery story RunnerVM does not have yet.
func resize(ctx context.Context, log *slog.Logger, rootPath string) (Result, error) {
	return Result{}, ErrNotSupported
}
