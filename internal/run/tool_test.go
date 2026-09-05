package run

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/tool"
	"cli.321.do/internal/trust"
)

// The deploy_engine tool binding through the runner, with the unbranded
// operator fixture and the recording fake engine. Nothing here needs a
// model, a network, or a real engine.

func operator(t *testing.T) *trust.Loaded {
	t.Helper()
	dir := fixture(t, "example.test/operator")
	d, _, err := digest.Compute(dir)
	if err != nil {
		t.Fatal(err)
	}
	c := &trust.Config{Schema: protocol.SchemaTrustConfig, Publishers: map[string]trust.Publisher{"example.test": {
		Packages: map[string]trust.Pin{"operator": {Path: dir, Version: "0.1.0", Digest: d, Trust: trust.LevelDevelopment}},
	}}}
	r, err := c.Resolve("example.test/operator")
	if err != nil {
		t.Fatal(err)
	}
	l, err := trust.LoadResolved(r)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// modelTrap is an adapter that would be selected for any non-procedure
// request; selecting it fails the test.
type modelTrap struct{ t *testing.T }

func (m modelTrap) Name() string { return "modeltrap" }
func (m modelTrap) Detect() adapter.Detection {
	return adapter.Detection{Available: true, Version: "trap"}
}
func (m modelTrap) Enforcement() adapter.Enforcement {
	e := adapter.Enforcement{}
	for _, f := range protocol.Features() {
		e[f] = true
	}
	return e
}
func (m modelTrap) Run(ctx context.Context, spec adapter.Spec, ctl adapter.Control) (adapter.Outcome, error) {
	m.t.Fatalf("a model adapter was selected for objective %q", spec.Package.Objective)
	return adapter.Outcome{}, nil
}

func toolRegistry(t *testing.T, env ...string) (*adapter.Registry, string) {
	t.Helper()
	bin, _ := filepath.Abs(filepath.Join("..", "..", "testdata", "fakeengine", "deploy-engine"))
	log := filepath.Join(t.TempDir(), "engine.log")
	de := &tool.DeployEngine{Bin: bin, Env: append(append(os.Environ(), "FAKE_ENGINE_LOG="+log), env...), Timeout: 30 * time.Second}
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedureWithTools(tool.Registry{"deploy_engine": de}))
	r.Register(modelTrap{t})
	return r, log
}

func engineLog(log string) []string {
	b, err := os.ReadFile(log)
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	for i := range lines {
		lines[i] = strings.TrimSpace(lines[i])
	}
	return lines
}

func opPkg(agent *trust.Loaded, objective string, grants ...string) *protocol.WorkPackage {
	wp := pkgFor(agent, objective)
	if grants == nil {
		grants = []string{protocol.CapDeployRead, protocol.CapDeployPlan}
	}
	wp.Capabilities.Granted = grants
	return wp
}

func TestStatusIsADeterministicToolCallWithNoModel(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	col := newCollector()
	r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, "status alpha.web live"), agent, Options{Sink: col})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted {
		t.Fatalf("%s: %v", r.Status, r.Evidence.Errors)
	}
	if col.count(protocol.EventAdapterSelected) != 0 || col.count(protocol.EventProcedureSelected) != 1 {
		t.Fatal("a procedure, never an adapter")
	}
	if r.Cost.USD != 0 || r.Cost.Basis != protocol.CostNone {
		t.Fatalf("no model cost, and the receipt says so: %+v", r.Cost)
	}
	if got := engineLog(log); len(got) != 1 || got[0] != "status alpha.web live --json" {
		t.Fatalf("argv: %q", got)
	}
	if len(r.Evidence.ToolCalls) != 1 || r.Evidence.ToolCalls[0].Capability != protocol.CapDeployRead || !r.Evidence.ToolCalls[0].Ok {
		t.Fatalf("tool call: %+v", r.Evidence.ToolCalls)
	}
	if !strings.Contains(r.Summary, "alpha.web running") {
		t.Fatalf("summary: %s", r.Summary)
	}
	if r.Evidence.Proposal != nil {
		t.Fatal("status makes no proposal")
	}
}

func TestPlanBindsAnExactRevisionAndYieldsAValidProposal(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	wp := opPkg(agent, "plan alpha.web live revision 0f94b03cf776c9b4ca9fe028d6879557f8d06bb3")
	r := (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted {
		t.Fatalf("%s: %v %s", r.Status, r.Evidence.Errors, r.BlockedOn)
	}
	p := r.Evidence.Proposal
	if p == nil {
		t.Fatal("no proposal on the receipt")
	}
	if ps := protocol.ValidateDeploymentProposal(p); len(ps) > 0 {
		t.Fatalf("proposal invalid: %v", ps)
	}
	if p.Service != "alpha.web" || p.Target != "live" || p.Revision["sha"] != "0f94b03cf776c9b4ca9fe028d6879557f8d06bb3" || p.Revision["source"] != "requested" {
		t.Fatalf("binding: %+v", p)
	}
	if p.PackageID != wp.PackageID || p.Agent.ID != "example.test/operator" || p.Agent.Digest != agent.Digest {
		t.Fatalf("provenance: %+v", p.Agent)
	}
	if strings.Join(p.Unperformed, ",") != "tests,apt_deps" {
		t.Fatalf("unperformed checks must stay visible: %v", p.Unperformed)
	}
	if d, _ := protocol.ProposalDigest(*p); d != p.ProposalDigest {
		t.Fatal("digest must recompute")
	}
	if got := engineLog(log); len(got) != 1 || !strings.HasPrefix(got[0], "plan alpha.web live --revision 0f94b03") {
		t.Fatalf("argv: %q", got)
	}
}

func TestAmbiguousTargetsBlockWithAQuestionNeverAGuess(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	cases := map[string]string{
		"plan live":            "Which service",
		"plan alpha.web":       "Which target",
		"plan alpha.web stage": "no target 'stage'",
		"plan gamma.web live":  "No service is named exactly",
	}
	for objective, want := range cases {
		r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, objective), agent, Options{})
		if r.Status != protocol.StatusBlocked || !strings.Contains(r.BlockedOn, want) {
			t.Errorf("%q: %s %q, want blocked mentioning %q", objective, r.Status, r.BlockedOn, want)
		}
		if r.Evidence.Proposal == nil || r.Evidence.Proposal.Status != "blocked" {
			t.Errorf("%q: the blocked plan is still recorded as a blocked proposal", objective)
		}
	}
	for _, line := range engineLog(log) {
		if !strings.HasPrefix(line, "plan ") {
			t.Fatalf("only plan reached the engine: %q", line)
		}
	}
}

func TestUnknownAndInjectedRequestsNeverReachTheEngine(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	for _, objective := range []string{
		"deploy alpha.web to live now",
		"restart alpha.web",
		"status alpha.web; rm -rf /",
		"plan alpha.web live --force",
		"plan alpha.web live revision master",
		"go alpha.web live && touch /tmp/x",
	} {
		r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, objective), agent, Options{})
		if r.Status != protocol.StatusBlocked || !strings.Contains(r.BlockedOn, "Unsupported request") {
			t.Errorf("%q: %s %q", objective, r.Status, r.BlockedOn)
		}
	}
	if _, err := os.Stat(log); err == nil {
		t.Fatalf("the engine was invoked: %v", engineLog(log))
	}
}

func TestGoPreparesTheProposalAndReportsExecutionUnavailable(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	wp := opPkg(agent, "go alpha.web live revision 0f94b03", protocol.CapDeployRead, protocol.CapDeployPlan, protocol.CapDeployInvoke)
	// Even an approval on the package changes nothing in this build.
	h, _ := protocol.ParamsHash(map[string]any{})
	wp.Approval = &protocol.Approval{ProposalRef: "p", ApprovalRef: "a", ApprovedBy: "user:1", Action: "deploy", Target: "alpha.web@live", Params: map[string]any{}, ParamsHash: h}
	r := (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{})
	checkReceipt(t, r)
	if r.Status != protocol.StatusBlocked || !strings.Contains(r.BlockedOn, "execution is unavailable") || !strings.Contains(r.BlockedOn, "nothing was deployed") {
		t.Fatalf("%s: %q", r.Status, r.BlockedOn)
	}
	if r.Evidence.Proposal == nil || r.Evidence.Proposal.Status != "planned" {
		t.Fatal("the proposal must still be prepared")
	}
	if !strings.Contains(r.BlockedOn, r.Evidence.Proposal.ProposalID) {
		t.Fatal("the answer names the proposal")
	}
	if len(r.Evidence.ToolCalls) != 2 || r.Evidence.ToolCalls[1].Op != "execute" || r.Evidence.ToolCalls[1].Unavailable == "" || r.Evidence.ToolCalls[1].Argv != nil {
		t.Fatalf("the execute call is recorded as not performed: %+v", r.Evidence.ToolCalls)
	}
	if got := engineLog(log); len(got) != 1 || !strings.HasPrefix(got[0], "plan ") {
		t.Fatalf("only plan reached the engine: %q", got)
	}
	if r.Evidence.ExternalAction != nil {
		t.Fatal("no external action may be recorded")
	}
}

func TestGoWithoutTheInvokeGrantIsStillPreparedAndStillNotExecuted(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, "go alpha.web live revision 0f94b03"), agent, Options{})
	if r.Status != protocol.StatusBlocked || !strings.Contains(r.BlockedOn, "execution is unavailable") || !strings.Contains(r.BlockedOn, "deploy.invoke is not granted") {
		t.Fatalf("%s: %q", r.Status, r.BlockedOn)
	}
	if r.Evidence.Proposal == nil || r.Evidence.Proposal.Status != "planned" {
		t.Fatal("the proposal is prepared")
	}
	if got := engineLog(log); len(got) != 1 || !strings.HasPrefix(got[0], "plan ") {
		t.Fatalf("only plan reached the engine: %q", got)
	}
}

func TestGrantsAreCheckedPerOperation(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t)
	// deploy.plan is required by the package, so a package granting only
	// deploy.read is denied before any procedure runs.
	r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, "status", protocol.CapDeployRead), agent, Options{})
	if r.Status != protocol.StatusDenied {
		t.Fatalf("missing required capability: %s", r.Status)
	}
	if _, err := os.Stat(log); err == nil {
		t.Fatal("nothing may run under a denial")
	}
}

func TestStopDuringAToolCallPreservesEvidenceAndRunsNothingMore(t *testing.T) {
	agent := operator(t)
	reg, log := toolRegistry(t, "FAKE_ENGINE_SLEEP=3")
	wp := opPkg(agent, "go alpha.web live")
	ch := make(chan protocol.WorkDirective, 4)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventToolCall, nil)
	// the engine has been invoked once it has written its argv
	deadline := time.Now().Add(10 * time.Second)
	for len(engineLog(log)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the engine never started")
		}
		time.Sleep(5 * time.Millisecond)
	}
	stop := directive(wp.PackageID, 1, protocol.DirectiveStop, "stop planning")
	ch <- stop
	r := <-done
	checkReceipt(t, r)
	if r.Status != protocol.StatusStopped || r.Stop == nil || r.Stop.DirectiveID != stop.DirectiveID {
		t.Fatalf("expected a stop: %s %+v", r.Status, r.Stop)
	}
	if len(r.Evidence.ToolCalls) != 1 || r.Evidence.ToolCalls[0].Op != "plan" {
		t.Fatalf("the interrupted call is preserved and nothing after it ran: %+v", r.Evidence.ToolCalls)
	}
	if got := engineLog(log); len(got) != 1 {
		t.Fatalf("one engine invocation: %q", got)
	}
	if r.Evidence.Proposal != nil {
		t.Fatal("an interrupted plan yields no proposal")
	}
	// After the stop, a further request is a new run with its own package;
	// the stopped receipt is sealed.
	if d, _ := protocol.ReceiptDigest(*r); d != r.ReceiptDigest {
		t.Fatal("receipt sealed")
	}
}

func TestAReplacementProposalNamesItsPredecessorAndLeavesItHistorical(t *testing.T) {
	agent := operator(t)
	reg, _ := toolRegistry(t)
	first := opPkg(agent, "plan alpha.web live")
	r1 := (&Runner{Adapters: reg}).Run(context.Background(), first, agent, Options{})
	if r1.Status != protocol.StatusCompleted || r1.Evidence.Proposal == nil {
		t.Fatal("first plan")
	}
	sealed := r1.ReceiptDigest
	old := r1.Evidence.Proposal.ProposalDigest

	second := opPkg(agent, "plan alpha.web live revision 0f94b03")
	second.SupersedesPackageID = first.PackageID
	r2 := (&Runner{Adapters: reg}).Run(context.Background(), second, agent, Options{})
	if r2.Status != protocol.StatusCompleted || r2.Evidence.Proposal == nil {
		t.Fatal("second plan")
	}
	p2 := r2.Evidence.Proposal
	if p2.SupersedesPackageID != first.PackageID || p2.PackageID != second.PackageID {
		t.Fatalf("the replacement names its predecessor: %+v", p2)
	}
	if p2.ProposalDigest == old || p2.ProposalID == r1.Evidence.Proposal.ProposalID {
		t.Fatal("a replacement is a new proposal")
	}
	if r1.ReceiptDigest != sealed || r1.Evidence.Proposal.ProposalDigest != old || r1.SupersedesPackageID != "" {
		t.Fatal("the superseded receipt and proposal are untouched")
	}
}

// The execution boundary with a RECORDING executor bound: the shape the
// real boundary will have, exercised without deploying anything.

func boundRegistry(t *testing.T, env ...string) (*adapter.Registry, string, *tool.RecordingExecutor) {
	t.Helper()
	bin, _ := filepath.Abs(filepath.Join("..", "..", "testdata", "fakeengine", "deploy-engine"))
	log := filepath.Join(t.TempDir(), "engine.log")
	ex := &tool.RecordingExecutor{}
	de := &tool.DeployEngine{Bin: bin, Env: append(append(os.Environ(), "FAKE_ENGINE_LOG="+log), env...), Timeout: 30 * time.Second, Exec: ex}
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedureWithTools(tool.Registry{"deploy_engine": de}))
	r.Register(modelTrap{t})
	return r, log, ex
}

// approvedPlan runs a plan and returns the proposal a person would approve
// and the approval bound to it.
func approvedPlan(t *testing.T, reg *adapter.Registry, agent *trust.Loaded) (*protocol.DeploymentProposal, *protocol.Approval) {
	t.Helper()
	r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, "plan alpha.web live revision 0f94b03"), agent, Options{})
	if r.Status != protocol.StatusCompleted || r.Evidence.Proposal == nil {
		t.Fatalf("plan: %s", r.Status)
	}
	p := r.Evidence.Proposal
	params := tool.ApprovalParams(p)
	h, _ := protocol.ParamsHash(params)
	return p, &protocol.Approval{ProposalRef: "entry:1", ApprovalRef: "reaction:1", ApprovedBy: "user:1", Action: "deploy",
		Target: p.Service + "@" + p.Target, Params: params, ParamsHash: h, Proposal: p}
}

func TestAnApprovedGoIsExecutedByTheBoundExecutorAfterAFreshMatchingPlan(t *testing.T) {
	agent := operator(t)
	reg, log, ex := boundRegistry(t)
	approved, approval := approvedPlan(t, reg, agent)
	wp := opPkg(agent, "go alpha.web live revision 0f94b03", protocol.CapDeployRead, protocol.CapDeployPlan, protocol.CapDeployInvoke)
	wp.Approval = approval
	if ps := protocol.ValidateWorkPackage(wp); len(ps) > 0 {
		t.Fatalf("package with an embedded proposal must validate: %v", ps)
	}
	r := (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted {
		t.Fatalf("%s: %v %s", r.Status, r.Evidence.Errors, r.BlockedOn)
	}
	if len(ex.Calls) != 1 || !strings.HasPrefix(ex.Calls[0], approved.ProposalID) {
		t.Fatalf("executed exactly once for the approved proposal: %v", ex.Calls)
	}
	if r.Evidence.ExternalAction == nil || r.Evidence.ExternalAction.Target != "alpha.web@live" || r.Evidence.ExternalAction.ApprovalRef != "reaction:1" {
		t.Fatalf("external action: %+v", r.Evidence.ExternalAction)
	}
	if r.Evidence.ApprovalCheck == nil || !r.Evidence.ApprovalCheck.OperationMatched || !r.Evidence.ApprovalCheck.ParamsHashMatched {
		t.Fatalf("approval check: %+v", r.Evidence.ApprovalCheck)
	}
	// The fresh plan is recorded too, and it is a different proposal.
	if r.Evidence.Proposal == nil || r.Evidence.Proposal.ProposalID == approved.ProposalID {
		t.Fatal("the fresh plan is its own proposal")
	}
	if got := engineLog(log); len(got) != 2 || !strings.HasPrefix(got[1], "plan ") {
		t.Fatalf("the engine saw only plans; execution went to the executor: %q", got)
	}
}

func TestExecutionRefusesWhenTheStateMovedSinceApproval(t *testing.T) {
	agent := operator(t)
	reg, _, _ := boundRegistry(t)
	_, approval := approvedPlan(t, reg, agent)
	// The deployed revision on the target moved after the person approved.
	reg2, _, ex := boundRegistry(t, "FAKE_ENGINE_DEPLOYED="+strings.Repeat("9", 40))
	wp := opPkg(agent, "go alpha.web live revision 0f94b03", protocol.CapDeployRead, protocol.CapDeployPlan, protocol.CapDeployInvoke)
	wp.Approval = approval
	r := (&Runner{Adapters: reg2}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusFailed || !strings.Contains(strings.Join(r.Evidence.Errors, " "), "deployed revision has changed") {
		t.Fatalf("%s: %v", r.Status, r.Evidence.Errors)
	}
	if len(ex.Calls) != 0 {
		t.Fatalf("the executor must not be called: %v", ex.Calls)
	}
	if r.Evidence.ApprovalCheck == nil || r.Evidence.ApprovalCheck.OperationMatched {
		t.Fatalf("the check is recorded as failed: %+v", r.Evidence.ApprovalCheck)
	}
}

func TestExecutionRefusesAnApprovalForAnotherRevisionOrTarget(t *testing.T) {
	agent := operator(t)
	reg, _, ex := boundRegistry(t)
	_, approval := approvedPlan(t, reg, agent)
	for _, objective := range []string{"go alpha.web live revision 1234567", "go alpha.web dev revision 0f94b03", "go beta.web live revision 0f94b03"} {
		wp := opPkg(agent, objective, protocol.CapDeployRead, protocol.CapDeployPlan, protocol.CapDeployInvoke)
		wp.Approval = approval
		r := (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{})
		if r.Status != protocol.StatusFailed || r.EndedAt == "" {
			t.Errorf("%q: %s %v", objective, r.Status, r.Evidence.Errors)
		}
	}
	if len(ex.Calls) != 0 {
		t.Fatalf("nothing may execute: %v", ex.Calls)
	}
}

func TestExecutionNeedsAnApprovalAndTheInvokeGrant(t *testing.T) {
	agent := operator(t)
	reg, _, ex := boundRegistry(t)
	r := (&Runner{Adapters: reg}).Run(context.Background(), opPkg(agent, "go alpha.web live revision 0f94b03", protocol.CapDeployRead, protocol.CapDeployPlan, protocol.CapDeployInvoke), agent, Options{})
	if r.Status != protocol.StatusBlocked || !strings.Contains(r.BlockedOn, "needs a person's approval") {
		t.Fatalf("no approval: %s %q", r.Status, r.BlockedOn)
	}
	_, approval := approvedPlan(t, reg, agent)
	wp := opPkg(agent, "go alpha.web live revision 0f94b03")
	wp.Approval = approval
	r = (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusFailed || !strings.Contains(strings.Join(r.Evidence.Errors, " "), "deploy.invoke") {
		t.Fatalf("no grant: %s %v", r.Status, r.Evidence.Errors)
	}
	if len(ex.Calls) != 0 {
		t.Fatalf("nothing may execute: %v", ex.Calls)
	}
}

func TestATamperedEmbeddedProposalIsRefusedAtValidation(t *testing.T) {
	agent := operator(t)
	reg, _, _ := boundRegistry(t)
	_, approval := approvedPlan(t, reg, agent)
	tampered := *approval.Proposal
	tampered.Revision = map[string]any{"sha": strings.Repeat("9", 40), "source": "requested"}
	approval.Proposal = &tampered
	wp := opPkg(agent, "go alpha.web live revision 0f94b03", protocol.CapDeployRead, protocol.CapDeployPlan, protocol.CapDeployInvoke)
	wp.Approval = approval
	if ps := protocol.ValidateWorkPackage(wp); len(ps) == 0 {
		t.Fatal("an embedded proposal whose digest no longer matches must not validate")
	}
}
