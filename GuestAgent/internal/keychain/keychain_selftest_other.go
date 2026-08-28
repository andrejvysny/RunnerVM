//go:build !darwin

package keychain

import "context"

// selfTest has nothing to prove off macOS: there is no keychain and no
// codesign. agent.selfTest stays callable and answers with an empty check
// list so the host needs no per-platform branch.
func selfTest(context.Context, Config) []Check { return []Check{} }
