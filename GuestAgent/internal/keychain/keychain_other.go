//go:build !darwin

package keychain

import "context"

// newPreparer returns a preparer that does nothing. A Linux guest has no
// keychain and signs nothing, so agent.startRunner must behave exactly as
// it did before this package existed: an empty Env contributes no entries
// to the runner's environment.
func newPreparer(Config) Preparer { return noopPreparer{} }

type noopPreparer struct{}

func (noopPreparer) Prepare(context.Context, string) (Session, error) { return noopSession{}, nil }

type noopSession struct{}

func (noopSession) Env() map[string]string { return map[string]string{} }

func (noopSession) Close() error { return nil }
