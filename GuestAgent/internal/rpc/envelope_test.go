package rpc

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

// fixturesPath is relative to this package directory, per the fixture
// file's own contract ("Frames are the JSON text below prefixed with
// uint32 big-endian byte length").
const fixturesPath = "../../../Proto/fixtures/envelopes.json"

type fixtureFile struct {
	Description string        `json:"description"`
	Cases       []fixtureCase `json:"cases"`
	Framing     []framingCase `json:"framing"`
}

type fixtureCase struct {
	Name   string `json:"name"`
	Expect string `json:"expect"`
	Reason string `json:"reason"`
	JSON   string `json:"json"`
	Note   string `json:"note"`
}

type framingCase struct {
	Name            string `json:"name"`
	Expect          string `json:"expect"`
	Reason          string `json:"reason"`
	LengthPrefixHex string `json:"lengthPrefixHex"`
	Note            string `json:"note"`
}

func loadFixtures(t *testing.T) fixtureFile {
	t.Helper()
	b, err := os.ReadFile(fixturesPath)
	if err != nil {
		t.Fatalf("read fixtures: %v", err)
	}
	var f fixtureFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("parse fixtures: %v", err)
	}
	return f
}

// peekProtocol best-effort extracts the "protocol" field from a fixture's
// raw JSON so Decode is called with the matching expectProtocol; fixtures
// carry no PROTOCOL_MISMATCH case, so this never needs to intentionally
// mismatch.
func peekProtocol(raw string) string {
	var probe struct {
		Protocol string `json:"protocol"`
	}
	if err := json.Unmarshal([]byte(raw), &probe); err != nil || probe.Protocol == "" {
		return "guest"
	}
	return probe.Protocol
}

func TestEnvelopeFixtures(t *testing.T) {
	fixtures := loadFixtures(t)
	if len(fixtures.Cases) == 0 {
		t.Fatal("no fixture cases loaded")
	}

	for _, tc := range fixtures.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			protocol := peekProtocol(tc.JSON)
			env, err := Decode([]byte(tc.JSON), protocol)

			switch tc.Expect {
			case "valid":
				if err != nil {
					t.Fatalf("expected valid, got error: %v", err)
				}
				// Round-trip: re-encoding a decoded envelope must decode
				// back to an equal envelope (deterministic encode/decode).
				encoded, encErr := Encode(env)
				if encErr != nil {
					t.Fatalf("re-encode: %v", encErr)
				}
				roundTripped, decErr := Decode(encoded, protocol)
				if decErr != nil {
					t.Fatalf("decode re-encoded envelope: %v", decErr)
				}
				assertEnvelopesEqual(t, env, roundTripped)
			case "invalid":
				if err == nil {
					t.Fatalf("expected invalid (%s), got valid envelope %+v", tc.Reason, env)
				}
				var rpcErr *RPCError
				if !errors.As(err, &rpcErr) {
					t.Fatalf("expected *RPCError, got %T: %v", err, err)
				}
				if rpcErr.Code != tc.Reason {
					t.Fatalf("expected reason %s, got %s (%v)", tc.Reason, rpcErr.Code, rpcErr)
				}
			default:
				t.Fatalf("fixture %q has unknown expect value %q", tc.Name, tc.Expect)
			}
		})
	}
}

func assertEnvelopesEqual(t *testing.T, a, b Envelope) {
	t.Helper()
	if a.Protocol != b.Protocol || a.Version != b.Version || a.Kind != b.Kind || a.RequestID != b.RequestID || a.Method != b.Method {
		t.Fatalf("envelope mismatch: %+v vs %+v", a, b)
	}
	if string(a.Payload) != string(b.Payload) {
		t.Fatalf("payload mismatch: %s vs %s", a.Payload, b.Payload)
	}
	if (a.StreamSeq == nil) != (b.StreamSeq == nil) || (a.StreamSeq != nil && *a.StreamSeq != *b.StreamSeq) {
		t.Fatalf("streamSeq mismatch: %+v vs %+v", a.StreamSeq, b.StreamSeq)
	}
	if (a.End == nil) != (b.End == nil) || (a.End != nil && *a.End != *b.End) {
		t.Fatalf("end mismatch: %+v vs %+v", a.End, b.End)
	}
	if (a.Error == nil) != (b.Error == nil) || (a.Error != nil && *a.Error != *b.Error) {
		t.Fatalf("error mismatch: %+v vs %+v", a.Error, b.Error)
	}
}

// TestBigInt64Exactness verifies the fixture note: 9007199254740993 exceeds
// float64 exactness and must survive decode/re-encode as an exact int64,
// never silently rounded through float64.
func TestBigInt64Exactness(t *testing.T) {
	fixtures := loadFixtures(t)
	var tc *fixtureCase
	for i := range fixtures.Cases {
		if fixtures.Cases[i].Name == "big-int64" {
			tc = &fixtures.Cases[i]
			break
		}
	}
	if tc == nil {
		t.Fatal("fixture \"big-int64\" not found")
	}

	env, err := Decode([]byte(tc.JSON), peekProtocol(tc.JSON))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}

	var payload struct {
		TotalBytes int64 `json:"totalBytes"`
	}
	if err := json.Unmarshal(env.Payload, &payload); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	const want = int64(9007199254740993)
	if payload.TotalBytes != want {
		t.Fatalf("totalBytes = %d, want %d", payload.TotalBytes, want)
	}

	// Also confirm the raw payload text was preserved byte-for-byte (no
	// float64 round-trip) through Decode, and survives re-Encode.
	if got := string(env.Payload); got != `{"totalBytes":9007199254740993}` {
		t.Fatalf("payload raw bytes = %s, want exact literal preserved", got)
	}
	reencoded, err := Encode(env)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	env2, err := Decode(reencoded, peekProtocol(tc.JSON))
	if err != nil {
		t.Fatalf("decode re-encoded: %v", err)
	}
	var payload2 struct {
		TotalBytes int64 `json:"totalBytes"`
	}
	if err := json.Unmarshal(env2.Payload, &payload2); err != nil {
		t.Fatalf("unmarshal re-encoded payload: %v", err)
	}
	if payload2.TotalBytes != want {
		t.Fatalf("round-tripped totalBytes = %d, want %d", payload2.TotalBytes, want)
	}
}

// TestFramingFixtures exercises the framing fixtures against ReadFrame,
// reconstructing each frame from its declared length prefix (and, for the
// valid case, the matching envelope JSON's byte length).
func TestFramingFixtures(t *testing.T) {
	fixtures := loadFixtures(t)
	if len(fixtures.Framing) == 0 {
		t.Fatal("no framing fixture cases loaded")
	}

	var requestMinimal string
	for _, c := range fixtures.Cases {
		if c.Name == "request-minimal" {
			requestMinimal = c.JSON
		}
	}
	if requestMinimal == "" {
		t.Fatal("fixture \"request-minimal\" not found (needed by frame-of-request-minimal)")
	}

	for _, fc := range fixtures.Framing {
		t.Run(fc.Name, func(t *testing.T) {
			prefix := hexToBytes(t, fc.LengthPrefixHex)
			if len(prefix) != 4 {
				t.Fatalf("lengthPrefixHex %q is not 4 bytes", fc.LengthPrefixHex)
			}
			declaredLen := binary.BigEndian.Uint32(prefix)

			if fc.Expect == "" { // frame-of-request-minimal: informational only
				if int(declaredLen) != len(requestMinimal) {
					t.Fatalf("declared length %d != len(request-minimal json) %d", declaredLen, len(requestMinimal))
				}
				var buf bytes.Buffer
				if err := WriteFrame(&buf, []byte(requestMinimal)); err != nil {
					t.Fatalf("WriteFrame: %v", err)
				}
				got, err := ReadFrame(&buf, FrameCapGuest)
				if err != nil {
					t.Fatalf("ReadFrame: %v", err)
				}
				if string(got) != requestMinimal {
					t.Fatalf("round-tripped frame body mismatch")
				}
				return
			}

			// Build a frame stream: the declared (bogus) length prefix
			// followed by however many body bytes we can plausibly supply.
			// For zero-length there is no body; for over-cap we don't need
			// to supply 4MiB+1 of body bytes since ReadFrame must reject
			// based on the length prefix alone before reading the body.
			var buf bytes.Buffer
			buf.Write(prefix)
			_, err := ReadFrame(&buf, FrameCapGuest)
			if err == nil {
				t.Fatalf("expected error (%s), ReadFrame succeeded", fc.Reason)
			}
		})
	}
}

func hexToBytes(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("invalid hex %q: %v", s, err)
	}
	return b
}
