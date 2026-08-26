package rpc

// RPC error codes (UPPER_SNAKE strings), per ../../../Proto/envelope.md.
const (
	CodeProtocolVersion  = "PROTOCOL_VERSION"
	CodeProtocolMismatch = "PROTOCOL_MISMATCH"
	CodeMalformed        = "MALFORMED"
	CodeUnknownMethod    = "UNKNOWN_METHOD"
	CodeInvalidParams    = "INVALID_PARAMS"
	CodeDeadline         = "DEADLINE"
	CodeCancelled        = "CANCELLED"
	CodeBusy             = "BUSY"
	CodeInternal         = "INTERNAL"
)

// RPCError is the error type produced by envelope decoding and by server/
// client RPC handling. Code is one of the Code* constants above.
type RPCError struct {
	Code      string
	Message   string
	Retryable bool
}

func (e *RPCError) Error() string {
	return e.Code + ": " + e.Message
}

// Payload converts the error into the wire ErrorPayload shape.
func (e *RPCError) Payload() ErrorPayload {
	return ErrorPayload{Code: e.Code, Message: e.Message, Retryable: e.Retryable}
}

func newRPCError(code, message string) *RPCError {
	return &RPCError{Code: code, Message: message}
}

func newMalformed(message string) *RPCError {
	return newRPCError(CodeMalformed, message)
}
