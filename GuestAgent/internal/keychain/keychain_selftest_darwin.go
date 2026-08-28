//go:build darwin

package keychain

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// The self-test signs with a throwaway certificate it generates itself.
// The identity name is the certificate's common name; the PKCS#12 pass
// phrase protects a key that exists for the length of one call, in a
// directory nothing else can reach, so it is a constant on purpose.
const (
	selfTestIdentity    = "RunnerVM SelfTest"
	selfTestP12Password = "selftest"
	// selfTestSubject is the binary that gets signed. /usr/bin/true is the
	// smallest Mach-O every macOS ships; it is copied first because
	// codesign rewrites the file it is given.
	selfTestSubject = "/usr/bin/true"
)

// selfTest runs the whole inject-a-certificate-and-sign proof in a
// temporary keychain. See SelfTest for the contract.
func selfTest(ctx context.Context, cfg Config) []Check {
	checks := []Check{}

	dir, err := os.MkdirTemp(selfTestParent(cfg), "runnervm-selftest-")
	if err != nil {
		return append(checks, Check{Name: "tempDir", Detail: err.Error()})
	}
	defer os.RemoveAll(dir)
	if c := cfg.Credential; c != nil {
		// The tools run as the runner account and must own their scratch.
		if err := os.Chown(dir, int(c.Uid), int(c.Gid)); err != nil {
			return append(checks, Check{Name: "tempDir", Detail: err.Error()})
		}
	}
	password, err := newPassword()
	if err != nil {
		return append(checks, Check{Name: "password", Detail: err.Error()})
	}

	kc := filepath.Join(dir, "runnervm-selftest.keychain-db")
	key := filepath.Join(dir, "key.pem")
	cert := filepath.Join(dir, "cert.pem")
	p12 := filepath.Join(dir, "cert.p12")
	binary := filepath.Join(dir, "selftest-binary")

	// The temporary keychain is never added to a search list, so deleting
	// it is the only cleanup needed. It runs on a background context so a
	// cancelled RPC still cannot leak a keychain.
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), commandTimeout)
		defer cancel()
		_, _ = run(cleanup, cfg, cfg.SecurityPath, password, "delete-keychain", kc)
	}()

	security := func(args ...string) (string, error) {
		_, err := run(ctx, cfg, cfg.SecurityPath, password, args...)
		return "", err
	}
	openssl := func(args ...string) (string, error) {
		_, err := run(ctx, cfg, cfg.OpenSSLPath, "", args...)
		return "", err
	}
	codesign := func(args ...string) (string, error) {
		_, err := run(ctx, cfg, cfg.CodesignPath, password, args...)
		return "", err
	}

	steps := []struct {
		name string
		run  func() (detail string, err error)
	}{
		{"createKeychain", func() (string, error) {
			return security("create-keychain", "-p", password, kc)
		}},
		{"unlockKeychain", func() (string, error) {
			return security("unlock-keychain", "-p", password, kc)
		}},
		{"generateCertificate", func() (string, error) {
			return openssl("req", "-x509", "-newkey", "rsa:2048",
				"-keyout", key, "-out", cert, "-days", "1", "-nodes",
				"-subj", "/CN="+selfTestIdentity,
				"-addext", "extendedKeyUsage=codeSigning",
				"-addext", "keyUsage=digitalSignature")
		}},
		{"exportPKCS12", func() (string, error) { return exportPKCS12(openssl, key, cert, p12) }},
		{"importCertificate", func() (string, error) {
			// -T grants codesign non-interactive access to the imported
			// key; without it signing would block on a UI prompt no guest
			// can answer.
			return security("import", p12, "-k", kc, "-P", selfTestP12Password, "-T", cfg.CodesignPath)
		}},
		{"partitionList", func() (string, error) {
			// The ACL above is only half of it: macOS still asks for the
			// keychain password on first use unless the partition list is
			// set explicitly.
			return security("set-key-partition-list",
				"-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, kc)
		}},
		{"codesign", func() (string, error) {
			if err := copyFile(selfTestSubject, binary); err != nil {
				return "", err
			}
			return codesign("-s", selfTestIdentity, "--keychain", kc, binary)
		}},
		{"verifySignature", func() (string, error) { return codesign("-v", binary) }},
	}

	for _, step := range steps {
		detail, err := step.run()
		if err != nil {
			return append(checks, Check{Name: step.name, Detail: err.Error()})
		}
		checks = append(checks, Check{Name: step.name, OK: true, Detail: detail})
	}
	return checks
}

// exportPKCS12 bundles the key and certificate for `security import`.
// LibreSSL (what macOS ships as /usr/bin/openssl) and OpenSSL 3 disagree on
// -legacy: OpenSSL 3 needs it for the RC2 encryption the macOS keychain
// importer accepts, older LibreSSL rejects the flag outright. Try the
// portable-to-newer form first and fall back.
func exportPKCS12(openssl func(...string) (string, error), key, cert, p12 string) (string, error) {
	args := func(extra ...string) []string {
		out := append([]string{"pkcs12", "-export"}, extra...)
		return append(out, "-out", p12, "-inkey", key, "-in", cert,
			"-passout", "pass:"+selfTestP12Password)
	}
	if _, err := openssl(args("-legacy")...); err == nil {
		return "", nil
	} else if _, fallbackErr := openssl(args()...); fallbackErr != nil {
		return "", fmt.Errorf("%v (and without -legacy: %v)", err, fallbackErr)
	}
	return "openssl rejected -legacy; exported without it", nil
}

// selfTestParent keeps the scratch directory inside the runner's own home
// when there is one, so it is writable by the account the tools run as.
func selfTestParent(cfg Config) string {
	if cfg.RunnerHome != "" {
		if info, err := os.Stat(cfg.RunnerHome); err == nil && info.IsDir() {
			return cfg.RunnerHome
		}
	}
	return "" // os.MkdirTemp falls back to the system temp directory
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("keychain: read %s: %w", src, err)
	}
	if err := os.WriteFile(dst, b, 0o755); err != nil {
		return fmt.Errorf("keychain: write %s: %w", dst, err)
	}
	return nil
}
