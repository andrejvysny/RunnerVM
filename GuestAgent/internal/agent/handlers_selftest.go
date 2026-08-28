package agent

import (
	"context"

	"github.com/runnervm/guest-agent/internal/keychain"
	"github.com/runnervm/guest-agent/internal/rpc"
)

// handleSelfTest proves that a certificate injected into a
// RunnerVM-created keychain can actually sign code: it builds a temporary
// keychain, generates a self-signed codesigning certificate, imports it,
// signs a copy of a system binary and verifies the signature. It never
// touches the runner's session keychain, so it is safe at any time, and it
// mutates nothing the host can observe -- hence readOnly. A Linux guest has
// nothing to prove and answers with an empty check list.
func (s *Service) handleSelfTest(ctx context.Context, req rpc.Envelope) (any, error) {
	checks := keychain.SelfTest(ctx, s.keychainCfg)
	out := make([]SelfTestCheck, 0, len(checks))
	for _, c := range checks {
		out = append(out, SelfTestCheck{Name: c.Name, OK: c.OK, Detail: c.Detail})
	}
	return SelfTestResult{Checks: out}, nil
}
