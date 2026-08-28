//go:build darwin

package keychain

import (
	"context"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeTool writes a stand-in for one of the macOS tools. The package builds
// the tool environment explicitly (HOME and USER only), so a stub cannot be
// configured through the environment: its log path and failure markers are
// baked into the script instead.
//
// Markers, all in dir: fail-<tool> fails every call, fail-<subcommand>
// fails the calls whose first argument matches, and fail-legacy fails any
// call carrying -legacy (which is how the openssl fallback is exercised).
func fakeTool(t *testing.T, dir, name, logPath string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	q := func(parts ...string) string { return "'" + filepath.Join(parts...) + "'" }
	script := "#!/bin/sh\n" +
		"{ printf '" + name + " %s\\n' \"$*\"; printf 'HOME %s\\n' \"$HOME\";" +
		" printf 'USER %s\\n' \"$USER\"; } >> " + q(logPath) + "\n" +
		"if [ -f " + q(dir, "fail-"+name) + " ]; then echo \"stub: " + name + " refused\" >&2; exit 1; fi\n" +
		"if [ -f " + q(dir, "fail-") + "\"$1\" ]; then echo \"stub: $1 refused\" >&2; exit 1; fi\n" +
		"if [ -f " + q(dir, "fail-legacy") + " ]; then\n" +
		"  case \" $* \" in *\" -legacy \"*) echo 'stub: -legacy unsupported' >&2; exit 1;; esac\n" +
		"fi\n" +
		"exit 0\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write %s stub: %v", name, err)
	}
	return path
}

func failMarker(t *testing.T, dir, what string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "fail-"+what), nil, 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
}

// toolLog is the parsed stub transcript.
type toolLog struct {
	argv  []string // one entry per call, "<tool> <args...>"
	homes []string
	users []string
}

func readToolLog(t *testing.T, path string) toolLog {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return toolLog{}
		}
		t.Fatalf("read %s: %v", path, err)
	}
	var out toolLog
	for _, line := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		switch {
		case strings.HasPrefix(line, "HOME "):
			out.homes = append(out.homes, strings.TrimPrefix(line, "HOME "))
		case strings.HasPrefix(line, "USER "):
			out.users = append(out.users, strings.TrimPrefix(line, "USER "))
		default:
			out.argv = append(out.argv, line)
		}
	}
	return out
}

// subcommands reduces the transcript to "<tool> <subcommand>" pairs.
func (l toolLog) subcommands() []string {
	out := make([]string, 0, len(l.argv))
	for _, call := range l.argv {
		fields := strings.Fields(call)
		if len(fields) >= 2 {
			out = append(out, fields[0]+" "+fields[1])
		}
	}
	return out
}

func (l toolLog) find(t *testing.T, prefix string) string {
	t.Helper()
	for _, call := range l.argv {
		if strings.HasPrefix(call, prefix) {
			return call
		}
	}
	t.Fatalf("no call starting with %q in:\n%s", prefix, strings.Join(l.argv, "\n"))
	return ""
}

// fixture is a preparer wired to a stubbed `security`.
type fixture struct {
	dir     string
	home    string
	logPath string
	cfg     Config
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatalf("mkdir home: %v", err)
	}
	logPath := filepath.Join(dir, "tools.log")
	return fixture{
		dir: dir, home: home, logPath: logPath,
		cfg: Config{
			RunnerHome:   home,
			User:         "runner",
			SecurityPath: fakeTool(t, dir, "security", logPath),
			OpenSSLPath:  fakeTool(t, dir, "openssl", logPath),
			CodesignPath: fakeTool(t, dir, "codesign", logPath),
		},
	}
}

func (f fixture) log(t *testing.T) toolLog { return readToolLog(t, f.logPath) }

func TestPrepareRunsTheKeychainSequenceInOrder(t *testing.T) {
	f := newFixture(t)

	sess, err := NewPreparer(f.cfg).Prepare(context.Background(), "sess-1")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}

	want := []string{
		// The stale-file sweep comes first: a keychain left by a crashed
		// run would make create-keychain fail.
		"security delete-keychain",
		"security create-keychain",
		"security set-keychain-settings",
		"security unlock-keychain",
		"security list-keychains",
		"security default-keychain",
		"security show-keychain-info",
	}
	got := f.log(t).subcommands()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("sequence =\n  %s\nwant\n  %s", strings.Join(got, "\n  "), strings.Join(want, "\n  "))
	}

	env := sess.Env()
	path := filepath.Join(f.home, "Library", "Keychains", "runnervm-ci.keychain-db")
	if env[EnvKeychainPath] != path {
		t.Fatalf("%s = %q, want %q", EnvKeychainPath, env[EnvKeychainPath], path)
	}
	password := env[EnvKeychainPassword]
	if len(password) != 2*passwordBytes {
		t.Fatalf("password is %d chars, want %d", len(password), 2*passwordBytes)
	}
	if _, err := hex.DecodeString(password); err != nil {
		t.Fatalf("password %q is not hex: %v", password, err)
	}
	if len(env) != 2 {
		t.Fatalf("Env() = %v, want exactly the two RUNNERVM_CI_KEYCHAIN* keys", env)
	}

	l := f.log(t)
	if got, want := l.find(t, "security create-keychain"), "security create-keychain -p "+password+" "+path; got != want {
		t.Fatalf("create-keychain argv = %q, want %q", got, want)
	}
	// The search list is replaced, and the keychain becomes the default,
	// in the user domain only.
	if got, want := l.find(t, "security list-keychains"), "security list-keychains -d user -s "+path; got != want {
		t.Fatalf("list-keychains argv = %q, want %q", got, want)
	}
	if got, want := l.find(t, "security default-keychain"), "security default-keychain -d user -s "+path; got != want {
		t.Fatalf("default-keychain argv = %q, want %q", got, want)
	}
	// No -l/-u/-t: the keychain must never auto-lock.
	if got, want := l.find(t, "security set-keychain-settings"), "security set-keychain-settings "+path; got != want {
		t.Fatalf("set-keychain-settings argv = %q, want %q", got, want)
	}

	for _, home := range l.homes {
		if home != f.home {
			t.Fatalf("a tool ran with HOME=%q, want %q", home, f.home)
		}
	}
	for _, user := range l.users {
		if user != "runner" {
			t.Fatalf("a tool ran with USER=%q, want runner", user)
		}
	}
}

func TestCloseDeletesTheKeychainExactlyOnce(t *testing.T) {
	f := newFixture(t)
	sess, err := NewPreparer(f.cfg).Prepare(context.Background(), "sess-1")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	before := len(f.log(t).argv)

	if err := sess.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	after := f.log(t)
	if len(after.argv) != before+1 {
		t.Fatalf("Close issued %d calls, want 1", len(after.argv)-before)
	}
	path := sess.Env()[EnvKeychainPath]
	if got, want := after.argv[len(after.argv)-1], "security delete-keychain "+path; got != want {
		t.Fatalf("Close argv = %q, want %q", got, want)
	}

	// Double Close must not delete a keychain a later session may own.
	if err := sess.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if n := len(f.log(t).argv); n != len(after.argv) {
		t.Fatalf("second Close issued %d extra calls, want 0", n-len(after.argv))
	}
}

func TestPrepareFailsClosedAndNeverLeaksThePassword(t *testing.T) {
	f := newFixture(t)
	failMarker(t, f.dir, "create-keychain")

	sess, err := NewPreparer(f.cfg).Prepare(context.Background(), "sess-1")
	if err == nil {
		_ = sess.Close()
		t.Fatal("Prepare succeeded although create-keychain failed")
	}
	if sess != nil {
		t.Fatal("Prepare returned a session alongside an error")
	}
	if !strings.Contains(err.Error(), "create-keychain") {
		t.Fatalf("error %q does not name the failing step", err)
	}

	l := f.log(t)
	// The password the failed attempt used is recoverable from the stub
	// transcript; it must appear nowhere in what the host is told.
	fields := strings.Fields(l.find(t, "security create-keychain"))
	password := fields[3]
	if strings.Contains(err.Error(), password) {
		t.Fatalf("the keychain password leaked into the error: %q", err)
	}
	// A half-built keychain is removed rather than left behind.
	if last := l.subcommands()[len(l.subcommands())-1]; last != "security delete-keychain" {
		t.Fatalf("last call = %q, want a cleanup delete-keychain", last)
	}
}

// A keychain file left by a crashed previous run cannot be unlocked (its
// password is gone), so the pre-emptive delete is best effort: its failure
// must not stop a new session.
func TestPrepareIgnoresTheStaleKeychainSweepFailing(t *testing.T) {
	f := newFixture(t)
	failMarker(t, f.dir, "delete-keychain")

	sess, err := NewPreparer(f.cfg).Prepare(context.Background(), "sess-1")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	// The same marker makes the teardown delete fail, which Close reports
	// rather than swallowing.
	if err := sess.Close(); err == nil {
		t.Fatal("Close must surface a failed delete-keychain")
	}
}

func TestPrepareRequiresARunnerHome(t *testing.T) {
	cfg := Config{SecurityPath: "/nonexistent"}
	if _, err := NewPreparer(cfg).Prepare(context.Background(), "sess-1"); err == nil {
		t.Fatal("Prepare accepted an empty RunnerHome")
	}
}

// The keychain directory is created for the runner account when the agent
// is root; here the agent is the account, so only the mode is checked.
func TestPrepareCreatesThePrivateKeychainDirectory(t *testing.T) {
	f := newFixture(t)
	if _, err := NewPreparer(f.cfg).Prepare(context.Background(), "sess-1"); err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	info, err := os.Stat(filepath.Join(f.home, "Library", "Keychains"))
	if err != nil {
		t.Fatalf("stat keychain dir: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Fatalf("keychain dir mode = %o, want 700", perm)
	}
}
