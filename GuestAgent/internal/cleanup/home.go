package cleanup

// SnapshotHome/RestoreHome give agent.cleanup a known-clean HOME to reset a
// reusable VM's runner account into between jobs. A cache-dir allowlist
// (see DefaultHomeRelPaths) cannot enumerate every credential a job's own
// build tooling might drop under HOME -- .gitconfig, .netrc, cloud CLI
// configs, ssh keys -- so instead the whole directory is captured once,
// before any job has run, and restored wholesale on every cleanup pass.

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// chownEntry sets ownership without following a symlink. A package var so
// its behaviour is easy to reason about in one place; RestoreHome treats a
// permission error from it as best-effort (see applyMetadata) rather than
// failing the whole restore, since only a root agent can chown arbitrarily.
var chownEntry = os.Lchown

// SnapshotHome writes a tar archive of every entry under home (including
// home's own mode, for RestoreHome's final chmod) to snapshotPath. Symlinks
// are captured, never followed; sockets, FIFOs and devices are skipped, as
// they are job runtime residue, never credentials. The write lands at
// snapshotPath+".part" and is renamed into place, so a crash mid-snapshot
// never leaves a partial file where RestoreHome expects a complete one.
func SnapshotHome(home, snapshotPath string) error {
	if _, err := validateHomeDir(home); err != nil {
		return err
	}
	home = filepath.Clean(home) // keep the escape check in extractEntry exact
	tmp := snapshotPath + ".part"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("cleanup: create snapshot: %w", err)
	}
	if err := writeTar(f, home); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("cleanup: close snapshot: %w", err)
	}
	if err := os.Rename(tmp, snapshotPath); err != nil {
		return fmt.Errorf("cleanup: commit snapshot: %w", err)
	}
	return nil
}

// RestoreHome resets home to the state captured by SnapshotHome: every
// existing entry under home is removed -- regardless of who owns it, since
// resetting HOME wholesale does not distinguish an image default from
// something a job wrote -- and the snapshot is extracted back in its place.
// uid/gid become the owner of HOME itself (see restoreHomeMetadata); every
// other restored entry gets back the ownership recorded in the snapshot.
func RestoreHome(home, snapshotPath string, uid, gid int) error {
	info, err := validateHomeDir(home)
	if err != nil {
		return err
	}
	home = filepath.Clean(home) // keep the escape check in extractEntry exact
	dev, _ := deviceID(info)
	if err := clearHomeContents(home, dev); err != nil {
		return fmt.Errorf("cleanup: clear home: %w", err)
	}
	if err := extractHome(home, snapshotPath, uid, gid); err != nil {
		return fmt.Errorf("cleanup: extract home snapshot: %w", err)
	}
	return nil
}

// validateHomeDir refuses to operate through a symlink -- home "resolving
// outside itself" -- or on anything that is not a plain directory, since
// both SnapshotHome and RestoreHome are about to read or delete everything
// under the path they are given.
func validateHomeDir(home string) (os.FileInfo, error) {
	info, err := os.Lstat(home)
	if err != nil {
		return nil, fmt.Errorf("cleanup: stat home %s: %w", home, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("cleanup: home %q is a symlink; refusing (resolves outside itself)", home)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("cleanup: home %q is not a directory", home)
	}
	return info, nil
}

// deviceID reads the filesystem device an entry lives on, when the
// platform's FileInfo exposes it.
func deviceID(info os.FileInfo) (uint64, bool) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return uint64(st.Dev), true
}

// writeTar walks home depth-first, home itself included as entry ".", and
// writes one tar header (plus content, for regular files) per entry.
func writeTar(w io.Writer, home string) error {
	tw := tar.NewWriter(w)
	walkErr := filepath.WalkDir(home, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("cleanup: walk %s: %w", path, err)
		}
		rel, err := filepath.Rel(home, path)
		if err != nil {
			return fmt.Errorf("cleanup: relativize %s: %w", path, err)
		}
		info, err := d.Info() // Lstat-based via WalkDir: never follows symlinks
		if err != nil {
			return fmt.Errorf("cleanup: stat %s: %w", path, err)
		}
		return writeTarEntry(tw, path, rel, info)
	})
	if walkErr != nil {
		return walkErr
	}
	return tw.Close()
}

// writeTarEntry records one filesystem entry. Sockets, FIFOs and device
// nodes are skipped: a build/service process can leave these under HOME,
// but they hold no credential and archive/tar has no portable way to
// reproduce them anyway.
func writeTarEntry(tw *tar.Writer, path, rel string, info fs.FileInfo) error {
	mode := info.Mode()
	if mode&(os.ModeSocket|os.ModeNamedPipe|os.ModeDevice|os.ModeCharDevice) != 0 {
		return nil
	}
	var link string
	if mode&os.ModeSymlink != 0 {
		l, err := os.Readlink(path)
		if err != nil {
			return fmt.Errorf("cleanup: readlink %s: %w", path, err)
		}
		link = l
	}
	hdr, err := tar.FileInfoHeader(info, link)
	if err != nil {
		return fmt.Errorf("cleanup: tar header for %s: %w", path, err)
	}
	hdr.Name = rel
	if info.IsDir() {
		hdr.Name += "/"
	}
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		hdr.Uid, hdr.Gid = int(st.Uid), int(st.Gid)
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return fmt.Errorf("cleanup: write header for %s: %w", path, err)
	}
	if !mode.IsRegular() {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("cleanup: open %s: %w", path, err)
	}
	defer f.Close()
	if _, err := io.Copy(tw, f); err != nil {
		return fmt.Errorf("cleanup: write %s: %w", path, err)
	}
	return nil
}

// clearHomeContents removes every entry directly and indirectly inside
// home, leaving home itself in place for extractHome to repopulate.
func clearHomeContents(home string, dev uint64) error {
	entries, err := os.ReadDir(home)
	if err != nil {
		return fmt.Errorf("cleanup: read home: %w", err)
	}
	for _, e := range entries {
		if err := removeTree(filepath.Join(home, e.Name()), dev); err != nil {
			return err
		}
	}
	return nil
}

// removeTree deletes path and, if it is a directory, everything under it.
// It is lstat-based throughout, so a symlink is removed as itself and never
// followed, and it refuses to descend into a nested mount point (a
// different device than home's own), leaving a bind-mounted volume alone
// instead of letting a wholesale HOME reset destroy it.
func removeTree(path string, homeDev uint64) error {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("cleanup: stat %s: %w", path, err)
	}
	if info.IsDir() {
		if dev, ok := deviceID(info); ok && dev != homeDev {
			return nil
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			return fmt.Errorf("cleanup: read %s: %w", path, err)
		}
		for _, e := range entries {
			if err := removeTree(filepath.Join(path, e.Name()), homeDev); err != nil {
				return err
			}
		}
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("cleanup: remove %s: %w", path, err)
	}
	return nil
}

// extractHome replays the tar snapshot into home, entry by entry.
func extractHome(home, snapshotPath string, uid, gid int) error {
	f, err := os.Open(snapshotPath)
	if err != nil {
		return fmt.Errorf("cleanup: open snapshot: %w", err)
	}
	defer f.Close()
	tr := tar.NewReader(f)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("cleanup: read snapshot: %w", err)
		}
		if err := extractEntry(home, hdr, tr, uid, gid); err != nil {
			return err
		}
	}
}

// extractEntry recreates one snapshot entry under home. The "." entry
// (home itself) is handled separately by restoreHomeMetadata rather than
// through the generic dir/file/symlink cases below.
func extractEntry(home string, hdr *tar.Header, r io.Reader, uid, gid int) error {
	rel := strings.TrimSuffix(hdr.Name, "/")
	if rel == "." || rel == "" {
		return restoreHomeMetadata(home, hdr, uid, gid)
	}
	dest := filepath.Join(home, rel)
	if dest != home && !strings.HasPrefix(dest, home+string(filepath.Separator)) {
		return fmt.Errorf("cleanup: snapshot entry %q escapes home", hdr.Name)
	}
	switch hdr.Typeflag {
	case tar.TypeDir:
		if err := os.MkdirAll(dest, 0o700); err != nil {
			return fmt.Errorf("cleanup: mkdir %s: %w", dest, err)
		}
	case tar.TypeSymlink:
		if err := os.Symlink(hdr.Linkname, dest); err != nil {
			return fmt.Errorf("cleanup: symlink %s: %w", dest, err)
		}
	case tar.TypeReg:
		if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
			return fmt.Errorf("cleanup: mkdir %s: %w", filepath.Dir(dest), err)
		}
		if err := writeRegularFile(dest, r); err != nil {
			return err
		}
	default:
		return nil // sockets/FIFOs/devices were never captured by SnapshotHome
	}
	return applyMetadata(dest, hdr)
}

func writeRegularFile(dest string, r io.Reader) error {
	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("cleanup: create %s: %w", dest, err)
	}
	if _, err := io.Copy(out, r); err != nil {
		out.Close()
		return fmt.Errorf("cleanup: write %s: %w", dest, err)
	}
	return out.Close()
}

// applyMetadata restores mode, ownership and mtime on a freshly-written
// entry. A permission error from chownEntry is swallowed: only a root agent
// (the only place this runs for real) can chown to an arbitrary uid/gid,
// and content plus permissions -- not ownership -- are what the credential
// erasure guarantee actually depends on.
func applyMetadata(dest string, hdr *tar.Header) error {
	if hdr.Typeflag != tar.TypeSymlink {
		if err := os.Chmod(dest, os.FileMode(hdr.Mode)&0o777); err != nil {
			return fmt.Errorf("cleanup: chmod %s: %w", dest, err)
		}
	}
	if err := chownEntry(dest, hdr.Uid, hdr.Gid); err != nil && !errors.Is(err, os.ErrPermission) {
		return fmt.Errorf("cleanup: chown %s: %w", dest, err)
	}
	if hdr.Typeflag == tar.TypeSymlink {
		return nil // no portable way to set a symlink's own mtime
	}
	if err := os.Chtimes(dest, hdr.ModTime, hdr.ModTime); err != nil {
		return fmt.Errorf("cleanup: set mtime %s: %w", dest, err)
	}
	return nil
}

// restoreHomeMetadata applies the "." snapshot entry to home itself: mode
// 0700 is reasserted when the snapshot recorded 0700 (otherwise home's
// current mode is left alone, since clearHomeContents never touched it),
// and ownership always follows the uid/gid passed in -- the account
// currently configured -- rather than whatever the snapshot recorded.
func restoreHomeMetadata(home string, hdr *tar.Header, uid, gid int) error {
	if hdr.FileInfo().Mode().Perm() == 0o700 {
		if err := os.Chmod(home, 0o700); err != nil {
			return fmt.Errorf("cleanup: chmod home: %w", err)
		}
	}
	if err := chownEntry(home, uid, gid); err != nil && !errors.Is(err, os.ErrPermission) {
		return fmt.Errorf("cleanup: chown home: %w", err)
	}
	return nil
}
