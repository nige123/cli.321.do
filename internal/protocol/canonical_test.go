package protocol

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixtureDir(t *testing.T, parts ...string) string {
	t.Helper()
	return filepath.Join(append([]string{"..", "..", "testdata"}, parts...)...)
}

// The .canonical and .digest files beside each input are the contract a
// second implementation must reproduce. Regenerate deliberately with
// UPDATE_CANONICAL_FIXTURES=1 after changing the rules, never by accident.
func TestCanonicalFixtures(t *testing.T) {
	dir := fixtureDir(t, "canonical")
	inputs, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	if len(inputs) < 5 {
		t.Fatalf("expected fixtures in %s", dir)
	}
	for _, in := range inputs {
		raw, err := os.ReadFile(in)
		if err != nil {
			t.Fatal(err)
		}
		got, err := CanonicalizeJSON(raw)
		if err != nil {
			t.Fatalf("%s: %v", in, err)
		}
		base := strings.TrimSuffix(in, ".json")
		if os.Getenv("UPDATE_CANONICAL_FIXTURES") == "1" {
			os.WriteFile(base+".canonical", got, 0o644)
			os.WriteFile(base+".digest", []byte(DigestBytes(got)+"\n"), 0o644)
			continue
		}
		want, err := os.ReadFile(base + ".canonical")
		if err != nil {
			t.Fatalf("%s: no .canonical file; run with UPDATE_CANONICAL_FIXTURES=1", in)
		}
		if string(got) != string(want) {
			t.Errorf("%s:\n got %s\nwant %s", in, got, want)
		}
		wantDigest, _ := os.ReadFile(base + ".digest")
		if DigestBytes(got) != strings.TrimSpace(string(wantDigest)) {
			t.Errorf("%s: digest %s, want %s", in, DigestBytes(got), strings.TrimSpace(string(wantDigest)))
		}
	}
}

func TestCanonicalRulesInDetail(t *testing.T) {
	cases := map[string]string{
		`{"b":1,"a":2}`:                         `{"a":2,"b":1}`,
		`{"é":1,"z":2,"Z":3}`:                   `{"Z":3,"z":2,"é":1}`, // bytewise: Z < z < é
		`"a\/b"`:                                `"a/b"`,
		`"\u2028"`:                              "\"\u2028\"",
		`"\u0001\u001f\t"`:                      `"\u0001\u001f\t"`,
		`"\u00e9"`:                              `"é"`,
		`-0`:                                    `0`,
		`-0.0`:                                  `0`,
		`1.0`:                                   `1`,
		`1E2`:                                   `100`,
		`1e21`:                                  `1e+21`,
		`1e20`:                                  `100000000000000000000`,
		`1e-7`:                                  `1e-7`,
		`0.000001`:                              `0.000001`,
		`0.0000001`:                             `1e-7`,
		`-2.5e-3`:                               `-0.0025`,
		`0.30000000000000004`:                   `0.30000000000000004`,
		`9007199254740993`:                      `9007199254740993`, // integer literal kept exactly
		`[1, 2 ,3]`:                             `[1,2,3]`,
		`{"k": [{"b": 2, "a": 1}]}`:             `{"k":[{"a":1,"b":2}]}`,
		`{"a":{"c":null,"b":true,"a":false}}`:   `{"a":{"a":false,"b":true,"c":null}}`,
		"{\"s\":\"caf\u00e9 \U0001F600\"}":      "{\"s\":\"caf\u00e9 \U0001F600\"}",
		`{"s":"quote \" and backslash \\ end"}`: `{"s":"quote \" and backslash \\ end"}`,
	}
	for in, want := range cases {
		got, err := CanonicalizeJSON([]byte(in))
		if err != nil {
			t.Errorf("%s: %v", in, err)
			continue
		}
		if string(got) != want {
			t.Errorf("%s: got %s want %s", in, got, want)
		}
	}
	for _, bad := range []string{`{"a":1} x`, "\"\xff\"", `NaN`} {
		if _, err := CanonicalizeJSON([]byte(bad)); err == nil {
			t.Errorf("%q must be rejected", bad)
		}
	}
	if s, _ := FormatNumber(0.6); s != "0.6" {
		t.Errorf("0.6 -> %s", s)
	}
	if s, _ := FormatNumber(123456789012345680000); s != "123456789012345680000" {
		t.Errorf("large -> %s", s)
	}
	if _, err := FormatNumber(1.0 / zero()); err == nil {
		t.Error("infinity must be an error")
	}
}

func zero() float64 { return 0 }

func TestPackageAndConditionsDigests(t *testing.T) {
	wp := WorkPackage{Schema: SchemaWorkPackage, PackageID: NewULID(), Objective: "x", Completion: Completion{Conditions: []string{"b", "a"}}}
	d1, _ := PackageDigest(wp)
	wp2 := wp
	wp2.Objective = "y"
	d2, _ := PackageDigest(wp2)
	if d1 == d2 {
		t.Fatal("different packages must differ")
	}
	c1, _ := ConditionsDigest([]string{"b", "a"})
	c2, _ := ConditionsDigest([]string{"a", "b"})
	if c1 == c2 {
		t.Fatal("condition order is part of the mapping")
	}
	e1, _ := ConditionsDigest(nil)
	e2, _ := ConditionsDigest([]string{})
	if e1 != e2 {
		t.Fatal("nil and empty conditions digest alike")
	}
}
