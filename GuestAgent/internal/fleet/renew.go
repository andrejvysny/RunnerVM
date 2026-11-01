package fleet

import (
	"context"
	"time"
)

// renewLoop renews every owned lease on each tick until ctx is cancelled.
func (g *InstanceGroup) renewLoop(ctx context.Context, ticks <-chan time.Time) {
	defer g.wg.Done()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticks:
			g.renewOwned(ctx)
		}
	}
}

// renewOwned renews all owned ids and forgets the ones the daemon no longer
// reports as renewed (deleted, reaped or unknown).
func (g *InstanceGroup) renewOwned(ctx context.Context) {
	ids := g.ownedIDs()
	if len(ids) == 0 {
		return
	}
	renewed, err := g.cli.renew(ctx, ids, g.leaseDur)
	if err != nil {
		g.log.Warn("lease renewal failed", "error", err.Error())
		return
	}
	alive := make(map[string]struct{}, len(renewed))
	for _, id := range renewed {
		alive[id] = struct{}{}
	}
	for _, id := range ids {
		if _, ok := alive[id]; !ok {
			g.log.Info("instance no longer renewable, dropping", "id", id)
			g.forget(id)
		}
	}
}
