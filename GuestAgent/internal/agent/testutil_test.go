package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func decodeString(t *testing.T, m map[string]json.RawMessage, key string) string {
	t.Helper()
	raw, ok := m[key]
	if !ok {
		t.Fatalf("field %q is missing", key)
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("field %q is not a string: %v", key, err)
	}
	return s
}

// assertInteger fails if the JSON number carries a fraction or exponent:
// the envelope contract says counts are signed 64-bit integers on the wire.
func assertInteger(t *testing.T, m map[string]json.RawMessage, key string) {
	t.Helper()
	raw, ok := m[key]
	if !ok {
		t.Fatalf("field %q is missing", key)
	}
	s := string(raw)
	if strings.ContainsAny(s, ".eE") {
		t.Fatalf("field %q = %s, want a plain integer", key, s)
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err != nil {
		t.Fatalf("field %q is not a number: %v", key, err)
	}
	if _, err := n.Int64(); err != nil {
		t.Fatalf("field %q = %s does not fit int64: %v", key, s, err)
	}
}
