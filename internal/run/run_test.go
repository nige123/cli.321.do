package run

import (
	"context"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
)

// ---------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------

func fixture(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "testdata", "packages", rel))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// helper loads example.test/helper through a development pin, which is
// how an unsigned package with a publisher identity is used in practice.
func helper(t *testing.T) *trust.Loaded {
	t.Helper()
	dir := fixture(t, "example.test/helper")
	d, _, err := digest.Compute(dir)
	if err != nil {
		t.Fatal(err)
	}
	c := &trust.Config{Schema: protocol.SchemaTrustConfig, Publishers: map[string]trust.Publisher{"example.test": {
		Packages: map[string]trust.Pin{"helper": {Path: dir, Version: "1.2.0", Digest: d, Trust: trust.LevelDevelopment}},
	}}}
	r, err := c.Resolve("example.test/helper")
	if err != nil {
		t.Fatal(err)
	}
	l, err := trust.LoadResolved(r)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func pkgFor(agent *trust.Loaded, objective string, conditions ...string) *protocol.WorkPackage {
	if conditions == nil {
		conditions = []string{}
	}
	return &protocol.WorkPackage{
		Schema: protocol.SchemaWorkPackage, PackageID: protocol.NewULID(),
		Issuer: protocol.Issuer{Kind: "test", ID: "t"}, IssuedAt: protocol.Now(),
		Correlation:  protocol.Correlation{Refs: []protocol.Ref{{Kind: "opaque", ID: "step:17"}}},
		Agent:        protocol.AgentRef{ID: agent.ID(), Version: agent.Manifest.Version, Digest: agent.Digest},
		Placement:    protocol.PlacementClient,
		Workspace:    protocol.Workspace{Kind: "none", Ownership: "caller"},
		Objective:    objective,
		Completion:   protocol.Completion{Conditions: conditions},
		Capabilities: protocol.Grants{Granted: []string{protocol.CapRepoRead}, Limits: protocol.Limits{}},
	}
}

func directive(pkg string, seq int, kind, text string) protocol.WorkDirective {
	d := protocol.WorkDirective{Schema: protocol.SchemaWorkDirective, DirectiveID: "d" + itoa(seq) + "-" + kind, PackageID: pkg, Seq: seq,
		Issuer: protocol.Issuer{Kind: "test", ID: "person"}, IssuedAt: protocol.Now(), Kind: kind, Payload: protocol.DirectivePayload{Text: text, Reason: text}}
	d.Digest, _ = protocol.DirectiveDigest(d)
	return d
}

func itoa(i int) string { return strings.TrimSpace(strings.Repeat(" ", 0) + string(rune('0'+i))) }

// collector gathers events and lets a test wait for one of a kind by
// polling, which cannot lose a wakeup however the scheduler behaves.
type collector struct {
	mu     sync.Mutex
	events []protocol.RunEvent
}

func newCollector() *collector { return &collector{} }

func (c *collector) Emit(e protocol.RunEvent) {
	c.mu.Lock()
	c.events = append(c.events, e)
	c.mu.Unlock()
}

func (c *collector) wait(t *testing.T, kind string, match func(protocol.RunEvent) bool) protocol.RunEvent {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		c.mu.Lock()
		for _, e := range c.events {
			if e.Kind == kind && (match == nil || match(e)) {
				c.mu.Unlock()
				return e
			}
		}
		kinds := c.kindsLocked()
		c.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s; saw %s", kind, kinds)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func (c *collector) kindsLocked() string {
	var ks []string
	for _, e := range c.events {
		ks = append(ks, e.Kind)
	}
	return strings.Join(ks, ",")
}

func (c *collector) count(kind string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, e := range c.events {
		if e.Kind == kind {
			n++
		}
	}
	return n
}

func fakeRegistry(script []protocol.ProcedureStep) *adapter.Registry {
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedure())
	r.RegisterHidden(adapter.NewFake(script))
	return r
}

func has(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// stubAdapter simulates a print-mode harness: no live steer, no pause,
// optional session continuation. Each call is one attempt.
type stubAdapter struct {
	enf     adapter.Enforcement
	mu      sync.Mutex
	specs   []adapter.Spec
	release chan struct{} // when set, the first attempt blocks until closed or cancelled
	cost    protocol.Cost
	status  string
}

func newStub(sessionContinue bool) *stubAdapter {
	e := adapter.Enforcement{protocol.FeatToolAllowlist: true, protocol.FeatStructuredOutput: true, protocol.FeatTurnLimit: true,
		protocol.FeatSpendLimit: true, protocol.FeatTimeout: true, protocol.FeatEventStream: true, protocol.FeatGracefulStop: true}
	if sessionContinue {
		e[protocol.FeatSessionContinue] = true
	}
	return &stubAdapter{enf: e, status: protocol.StatusCompleted}
}

func (s *stubAdapter) Name() string { return "stub" }
func (s *stubAdapter) Detect() adapter.Detection {
	return adapter.Detection{Available: true, Version: "stub"}
}
func (s *stubAdapter) Enforcement() adapter.Enforcement { return s.enf }
func (s *stubAdapter) Run(ctx context.Context, spec adapter.Spec, ctl adapter.Control) (adapter.Outcome, error) {
	s.mu.Lock()
	s.specs = append(s.specs, spec)
	n := len(s.specs)
	rel := s.release
	s.mu.Unlock()
	ctl.Emit(protocol.EventProgress, map[string]any{"text": "working"})
	if n == 1 && rel != nil {
		select {
		case <-rel:
		case <-ctx.Done():
			return adapter.Outcome{Status: protocol.StatusStopped, EndReason: "cancelled", SessionRef: "sess-1", Cost: s.cost}, nil
		}
	}
	conds := make([]protocol.ConditionProof, len(spec.Package.Completion.Conditions))
	for i := range conds {
		conds[i] = protocol.ConditionProof{Met: true, Proof: "stub attempt " + itoa(n)}
	}
	return adapter.Outcome{Status: s.status, EndReason: s.status, Summary: "stub done", Conditions: conds, SessionRef: "sess-" + itoa(n), Cost: s.cost}, nil
}

func (s *stubAdapter) attempts() []adapter.Spec {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]adapter.Spec(nil), s.specs...)
}

func stubRegistry(s *stubAdapter) *adapter.Registry {
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedure())
	r.Register(s)
	return r
}

func checkReceipt(t *testing.T, r *protocol.RunReceipt) {
	t.Helper()
	if ps := protocol.ValidateRunReceipt(r); len(ps) > 0 {
		t.Fatalf("receipt invalid: %v", ps)
	}
	if r.InstructionHistory.Digest == "" {
		t.Fatal("receipt must carry the instruction history digest")
	}
	if r.Correlation.Refs[0].ID != "step:17" {
		t.Fatal("correlation must be echoed verbatim")
	}
}

// ---------------------------------------------------------------------
// procedures, denials and approvals
// ---------------------------------------------------------------------

func TestAProcedureRunsWithoutAModelAndProducesAValidReceipt(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "note: remember the milk", "a note was taken")
	r := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{HistoryDir: t.TempDir()})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted || r.Harness.Adapter != "procedure" || r.Harness.Procedure != "note" {
		t.Fatalf("unexpected receipt: %+v", r)
	}
	if len(r.Conditions) != 1 || !r.Conditions[0].Met || r.Conditions[0].Proof != "the note procedure ran" {
		t.Fatalf("conditions: %+v", r.Conditions)
	}
	if r.Agent.Digest != agent.Digest || r.Agent.ID != "example.test/helper" {
		t.Fatal("receipt must pin the agent digest and identity")
	}
	if !strings.HasPrefix(r.InstructionHistory.URI, "file://") {
		t.Fatal("history should be written to the history dir")
	}
}

func TestConditionsAlignByIndexAndAreNeverReordered(t *testing.T) {
	agent := helper(t)
	stub := newStub(false)
	wp := pkgFor(agent, "do three things", "one", "two", "three")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	r := (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{})
	if len(r.Conditions) != 3 {
		t.Fatalf("expected 3 conditions, got %d", len(r.Conditions))
	}
	// Fewer answers than conditions: the missing ones are unmet with a reason.
	script := []protocol.ProcedureStep{{Kind: "assert", Condition: 2, Met: true, Proof: "only the second"}}
	r = (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake"})
	if r.Conditions[0].Met || !r.Conditions[1].Met || r.Conditions[2].Met || !strings.Contains(r.Conditions[0].Proof, "no answer") {
		t.Fatalf("alignment wrong: %+v", r.Conditions)
	}
}

func TestDenialsNameTheirReasonAndNeverFallBack(t *testing.T) {
	agent := helper(t)
	deny := func(t *testing.T, wp *protocol.WorkPackage, reg *adapter.Registry, want string) {
		t.Helper()
		r := (&Runner{Adapters: reg}).Run(context.Background(), wp, agent, Options{})
		if r.Status != protocol.StatusDenied || r.Denied == nil {
			t.Fatalf("expected denial for %q, got %s: %s", want, r.Status, r.Summary)
		}
		all := r.Denied.Reason + " " + strings.Join(r.Denied.Details, " ")
		if !strings.Contains(all, want) {
			t.Fatalf("denial should mention %q: %s", want, all)
		}
		if len(r.Attempts) != 0 {
			t.Fatal("a denied run must make no attempt")
		}
		if ps := protocol.ValidateRunReceipt(r); len(ps) > 0 {
			t.Fatalf("denial receipt invalid: %v", ps)
		}
	}
	// Required capability not granted.
	wp := pkgFor(agent, "anything")
	wp.Capabilities.Granted = []string{}
	deny(t, wp, stubRegistry(newStub(false)), "missing: repo.read")
	// Unenforceable restriction: shell with a non-open network and an adapter that cannot deny the network.
	wp = pkgFor(agent, "anything")
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapShellRun}
	deny(t, wp, stubRegistry(newStub(false)), protocol.FeatNetworkDeny)
	// Expired.
	wp = pkgFor(agent, "anything")
	wp.ExpiresAt = "2020-01-01T00:00:00Z"
	deny(t, wp, stubRegistry(newStub(false)), "expired")
	// Wrong agent digest.
	wp = pkgFor(agent, "anything")
	wp.Agent.Digest = "sha256:" + strings.Repeat("1", 64)
	deny(t, wp, stubRegistry(newStub(false)), "digest does not match")
	// Wrong agent identity.
	wp = pkgFor(agent, "anything")
	wp.Agent.ID = "example.test/other"
	deny(t, wp, stubRegistry(newStub(false)), "different agent")
	// Placement the package does not allow.
	local, _ := trust.LoadPath(fixture(t, "local/helper"))
	wpl := pkgFor(local, "anything")
	wpl.Capabilities.Granted = []string{}
	wpl.Placement = protocol.PlacementServer
	r := (&Runner{Adapters: stubRegistry(newStub(false))}).Run(context.Background(), wpl, local, Options{})
	if r.Status != protocol.StatusDenied || !strings.Contains(r.Denied.Reason, "placement") {
		t.Fatalf("placement denial expected: %+v", r.Denied)
	}
	// Invalid package.
	wp = pkgFor(agent, "")
	deny(t, wp, stubRegistry(newStub(false)), "invalid")
	// A denied capability in the package never reaches the adapter even if granted.
	wp = pkgFor(agent, "anything")
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapNetFetch}
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	stub := newStub(false)
	r = (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusCompleted || has(stub.attempts()[0].Grants, protocol.CapNetFetch) {
		t.Fatalf("package-denied capability must be stripped: %v", stub.attempts()[0].Grants)
	}
}

func TestPolicyCeilingBoundsGrants(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "anything")
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapRepoWrite}
	stub := newStub(false)
	r := (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{Policy: trust.Policy{CapabilityCeiling: []string{protocol.CapRepoRead}}})
	if r.Status != protocol.StatusCompleted || has(stub.attempts()[0].Grants, protocol.CapRepoWrite) {
		t.Fatalf("policy must strip repo.write: %v", stub.attempts()[0].Grants)
	}
	r = (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{Policy: trust.Policy{CapabilityCeiling: []string{}}})
	if r.Status != protocol.StatusDenied {
		t.Fatal("a policy that removes a required capability denies the run")
	}
}

func TestAnApprovedActionIsCheckedAgainstTheApprovalItself(t *testing.T) {
	agent := helper(t)
	params := map[string]any{"subject": "Quote request", "to": "supplier@example.test"}
	h, _ := protocol.ParamsHash(params)
	approval := &protocol.Approval{ProposalRef: "entry:9", ApprovalRef: "reaction:3", ApprovedBy: "user:7",
		Action: "send_email", Target: "supplier@example.test", Params: params, ParamsHash: h}
	wp := pkgFor(agent, "approved-send: the quote", "the email was sent")
	wp.Approval = approval
	r := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted || r.Evidence.ExternalAction == nil || r.Evidence.ApprovalCheck == nil {
		t.Fatalf("expected a recorded external action: %+v", r)
	}
	if !r.Evidence.ApprovalCheck.ParamsHashMatched || !r.Evidence.ApprovalCheck.OperationMatched {
		t.Fatalf("approval check: %+v", r.Evidence.ApprovalCheck)
	}
	if r.Evidence.ExternalAction.ApprovalRef != "reaction:3" {
		t.Fatal("the external action must cite the approval")
	}
	// Same hash, different approved target: the operation does not match.
	wrong := *approval
	wrong.Target = "other@example.test"
	wp2 := pkgFor(agent, "approved-send: the quote", "the email was sent")
	wp2.Approval = &wrong
	r = (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp2, agent, Options{})
	if r.Status != protocol.StatusFailed || r.Evidence.ExternalAction != nil || r.Evidence.ApprovalCheck == nil || r.Evidence.ApprovalCheck.OperationMatched {
		t.Fatalf("a mismatched operation must be refused before it happens: %s %+v", r.Status, r.Evidence)
	}
	// Different params than approved: the hash the caller sent still
	// matches its own params, but the operation differs.
	other := map[string]any{"subject": "Order", "to": "supplier@example.test"}
	oh, _ := protocol.ParamsHash(other)
	wp3 := pkgFor(agent, "approved-send: the quote", "the email was sent")
	wp3.Approval = &protocol.Approval{ProposalRef: "p", ApprovalRef: "a", ApprovedBy: "u", Action: "send_email", Target: "supplier@example.test", Params: other, ParamsHash: oh}
	r = (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp3, agent, Options{})
	if r.Status != protocol.StatusFailed || r.Evidence.ExternalAction != nil {
		t.Fatal("different approved params must refuse the operation")
	}
	// No approval at all.
	wp4 := pkgFor(agent, "approved-send: the quote", "the email was sent")
	r = (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp4, agent, Options{})
	if r.Status != protocol.StatusFailed || r.Evidence.ExternalAction != nil {
		t.Fatal("an external action with no approval must fail")
	}
	// A tampered paramsHash never gets as far as execution.
	wp5 := pkgFor(agent, "approved-send: the quote", "the email was sent")
	bad := *approval
	bad.ParamsHash = "sha256:" + strings.Repeat("f", 64)
	wp5.Approval = &bad
	r = (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp5, agent, Options{})
	if r.Status != protocol.StatusDenied {
		t.Fatal("a package whose paramsHash does not match is invalid and denied")
	}
}

func TestAProcedureWritesOnlyWithTheGrantAndInsideTheWorkspace(t *testing.T) {
	agent := helper(t)
	ws := t.TempDir()
	wp := pkgFor(agent, "write-file: please", "the file exists")
	wp.Workspace = protocol.Workspace{Kind: "git", Path: ws, Ownership: "caller"}
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapRepoWrite}
	listed := false
	r := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{ListChangedFiles: func(string) []string { listed = true; return []string{"helper-output.txt"} }})
	if r.Status != protocol.StatusCompleted || !listed || len(r.Evidence.FilesChanged) != 1 {
		t.Fatalf("expected a completed write with evidence: %+v", r)
	}
	wp.Capabilities.Granted = []string{protocol.CapRepoRead}
	r = (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusFailed || len(r.Evidence.Denials) == 0 {
		t.Fatalf("a write without the grant must be denied, not silently done: %+v", r)
	}
}

func TestABlockedProcedureReportsItsQuestion(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "ask: what now", "something")
	r := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusBlocked || r.BlockedOn != "Which file should I change?" {
		t.Fatalf("expected blocked with the question: %+v", r)
	}
}

// ---------------------------------------------------------------------
// directives with a live adapter (the fake)
// ---------------------------------------------------------------------

func TestOrderedDirectivesApplyInSequenceWhateverOrderTheyArrive(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "steer me", "done")
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	ch <- directive(wp.PackageID, 2, protocol.DirectiveSteer, "second")
	ch <- directive(wp.PackageID, 1, protocol.DirectiveSteer, "first")
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch, Sink: col})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted {
		t.Fatalf("status %s: %s", r.Status, r.Summary)
	}
	if strings.Join(r.Directives.Applied, ",") != "d1-steer,d2-steer" {
		t.Fatalf("applied order must follow seq: %v", r.Directives.Applied)
	}
	if len(r.Directives.Received) != 2 || col.count(protocol.EventDirectiveReceived) != 2 || col.count(protocol.EventDirectiveApplied) != 2 {
		t.Fatal("received and applied are distinct acknowledgements, one each per directive")
	}
}

func TestDuplicatesAreAcknowledgedAsDuplicatesAndAppliedOnce(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "steer me", "done")
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	ch := make(chan protocol.WorkDirective, 8)
	d := directive(wp.PackageID, 1, protocol.DirectiveSteer, "once")
	ch <- d
	ch <- d
	sameSeq := directive(wp.PackageID, 1, protocol.DirectiveSteer, "again")
	ch <- sameSeq
	col := newCollector()
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch, Sink: col})
	if len(r.Directives.Applied) != 1 || len(r.Directives.Duplicates) != 2 {
		t.Fatalf("applied %v duplicates %v", r.Directives.Applied, r.Directives.Duplicates)
	}
	if col.count(protocol.EventDirectiveDuplicate) != 2 {
		t.Fatal("each duplicate is acknowledged as one")
	}
}

func TestAGapThatNeverFillsIsRejectedNotSilentlyDropped(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "steer me", "done")
	script := []protocol.ProcedureStep{{Kind: "sleep", Duration: "30ms"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	ch := make(chan protocol.WorkDirective, 8)
	ch <- directive(wp.PackageID, 2, protocol.DirectiveSteer, "orphan")
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch})
	if r.Status != protocol.StatusCompleted || len(r.Directives.Applied) != 0 {
		t.Fatalf("an out-of-order directive must not apply: %+v", r.Directives)
	}
	if len(r.Directives.Rejected) != 1 || !strings.Contains(r.Directives.Rejected[0].Reason, "sequence 1 never arrived") {
		t.Fatalf("expected a gap rejection: %+v", r.Directives.Rejected)
	}
}

func TestStopBypassesGapsAndIsAppliedOnlyOnceTheAdapterHasEnded(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "wait forever", "done")
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "never"}}
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	stop := directive(wp.PackageID, 5, protocol.DirectiveStop, "operator said stop")
	ch <- stop
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch, Sink: col})
	checkReceipt(t, r)
	if r.Status != protocol.StatusStopped || r.Stop == nil || r.Stop.DirectiveID != stop.DirectiveID || r.Stop.Issuer.ID != "person" {
		t.Fatalf("expected a stop attributed to the directive: %+v", r.Stop)
	}
	if len(r.Directives.Gaps) != 1 || r.Directives.Gaps[0].ExpectedSeq != 1 || r.Directives.Gaps[0].ReceivedSeq != 5 {
		t.Fatalf("the gap must be recorded: %+v", r.Directives.Gaps)
	}
	if !has(r.Directives.Applied, stop.DirectiveID) {
		t.Fatal("stop must be acknowledged as applied")
	}
	if r.Conditions[0].Met {
		t.Fatal("a stopped run must not claim its conditions")
	}
	// Ordering of acknowledgements: received, then stopping, then applied.
	var seq []string
	col.mu.Lock()
	defer col.mu.Unlock()
	for _, e := range col.events {
		switch e.Kind {
		case protocol.EventDirectiveReceived, protocol.EventStopping, protocol.EventDirectiveApplied:
			seq = append(seq, e.Kind)
		}
	}
	if strings.Join(seq, ",") != "directive_received,stopping,directive_applied" {
		t.Fatalf("acknowledgement order: %v", seq)
	}
}

func TestASecondStopIsRejectedAndTheFirstWins(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "wait", "done")
	script := []protocol.ProcedureStep{{Kind: "await_directive"}}
	ch := make(chan protocol.WorkDirective, 8)
	ch <- directive(wp.PackageID, 1, protocol.DirectiveStop, "one")
	ch <- directive(wp.PackageID, 2, protocol.DirectiveStop, "two")
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch})
	if r.Status != protocol.StatusStopped || r.Stop.DirectiveID != "d1-stop" {
		t.Fatalf("first stop wins: %+v", r.Stop)
	}
	if len(r.Directives.Applied) != 1 {
		t.Fatalf("only one stop applies: %v (rejected %v)", r.Directives.Applied, r.Directives.Rejected)
	}
}

func TestLivePauseIsAppliedOnlyWhenPausedAndResumeContinues(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "pause me", "done")
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "after resume"}}
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventAttemptStarted, nil)
	pause := directive(wp.PackageID, 1, protocol.DirectivePause, "hold")
	ch <- pause
	col.wait(t, protocol.EventPaused, nil)
	col.wait(t, protocol.EventDirectiveApplied, func(e protocol.RunEvent) bool { return e.Payload["directiveId"] == pause.DirectiveID })
	select {
	case r := <-done:
		t.Fatalf("the run must stay paused, but it ended: %s", r.Status)
	case <-time.After(50 * time.Millisecond):
	}
	ch <- directive(wp.PackageID, 2, protocol.DirectiveResume, "go")
	r := <-done
	if r.Status != protocol.StatusCompleted || !r.Conditions[0].Met {
		t.Fatalf("expected completion after resume: %s", r.Status)
	}
	if strings.Join(r.Directives.Applied, ",") != "d1-pause,d2-resume" {
		t.Fatalf("applied: %v", r.Directives.Applied)
	}
}

func TestStopWhilePausedEndsTheRun(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "pause then stop", "done")
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "never"}}
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventAttemptStarted, nil)
	ch <- directive(wp.PackageID, 1, protocol.DirectivePause, "hold")
	col.wait(t, protocol.EventPaused, nil)
	ch <- directive(wp.PackageID, 2, protocol.DirectiveStop, "enough")
	r := <-done
	if r.Status != protocol.StatusStopped || r.Conditions[0].Met {
		t.Fatalf("expected stopped: %s", r.Status)
	}
}

func TestAResumeWhenNotPausedIsRejected(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "x", "done")
	// A resume that is rejected never reaches the adapter, so the script
	// must not wait for it.
	script := []protocol.ProcedureStep{{Kind: "sleep", Duration: "10ms"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	ch := make(chan protocol.WorkDirective, 8)
	ch <- directive(wp.PackageID, 1, protocol.DirectiveResume, "")
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch})
	if len(r.Directives.Rejected) != 1 || !strings.Contains(r.Directives.Rejected[0].Reason, "not paused") {
		t.Fatalf("rejected: %+v", r.Directives.Rejected)
	}
}

func TestInvalidOrForeignDirectivesAreRejectedNotApplied(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "x", "done")
	script := []protocol.ProcedureStep{{Kind: "sleep", Duration: "20ms"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	ch := make(chan protocol.WorkDirective, 8)
	foreign := directive(protocol.NewULID(), 1, protocol.DirectiveStop, "wrong package")
	ch <- foreign
	tampered := directive(wp.PackageID, 1, protocol.DirectiveStop, "tampered")
	tampered.Payload.Reason = "changed after signing"
	ch <- tampered
	r := (&Runner{Adapters: fakeRegistry(script)}).Run(context.Background(), wp, agent, Options{Adapter: "fake", Directives: ch})
	if r.Status != protocol.StatusCompleted {
		t.Fatalf("neither directive may stop the run: %s", r.Status)
	}
	if len(r.Directives.Rejected) != 2 || len(r.Directives.Received) != 0 {
		t.Fatalf("expected two rejections and no receipt of them: %+v", r.Directives)
	}
}

// ---------------------------------------------------------------------
// directives with a print-mode adapter (no live steer): boundaries
// ---------------------------------------------------------------------

func TestSteerWithSessionContinuationEndsTheAttemptAndResumesWithTheInstruction(t *testing.T) {
	agent := helper(t)
	stub := newStub(true)
	stub.release = make(chan struct{})
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil)
	steer := directive(wp.PackageID, 1, protocol.DirectiveSteer, "use the existing helper")
	ch <- steer
	r := <-done
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted || len(r.Attempts) != 2 {
		t.Fatalf("expected two attempts and completion: %s %+v", r.Status, r.Attempts)
	}
	if r.Attempts[0].EndReason != "ended_for_instructions" {
		t.Fatalf("attempt 1 should end for instructions: %+v", r.Attempts[0])
	}
	specs := stub.attempts()
	if specs[1].SessionRef != "sess-1" || len(specs[1].Instructions) != 1 || specs[1].Instructions[0] != "use the existing helper" {
		t.Fatalf("attempt 2 must resume the session with the instruction: %+v", specs[1])
	}
	if !strings.Contains(specs[1].Prompt, "use the existing helper") {
		t.Fatal("the instruction must reach the prompt")
	}
	if !has(r.Directives.Applied, steer.DirectiveID) || !has(r.Directives.Received, steer.DirectiveID) {
		t.Fatal("the steer must be received and then applied")
	}
	if !has(r.Harness.SessionRefs, "sess-1") {
		t.Fatal("session refs must be recorded")
	}
	// Applied only after the new attempt began, not on receipt.
	var order []string
	col.mu.Lock()
	defer col.mu.Unlock()
	for _, e := range col.events {
		switch e.Kind {
		case protocol.EventDirectiveReceived, protocol.EventDirectiveApplied, protocol.EventAttemptEnded, protocol.EventAttemptStarted:
			order = append(order, e.Kind)
		}
	}
	joined := strings.Join(order, ",")
	if !strings.Contains(joined, "directive_received,attempt_ended,attempt_started,directive_applied") {
		t.Fatalf("acknowledgement must follow the boundary: %s", joined)
	}
}

func TestSteerWithoutSessionContinuationWaitsForTheAttemptThenContinues(t *testing.T) {
	agent := helper(t)
	stub := newStub(false)
	stub.release = make(chan struct{})
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil)
	ch <- directive(wp.PackageID, 1, protocol.DirectiveSteer, "also add a test")
	time.Sleep(30 * time.Millisecond)
	if len(stub.attempts()) != 1 {
		t.Fatal("without session continuation the attempt must not be interrupted")
	}
	close(stub.release)
	r := <-done
	if r.Status != protocol.StatusCompleted || len(r.Attempts) != 2 {
		t.Fatalf("expected a continuation attempt: %+v", r.Attempts)
	}
	if stub.attempts()[1].SessionRef != "" {
		t.Fatal("no session continuation means a fresh attempt")
	}
	if len(r.Directives.Applied) != 1 {
		t.Fatalf("the late steer must still apply: %+v", r.Directives)
	}
}

func TestPauseWithoutLivePauseEndsTheAttemptAndResumesTheSession(t *testing.T) {
	agent := helper(t)
	stub := newStub(true)
	stub.release = make(chan struct{})
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil)
	pause := directive(wp.PackageID, 1, protocol.DirectivePause, "hold on")
	ch <- pause
	col.wait(t, protocol.EventPaused, nil)
	col.wait(t, protocol.EventDirectiveApplied, func(e protocol.RunEvent) bool { return e.Payload["directiveId"] == pause.DirectiveID })
	if len(stub.attempts()) != 1 {
		t.Fatal("paused: no new attempt yet")
	}
	// Steering while paused is queued and applied at resume.
	ch <- directive(wp.PackageID, 2, protocol.DirectiveSteer, "and rename it")
	ch <- directive(wp.PackageID, 3, protocol.DirectiveResume, "")
	r := <-done
	if r.Status != protocol.StatusCompleted || len(r.Attempts) != 2 || r.Attempts[0].EndReason != "paused" {
		t.Fatalf("expected paused then a second attempt: %+v", r.Attempts)
	}
	if strings.Join(r.Directives.Applied, ",") != "d1-pause,d3-resume,d2-steer" && strings.Join(r.Directives.Applied, ",") != "d1-pause,d2-steer,d3-resume" {
		t.Fatalf("applied: %v", r.Directives.Applied)
	}
	if specs := stub.attempts(); specs[1].SessionRef != "sess-1" || len(specs[1].Instructions) != 1 {
		t.Fatalf("resume must continue the session with the queued steer: %+v", specs[1])
	}
}

func TestBudgetsAreCumulativeAcrossAttempts(t *testing.T) {
	agent := helper(t)
	stub := newStub(true)
	stub.cost = protocol.Cost{USD: 0.6, Turns: 3}
	stub.release = make(chan struct{})
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits = protocol.Limits{MaxUSD: 1.0, MaxTurns: 10, Network: protocol.NetworkOpen}
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil)
	ch <- directive(wp.PackageID, 1, protocol.DirectiveSteer, "more")
	r := <-done
	specs := stub.attempts()
	if len(specs) != 2 {
		t.Fatalf("expected 2 attempts, got %d", len(specs))
	}
	if specs[0].Limits.MaxUSD != 1.0 || specs[1].Limits.MaxUSD < 0.39 || specs[1].Limits.MaxUSD > 0.41 || specs[1].Limits.MaxTurns != 7 {
		t.Fatalf("remaining budget must be passed to the next attempt: %+v then %+v", specs[0].Limits, specs[1].Limits)
	}
	if r.Cost.USD < 1.19 || r.Cost.Turns != 6 {
		t.Fatalf("receipt cost must be cumulative: %+v", r.Cost)
	}
	// A third steer would exceed the budget: the run fails rather than spends.
	stub2 := newStub(true)
	stub2.cost = protocol.Cost{USD: 0.6}
	stub2.release = make(chan struct{})
	wp2 := pkgFor(agent, "build it", "built")
	wp2.Capabilities.Limits = protocol.Limits{MaxUSD: 0.5, Network: protocol.NetworkOpen}
	ch2 := make(chan protocol.WorkDirective, 8)
	col2 := newCollector()
	done2 := make(chan *protocol.RunReceipt, 1)
	go func() {
		done2 <- (&Runner{Adapters: stubRegistry(stub2)}).Run(context.Background(), wp2, agent, Options{Directives: ch2, Sink: col2})
	}()
	col2.wait(t, protocol.EventProgress, nil)
	ch2 <- directive(wp2.PackageID, 1, protocol.DirectiveSteer, "more")
	r2 := <-done2
	if r2.Status != protocol.StatusFailed || !strings.Contains(r2.Summary, "budget") || len(stub2.attempts()) != 1 {
		t.Fatalf("expected a budget failure after one attempt: %s %s", r2.Status, r2.Summary)
	}
}

func TestATimeoutEndsTheRunAsFailedNotStopped(t *testing.T) {
	agent := helper(t)
	stub := newStub(false)
	stub.release = make(chan struct{})
	wp := pkgFor(agent, "hang", "done")
	wp.Capabilities.Limits = protocol.Limits{Timeout: "40ms", Network: protocol.NetworkOpen}
	r := (&Runner{Adapters: stubRegistry(stub)}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusFailed || r.Attempts[0].EndReason != "timeout" {
		t.Fatalf("expected timeout failure: %s %+v", r.Status, r.Attempts)
	}
}

func TestCallerCancellationIsAStopFromTheRuntime(t *testing.T) {
	agent := helper(t)
	stub := newStub(false)
	stub.release = make(chan struct{})
	wp := pkgFor(agent, "hang", "done")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(20 * time.Millisecond); cancel() }()
	r := (&Runner{Adapters: stubRegistry(stub)}).Run(ctx, wp, agent, Options{})
	if r.Status != protocol.StatusStopped || r.Stop == nil || r.Stop.Issuer.Kind != "runtime" {
		t.Fatalf("expected a runtime stop: %s %+v", r.Status, r.Stop)
	}
}

func TestADirectiveArrivingAfterTheRunIsIgnoredAndTheReceiptIsSealed(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "note: quick", "done")
	ch := make(chan protocol.WorkDirective, 8)
	r := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{Directives: ch})
	ch <- directive(wp.PackageID, 1, protocol.DirectiveSteer, "too late")
	time.Sleep(10 * time.Millisecond)
	if d, _ := protocol.ReceiptDigest(*r); d != r.ReceiptDigest {
		t.Fatal("receipt changed after sealing")
	}
	// A directive already handed over before the receipt was sealed, on a
	// run too quick to act on it, is acknowledged as rejected, and a late
	// stop cannot turn a completed run into a stopped one.
	ch2 := make(chan protocol.WorkDirective, 8)
	wp2 := pkgFor(agent, "note: quick", "done")
	ch2 <- directive(wp2.PackageID, 1, protocol.DirectiveStop, "late stop")
	// The reader goroutine races the procedure; whichever wins, the
	// receipt must be consistent: either stopped with the stop applied, or
	// completed with the stop rejected as late.
	r2 := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp2, agent, Options{Directives: ch2})
	switch r2.Status {
	case protocol.StatusStopped:
		if !has(r2.Directives.Applied, "d1-stop") {
			t.Fatal("a stop that won the race must be applied")
		}
	case protocol.StatusCompleted:
		if len(r2.Directives.Rejected) != 1 || !strings.Contains(r2.Directives.Rejected[0].Reason, "after the run ended") {
			t.Fatalf("a stop that lost the race must be rejected as late: %+v", r2.Directives)
		}
	default:
		t.Fatalf("unexpected status %s", r2.Status)
	}
}

func TestPromptCarriesTheContractButClaimsNoAuthority(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "fix the thing", "tests pass", "no new warnings")
	wp.Authority = protocol.Authority{May: []protocol.AuthorityGrant{{Capability: "edit", Scope: "src/ only"}}, MayNot: []string{"touch prod"}, ApprovalRequired: []string{"deploy"}}
	wp.Context.Lines = []string{"someone: the failing test is in pkg/x"}
	p := Prompt(wp, agent, []string{protocol.CapRepoRead}, []string{"prefer the helper"})
	for _, want := range []string{"example.test/helper", "1. tests pass", "2. no new warnings", "may: edit (src/ only)", "may not: touch prod", "needs a person's approval first: deploy", "the failing test is in pkg/x", "1. prefer the helper", "do not widen", "Absence of a grant is denial"} {
		if !strings.Contains(p, want) {
			t.Errorf("prompt missing %q", want)
		}
	}
}

// ---------------------------------------------------------------------
// continuation and receipt digests
// ---------------------------------------------------------------------

func TestTheReceiptNamesThePackageAndConditionsItAnswers(t *testing.T) {
	agent := helper(t)
	wp := pkgFor(agent, "note: quick", "a", "b")
	r := (&Runner{Adapters: fakeRegistry(nil)}).Run(context.Background(), wp, agent, Options{})
	pd, _ := protocol.PackageDigest(*wp)
	cd, _ := protocol.ConditionsDigest(wp.Completion.Conditions)
	if r.PackageDigest != pd || r.ConditionsDigest != cd {
		t.Fatalf("receipt digests %s %s, want %s %s", r.PackageDigest, r.ConditionsDigest, pd, cd)
	}
	other := pkgFor(agent, "note: quick", "b", "a")
	od, _ := protocol.ConditionsDigest(other.Completion.Conditions)
	if od == cd {
		t.Fatal("reordered conditions must not share a digest")
	}
}

func TestAContinuationCarriesCostAttemptsAndSessionAndLinksTheOldReceipt(t *testing.T) {
	agent := helper(t)
	first := newStub(true)
	first.status = protocol.StatusBlocked
	first.cost = protocol.Cost{USD: 0.4, Turns: 2}
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits = protocol.Limits{MaxUSD: 1.0, Network: protocol.NetworkOpen}
	r1 := (&Runner{Adapters: stubRegistry(first)}).Run(context.Background(), wp, agent, Options{})
	checkReceipt(t, r1)
	if r1.Status != protocol.StatusBlocked || len(r1.Attempts) != 1 {
		t.Fatalf("first run should be blocked after one attempt: %s", r1.Status)
	}

	second := newStub(true)
	second.cost = protocol.Cost{USD: 0.3, Turns: 1}
	ch := make(chan protocol.WorkDirective, 4)
	ch <- directive(wp.PackageID, 1, protocol.DirectiveClarify, "change calc.go")
	r2 := (&Runner{Adapters: stubRegistry(second)}).Run(context.Background(), wp, agent, Options{Directives: ch, Continue: r1})
	checkReceipt(t, r2)
	if r2.Status != protocol.StatusCompleted {
		t.Fatalf("continuation should complete: %s %s", r2.Status, r2.Summary)
	}
	if r2.Continues == nil || r2.Continues.RunID != r1.RunID || r2.Continues.ReceiptDigest != r1.ReceiptDigest || r2.Continues.Attempts != 1 {
		t.Fatalf("continuation link wrong: %+v", r2.Continues)
	}
	if len(r2.Attempts) != 1 || r2.Attempts[0].N != 2 {
		t.Fatalf("attempt numbering must continue: %+v", r2.Attempts)
	}
	spec := second.attempts()[0]
	if spec.SessionRef != "sess-1" || len(spec.Instructions) != 1 || spec.Instructions[0] != "change calc.go" {
		t.Fatalf("the continuation must resume the session with the answer: %+v", spec)
	}
	if spec.Limits.MaxUSD < 0.59 || spec.Limits.MaxUSD > 0.61 {
		t.Fatalf("remaining budget must reflect the earlier run: %v", spec.Limits.MaxUSD)
	}
	if r2.Cost.USD < 0.69 || r2.Cost.USD > 0.71 || r2.Cost.Turns != 3 {
		t.Fatalf("cost must be cumulative across the chain: %+v", r2.Cost)
	}
	if r2.PackageDigest != r1.PackageDigest {
		t.Fatal("same package, same digest")
	}
	if d, _ := protocol.ReceiptDigest(*r1); d != r1.ReceiptDigest {
		t.Fatal("the old receipt must be untouched")
	}
	// A receipt from a different package or a tampered one cannot be continued.
	other := pkgFor(agent, "other")
	other.Capabilities.Limits.Network = protocol.NetworkOpen
	r3 := (&Runner{Adapters: stubRegistry(newStub(true))}).Run(context.Background(), other, agent, Options{Continue: r1})
	if r3.Status != protocol.StatusDenied || !strings.Contains(r3.Denied.Reason, "different package") {
		t.Fatalf("expected denial: %+v", r3.Denied)
	}
	tampered := *r1
	tampered.Summary = "edited"
	r4 := (&Runner{Adapters: stubRegistry(newStub(true))}).Run(context.Background(), wp, agent, Options{Continue: &tampered})
	if r4.Status != protocol.StatusDenied || !strings.Contains(r4.Denied.Reason, "digest") {
		t.Fatalf("a tampered receipt cannot be continued: %+v", r4.Denied)
	}
}

func TestAContinuationOnADifferentAdapterDoesNotResumeTheSession(t *testing.T) {
	agent := helper(t)
	first := newStub(true)
	first.status = protocol.StatusBlocked
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	r1 := (&Runner{Adapters: stubRegistry(first)}).Run(context.Background(), wp, agent, Options{})
	r1.Harness.Adapter = "other-harness"
	r1.ReceiptDigest, _ = protocol.ReceiptDigest(*r1)
	second := newStub(true)
	(&Runner{Adapters: stubRegistry(second)}).Run(context.Background(), wp, agent, Options{Continue: r1})
	if second.attempts()[0].SessionRef != "" {
		t.Fatal("a session from another harness must not be resumed")
	}
}
