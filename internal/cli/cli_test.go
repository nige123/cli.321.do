package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
	"cli.321.do/internal/wire"
)

func fixture(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "testdata", "packages", rel))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func testRegistry() *adapter.Registry {
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedure())
	r.RegisterHidden(adapter.NewFake(nil))
	return r
}

func runCLI(t *testing.T, trustPath string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	home := t.TempDir()
	code := Main(Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb, Args: args, TrustPath: trustPath, Home: home, Adapters: testRegistry()})
	return code, out.String(), errb.String()
}

func trustFile(t *testing.T, cfg *trust.Config) string {
	t.Helper()
	b, _ := json.Marshal(cfg)
	p := filepath.Join(t.TempDir(), "trust.json")
	os.WriteFile(p, b, 0o600)
	return p
}

func devTrust(t *testing.T) string {
	t.Helper()
	dir := fixture(t, "example.test/helper")
	d, _, _ := digest.Compute(dir)
	return trustFile(t, &trust.Config{Schema: protocol.SchemaTrustConfig,
		Publishers: map[string]trust.Publisher{"example.test": {Packages: map[string]trust.Pin{"helper": {Path: dir, Version: "1.2.0", Digest: d, Trust: trust.LevelDevelopment}}}},
		Aliases:    map[string]string{"helper": "example.test/helper"},
		Policy:     trust.Policy{Adapters: trust.AdapterPolicy{Preferred: []string{"fake"}}},
	})
}

func TestUsageAndReservedWords(t *testing.T) {
	code, out, _ := runCLI(t, "", "help")
	if code != 0 || !strings.Contains(out, "321 <agent> <request...>") {
		t.Fatalf("help: %d %s", code, out)
	}
	code, _, errb := runCLI(t, "")
	if code != wire.ExitUsage {
		t.Fatalf("no args is a usage error: %d %s", code, errb)
	}
	code, _, errb = runCLI(t, "", "--bogus", "helper", "x")
	if code != wire.ExitUsage || !strings.Contains(errb, "unknown option") {
		t.Fatalf("unknown option: %d %s", code, errb)
	}
	code, out, _ = runCLI(t, "", "version")
	if code != 0 || !strings.HasPrefix(out, "321 ") {
		t.Fatalf("version: %s", out)
	}
}

func TestStandaloneRequestRunsAProcedureThroughTheSamePath(t *testing.T) {
	home := t.TempDir()
	var out, errb bytes.Buffer
	code := Main(Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb, Home: home, Adapters: testRegistry(),
		Args: []string{"--package-dir", fixture(t, "local/helper"), "--done", "a note exists", "helper", "note:", "remember", "the", "milk; rm -rf /"}})
	if code != 0 {
		t.Fatalf("exit %d\nstdout %s\nstderr %s", code, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "COMPLETED") || !strings.Contains(out.String(), "✓ 1.") {
		t.Fatalf("transcript: %s", out.String())
	}
	runs, _ := os.ReadDir(filepath.Join(home, "runs"))
	if len(runs) != 1 {
		t.Fatal("one run directory expected")
	}
	runDir := filepath.Join(home, "runs", runs[0].Name())
	var wp protocol.WorkPackage
	b, _ := os.ReadFile(filepath.Join(runDir, "work-package.json"))
	json.Unmarshal(b, &wp)
	if wp.Objective != "note: remember the milk; rm -rf /" {
		t.Fatalf("the request must be carried verbatim as text, never interpreted: %q", wp.Objective)
	}
	if wp.Issuer.Kind != "local" || wp.Approval != nil {
		t.Fatal("a standalone package is issued locally and carries no approval")
	}
	if _, err := os.Stat(filepath.Join(runDir, "receipt.json")); err != nil {
		t.Fatal("receipt must be written")
	}
	if _, err := os.Stat(filepath.Join(runDir, "instruction-history.ndjson")); err != nil {
		t.Fatal("history must be written")
	}
}

func TestAliasResolutionThroughTheTrustFile(t *testing.T) {
	tp := devTrust(t)
	code, out, errb := runCLI(t, tp, "helper", "note: via alias")
	if code != 0 {
		t.Fatalf("exit %d %s %s", code, out, errb)
	}
	if !strings.Contains(errb, "administrator-pinned") {
		t.Fatalf("the trust label must be shown: %s", errb)
	}
	code, _, errb = runCLI(t, tp, "example.test/helper", "note: via canonical id")
	if code != 0 {
		t.Fatalf("canonical id: %d %s", code, errb)
	}
	code, _, errb = runCLI(t, tp, "stranger", "note: x")
	if code != wire.ExitDenied || !strings.Contains(errb, "no agent") {
		t.Fatalf("unknown agent: %d %s", code, errb)
	}
	code, _, errb = runCLI(t, tp, "helper")
	if code != wire.ExitUsage || !strings.Contains(errb, "what should helper do") {
		t.Fatalf("empty request: %d %s", code, errb)
	}
}

func TestAPackageDirMustMatchTheNamedAgent(t *testing.T) {
	code, _, errb := runCLI(t, "", "--package-dir", fixture(t, "local/helper"), "other", "note: x")
	if code != wire.ExitDenied || !strings.Contains(errb, "is local/helper, not other") {
		t.Fatalf("%d %s", code, errb)
	}
	code, _, errb = runCLI(t, "", "--package-dir", fixture(t, "example.test/helper"), "helper", "note: x")
	if code != wire.ExitDenied || !strings.Contains(errb, "declares publisher") {
		t.Fatalf("a self-declared publisher must not load by path: %d %s", code, errb)
	}
}

func TestGrantsStayInsidePackageAndPolicy(t *testing.T) {
	tp := devTrust(t)
	code, _, errb := runCLI(t, tp, "--grant", "deploy.invoke", "helper", "note: x")
	if code != wire.ExitUsage || !strings.Contains(errb, "does not list it as optional") {
		t.Fatalf("a grant the package does not offer is refused: %d %s", code, errb)
	}
	dir := fixture(t, "example.test/helper")
	d, _, _ := digest.Compute(dir)
	strict := trustFile(t, &trust.Config{Schema: protocol.SchemaTrustConfig,
		Publishers: map[string]trust.Publisher{"example.test": {Packages: map[string]trust.Pin{"helper": {Path: dir, Version: "1.2.0", Digest: d, Trust: trust.LevelDevelopment}}}},
		Aliases:    map[string]string{"helper": "example.test/helper"},
		Policy:     trust.Policy{CapabilityCeiling: []string{protocol.CapModelText}}})
	code, _, errb = runCLI(t, strict, "helper", "note: x")
	if code != wire.ExitUsage || !strings.Contains(errb, "local policy does not allow repo.read") {
		t.Fatalf("policy ceiling: %d %s", code, errb)
	}
}

func TestInspectionCommands(t *testing.T) {
	tp := devTrust(t)
	code, out, _ := runCLI(t, tp, "agents")
	if code != 0 || !strings.Contains(out, "example.test/helper") || !strings.Contains(out, "development") || !strings.Contains(out, "alias helper") {
		t.Fatalf("agents: %d %s", code, out)
	}
	code, out, _ = runCLI(t, tp, "packages", "validate", fixture(t, "example.test/helper"))
	if code != 0 || !strings.HasPrefix(out, "OK example.test/helper 1.2.0 sha256:") {
		t.Fatalf("validate: %d %s", code, out)
	}
	code, out, _ = runCLI(t, tp, "packages", "show", "helper")
	if code != 0 || !strings.Contains(out, "administrator-pinned") || !strings.Contains(out, "procedures:") {
		t.Fatalf("show: %d %s", code, out)
	}
	code, out, _ = runCLI(t, tp, "trust", "check")
	if code != 0 || !strings.Contains(out, "ok   example.test/helper") {
		t.Fatalf("trust check: %d %s", code, out)
	}
	code, out, _ = runCLI(t, tp, "doctor")
	if code != 0 || !strings.Contains(out, "fake") || !strings.Contains(out, "enforces:") {
		t.Fatalf("doctor: %d %s", code, out)
	}
	bad := trustFile(t, &trust.Config{Schema: protocol.SchemaTrustConfig, Aliases: map[string]string{"run": "local/x"}})
	code, _, errb := runCLI(t, bad, "agents")
	if code != wire.ExitInternal || !strings.Contains(errb, "reserved") {
		t.Fatalf("a reserved alias is refused at load: %d %s", code, errb)
	}
}

func TestRunSubcommandParsesItsOptions(t *testing.T) {
	code, _, errb := runCLI(t, "", "run", "--nope")
	if code != wire.ExitUsage || !strings.Contains(errb, "unknown option") {
		t.Fatalf("%d %s", code, errb)
	}
}
