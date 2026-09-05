// Package trust resolves agent names to configured, pinned packages and
// loads them under the trust level the configuration grants.
//
// Everything here is administrator-managed in ~/.321/trust.json. There is
// no downloading, no installation and no online enrolment: those are later
// boundaries, documented in README.md, and their absence is deliberate.
//
// Trust levels a loaded package can hold:
//
//	verified     a publisher pin whose digest matches and whose SIGNATURE
//	             verifies against one of the publisher's pinned keys
//	development  a publisher pin with "trust": "development": digest must
//	             match, the signature is not required, and the package is
//	             labelled unsigned and administrator-pinned. It is never
//	             reported as verified.
//	local        an unsigned package with a local/<name> identity, pinned by
//	             path. It has no publisher and claims none.
package trust

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"cli.321.do/internal/protocol"
)

// Trust levels.
const (
	LevelVerified    = "verified"
	LevelDevelopment = "development"
	LevelLocal       = "local"
)

// Config is trust.json.
type Config struct {
	Schema     string               `json:"schema"`
	Publishers map[string]Publisher `json:"publishers,omitempty"`
	Local      map[string]LocalPin  `json:"local,omitempty"`
	Aliases    map[string]string    `json:"aliases,omitempty"`
	Policy     Policy               `json:"policy,omitempty"`

	path string
}

// Publisher is one pinned publisher domain.
type Publisher struct {
	Keys     []Key          `json:"keys,omitempty"`
	Packages map[string]Pin `json:"packages,omitempty"`
}

// Key is a pinned public key.
type Key struct {
	KeyID     string `json:"keyId"`
	PublicKey string `json:"publicKey"`
	Since     string `json:"since,omitempty"`
	Note      string `json:"note,omitempty"`
}

// Pin is one configured package under a publisher.
type Pin struct {
	Path    string `json:"path"`
	Version string `json:"version"`
	Digest  string `json:"digest"`
	Trust   string `json:"trust,omitempty"` // verified (default) | development
}

// LocalPin is an unsigned local package by path.
type LocalPin struct {
	Path string `json:"path"`
}

// Policy is the operator's ceiling for standalone runs and adapter choice.
type Policy struct {
	CapabilityCeiling []string        `json:"capabilityCeiling,omitempty"` // nil: no ceiling; empty: nothing allowed
	Limits            protocol.Limits `json:"limits,omitempty"`
	Adapters          AdapterPolicy   `json:"adapters,omitempty"`
}

// AdapterPolicy orders adapter preference and can forbid some.
type AdapterPolicy struct {
	Preferred []string `json:"preferred,omitempty"`
	Denied    []string `json:"denied,omitempty"`
}

// Reserved names an alias may never shadow.
var Reserved = []string{"run", "agents", "packages", "trust", "doctor", "help", "version"}

// DefaultPath is ~/.321/trust.json.
func DefaultPath() (string, error) {
	if p := os.Getenv("X321_TRUST"); p != "" {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".321", "trust.json"), nil
}

// Load reads and checks a trust file. A missing file yields an empty
// configuration, so path-based local packages still work.
func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &Config{Schema: protocol.SchemaTrustConfig, path: path}, nil
	}
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("trust: %s: %v", path, err)
	}
	c.path = path
	if err := c.Check(); err != nil {
		return nil, fmt.Errorf("trust: %s: %v", path, err)
	}
	return &c, nil
}

// Path is where the configuration was read from.
func (c *Config) Path() string { return c.path }

// Check validates the configuration's internal consistency.
func (c *Config) Check() error {
	if c.Schema != protocol.SchemaTrustConfig {
		return fmt.Errorf("schema must be %q", protocol.SchemaTrustConfig)
	}
	for dom, p := range c.Publishers {
		if !protocol.IsDomain(dom) {
			return fmt.Errorf("publisher %q is not a domain", dom)
		}
		for i, k := range p.Keys {
			if k.KeyID == "" || k.PublicKey == "" {
				return fmt.Errorf("publisher %s key[%d] needs keyId and publicKey", dom, i)
			}
		}
		for name, pin := range p.Packages {
			if !protocol.IsAgentName(name) {
				return fmt.Errorf("publisher %s package %q is not an agent name", dom, name)
			}
			if pin.Path == "" || pin.Version == "" || pin.Digest == "" {
				return fmt.Errorf("publisher %s package %s needs path, version and digest", dom, name)
			}
			if !protocol.IsDigest(pin.Digest) {
				return fmt.Errorf("publisher %s package %s digest must be sha256:<hex>", dom, name)
			}
			switch pin.Trust {
			case "", LevelVerified, LevelDevelopment:
			default:
				return fmt.Errorf("publisher %s package %s trust must be verified or development", dom, name)
			}
			if (pin.Trust == "" || pin.Trust == LevelVerified) && len(p.Keys) == 0 {
				return fmt.Errorf("publisher %s package %s is pinned as verified but the publisher has no keys", dom, name)
			}
		}
	}
	for name, l := range c.Local {
		if !protocol.IsAgentName(name) {
			return fmt.Errorf("local package %q is not an agent name", name)
		}
		if l.Path == "" {
			return fmt.Errorf("local package %s needs a path", name)
		}
	}
	for alias, target := range c.Aliases {
		if !protocol.IsAgentName(alias) {
			return fmt.Errorf("alias %q is not an agent name", alias)
		}
		for _, r := range Reserved {
			if alias == r {
				return fmt.Errorf("alias %q shadows a reserved command", alias)
			}
		}
		if _, err := c.find(target); err != nil {
			return fmt.Errorf("alias %s -> %s: %v", alias, target, err)
		}
	}
	return nil
}

// Resolution is a name resolved to a configured package.
type Resolution struct {
	ID    protocol.AgentID
	Path  string
	Level string
	Pin   *Pin   // for publisher packages
	Keys  []Key  // the publisher's keys
	Alias string // the alias used, if any
}

// Resolve turns what a person typed into a configured package: a canonical
// id with a slash is looked up directly; a bare name is looked up as an
// explicit alias, then as a local package. Nothing is inferred from
// package contents. Ambiguity or absence is an error that names the
// candidates and the canonical form.
func (c *Config) Resolve(name string) (*Resolution, error) {
	if strings.Contains(name, "/") {
		return c.find(name)
	}
	if !protocol.IsAgentName(name) {
		return nil, fmt.Errorf("%q is not an agent name or canonical id", name)
	}
	if target, ok := c.Aliases[name]; ok {
		r, err := c.find(target)
		if err != nil {
			return nil, err
		}
		r.Alias = name
		return r, nil
	}
	var candidates []string
	if _, ok := c.Local[name]; ok {
		candidates = append(candidates, protocol.LocalDomain+"/"+name)
	}
	for dom, p := range c.Publishers {
		if _, ok := p.Packages[name]; ok {
			candidates = append(candidates, dom+"/"+name)
		}
	}
	sort.Strings(candidates)
	switch len(candidates) {
	case 0:
		return nil, fmt.Errorf("no agent %q is configured; use a canonical id such as <publisher>/%s or add an alias to %s", name, name, c.displayPath())
	case 1:
		if strings.HasPrefix(candidates[0], protocol.LocalDomain+"/") {
			return c.find(candidates[0])
		}
		return nil, fmt.Errorf("%q is not an alias; %s is configured, so use that canonical id or add the alias explicitly", name, candidates[0])
	default:
		return nil, fmt.Errorf("%q is ambiguous between %s; use a canonical id", name, strings.Join(candidates, ", "))
	}
}

func (c *Config) find(canonical string) (*Resolution, error) {
	id, err := protocol.ParseAgentID(canonical)
	if err != nil {
		return nil, err
	}
	if id.IsLocal() {
		l, ok := c.Local[id.Name]
		if !ok {
			return nil, fmt.Errorf("no local package %q is configured", id.Name)
		}
		return &Resolution{ID: id, Path: l.Path, Level: LevelLocal}, nil
	}
	p, ok := c.Publishers[id.Domain]
	if !ok {
		return nil, fmt.Errorf("publisher %q is not configured", id.Domain)
	}
	pin, ok := p.Packages[id.Name]
	if !ok {
		return nil, fmt.Errorf("publisher %s has no package %q configured", id.Domain, id.Name)
	}
	level := LevelVerified
	if pin.Trust == LevelDevelopment {
		level = LevelDevelopment
	}
	pinCopy := pin
	return &Resolution{ID: id, Path: pin.Path, Level: level, Pin: &pinCopy, Keys: p.Keys}, nil
}

func (c *Config) displayPath() string {
	if c.path == "" {
		return "~/.321/trust.json"
	}
	return c.path
}

// Configured lists every configured package identity, sorted, with its
// trust level, for `321 agents`.
func (c *Config) Configured() []Resolution {
	var out []Resolution
	for name, l := range c.Local {
		out = append(out, Resolution{ID: protocol.AgentID{Domain: protocol.LocalDomain, Name: name}, Path: l.Path, Level: LevelLocal})
	}
	for dom, p := range c.Publishers {
		for name, pin := range p.Packages {
			level := LevelVerified
			if pin.Trust == LevelDevelopment {
				level = LevelDevelopment
			}
			pinCopy := pin
			out = append(out, Resolution{ID: protocol.AgentID{Domain: dom, Name: name}, Path: pin.Path, Level: level, Pin: &pinCopy})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID.String() < out[j].ID.String() })
	for i := range out {
		for alias, target := range c.Aliases {
			if target == out[i].ID.String() {
				out[i].Alias = alias
			}
		}
	}
	return out
}
