//go:build darwin

package keychain

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// wantSelfTestSteps is the proof, in order: build a keychain, put a
// certificate in it, sign with that certificate, verify the signature.
var wantSelfTestSteps = []string{
	"createKeychain", "unlockKeychain", "generateCertificate", "exportPKCS12",
	"importCertificate", "partitionList", "codesign", "verifySignature",
}

func names(checks []Check) []string {
	out := make([]string, 0, len(checks))
	for _, c := range checks {
		out = append(out, c.Name)
	}
	return out
}

func TestSelfTestProvesSigningEndToEnd(t *testing.T) {
	f := newFixture(t)

	checks := SelfTest(context.Background(), f.cfg)

	if got := strings.Join(names(checks), ","); got != strings.Join(wantSelfTestSteps, ",") {
		t.Fatalf("checks = %s\nwant     %s", got, strings.Join(wantSelfTestSteps, ","))
	}
	for _, c := range checks {
		if !c.OK {
			t.Fatalf("check %q failed: %s", c.Name, c.Detail)
		}
	}

	l := f.log(t)
	// The proof must run in a scratch keychain: touching the session
	// keychain would invalidate the runner's signing identity mid-job.
	sessionKeychain := filepath.Join(f.home, "Library", "Keychains", "runnervm-ci.keychain-db")
	fields := strings.Fields(l.find(t, "security create-keychain"))
	tempKeychain := fields[len(fields)-1]
	if tempKeychain == sessionKeychain {
		t.Fatal("the self-test built the session keychain instead of a temporary one")
	}
	if _, err := os.Stat(sessionKeychain); !os.IsNotExist(err) {
		t.Fatalf("the self-test created %s", sessionKeychain)
	}

	// Everything it made is gone afterwards.
	if last := l.subcommands()[len(l.subcommands())-1]; last != "security delete-keychain" {
		t.Fatalf("last call = %q, want the temporary keychain to be deleted", last)
	}
	if _, err := os.Stat(filepath.Dir(tempKeychain)); !os.IsNotExist(err) {
		t.Fatalf("scratch directory %s survived", filepath.Dir(tempKeychain))
	}

	// The certificate is generated with the extensions a codesigning
	// identity needs, and imported with codesign pre-authorised so signing
	// cannot block on a UI prompt no guest can answer.
	req := l.find(t, "openssl req")
	for _, want := range []string{"-x509", "rsa:2048", "extendedKeyUsage=codeSigning", "/CN=" + selfTestIdentity} {
		if !strings.Contains(req, want) {
			t.Fatalf("openssl req argv %q is missing %q", req, want)
		}
	}
	imp := l.find(t, "security import")
	if !strings.Contains(imp, "-T "+f.cfg.CodesignPath) {
		t.Fatalf("import argv %q does not pre-authorise codesign", imp)
	}
	if !strings.Contains(l.find(t, "security set-key-partition-list"), "apple-tool:,apple:,codesign:") {
		t.Fatal("the partition list does not grant codesign access")
	}
	sign := l.find(t, "codesign -s")
	if !strings.Contains(sign, "--keychain "+tempKeychain) {
		t.Fatalf("codesign argv %q does not pin the temporary keychain", sign)
	}
}

func TestSelfTestStopsAtTheFirstFailure(t *testing.T) {
	f := newFixture(t)
	failMarker(t, f.dir, "import")

	checks := SelfTest(context.Background(), f.cfg)

	want := wantSelfTestSteps[:5] // up to and including importCertificate
	if got := strings.Join(names(checks), ","); got != strings.Join(want, ",") {
		t.Fatalf("checks = %s, want %s", got, strings.Join(want, ","))
	}
	for _, c := range checks[:len(checks)-1] {
		if !c.OK {
			t.Fatalf("check %q failed unexpectedly: %s", c.Name, c.Detail)
		}
	}
	last := checks[len(checks)-1]
	if last.OK {
		t.Fatal("importCertificate reported ok although the tool failed")
	}
	if last.Detail == "" {
		t.Fatal("a failed check must carry a detail")
	}
	for _, call := range f.log(t).argv {
		if strings.HasPrefix(call, "codesign ") {
			t.Fatalf("signing was attempted after a failed import: %q", call)
		}
	}
}

// macOS ships LibreSSL, which may not know -legacy; OpenSSL 3 needs it.
func TestSelfTestFallsBackWhenOpenSSLRejectsLegacy(t *testing.T) {
	f := newFixture(t)
	failMarker(t, f.dir, "legacy")

	checks := SelfTest(context.Background(), f.cfg)

	if got := strings.Join(names(checks), ","); got != strings.Join(wantSelfTestSteps, ",") {
		t.Fatalf("checks = %s, want the full sequence", got)
	}
	export := checks[3]
	if export.Name != "exportPKCS12" || !export.OK {
		t.Fatalf("exportPKCS12 = %+v, want ok", export)
	}
	if !strings.Contains(export.Detail, "-legacy") {
		t.Fatalf("detail %q does not record the fallback", export.Detail)
	}
	var pkcs12 int
	for _, call := range f.log(t).argv {
		if strings.HasPrefix(call, "openssl pkcs12") {
			pkcs12++
		}
	}
	if pkcs12 != 2 {
		t.Fatalf("openssl pkcs12 ran %d times, want 2 (with -legacy, then without)", pkcs12)
	}
}
