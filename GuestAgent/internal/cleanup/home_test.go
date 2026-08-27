package cleanup

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// sentinel is written into every credential path a job might leave behind;
// RestoreHome must ensure none of these bytes survive under HOME.
const sentinel = "SENTINEL-CREDENTIAL-MUST-NOT-SURVIVE-RESTORE"

// credentialPaths mirrors the paths named in the reusable-lifecycle
// credential-leak gap: git, package-manager, cloud, container and ssh
// credentials, plus a nested VCS config a job's checkout might leave.
var credentialPaths = []string{
	".gitconfig",
	".netrc",
	".npmrc",
	".cargo/credentials.toml",
	".docker/config.json",
	".ssh/id_ed25519",
	".aws/credentials",
	".config/gh/hosts.yml",
	".pypirc",
	".m2/settings.xml",
	"work/.git/config",
}

func writeSentinel(t *testing.T, path string) {
	t.Helper()
	mkfile(t, path)
	if err := os.WriteFile(path, []byte(sentinel), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestRestoreHomeRemovesCredentialSentinels(t *testing.T) {
	home := t.TempDir()
	snapshot := filepath.Join(t.TempDir(), "home.tar")

	benign := map[string]string{
		".bashrc":          "export PATH=$PATH:/usr/local/bin\n",
		".profile":         "# profile\n",
		".ssh/known_hosts": "github.com ssh-ed25519 AAAA...\n",
	}
	for rel, content := range benign {
		path := filepath.Join(home, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		// mode is meaningful here (asserted below), so this must be the call
		// that creates the file -- os.WriteFile only applies its mode arg on
		// creation, not on an already-existing file.
		if err := os.WriteFile(path, []byte(content), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	if err := SnapshotHome(home, snapshot); err != nil {
		t.Fatalf("SnapshotHome: %v", err)
	}

	for _, rel := range credentialPaths {
		writeSentinel(t, filepath.Join(home, rel))
	}
	outside := t.TempDir()
	canary := filepath.Join(outside, "hostname")
	if err := os.WriteFile(canary, []byte("outside-canary"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(canary, filepath.Join(home, "evil")); err != nil {
		t.Fatal(err)
	}

	if err := RestoreHome(home, snapshot, os.Getuid(), os.Getgid()); err != nil {
		t.Fatalf("RestoreHome: %v", err)
	}

	assertNoSentinel(t, home)
	if _, err := os.Lstat(filepath.Join(home, "evil")); !os.IsNotExist(err) {
		t.Fatalf("symlink survived restore: %v", err)
	}
	assertBenignFilesRestored(t, home, benign)
}

// assertNoSentinel checks, via a plain top-level listing and a full
// recursive walk, that no restored file contains the credential sentinel.
func assertNoSentinel(t *testing.T, home string) {
	t.Helper()
	if _, err := os.ReadDir(home); err != nil {
		t.Fatalf("ReadDir %s: %v", home, err)
	}
	err := filepath.WalkDir(home, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.Type().IsRegular() {
			return nil // symlinks/dirs/etc. cannot themselves hold the sentinel text
		}
		b, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatalf("read %s: %v", path, readErr)
		}
		if bytes.Contains(b, []byte(sentinel)) {
			t.Fatalf("%s still contains the credential sentinel after restore", path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", home, err)
	}
}

func assertBenignFilesRestored(t *testing.T, home string, want map[string]string) {
	t.Helper()
	for rel, content := range want {
		path := filepath.Join(home, rel)
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("benign file %s missing after restore: %v", rel, err)
		}
		if string(got) != content {
			t.Fatalf("benign file %s = %q, want %q", rel, got, content)
		}
	}
	info, err := os.Stat(filepath.Join(home, ".ssh", "known_hosts"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("known_hosts mode = %o, want 0640", info.Mode().Perm())
	}
}

// RestoreHome must be lstat-based when clearing HOME: a symlink under HOME
// pointing outside it must be removed as itself, never traversed into.
func TestRestoreHomeDoesNotFollowSymlinks(t *testing.T) {
	home := t.TempDir()
	snapshot := filepath.Join(t.TempDir(), "home.tar")
	mkfile(t, filepath.Join(home, ".bashrc"))
	if err := SnapshotHome(home, snapshot); err != nil {
		t.Fatalf("SnapshotHome: %v", err)
	}

	outside := t.TempDir()
	canary := filepath.Join(outside, "canary")
	if err := os.WriteFile(canary, []byte("do not touch"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(home, "link")); err != nil {
		t.Fatal(err)
	}

	if err := RestoreHome(home, snapshot, os.Getuid(), os.Getgid()); err != nil {
		t.Fatalf("RestoreHome: %v", err)
	}
	if _, err := os.Stat(canary); err != nil {
		t.Fatalf("restore reached through the symlink and deleted %s: %v", canary, err)
	}
}

func TestSnapshotRefusesNonDirectoryOrEscapingHome(t *testing.T) {
	root := t.TempDir()

	notADir := filepath.Join(root, "not-a-dir")
	if err := os.WriteFile(notADir, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SnapshotHome(notADir, filepath.Join(root, "a.tar")); err == nil {
		t.Fatal("SnapshotHome accepted a non-directory home")
	}

	elsewhere := t.TempDir()
	symlinkHome := filepath.Join(root, "home-link")
	if err := os.Symlink(elsewhere, symlinkHome); err != nil {
		t.Fatal(err)
	}
	if err := SnapshotHome(symlinkHome, filepath.Join(root, "b.tar")); err == nil {
		t.Fatal("SnapshotHome accepted a home path that is itself a symlink")
	}

	missing := filepath.Join(root, "does-not-exist")
	if err := SnapshotHome(missing, filepath.Join(root, "c.tar")); err == nil {
		t.Fatal("SnapshotHome accepted a missing home directory")
	}
}
