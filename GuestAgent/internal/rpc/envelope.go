// Package rpc implements the envelope framing protocol shared by the
// daemon, worker and guest channels, per ../../../Proto/envelope.md.
// Decoding is strict and defensive: the guest treats every inbound frame
// as untrusted input.
package rpc

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Envelope kinds, per envelope.md.
const (
	KindRequest  = "request"
	KindResponse = "response"
	KindEvent    = "event"
	KindChunk    = "chunk"
	KindCancel   = "cancel"
)

// protocolVersion is the only version this package understands.
const protocolVersion = 1

// Envelope is the wire-level RPC message. JSON field names are exactly as
// specified in envelope.md; see Decode for the validation rules.
type Envelope struct {
	Protocol  string          `json:"protocol"`
	Version   int             `json:"version"`
	Kind      string          `json:"kind"`
	RequestID string          `json:"requestId"`
	Method    string          `json:"method,omitempty"`
	StreamSeq *int64          `json:"streamSeq,omitempty"`
	End       *bool           `json:"end,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Error     *ErrorPayload   `json:"error,omitempty"`
}

// ErrorPayload is the wire shape of Envelope.Error.
type ErrorPayload struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

// allowedEnvelopeFields is the complete set of top-level envelope keys.
// Anything else is rejected as MALFORMED (strict decoding).
var allowedEnvelopeFields = map[string]bool{
	"protocol":  true,
	"version":   true,
	"kind":      true,
	"requestId": true,
	"method":    true,
	"streamSeq": true,
	"end":       true,
	"payload":   true,
	"error":     true,
}

var validKinds = map[string]bool{
	KindRequest:  true,
	KindResponse: true,
	KindEvent:    true,
	KindChunk:    true,
	KindCancel:   true,
}

// Encode marshals an Envelope to its canonical JSON wire form. Encoding is
// deterministic: encoding/json always emits struct fields in declaration
// order, and json.RawMessage/json.Number payloads are copied byte-for-byte,
// so integers never round-trip through float64.
func Encode(e Envelope) ([]byte, error) {
	return json.Marshal(e)
}

// Decode parses and strictly validates a single envelope from b.
//
// Rejected as MALFORMED: empty input, non-object top level, unknown
// top-level keys, duplicate keys at any object nesting level, trailing
// bytes after the JSON value, and kind-specific shape violations (request/
// event without method, chunk without streamSeq+end, response without
// exactly one of payload/error, cancel with anything beyond requestId).
//
// version != 1 is rejected as PROTOCOL_VERSION. protocol != expectProtocol
// is rejected as PROTOCOL_MISMATCH. Both checks run only after the document
// is structurally well-formed.
func Decode(b []byte, expectProtocol string) (Envelope, error) {
	fields, err := decodeTopLevel(b)
	if err != nil {
		return Envelope{}, err
	}

	protocol, err := requireString(fields, "protocol")
	if err != nil {
		return Envelope{}, err
	}
	version, err := requireInt64(fields, "version")
	if err != nil {
		return Envelope{}, err
	}
	kind, err := requireString(fields, "kind")
	if err != nil {
		return Envelope{}, err
	}
	requestID, err := requireString(fields, "requestId")
	if err != nil {
		return Envelope{}, err
	}

	if version != protocolVersion {
		return Envelope{}, newRPCError(CodeProtocolVersion,
			fmt.Sprintf("unsupported protocol version %d", version))
	}
	if protocol != expectProtocol {
		return Envelope{}, newRPCError(CodeProtocolMismatch,
			fmt.Sprintf("expected protocol %q, got %q", expectProtocol, protocol))
	}
	if !validKinds[kind] {
		return Envelope{}, newMalformed(fmt.Sprintf("unknown kind %q", kind))
	}

	env := Envelope{Protocol: protocol, Version: int(version), Kind: kind, RequestID: requestID}

	if raw, ok := fields["method"]; ok {
		s, err := parseString(raw)
		if err != nil {
			return Envelope{}, newMalformed("field \"method\" must be a string")
		}
		env.Method = s
	}
	if raw, ok := fields["payload"]; ok {
		env.Payload = raw
	}
	if raw, ok := fields["error"]; ok {
		var ep ErrorPayload
		if err := strictUnmarshal(raw, &ep); err != nil {
			return Envelope{}, newMalformed("field \"error\" is invalid: " + err.Error())
		}
		env.Error = &ep
	}
	if raw, ok := fields["streamSeq"]; ok {
		seq, err := parseInt64(raw)
		if err != nil {
			return Envelope{}, newMalformed("field \"streamSeq\" must be an integer")
		}
		env.StreamSeq = &seq
	}
	if raw, ok := fields["end"]; ok {
		var end bool
		if err := json.Unmarshal(raw, &end); err != nil {
			return Envelope{}, newMalformed("field \"end\" must be a boolean")
		}
		env.End = &end
	}

	if err := validateKindShape(env); err != nil {
		return Envelope{}, err
	}
	return env, nil
}

// validateKindShape enforces the per-kind structural rules from
// envelope.md's "Rules" section.
func validateKindShape(env Envelope) error {
	switch env.Kind {
	case KindRequest, KindEvent:
		if env.Method == "" {
			return newMalformed(fmt.Sprintf("kind %q requires \"method\"", env.Kind))
		}
	case KindChunk:
		if env.StreamSeq == nil {
			return newMalformed("kind \"chunk\" requires \"streamSeq\"")
		}
		if env.End == nil {
			return newMalformed("kind \"chunk\" requires \"end\"")
		}
	case KindResponse:
		hasPayload := env.Payload != nil
		hasError := env.Error != nil
		if hasPayload == hasError {
			return newMalformed("kind \"response\" requires exactly one of payload or error")
		}
	case KindCancel:
		if env.Method != "" || env.Payload != nil || env.Error != nil || env.StreamSeq != nil || env.End != nil {
			return newMalformed("kind \"cancel\" must contain only requestId")
		}
	}
	return nil
}

// decodeTopLevel validates that data is exactly one well-formed JSON object
// with no duplicate keys at any nesting level, no unknown top-level keys,
// and no trailing bytes, returning the raw bytes of each top-level field.
func decodeTopLevel(data []byte) (map[string]json.RawMessage, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, newMalformed("empty input")
	}

	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()

	tok, err := dec.Token()
	if err != nil {
		return nil, newMalformed("invalid JSON: " + err.Error())
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return nil, newMalformed("top-level JSON value must be an object")
	}

	fields := make(map[string]json.RawMessage)
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return nil, newMalformed("invalid JSON: " + err.Error())
		}
		key, ok := keyTok.(string)
		if !ok {
			return nil, newMalformed("object key is not a string")
		}
		if !allowedEnvelopeFields[key] {
			return nil, newMalformed(fmt.Sprintf("unknown field %q", key))
		}
		if _, dup := fields[key]; dup {
			return nil, newMalformed(fmt.Sprintf("duplicate field %q", key))
		}

		// Token() and Decode() may be freely interleaved on the same
		// Decoder: this captures the raw bytes of the value that starts
		// at the decoder's current position without parsing numbers
		// into float64 (json.RawMessage copies bytes verbatim).
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, newMalformed("invalid JSON: " + err.Error())
		}
		if err := checkNoDuplicateKeys(raw); err != nil {
			return nil, err
		}
		fields[key] = raw
	}

	if _, err := dec.Token(); err != nil { // closing '}'
		return nil, newMalformed("invalid JSON: " + err.Error())
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, newMalformed("trailing data after envelope")
		}
		return nil, newMalformed("invalid JSON: " + err.Error())
	}

	return fields, nil
}

// checkNoDuplicateKeys recursively walks a raw JSON value and rejects any
// object — at any nesting level, including inside payload/error — that
// contains a repeated key.
func checkNoDuplicateKeys(raw json.RawMessage) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	return walkNoDuplicates(dec)
}

func walkNoDuplicates(dec *json.Decoder) error {
	tok, err := dec.Token()
	if err != nil {
		return newMalformed("invalid JSON: " + err.Error())
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		return nil // scalar: string, json.Number, bool, or null
	}

	switch delim {
	case '{':
		seen := make(map[string]struct{})
		for dec.More() {
			keyTok, err := dec.Token()
			if err != nil {
				return newMalformed("invalid JSON: " + err.Error())
			}
			key, ok := keyTok.(string)
			if !ok {
				return newMalformed("object key is not a string")
			}
			if _, dup := seen[key]; dup {
				return newMalformed(fmt.Sprintf("duplicate key %q", key))
			}
			seen[key] = struct{}{}
			if err := walkNoDuplicates(dec); err != nil {
				return err
			}
		}
		if _, err := dec.Token(); err != nil { // closing '}'
			return newMalformed("invalid JSON: " + err.Error())
		}
	case '[':
		for dec.More() {
			if err := walkNoDuplicates(dec); err != nil {
				return err
			}
		}
		if _, err := dec.Token(); err != nil { // closing ']'
			return newMalformed("invalid JSON: " + err.Error())
		}
	}
	return nil
}

// strictUnmarshal decodes raw into v, rejecting unknown fields and trailing
// data. Used for the fixed-shape ErrorPayload substructure.
func strictUnmarshal(raw json.RawMessage, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("unexpected trailing data")
	}
	return nil
}

func requireString(fields map[string]json.RawMessage, name string) (string, error) {
	raw, ok := fields[name]
	if !ok {
		return "", newMalformed(fmt.Sprintf("missing field %q", name))
	}
	s, err := parseString(raw)
	if err != nil {
		return "", newMalformed(fmt.Sprintf("field %q must be a string", name))
	}
	if s == "" {
		return "", newMalformed(fmt.Sprintf("field %q must not be empty", name))
	}
	return s, nil
}

func requireInt64(fields map[string]json.RawMessage, name string) (int64, error) {
	raw, ok := fields[name]
	if !ok {
		return 0, newMalformed(fmt.Sprintf("missing field %q", name))
	}
	n, err := parseInt64(raw)
	if err != nil {
		return 0, newMalformed(fmt.Sprintf("field %q must be an integer", name))
	}
	return n, nil
}

func parseString(raw json.RawMessage) (string, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", err
	}
	return s, nil
}

// parseInt64 parses raw as an exact 64-bit integer, using json.Number so
// large values never pass through float64 (which loses precision above
// 2^53).
func parseInt64(raw json.RawMessage) (int64, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var n json.Number
	if err := dec.Decode(&n); err != nil {
		return 0, err
	}
	return n.Int64()
}
