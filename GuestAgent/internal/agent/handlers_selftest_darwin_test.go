//go:build darwin

package agent

import (
	"strings"
	"testing"
)

func TestSelfTestReportsEveryStepOnDarwin(t *testing.T) {
	h := newHarness(t, nil)

	var res SelfTestResult
	h.call(t, "agent.selfTest", nil, &res)

	want := "createKeychain,unlockKeychain,generateCertificate,exportPKCS12," +
		"importCertificate,partitionList,codesign,verifySignature"
	got := make([]string, 0, len(res.Checks))
	for _, c := range res.Checks {
		got = append(got, c.Name)
		if !c.OK {
			t.Fatalf("check %q failed: %s", c.Name, c.Detail)
		}
	}
	if strings.Join(got, ",") != want {
		t.Fatalf("checks = %s\nwant     %s", strings.Join(got, ","), want)
	}
}

// A failing step is reported as a check, not as an RPC error: the host
// wants the partial transcript, not just "it broke".
func TestSelfTestReportsTheFailingStepOnDarwin(t *testing.T) {
	h := newHarness(t, nil)
	failTool(t, h.root, "create-keychain")

	var res SelfTestResult
	h.call(t, "agent.selfTest", nil, &res)

	if len(res.Checks) != 1 {
		t.Fatalf("checks = %+v, want only the failing first step", res.Checks)
	}
	if res.Checks[0].Name != "createKeychain" || res.Checks[0].OK {
		t.Fatalf("check = %+v, want createKeychain ok=false", res.Checks[0])
	}
	if res.Checks[0].Detail == "" {
		t.Fatal("a failed check must say why")
	}
}
