package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestCanonicalJSONIsOrderIndependent(t *testing.T) {
	a, _ := Canonical(map[string]any{"b": 1, "a": map[string]any{"z": true, "y": "x"}})
	b, _ := Canonical(map[string]any{"a": map[string]any{"y": "x", "z": true}, "b": 1})
	if string(a) != string(b) {
		t.Fatalf("canonical forms differ: %s vs %s", a, b)
	}
	if string(a) != `{"a":{"y":"x","z":true},"b":1}` {
		t.Fatalf("unexpected canonical form %s", a)
	}
}

func TestParamsHashIsStableAndEmptyIsTheEmptyObject(t *testing.T) {
	h1, _ := ParamsHash(map[string]any{"to": "x", "amount": 3})
	h2, _ := ParamsHash(map[string]any{"amount": 3, "to": "x"})
	if h1 != h2 {
		t.Fatal("same params, different hash")
	}
	hn, _ := ParamsHash(nil)
	he, _ := ParamsHash(map[string]any{})
	if hn != he {
		t.Fatal("nil params must hash as the empty object")
	}
	if !IsDigest(h1) {
		t.Fatalf("not a digest: %s", h1)
	}
}

func TestDirectiveDigestExcludesItself(t *testing.T) {
	d := WorkDirective{Schema: SchemaWorkDirective, DirectiveID: "d1", PackageID: NewULID(), Seq: 1,
		Issuer: Issuer{Kind: "local", ID: "t"}, IssuedAt: Now(), Kind: DirectiveSteer, Payload: DirectivePayload{Text: "go left"}}
	d.Digest, _ = DirectiveDigest(d)
	again, _ := DirectiveDigest(d)
	if again != d.Digest {
		t.Fatal("digest must not depend on the digest field")
	}
	if ps := ValidateWorkDirective(&d); len(ps) > 0 {
		t.Fatalf("valid directive rejected: %v", ps)
	}
	d.Payload.Text = "go right"
	if ps := ValidateWorkDirective(&d); len(ps) == 0 {
		t.Fatal("a tampered directive must fail its digest")
	}
}

func TestULIDsAreWellFormedAndSortable(t *testing.T) {
	a := NewULID()
	b := NewULID()
	if !IsULID(a) || !IsULID(b) {
		t.Fatalf("bad ulid shape: %s %s", a, b)
	}
	if a == b {
		t.Fatal("two ulids collided")
	}
	if a[:10] > b[:10] {
		t.Fatalf("time prefix must not go backwards: %s then %s", a, b)
	}
}

func TestAgentIDParsing(t *testing.T) {
	good := []string{"321.do/b1ll", "example.test/helper", "local/helper", "a.co.uk/1da"}
	for _, g := range good {
		if _, err := ParseAgentID(g); err != nil {
			t.Errorf("%s: %v", g, err)
		}
	}
	bad := []string{"b1ll", "/b1ll", "321.do/", "321.do/B1LL", "not a domain/x", "321.do/a", "321.do/with-dash"}
	for _, b := range bad {
		if _, err := ParseAgentID(b); err == nil {
			t.Errorf("%s should be rejected", b)
		}
	}
	id, _ := ParseAgentID("local/helper")
	if !id.IsLocal() {
		t.Fatal("local/ must be local")
	}
}

func TestWorkPackageValidationCatchesTheImportantThings(t *testing.T) {
	wp := WorkPackage{Schema: SchemaWorkPackage, PackageID: NewULID(), Issuer: Issuer{Kind: "local", ID: "t"}, IssuedAt: Now(),
		Agent: AgentRef{ID: "local/helper"}, Placement: PlacementClient, Workspace: Workspace{Kind: "none", Ownership: "caller"},
		Objective: "do", Completion: Completion{Conditions: []string{}}, Capabilities: Grants{Granted: []string{}}}
	if ps := ValidateWorkPackage(&wp); len(ps) > 0 {
		t.Fatalf("minimal package should validate: %v", ps)
	}
	bad := wp
	bad.Capabilities.Granted = []string{"root.everything"}
	if ps := ValidateWorkPackage(&bad); len(ps) == 0 {
		t.Fatal("unknown capability must be rejected")
	}
	bad = wp
	bad.Approval = &Approval{ProposalRef: "p", ApprovalRef: "a", ApprovedBy: "u", Action: "send", Params: map[string]any{"x": 1}, ParamsHash: "sha256:" + strings.Repeat("0", 64)}
	if ps := ValidateWorkPackage(&bad); len(ps) == 0 {
		t.Fatal("a paramsHash that does not match params must be rejected")
	}
	bad.Approval.ParamsHash, _ = ParamsHash(bad.Approval.Params)
	if ps := ValidateWorkPackage(&bad); len(ps) > 0 {
		t.Fatalf("matching paramsHash should validate: %v", ps)
	}
	bad = wp
	bad.Workspace = Workspace{Kind: "git", Ownership: "caller"}
	if ps := ValidateWorkPackage(&bad); len(ps) == 0 {
		t.Fatal("a git workspace needs a path")
	}
}

func TestSafeRelPath(t *testing.T) {
	for _, ok := range []string{"a", "a/b.md", "prompts/x.md"} {
		if !safeRelPath(ok) {
			t.Errorf("%q should be safe", ok)
		}
	}
	for _, bad := range []string{"", "/a", "../a", "a/../b", "./a", "a/./b", "a\\b", "a//b"} {
		if safeRelPath(bad) {
			t.Errorf("%q should be unsafe", bad)
		}
	}
}

// ---------------------------------------------------------------------
// The schema documents are the canonical definition; the Go types must
// not drift from them. Every JSON field a Go type can emit must be a
// property the matching schema declares somewhere, and vice versa for the
// top-level required fields.
// ---------------------------------------------------------------------

func schemaProps(t *testing.T, file string) (map[string]bool, map[string]any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "schemas", file))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("%s: %v", file, err)
	}
	props := map[string]bool{}
	var walk func(v any)
	walk = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			if p, ok := x["properties"].(map[string]any); ok {
				for k := range p {
					props[k] = true
				}
			}
			for _, c := range x {
				walk(c)
			}
		case []any:
			for _, c := range x {
				walk(c)
			}
		}
	}
	walk(doc)
	return props, doc
}

func jsonTags(t reflect.Type, into map[string]bool, seen map[reflect.Type]bool) {
	for t.Kind() == reflect.Ptr || t.Kind() == reflect.Slice || t.Kind() == reflect.Map {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct || seen[t] {
		return
	}
	seen[t] = true
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		tag := f.Tag.Get("json")
		if tag == "" || tag == "-" {
			continue
		}
		name := strings.Split(tag, ",")[0]
		into[name] = true
		jsonTags(f.Type, into, seen)
	}
}

func TestGoTypesMatchTheSchemaDocuments(t *testing.T) {
	cases := []struct {
		file string
		typ  reflect.Type
		name string
	}{
		{"agent-package.v1.json", reflect.TypeOf(AgentManifest{}), SchemaAgentPackage},
		{"work-package.v1.json", reflect.TypeOf(WorkPackage{}), SchemaWorkPackage},
		{"work-directive.v1.json", reflect.TypeOf(WorkDirective{}), SchemaWorkDirective},
		{"run-event.v1.json", reflect.TypeOf(RunEvent{}), SchemaRunEvent},
		{"run-receipt.v1.json", reflect.TypeOf(RunReceipt{}), SchemaRunReceipt},
		{"protocol-error.v1.json", reflect.TypeOf(ProtocolError{}), SchemaProtocolError},
	}
	for _, c := range cases {
		props, doc := schemaProps(t, c.file)
		if doc["title"] != c.name {
			t.Errorf("%s: title %v is not %s", c.file, doc["title"], c.name)
		}
		if id, _ := doc["$id"].(string); !strings.HasSuffix(id, "/"+c.file) {
			t.Errorf("%s: $id %q does not end with the file name", c.file, id)
		}
		tags := map[string]bool{}
		jsonTags(c.typ, tags, map[reflect.Type]bool{})
		var missing []string
		for tag := range tags {
			if !props[tag] {
				missing = append(missing, tag)
			}
		}
		sort.Strings(missing)
		if len(missing) > 0 {
			t.Errorf("%s: Go fields not declared in the schema: %v", c.file, missing)
		}
		// Top-level required fields must exist on the Go type.
		top, _ := doc["properties"].(map[string]any)
		for k := range top {
			if !tags[k] {
				t.Errorf("%s: schema property %q has no Go field", c.file, k)
			}
		}
	}
}

func TestFixturesValidate(t *testing.T) {
	for _, dir := range []string{"example.test/helper", "local/helper"} {
		b, err := os.ReadFile(filepath.Join("..", "..", "testdata", "packages", dir, "agent.json"))
		if err != nil {
			t.Fatal(err)
		}
		var m AgentManifest
		if err := json.Unmarshal(b, &m); err != nil {
			t.Fatal(err)
		}
		if ps := ValidateAgentManifest(&m); len(ps) > 0 {
			t.Errorf("%s: %v", dir, ps)
		}
	}
}

func TestManifestValidationRefusesEscapesAndContradictions(t *testing.T) {
	m := AgentManifest{Schema: SchemaAgentPackage, ID: "local/xx", Name: "xx", DisplayName: "X", Version: "1.0.0",
		Licence: Licence{SPDX: "MIT"}, Identity: Identity{Role: "r"}, Prompts: []string{"../secret"},
		Capabilities: CapabilitySpec{Required: []string{"repo.write"}, Denied: []string{"repo.write"}},
		Harness:      HarnessSpec{Requires: []string{"magic"}}, Placement: PlacementSpec{Allowed: []string{"client"}},
		OutputSchemas: OutputSchemas{Default: "s.json"}}
	ps := ValidateAgentManifest(&m)
	joined := ps.Error()
	for _, want := range []string{"prompts[0]", "both required and denied", "harness.requires[0]"} {
		if !strings.Contains(joined, want) {
			t.Errorf("expected a problem mentioning %q, got: %s", want, joined)
		}
	}
	m2 := m
	m2.Prompts = []string{"p.md"}
	m2.Capabilities = CapabilitySpec{Required: []string{}}
	m2.Harness.Requires = nil
	m2.ID = "example.test/xx"
	m2.Publisher.Domain = "other.test"
	if ps := ValidateAgentManifest(&m2); !strings.Contains(ps.Error(), "publisher.domain") {
		t.Errorf("publisher must equal the id's domain: %v", ps)
	}
}
