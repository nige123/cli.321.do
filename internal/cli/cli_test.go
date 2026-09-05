package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/tool"
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

type noNetStub struct{}

func (noNetStub) Name() string { return "stubllm" }
func (noNetStub) Detect() adapter.Detection {
	return adapter.Detection{Available: true, Version: "t"}
}
func (noNetStub) Enforcement() adapter.Enforcement {
	return adapter.Enforcement{protocol.FeatToolAllowlist: true, protocol.FeatStructuredOutput: true, protocol.FeatTurnLimit: true, protocol.FeatSpendLimit: true, protocol.FeatGracefulStop: true}
}
func (noNetStub) Run(ctx context.Context, spec adapter.Spec, ctl adapter.Control) (adapter.Outcome, error) {
	return adapter.Outcome{Status: protocol.StatusCompleted, Summary: "stub", Conditions: []protocol.ConditionProof{{Met: true, Proof: "stub"}}}, nil
}

func TestShellDoesNotImplyNetworkAndTheGrantMustBeExplicit(t *testing.T) {
	tp := devTrust(t)
	reg := adapter.NewRegistry()
	reg.RegisterHidden(adapter.NewProcedure())
	reg.Register(noNetStub{})
	runWith := func(args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		code := Main(Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb, Args: args, TrustPath: tp, Home: t.TempDir(), Adapters: reg})
		return code, out.String(), errb.String()
	}
	// helper lists shell.run as optional; granting it without a network
	// grant leaves a shell that could reach the network unrestricted.
	code, out, _ := runWith("--grant", "shell.run", "helper", "build something")
	if code != wire.ExitDenied || !strings.Contains(out, "network_deny") {
		t.Fatalf("expected denial naming network_deny: %d %s", code, out)
	}
	code, out, _ = runWith("--grant", "shell.run", "--network", "open", "helper", "build something")
	if code != 0 {
		t.Fatalf("an explicit open network grant should run: %d %s", code, out)
	}
	code, _, errb := runWith("--network", "wide", "helper", "build something")
	if code != wire.ExitUsage || !strings.Contains(errb, "--network must be") {
		t.Fatalf("bad network value: %d %s", code, errb)
	}
}

// ---------------------------------------------------------------------
// tool bindings: the unbranded operator fixture through the CLI
// ---------------------------------------------------------------------

func operatorTrust(t *testing.T) string {
	t.Helper()
	dir := fixture(t, "example.test/operator")
	d, _, _ := digest.Compute(dir)
	return trustFile(t, &trust.Config{Schema: protocol.SchemaTrustConfig,
		Publishers: map[string]trust.Publisher{"example.test": {Packages: map[string]trust.Pin{"operator": {Path: dir, Version: "0.1.0", Digest: d, Trust: trust.LevelDevelopment}}}},
		Aliases:    map[string]string{"op": "example.test/operator"},
	})
}

// modelTrapCLI fails the test if any non-procedure adapter is selected.
type modelTrapCLI struct{ t *testing.T }

func (m modelTrapCLI) Name() string { return "modeltrap" }
func (m modelTrapCLI) Detect() adapter.Detection {
	return adapter.Detection{Available: true, Version: "trap"}
}
func (m modelTrapCLI) Enforcement() adapter.Enforcement {
	e := adapter.Enforcement{}
	for _, f := range protocol.Features() {
		e[f] = true
	}
	return e
}
func (m modelTrapCLI) Run(ctx context.Context, spec adapter.Spec, ctl adapter.Control) (adapter.Outcome, error) {
	m.t.Fatalf("a model adapter ran for %q", spec.Package.Objective)
	return adapter.Outcome{}, nil
}

func operatorCLI(t *testing.T, bound bool) (func(args ...string) (int, string, string, string), string) {
	t.Helper()
	tp := operatorTrust(t)
	log := filepath.Join(t.TempDir(), "engine.log")
	de := &tool.DeployEngine{}
	if bound {
		bin, _ := filepath.Abs(filepath.Join("..", "..", "testdata", "fakeengine", "deploy-engine"))
		de = &tool.DeployEngine{Bin: bin, Env: append(os.Environ(), "FAKE_ENGINE_LOG="+log)}
	}
	reg := adapter.NewRegistry()
	reg.RegisterHidden(adapter.NewProcedureWithTools(tool.Registry{"deploy_engine": de}))
	reg.Register(modelTrapCLI{t})
	home := t.TempDir()
	run := func(args ...string) (int, string, string, string) {
		var out, errb bytes.Buffer
		code := Main(Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb, Args: args, TrustPath: tp, Home: home, Adapters: reg})
		return code, out.String(), errb.String(), home
	}
	return run, log
}

func TestOperatorStatusByAliasAndByCanonicalIDUsesNoModel(t *testing.T) {
	run, log := operatorCLI(t, true)
	code, out, errb, _ := run("op", "status")
	if code != 0 {
		t.Fatalf("alias: %d\n%s\n%s", code, out, errb)
	}
	if !strings.Contains(out, "COMPLETED") || !strings.Contains(out, "Cost: none (no model was used)") || !strings.Contains(out, "alpha.web running") {
		t.Fatalf("transcript: %s", out)
	}
	code, out, errb, _ = run("example.test/operator", "status", "alpha.web", "live")
	if code != 0 || !strings.Contains(out, "Tool: deploy_engine status status alpha.web live --json (ok)") {
		t.Fatalf("canonical id: %d\n%s\n%s", code, out, errb)
	}
	b, _ := os.ReadFile(log)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	for i := range lines {
		lines[i] = strings.TrimSpace(lines[i])
	}
	if len(lines) != 2 || lines[0] != "status --json" || lines[1] != "status alpha.web live --json" {
		t.Fatalf("engine invocations: %q", lines)
	}
}

func TestOperatorPlanWritesAProposalAndAmbiguityAsksNonInteractively(t *testing.T) {
	run, _ := operatorCLI(t, true)
	code, out, _, home := run("--non-interactive", "op", "plan", "alpha.web", "live", "revision", "0f94b03")
	if code != 0 || !strings.Contains(out, "Proposal: ") || !strings.Contains(out, "it is a plan, not an approval, and nothing was deployed") {
		t.Fatalf("plan: %d %s", code, out)
	}
	runs, _ := os.ReadDir(filepath.Join(home, "runs"))
	var p protocol.DeploymentProposal
	b, err := os.ReadFile(filepath.Join(home, "runs", runs[len(runs)-1].Name(), "proposal.json"))
	if err != nil {
		t.Fatal("proposal.json must be written beside the receipt")
	}
	if json.Unmarshal(b, &p) != nil || p.Status != "planned" || p.Revision["sha"] != "0f94b03" {
		t.Fatalf("proposal: %s", b)
	}
	if ps := protocol.ValidateDeploymentProposal(&p); len(ps) > 0 {
		t.Fatalf("proposal invalid: %v", ps)
	}
	code, out, _, _ = run("--non-interactive", "op", "plan", "live")
	if code != wire.ExitBlocked || !strings.Contains(out, "Which service") {
		t.Fatalf("ambiguous: %d %s", code, out)
	}
}

func TestOperatorGoIsPreparedNotExecutedEvenWithAGrant(t *testing.T) {
	run, log := operatorCLI(t, true)
	code, out, _, _ := run("--grant", "deploy.invoke", "op", "go", "alpha.web", "live", "revision", "0f94b03")
	if code != wire.ExitBlocked {
		t.Fatalf("go: %d %s", code, out)
	}
	for _, want := range []string{"BLOCKED", "execution is unavailable in this development slice", "nothing was deployed", "Tool: deploy_engine execute  (not performed)", "Proposal: "} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(strings.ToLower(out), "deployed successfully") {
		t.Fatal("must never read as deployed")
	}
	b, _ := os.ReadFile(log)
	if lines := strings.Split(strings.TrimSpace(string(b)), "\n"); len(lines) != 1 || !strings.HasPrefix(lines[0], "plan ") {
		t.Fatalf("only plan reached the engine: %q", lines)
	}
}

func TestOperatorUnsupportedRequestAndUnboundEngine(t *testing.T) {
	run, _ := operatorCLI(t, true)
	code, out, _, _ := run("--non-interactive", "op", "restart", "alpha.web")
	if code != wire.ExitBlocked || !strings.Contains(out, "Unsupported request") {
		t.Fatalf("unsupported: %d %s", code, out)
	}
	run, _ = operatorCLI(t, false)
	code, out, _, _ = run("op", "status")
	if code != wire.ExitFailed || !strings.Contains(out, "DEPLOY_ENGINE_BIN") {
		t.Fatalf("unbound: %d %s", code, out)
	}
}

func TestDoctorListsTheToolBinding(t *testing.T) {
	reg := adapter.NewRegistry()
	reg.RegisterHidden(adapter.NewProcedureWithTools(tool.Registry{"deploy_engine": &tool.DeployEngine{Bin: "/opt/engine/bin/deploy-engine"}}))
	var out bytes.Buffer
	Main(Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &out, Args: []string{"doctor"}, TrustPath: "", Home: t.TempDir(), Adapters: reg})
	if !strings.Contains(out.String(), "deploy_engine: /opt/engine/bin/deploy-engine; execute unavailable; operations: status (deploy.read), plan (deploy.plan), execute (deploy.invoke)") {
		t.Fatalf("doctor: %s", out.String())
	}
}
