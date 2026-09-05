package trust

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
)

// ManifestFile is the manifest name at a package root.
const ManifestFile = "agent.json"

// Loaded is a package the runtime may execute, with the trust it holds.
type Loaded struct {
	Manifest *protocol.AgentManifest
	Root     string
	Digest   string
	Level    string
	Verified bool   // true only for a verifying signature under a pinned key
	Label    string // what to show a person about this package's trust
	Warnings []string
	prompts  map[string]string
}

// ReadManifest parses and validates agent.json without loading anything
// else. Package validators use it; so does `321 packages validate`.
func ReadManifest(root string) (*protocol.AgentManifest, error) {
	b, err := os.ReadFile(filepath.Join(root, ManifestFile))
	if err != nil {
		return nil, err
	}
	var m protocol.AgentManifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("%s: %v", ManifestFile, err)
	}
	if ps := protocol.ValidateAgentManifest(&m); len(ps) > 0 {
		return &m, ps
	}
	return &m, nil
}

// ValidatePackage checks a package directory as a package: manifest shape,
// every referenced file present and inside the root, DIGEST matching the
// content. It does not consult trust configuration.
func ValidatePackage(root string) (*protocol.AgentManifest, string, error) {
	m, err := ReadManifest(root)
	if err != nil {
		return m, "", err
	}
	if err := checkReferences(root, m); err != nil {
		return m, "", err
	}
	d, err := digest.Verify(root, "")
	if err != nil {
		return m, d, err
	}
	return m, d, nil
}

func checkReferences(root string, m *protocol.AgentManifest) error {
	var refs []string
	refs = append(refs, m.Prompts...)
	refs = append(refs, m.Skills...)
	refs = append(refs, m.Evaluations...)
	refs = append(refs, m.OutputSchemas.Default)
	for _, f := range m.OutputSchemas.ByProcedure {
		refs = append(refs, f)
	}
	for _, f := range m.Harness.Overlays {
		refs = append(refs, f)
	}
	for _, r := range refs {
		if _, err := ReadInside(root, r); err != nil {
			return err
		}
	}
	return nil
}

// ReadInside reads a file by safe relative path and refuses anything that
// would land outside root, including through a symlink.
func ReadInside(root, rel string) ([]byte, error) {
	if !protocol.SafeRelPath(rel) {
		return nil, fmt.Errorf("package: %q is not a safe relative path", rel)
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	full := filepath.Join(absRoot, filepath.FromSlash(rel))
	resolved, err := filepath.EvalSymlinks(full)
	if err != nil {
		return nil, fmt.Errorf("package: %s: %v", rel, err)
	}
	rootResolved, err := filepath.EvalSymlinks(absRoot)
	if err != nil {
		return nil, err
	}
	if resolved != rootResolved && !strings.HasPrefix(resolved, rootResolved+string(filepath.Separator)) {
		return nil, fmt.Errorf("package: %q escapes the package root", rel)
	}
	info, err := os.Lstat(full)
	if err != nil {
		return nil, fmt.Errorf("package: %s: %v", rel, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("package: %q is not a regular file", rel)
	}
	return os.ReadFile(full)
}

// LoadResolved loads a resolved package under its trust level. It never
// rewrites the manifest's identity: a manifest whose id disagrees with the
// configuration is an error, as is a domain-claiming manifest pinned as a
// local package.
func LoadResolved(r *Resolution) (*Loaded, error) {
	m, computed, err := ValidatePackage(r.Path)
	if err != nil {
		return nil, fmt.Errorf("package %s at %s: %v", r.ID, r.Path, err)
	}
	if m.ID != r.ID.String() {
		if r.Level == LevelLocal {
			return nil, fmt.Errorf("package at %s declares id %q but is configured as the local package %s; pin it under publishers.%s instead (as development if it is unsigned)", r.Path, m.ID, r.ID, strings.SplitN(m.ID, "/", 2)[0])
		}
		return nil, fmt.Errorf("package at %s declares id %q but is configured as %s", r.Path, m.ID, r.ID)
	}
	l := &Loaded{Manifest: m, Root: r.Path, Digest: computed, Level: r.Level, prompts: map[string]string{}}
	switch r.Level {
	case LevelLocal:
		l.Label = "local package, unsigned, not published"
	case LevelDevelopment:
		if r.Pin.Digest != computed {
			return nil, fmt.Errorf("package %s: pinned digest %s but the content is %s", r.ID, r.Pin.Digest, computed)
		}
		if r.Pin.Version != m.Version {
			return nil, fmt.Errorf("package %s: pinned version %s but the manifest says %s", r.ID, r.Pin.Version, m.Version)
		}
		l.Label = fmt.Sprintf("%s: unsigned, administrator-pinned development package (not cryptographically verified)", r.ID.Domain)
		l.Warnings = append(l.Warnings, "development pin: publisher identity is asserted by the administrator, not proven by a signature")
	case LevelVerified:
		if r.Pin.Digest != computed {
			return nil, fmt.Errorf("package %s: pinned digest %s but the content is %s", r.ID, r.Pin.Digest, computed)
		}
		if r.Pin.Version != m.Version {
			return nil, fmt.Errorf("package %s: pinned version %s but the manifest says %s", r.ID, r.Pin.Version, m.Version)
		}
		sig, err := digest.ReadSignatureFile(r.Path)
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("package %s is pinned as verified but has no SIGNATURE; pin it as development or sign it", r.ID)
		}
		if err != nil {
			return nil, fmt.Errorf("package %s: %v", r.ID, err)
		}
		if err := verifyAgainstKeys(computed, *sig, r.Keys); err != nil {
			return nil, fmt.Errorf("package %s: %v", r.ID, err)
		}
		l.Verified = true
		l.Label = fmt.Sprintf("%s: verified against pinned key %s", r.ID.Domain, sig.KeyID)
	default:
		return nil, fmt.Errorf("package %s: unknown trust level %q", r.ID, r.Level)
	}
	for _, p := range m.Prompts {
		b, err := ReadInside(r.Path, p)
		if err != nil {
			return nil, err
		}
		l.prompts[p] = string(b)
	}
	return l, nil
}

func verifyAgainstKeys(d string, sig protocol.Signature, keys []Key) error {
	for _, k := range keys {
		if k.KeyID != sig.KeyID {
			continue
		}
		pub, err := digest.ParsePublicKey(k.PublicKey)
		if err != nil {
			return fmt.Errorf("pinned key %s: %v", k.KeyID, err)
		}
		return digest.VerifySignature(d, sig, pub)
	}
	return fmt.Errorf("signature key %s is not a pinned key for this publisher", sig.KeyID)
}

// LoadPath loads an unsigned package straight from a directory with no
// trust configuration at all. Only a local/<name> identity is accepted
// this way; a manifest claiming a publisher domain must go through a pin.
func LoadPath(root string) (*Loaded, error) {
	m, computed, err := ValidatePackage(root)
	if err != nil {
		return nil, fmt.Errorf("package at %s: %v", root, err)
	}
	id, err := protocol.ParseAgentID(m.ID)
	if err != nil {
		return nil, err
	}
	if !id.IsLocal() {
		return nil, fmt.Errorf("package at %s declares publisher %s; a path reference may only load a local/<name> package. Pin it in trust configuration to load it under that identity", root, id.Domain)
	}
	l := &Loaded{Manifest: m, Root: root, Digest: computed, Level: LevelLocal, Label: "local package by path, unsigned, not published", prompts: map[string]string{}}
	for _, p := range m.Prompts {
		b, err := ReadInside(root, p)
		if err != nil {
			return nil, err
		}
		l.prompts[p] = string(b)
	}
	return l, nil
}

// ID is the package's canonical identity.
func (l *Loaded) ID() string { return l.Manifest.ID }

// Prompt returns the concatenated prompt files in manifest order.
func (l *Loaded) Prompt() string {
	var parts []string
	for _, p := range l.Manifest.Prompts {
		parts = append(parts, strings.TrimSpace(l.prompts[p]))
	}
	return strings.Join(parts, "\n\n")
}

// OutputSchema reads the default output schema, or the one named for a
// procedure when present.
func (l *Loaded) OutputSchema(procedure string) ([]byte, error) {
	file := l.Manifest.OutputSchemas.Default
	if procedure != "" {
		if f, ok := l.Manifest.OutputSchemas.ByProcedure[procedure]; ok {
			file = f
		}
	}
	return ReadInside(l.Root, file)
}

// Overlay reads adapter-specific tuning if the package ships one.
func (l *Loaded) Overlay(adapter string) ([]byte, bool, error) {
	f, ok := l.Manifest.Harness.Overlays[adapter]
	if !ok {
		return nil, false, nil
	}
	b, err := ReadInside(l.Root, f)
	return b, true, err
}
