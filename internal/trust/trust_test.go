package trust

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
)

func fixturePath(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "testdata", "packages", rel))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func copyFixture(t *testing.T, rel string) string {
	t.Helper()
	src := fixturePath(t, rel)
	dst := t.TempDir()
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		r, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, r)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, info.Mode())
	})
	if err != nil {
		t.Fatal(err)
	}
	return dst
}

func helperDigest(t *testing.T, dir string) string {
	t.Helper()
	d, _, err := digest.Compute(dir)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func newKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func TestALocalPackageLoadsByPathWithoutAnyTrustFile(t *testing.T) {
	l, err := LoadPath(fixturePath(t, "local/helper"))
	if err != nil {
		t.Fatal(err)
	}
	if l.ID() != "local/helper" || l.Level != LevelLocal || l.Verified {
		t.Fatalf("unexpected load: %+v", l)
	}
	if !strings.Contains(l.Prompt(), "Helper") {
		t.Fatal("prompt not loaded")
	}
}

func TestASelfDeclaredPublisherCannotBeLoadedByPath(t *testing.T) {
	_, err := LoadPath(fixturePath(t, "example.test/helper"))
	if err == nil || !strings.Contains(err.Error(), "declares publisher example.test") {
		t.Fatalf("a domain-claiming manifest must not load by path: %v", err)
	}
}

func TestADomainClaimingPackagePinnedAsLocalIsRefusedWithGuidance(t *testing.T) {
	c := &Config{Schema: protocol.SchemaTrustConfig, Local: map[string]LocalPin{"helper": {Path: fixturePath(t, "example.test/helper")}}}
	if err := c.Check(); err != nil {
		t.Fatal(err)
	}
	r, err := c.Resolve("helper")
	if err != nil {
		t.Fatal(err)
	}
	_, err = LoadResolved(r)
	if err == nil || !strings.Contains(err.Error(), "pin it under publishers.example.test") {
		t.Fatalf("expected guidance to pin under the publisher, got %v", err)
	}
}

func devConfig(t *testing.T, dir string) *Config {
	t.Helper()
	return &Config{Schema: protocol.SchemaTrustConfig,
		Publishers: map[string]Publisher{"example.test": {Packages: map[string]Pin{"helper": {Path: dir, Version: "1.2.0", Digest: helperDigest(t, dir), Trust: LevelDevelopment}}}},
		Aliases:    map[string]string{"helper": "example.test/helper"},
	}
}

func TestADevelopmentPinLoadsUnsignedButIsNeverVerified(t *testing.T) {
	dir := fixturePath(t, "example.test/helper")
	c := devConfig(t, dir)
	if err := c.Check(); err != nil {
		t.Fatal(err)
	}
	r, err := c.Resolve("helper")
	if err != nil {
		t.Fatal(err)
	}
	if r.Alias != "helper" || r.ID.String() != "example.test/helper" {
		t.Fatalf("alias resolution wrong: %+v", r)
	}
	l, err := LoadResolved(r)
	if err != nil {
		t.Fatal(err)
	}
	if l.Verified {
		t.Fatal("a development pin must never be reported as verified")
	}
	if !strings.Contains(l.Label, "unsigned") || !strings.Contains(l.Label, "administrator-pinned") {
		t.Fatalf("label must say unsigned and administrator-pinned: %q", l.Label)
	}
	if l.ID() != "example.test/helper" {
		t.Fatalf("identity must be preserved, got %s", l.ID())
	}
}

func TestAPinWithTheWrongDigestOrVersionIsRefused(t *testing.T) {
	dir := fixturePath(t, "example.test/helper")
	c := devConfig(t, dir)
	p := c.Publishers["example.test"].Packages["helper"]
	p.Digest = "sha256:" + strings.Repeat("0", 64)
	c.Publishers["example.test"].Packages["helper"] = p
	r, _ := c.Resolve("example.test/helper")
	if _, err := LoadResolved(r); err == nil || !strings.Contains(err.Error(), "pinned digest") {
		t.Fatalf("wrong digest must refuse: %v", err)
	}
	p.Digest = helperDigest(t, dir)
	p.Version = "9.9.9"
	c.Publishers["example.test"].Packages["helper"] = p
	r, _ = c.Resolve("example.test/helper")
	if _, err := LoadResolved(r); err == nil || !strings.Contains(err.Error(), "pinned version") {
		t.Fatalf("wrong version must refuse: %v", err)
	}
}

func TestAVerifiedPinRequiresASignatureFromAPinnedKey(t *testing.T) {
	dir := copyFixture(t, "example.test/helper")
	pub, priv := newKey(t)
	d := helperDigest(t, dir)
	cfg := &Config{Schema: protocol.SchemaTrustConfig, Publishers: map[string]Publisher{"example.test": {
		Keys:     []Key{{KeyID: digest.KeyID(pub), PublicKey: digest.EncodePublicKey(pub)}},
		Packages: map[string]Pin{"helper": {Path: dir, Version: "1.2.0", Digest: d}},
	}}}
	if err := cfg.Check(); err != nil {
		t.Fatal(err)
	}
	r, _ := cfg.Resolve("example.test/helper")
	if _, err := LoadResolved(r); err == nil || !strings.Contains(err.Error(), "no SIGNATURE") {
		t.Fatalf("unsigned package under a verified pin must refuse: %v", err)
	}
	if err := digest.WriteSignatureFile(dir, digest.Sign(d, priv)); err != nil {
		t.Fatal(err)
	}
	l, err := LoadResolved(r)
	if err != nil {
		t.Fatal(err)
	}
	if !l.Verified || !strings.Contains(l.Label, "verified") {
		t.Fatalf("expected verified, got %+v", l)
	}
	// Signing with a different key, as a new domain owner would, does not
	// inherit trust: the installation still pins the old key.
	_, other := newKey(t)
	digest.WriteSignatureFile(dir, digest.Sign(d, other))
	if _, err := LoadResolved(r); err == nil || !strings.Contains(err.Error(), "not a pinned key") {
		t.Fatalf("an unpinned key must not verify: %v", err)
	}
	// Tampering after signing breaks the digest before the signature is
	// even consulted.
	digest.WriteSignatureFile(dir, digest.Sign(d, priv))
	os.WriteFile(filepath.Join(dir, "prompts", "identity.md"), []byte("evil"), 0o644)
	if _, err := LoadResolved(r); err == nil {
		t.Fatal("tampered content must refuse")
	}
}

func TestAVerifiedPinWithNoKeysIsAConfigurationError(t *testing.T) {
	c := &Config{Schema: protocol.SchemaTrustConfig, Publishers: map[string]Publisher{"example.test": {
		Packages: map[string]Pin{"helper": {Path: "/x", Version: "1.0.0", Digest: "sha256:" + strings.Repeat("a", 64)}},
	}}}
	if err := c.Check(); err == nil || !strings.Contains(err.Error(), "no keys") {
		t.Fatalf("expected a no-keys error, got %v", err)
	}
}

func TestAliasesAreExplicitAndNeverGuessed(t *testing.T) {
	dir := fixturePath(t, "example.test/helper")
	c := devConfig(t, dir)
	delete(c.Aliases, "helper")
	if _, err := c.Resolve("helper"); err == nil || !strings.Contains(err.Error(), "not an alias") {
		t.Fatalf("a bare name that is only a publisher package must not resolve: %v", err)
	}
	if _, err := c.Resolve("nobody"); err == nil || !strings.Contains(err.Error(), "no agent") {
		t.Fatalf("unknown names must say so: %v", err)
	}
	if _, err := c.Resolve("example.test/helper"); err != nil {
		t.Fatalf("canonical id must resolve: %v", err)
	}
	// Ambiguity between a local package and a publisher package of the
	// same name is an error, never a guess.
	c.Local = map[string]LocalPin{"helper": {Path: fixturePath(t, "local/helper")}}
	if _, err := c.Resolve("helper"); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguity, got %v", err)
	}
	// An alias to something that does not exist is a configuration error.
	c.Aliases = map[string]string{"b": "example.test/nothing"}
	if err := c.Check(); err == nil {
		t.Fatal("dangling alias must fail Check")
	}
	// An alias may not shadow a command.
	c.Aliases = map[string]string{"run": "example.test/helper"}
	if err := c.Check(); err == nil || !strings.Contains(err.Error(), "reserved") {
		t.Fatalf("reserved alias must fail: %v", err)
	}
}

func TestLoadingTheTrustFileFromDisk(t *testing.T) {
	dir := fixturePath(t, "example.test/helper")
	c := devConfig(t, dir)
	b, _ := json.Marshal(c)
	path := filepath.Join(t.TempDir(), "trust.json")
	os.WriteFile(path, b, 0o600)
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Path() != path {
		t.Fatal("path not recorded")
	}
	list := loaded.Configured()
	if len(list) != 1 || list[0].Alias != "helper" || list[0].Level != LevelDevelopment {
		t.Fatalf("unexpected listing: %+v", list)
	}
	empty, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil || len(empty.Configured()) != 0 {
		t.Fatalf("a missing file is an empty configuration: %v", err)
	}
}

func TestReadInsideRefusesEscapes(t *testing.T) {
	dir := copyFixture(t, "local/helper")
	if _, err := ReadInside(dir, "../etc/passwd"); err == nil {
		t.Fatal("dotdot must be refused")
	}
	if err := os.Symlink("/etc/hostname", filepath.Join(dir, "prompts", "out.md")); err == nil {
		if _, err := ReadInside(dir, "prompts/out.md"); err == nil || !strings.Contains(err.Error(), "escapes") {
			t.Fatalf("a symlink out of the package must be refused: %v", err)
		}
	}
	if _, err := ReadInside(dir, "prompts/identity.md"); err != nil {
		t.Fatal(err)
	}
}
