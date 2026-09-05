package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// validateAny routes a fixture document to the validator its schema names.
func validateAny(t *testing.T, raw []byte) (string, Problems) {
	t.Helper()
	var probe struct {
		Schema string `json:"schema"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}
	switch probe.Schema {
	case SchemaAgentPackage:
		var m AgentManifest
		json.Unmarshal(raw, &m)
		return probe.Schema, ValidateAgentManifest(&m)
	case SchemaWorkPackage:
		var w WorkPackage
		json.Unmarshal(raw, &w)
		return probe.Schema, ValidateWorkPackage(&w)
	case SchemaWorkDirective:
		var d WorkDirective
		json.Unmarshal(raw, &d)
		return probe.Schema, ValidateWorkDirective(&d)
	case SchemaRunEvent:
		var e RunEvent
		json.Unmarshal(raw, &e)
		return probe.Schema, ValidateRunEvent(&e)
	case SchemaRunReceipt:
		var r RunReceipt
		json.Unmarshal(raw, &r)
		return probe.Schema, ValidateRunReceipt(&r)
	}
	t.Fatalf("fixture names unknown schema %q", probe.Schema)
	return "", nil
}

// TestProtocolFixtures runs the shared positive and negative fixtures. The
// same files are run by the Perl consumer in api.123.do.
func TestProtocolFixtures(t *testing.T) {
	valid, _ := filepath.Glob(fixtureDir(t, "protocol", "valid", "*.json"))
	invalid, _ := filepath.Glob(fixtureDir(t, "protocol", "invalid", "*.json"))
	if len(valid) < 5 || len(invalid) < 8 {
		t.Fatalf("expected fixtures: %d valid, %d invalid", len(valid), len(invalid))
	}
	for _, f := range valid {
		raw, _ := os.ReadFile(f)
		schema, ps := validateAny(t, raw)
		if len(ps) > 0 {
			t.Errorf("%s (%s) should be valid: %v", filepath.Base(f), schema, ps)
		}
	}
	for _, f := range invalid {
		raw, _ := os.ReadFile(f)
		var fx struct {
			Document json.RawMessage `json:"document"`
			Expect   []string        `json:"expect"`
		}
		if err := json.Unmarshal(raw, &fx); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		_, ps := validateAny(t, fx.Document)
		if len(ps) == 0 {
			t.Errorf("%s should be invalid", filepath.Base(f))
			continue
		}
		joined := ps.Error()
		for _, want := range fx.Expect {
			if !strings.Contains(joined, want) {
				t.Errorf("%s: expected a problem mentioning %q; got %s", filepath.Base(f), want, joined)
			}
		}
	}
}

// TestFixtureDigestsAreReal pins that every digest a valid fixture carries
// is the digest the canonical rules produce, so a fixture cannot pass by
// asserting a made-up value.
func TestFixtureDigestsAreReal(t *testing.T) {
	raw, _ := os.ReadFile(fixtureDir(t, "protocol", "valid", "work-directive-steer.json"))
	var d WorkDirective
	json.Unmarshal(raw, &d)
	want, _ := DirectiveDigest(d)
	if d.Digest != want {
		t.Fatalf("directive fixture digest is %s, should be %s", d.Digest, want)
	}
	raw, _ = os.ReadFile(fixtureDir(t, "protocol", "valid", "run-receipt-completed.json"))
	var r RunReceipt
	json.Unmarshal(raw, &r)
	want, _ = ReceiptDigest(r)
	if r.ReceiptDigest != want {
		t.Fatalf("receipt fixture digest is %s, should be %s", r.ReceiptDigest, want)
	}
	raw, _ = os.ReadFile(fixtureDir(t, "protocol", "valid", "work-package-approval.json"))
	var w WorkPackage
	json.Unmarshal(raw, &w)
	want, _ = ParamsHash(w.Approval.Params)
	if w.Approval.ParamsHash != want {
		t.Fatalf("approval fixture paramsHash is %s, should be %s", w.Approval.ParamsHash, want)
	}
	// The receipt fixture's packageDigest and conditionsDigest name the
	// work-package fixture it answers.
	raw, _ = os.ReadFile(fixtureDir(t, "protocol", "valid", "work-package-minimal.json"))
	var wp WorkPackage
	json.Unmarshal(raw, &wp)
	if pd, _ := PackageDigest(wp); pd != r.PackageDigest {
		t.Fatalf("receipt fixture packageDigest is %s, should be %s", r.PackageDigest, pd)
	}
	if cd, _ := ConditionsDigest(wp.Completion.Conditions); cd != r.ConditionsDigest {
		t.Fatalf("receipt fixture conditionsDigest is %s, should be %s", r.ConditionsDigest, cd)
	}
}
