package agent

import (
	"encoding/json"
	"fmt"

	"github.com/runnervm/guest-agent/internal/rpc"
)

// Guest-protocol error codes beyond the common set in Proto/envelope.md.
const (
	// CodeAlreadyStarted answers a duplicate agent.startRunner sessionId.
	CodeAlreadyStarted = "ALREADY_STARTED"
	// CodeNotSupported answers a method the platform cannot implement,
	// e.g. agent.resizeDisk on a macOS guest.
	CodeNotSupported = "NOT_SUPPORTED"
	// CodeOutputLimit terminates an agent.exec stream that exceeded
	// maxOutputBytes.
	CodeOutputLimit = "OUTPUT_LIMIT"
	// CodeKeychainUnavailable answers agent.startRunner when the per-VM CI
	// keychain could not be created (macOS). The runner was not started.
	CodeKeychainUnavailable = "KEYCHAIN_UNAVAILABLE"
	// CodeHomeSnapshotMissing answers agent.cleanup when it is configured to
	// restore the runner's HOME from a pristine snapshot but none exists.
	// Fails closed rather than reporting {ok:true} while a prior job's
	// credentials could still be sitting under HOME.
	CodeHomeSnapshotMissing = "HOME_SNAPSHOT_MISSING"
)

// hostSafeModeMessage is the exact text returned by agent.cleanup,
// agent.resizeDisk and agent.shutdown while host-safe-mode is active.
const hostSafeModeMessage = "refused: agent is not running inside a virtual machine (pass --allow-host-destructive to override)"

// errHostSafeMode is the refusal returned by the three destructive handlers
// when the Service could not confirm it is running inside a VM. See
// Service.hostSafeMode in service.go for how that is decided.
func errHostSafeMode() error {
	return &rpc.RPCError{Code: CodeNotSupported, Message: hostSafeModeMessage, Retryable: false}
}

func errInvalidParams(format string, args ...any) error {
	return &rpc.RPCError{Code: rpc.CodeInvalidParams, Message: fmt.Sprintf(format, args...)}
}

func errInternal(err error) error {
	return &rpc.RPCError{Code: rpc.CodeInternal, Message: err.Error()}
}

func errCode(code string, err error, retryable bool) error {
	return &rpc.RPCError{Code: code, Message: err.Error(), Retryable: retryable}
}

// decodePayload strictly unmarshals a request payload. An absent payload is
// an empty object, per envelope.md. Unknown fields are rejected so that a
// host/guest field-name drift fails loudly at the first call instead of
// being silently ignored.
func decodePayload(raw json.RawMessage, dst any) error {
	if len(raw) == 0 {
		raw = json.RawMessage("{}")
	}
	dec := json.NewDecoder(newByteReader(raw))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	if err := dec.Decode(dst); err != nil {
		return errInvalidParams("payload: %s", err)
	}
	return nil
}
