// Package digest computes the canonical content digest of a package
// directory and verifies ed25519 signatures over it.
//
// The digest is sha256 over a canonical file listing: every regular file
// under the root except DIGEST, SIGNATURE and anything under .git, with
// paths normalised to NFC-free ASCII-safe forward-slash form, sorted
// bytewise, each contributing "<path>\x00<sha256 of bytes>\n". Symlinks,
// absolute paths and any path that resolves outside the root are refused
// outright rather than skipped, because a package that contains one is not
// a package the runtime should load.
package digest

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

// DigestFile and SignatureFile are the two files excluded from the digest.
const (
	DigestFile    = "DIGEST"
	SignatureFile = "SIGNATURE"
)

// Entry is one file's contribution to the digest.
type Entry struct {
	Path   string
	SHA256 string
	Size   int64
}

// Compute walks root and returns the digest string and the listing that
// produced it. It fails on any symlink, on any path with a backslash or
// non-UTF-8 byte, and on a root that is not a directory.
func Compute(root string) (string, []Entry, error) {
	info, err := os.Lstat(root)
	if err != nil {
		return "", nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "", nil, fmt.Errorf("digest: package root %q is a symlink", root)
	}
	if !info.IsDir() {
		return "", nil, fmt.Errorf("digest: package root %q is not a directory", root)
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return "", nil, err
	}

	var entries []Entry
	err = filepath.WalkDir(absRoot, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(absRoot, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("digest: %q is a symlink; packages may not contain symlinks", rel)
		}
		if d.IsDir() {
			if rel == ".git" || strings.HasSuffix(rel, "/.git") {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("digest: %q is not a regular file", rel)
		}
		if rel == DigestFile || rel == SignatureFile {
			return nil
		}
		if !utf8.ValidString(rel) || strings.ContainsAny(rel, "\\\x00") {
			return fmt.Errorf("digest: %q has an unsafe path", rel)
		}
		sum, size, err := hashFile(p)
		if err != nil {
			return err
		}
		entries = append(entries, Entry{Path: rel, SHA256: sum, Size: size})
		return nil
	})
	if err != nil {
		return "", nil, err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })

	h := sha256.New()
	for _, e := range entries {
		h.Write([]byte(e.Path))
		h.Write([]byte{0})
		h.Write([]byte(e.SHA256))
		h.Write([]byte{'\n'})
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil)), entries, nil
}

func hashFile(p string) (string, int64, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// ReadDigestFile reads the DIGEST file: one line, "sha256:<hex>".
func ReadDigestFile(root string) (string, error) {
	b, err := os.ReadFile(filepath.Join(root, DigestFile))
	if err != nil {
		return "", err
	}
	s := strings.TrimSpace(string(b))
	if !strings.HasPrefix(s, "sha256:") || len(s) != 7+64 {
		return "", errors.New("digest: DIGEST file is not a sha256 digest line")
	}
	return s, nil
}

// WriteDigestFile records the computed digest beside the package.
func WriteDigestFile(root, digest string) error {
	return os.WriteFile(filepath.Join(root, DigestFile), []byte(digest+"\n"), 0o644)
}

// Verify recomputes the digest and compares it with the DIGEST file and,
// when want is non-empty, with the caller's pinned digest.
func Verify(root, want string) (string, error) {
	computed, _, err := Compute(root)
	if err != nil {
		return "", err
	}
	recorded, err := ReadDigestFile(root)
	if err != nil {
		return computed, fmt.Errorf("digest: %v", err)
	}
	if recorded != computed {
		return computed, fmt.Errorf("digest: DIGEST says %s but the content is %s", recorded, computed)
	}
	if want != "" && want != computed {
		return computed, fmt.Errorf("digest: pinned %s but the content is %s", want, computed)
	}
	return computed, nil
}
