package agent

import (
	"encoding/json"
	"testing"
)

// The host decodes checks unconditionally, so the field must be present and
// an array on every platform -- never null, never absent.
func TestSelfTestAlwaysAnswersWithACheckArray(t *testing.T) {
	h := newHarness(t, nil)

	var raw map[string]json.RawMessage
	h.call(t, "agent.selfTest", nil, &raw)
	checks, ok := raw["checks"]
	if !ok {
		t.Fatalf("response %v has no checks field", raw)
	}
	if string(checks) == "null" {
		t.Fatal("checks = null, want []")
	}

	var res SelfTestResult
	h.call(t, "agent.selfTest", nil, &res)
	if res.Checks == nil {
		t.Fatal("checks decoded to nil")
	}
	for _, c := range res.Checks {
		if c.Name == "" {
			t.Fatalf("a check has no name: %+v", res.Checks)
		}
	}
}
