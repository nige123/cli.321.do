package digest

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T) string {
	t.Helper()
	src := filepath.Join("..", "..", "testdata", "packages", "example.test", "helper")
	dst := t.TempDir()
	if err := copyTree(src, dst); err != nil {
		t.Fatal(err)
	}
	return dst
}

func copyTree(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, info.Mode())
	})
}

func TestDigestIsDeterministicAndMatchesTheRecordedFile(t *testing.T) {
	dir := fixture(t)
	d1, entries, err := Compute(dir)
	if err != nil {
		t.Fatal(err)
	}
	d2, _, _ := Compute(dir)
	if d1 != d2 {
		t.Fatal("digest changed between two computations")
	}
	recorded, err := ReadDigestFile(dir)
	if err != nil {
		t.Fatal(err)
	}
	if recorded != d1 {
		t.Fatalf("DIGEST %s does not match content %s", recorded, d1)
	}
	for _, e := range entries {
		if e.Path == DigestFile || e.Path == SignatureFile {
			t.Fatalf("%s must be excluded from the listing", e.Path)
		}
	}
}

func TestSignatureAndDigestFilesDoNotChangeTheDigest(t *testing.T) {
	dir := fixture(t)
	before, _, _ := Compute(dir)
	if err := WriteSignatureFile(dir, Sign(before, mustKey(t))); err != nil {
		t.Fatal(err)
	}
	if err := WriteDigestFile(dir, before); err != nil {
		t.Fatal(err)
	}
	after, _, _ := Compute(dir)
	if before != after {
		t.Fatal("DIGEST and SIGNATURE must be excluded")
	}
}

func TestAnyContentChangeChangesTheDigest(t *testing.T) {
	dir := fixture(t)
	before, _, _ := Compute(dir)
	os.WriteFile(filepath.Join(dir, "prompts", "identity.md"), []byte("changed"), 0o644)
	after, _, _ := Compute(dir)
	if before == after {
		t.Fatal("changed content must change the digest")
	}
	if _, err := Verify(dir, ""); err == nil {
		t.Fatal("Verify must notice DIGEST no longer matches")
	}
}

func TestSymlinksAreRefusedNotSkipped(t *testing.T) {
	dir := fixture(t)
	if err := os.Symlink("/etc/hostname", filepath.Join(dir, "prompts", "link.md")); err != nil {
		t.Skip("cannot create symlinks here")
	}
	if _, _, err := Compute(dir); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected a symlink refusal, got %v", err)
	}
}

func TestGitDirectoriesAreIgnored(t *testing.T) {
	dir := fixture(t)
	before, _, _ := Compute(dir)
	os.MkdirAll(filepath.Join(dir, ".git", "objects"), 0o755)
	os.WriteFile(filepath.Join(dir, ".git", "HEAD"), []byte("ref"), 0o644)
	after, _, _ := Compute(dir)
	if before != after {
		t.Fatal(".git must not contribute")
	}
}

func mustKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func TestSignAndVerifyWithEphemeralKeys(t *testing.T) {
	priv := mustKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	d := "sha256:" + strings.Repeat("ab", 32)
	sig := Sign(d, priv)
	if sig.Algorithm != AlgorithmEd25519 || sig.KeyID != KeyID(pub) {
		t.Fatal("signature metadata wrong")
	}
	if err := VerifySignature(d, sig, pub); err != nil {
		t.Fatal(err)
	}
	other := mustKey(t).Public().(ed25519.PublicKey)
	if err := VerifySignature(d, sig, other); err == nil {
		t.Fatal("a different key must not verify")
	}
	if err := VerifySignature("sha256:"+strings.Repeat("cd", 32), sig, pub); err == nil {
		t.Fatal("a different digest must not verify")
	}
	tampered := sig
	tampered.Algorithm = "rsa"
	if err := VerifySignature(d, tampered, pub); err == nil {
		t.Fatal("only ed25519 is accepted")
	}
	enc := EncodePublicKey(pub)
	back, err := ParsePublicKey(enc)
	if err != nil || string(back) != string(pub) {
		t.Fatal("public key round trip failed")
	}
}
