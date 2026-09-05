// Package run executes one WorkPackage: it checks the package against the
// loaded agent and local policy, computes effective grants, selects a
// procedure or a capable adapter, drives attempts while applying ordered
// directives, and produces the immutable receipt.
//
// Authority is decided here, once, before any adapter runs. Nothing an
// adapter or an agent says afterwards widens it.
package run

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
)

// Sink receives run events in order. Implementations must not block for
// long: the wire layer buffers and coalesces; tests collect.
type Sink interface {
	Emit(protocol.RunEvent)
}

// CoalescingSink is a Sink that can report how many events it dropped.
type CoalescingSink interface {
	Sink
	Coalesced() int
}

// SinkFunc adapts a function to Sink.
type SinkFunc func(protocol.RunEvent)

// Emit calls the function.
func (f SinkFunc) Emit(e protocol.RunEvent) { f(e) }

// Options configure one run.
type Options struct {
	Directives <-chan protocol.WorkDirective
	Sink       Sink
	RunID      string
	HistoryDir string
	Policy     trust.Policy
	Adapter    string // restrict selection to one adapter name
	// Continue is the terminal receipt of an earlier run of the SAME
	// package that this run continues, typically a blocked run whose
	// question has now been answered by a clarify directive. The contract
	// is unchanged; cost and attempt numbering carry forward; the old
	// receipt is untouched and linked from the new one.
	Continue *protocol.RunReceipt
	// PackageRaw is the package exactly as received (the wire frame, the
	// file, or the bytes the CLI itself wrote). The receipt's packageDigest
	// is computed over these bytes canonicalised, never over a re-marshalled
	// struct, so the issuer can compare it with the digest of what it sent.
	PackageRaw []byte
	Now        func() string
	// ListChangedFiles reports workspace changes for the receipt. The
	// default shells out to git for a git workspace.
	ListChangedFiles func(workspace string) []string
}

// Runner executes packages with a registry of adapters.
type Runner struct {
	Adapters *adapter.Registry
}

// Deny issues a denial receipt for a package whose agent could not be
// loaded at all, so the caller still gets a signed-shape receipt naming
// the package rather than nothing.
func (r *Runner) Deny(wp *protocol.WorkPackage, reason string, details []string, opts Options) *protocol.RunReceipt {
	s := newSession(r, wp, nil, opts)
	defer s.close()
	s.emit(protocol.EventStarted, map[string]any{"agent": wp.Agent.ID, "trust": "not loaded"})
	return s.deny(reason, details)
}

// Run executes wp with agent and always returns a receipt, even for a
// denial. The receipt's digest is set; its signature is not (slice 0).
func (r *Runner) Run(ctx context.Context, wp *protocol.WorkPackage, agent *trust.Loaded, opts Options) *protocol.RunReceipt {
	s := newSession(r, wp, agent, opts)
	defer s.close()
	s.emit(protocol.EventStarted, map[string]any{"agent": agent.ID(), "trust": agent.Label})

	if reason, details := s.check(); reason != "" {
		return s.deny(reason, details)
	}
	grants, reason, details := s.effectiveGrants()
	if reason != "" {
		return s.deny(reason, details)
	}
	s.grants = grants

	proc := s.matchProcedure()
	var ad adapter.Adapter
	if proc != nil {
		p, ok := r.Adapters.Get("procedure")
		if !ok {
			return s.deny("no procedure executor is registered", nil)
		}
		ad = p
		s.emit(protocol.EventProcedureSelected, map[string]any{"procedure": proc.Name})
	} else {
		reqs := adapter.Requirements(agent.Manifest, wp, grants)
		chosen, rejections := r.Adapters.Select(reqs, opts.Policy.Adapters, opts.Adapter)
		if chosen == nil {
			var details []string
			for _, rj := range rejections {
				details = append(details, rj.String())
			}
			if len(reqs) > 0 {
				var need []string
				for _, q := range reqs {
					need = append(need, q.Feature)
				}
				details = append(details, "required enforcement: "+strings.Join(need, ", "))
			}
			return s.deny("no installed adapter can enforce what this package requires", details)
		}
		ad = chosen
		s.emit(protocol.EventAdapterSelected, map[string]any{"adapter": ad.Name(), "version": ad.Detect().Version})
	}
	s.adapter = ad
	s.procedure = proc
	s.receipt.Harness.Adapter = ad.Name()
	s.receipt.Harness.Version = ad.Detect().Version
	if proc != nil {
		s.receipt.Harness.Procedure = proc.Name
	}
	return s.drive(ctx)
}

// ---------------------------------------------------------------------

type session struct {
	runner  *Runner
	wp      *protocol.WorkPackage
	agent   *trust.Loaded
	opts    Options
	now     func() string
	receipt *protocol.RunReceipt

	grants    []string
	adapter   adapter.Adapter
	procedure *protocol.Procedure

	mu          sync.Mutex
	eventSeq    int
	spent       protocol.Cost
	history     []historyLine
	closed      bool
	attemptBase int    // attempts spent by the runs this one continues
	seedSession string // session to resume from the continued run

	dir *directiveState
}

func newSession(r *Runner, wp *protocol.WorkPackage, agent *trust.Loaded, opts Options) *session {
	if opts.Now == nil {
		opts.Now = protocol.Now
	}
	if opts.Sink == nil {
		opts.Sink = SinkFunc(func(protocol.RunEvent) {})
	}
	if opts.ListChangedFiles == nil {
		opts.ListChangedFiles = gitChangedFiles
	}
	runID := opts.RunID
	if runID == "" {
		runID = protocol.NewULID()
	}
	s := &session{runner: r, wp: wp, agent: agent, opts: opts, now: opts.Now}
	agentRef := wp.Agent
	if agent != nil {
		agentRef = protocol.AgentRef{ID: agent.ID(), Version: agent.Manifest.Version, Digest: agent.Digest}
	}
	s.receipt = &protocol.RunReceipt{
		Schema:              protocol.SchemaRunReceipt,
		ReceiptID:           protocol.NewULID(),
		PackageID:           wp.PackageID,
		SupersedesPackageID: wp.SupersedesPackageID,
		RunID:               runID,
		Issuer:              wp.Issuer,
		Correlation:         wp.Correlation,
		Agent:               agentRef,
		Attempts:            []protocol.Attempt{},
		Directives:          protocol.DirectiveSummary{Received: []string{}, Applied: []string{}, Rejected: []protocol.RejectedDirective{}},
		StartedAt:           s.now(),
		Conditions:          []protocol.ConditionProof{},
	}
	if len(opts.PackageRaw) > 0 {
		if canon, err := protocol.CanonicalizeJSON(opts.PackageRaw); err == nil {
			s.receipt.PackageDigest = protocol.DigestBytes(canon)
		}
	}
	if s.receipt.PackageDigest == "" {
		s.receipt.PackageDigest, _ = protocol.PackageDigest(*wp)
	}
	s.receipt.ConditionsDigest, _ = protocol.ConditionsDigest(wp.Completion.Conditions)
	s.history = append(s.history, historyLine{Kind: "package", Package: wp})
	if prev := opts.Continue; prev != nil {
		s.attemptBase = len(prev.Attempts)
		if prev.Continues != nil {
			s.attemptBase += prev.Continues.Attempts
		}
		s.spent = prev.Cost
		s.receipt.Continues = &protocol.Continuation{RunID: prev.RunID, ReceiptID: prev.ReceiptID, ReceiptDigest: prev.ReceiptDigest, Attempts: s.attemptBase}
		if n := len(prev.Attempts); n > 0 {
			s.seedSession = prev.Attempts[n-1].SessionRef
		}
		s.history = append(s.history, historyLine{Kind: "continues", Continues: s.receipt.Continues})
	}
	s.dir = newDirectiveState(s)
	return s
}

func (s *session) appendHistory(l historyLine) {
	s.mu.Lock()
	s.history = append(s.history, l)
	s.mu.Unlock()
}

func (s *session) close() {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
}

func (s *session) emit(kind string, payload map[string]any) {
	s.mu.Lock()
	s.eventSeq++
	ev := protocol.RunEvent{
		Schema:    protocol.SchemaRunEvent,
		EventID:   protocol.NewULID(),
		PackageID: s.wp.PackageID,
		RunID:     s.receipt.RunID,
		Attempt:   s.attemptBase + len(s.receipt.Attempts) + 1,
		Seq:       s.eventSeq,
		At:        s.now(),
		Kind:      kind,
		Payload:   payload,
	}
	s.mu.Unlock()
	s.opts.Sink.Emit(ev)
}

// check refuses packages the runtime must not execute at all.
func (s *session) check() (string, []string) {
	if ps := protocol.ValidateWorkPackage(s.wp); len(ps) > 0 {
		var d []string
		for _, p := range ps {
			d = append(d, p.String())
		}
		return "the work package is invalid", d
	}
	if s.wp.ExpiresAt != "" {
		if t, err := protocol.ParseTime(s.wp.ExpiresAt); err == nil {
			if now, err := protocol.ParseTime(s.now()); err == nil && now.After(t) {
				return "the work package has expired", []string{"expiresAt " + s.wp.ExpiresAt}
			}
		}
	}
	if s.wp.Agent.ID != s.agent.ID() {
		return "the work package names a different agent", []string{"package wants " + s.wp.Agent.ID + ", loaded " + s.agent.ID()}
	}
	if s.wp.Agent.Version != "" && s.wp.Agent.Version != s.agent.Manifest.Version {
		return "the pinned agent version does not match", []string{"package wants " + s.wp.Agent.Version + ", loaded " + s.agent.Manifest.Version}
	}
	if s.wp.Agent.Digest != "" && s.wp.Agent.Digest != s.agent.Digest {
		return "the pinned agent digest does not match", []string{"package wants " + s.wp.Agent.Digest + ", loaded " + s.agent.Digest}
	}
	if s.wp.Placement != protocol.PlacementEither {
		ok := false
		for _, p := range s.agent.Manifest.Placement.Allowed {
			if p == s.wp.Placement {
				ok = true
			}
		}
		if !ok {
			return "the package's placement is not allowed by the agent package", []string{"placement " + s.wp.Placement + ", agent allows " + strings.Join(s.agent.Manifest.Placement.Allowed, ", ")}
		}
	}
	if s.wp.Workspace.Kind == "git" && s.wp.Workspace.Ownership != "caller" {
		return "runtime-owned workspaces are not supported in this release", nil
	}
	if prev := s.opts.Continue; prev != nil {
		if prev.PackageID != s.wp.PackageID {
			return "the continued receipt is for a different package", []string{"receipt " + prev.PackageID + ", package " + s.wp.PackageID}
		}
		if prev.PackageDigest != "" && prev.PackageDigest != s.receipt.PackageDigest {
			return "the continued receipt saw a different package document", []string{"receipt " + prev.PackageDigest + ", now " + s.receipt.PackageDigest}
		}
		if prev.Agent.Digest != "" && prev.Agent.Digest != s.agent.Digest {
			return "the continued receipt ran a different agent package", []string{"receipt " + prev.Agent.Digest + ", loaded " + s.agent.Digest}
		}
		if d, err := protocol.ReceiptDigest(*prev); err != nil || d != prev.ReceiptDigest {
			return "the continued receipt does not match its own digest", nil
		}
		switch prev.Status {
		case protocol.StatusBlocked, protocol.StatusStopped, protocol.StatusCompleted, protocol.StatusNoChange:
		default:
			return "only a blocked, stopped or completed run can be continued", []string{"previous status " + prev.Status}
		}
	}
	return "", nil
}

// effectiveGrants intersects the caller's grants with local policy and the
// package's own restrictions, and refuses when the package cannot run
// inside the result.
func (s *session) effectiveGrants() ([]string, string, []string) {
	granted := set(s.wp.Capabilities.Granted)
	if ceiling := s.opts.Policy.CapabilityCeiling; ceiling != nil {
		c := set(ceiling)
		for g := range granted {
			if !c[g] {
				delete(granted, g)
			}
		}
	}
	for _, d := range s.agent.Manifest.Capabilities.Denied {
		delete(granted, d)
	}
	var missing []string
	for _, req := range s.agent.Manifest.Capabilities.Required {
		if !granted[req] {
			missing = append(missing, req)
		}
	}
	if len(missing) > 0 {
		return nil, "the package requires capabilities that are not granted", []string{"missing: " + strings.Join(missing, ", ")}
	}
	if granted[protocol.CapNetFetch] && adapter.EffectiveNetwork(s.wp) != protocol.NetworkOpen {
		return nil, "net.fetch is granted but the network limit is not open", nil
	}
	out := make([]string, 0, len(granted))
	for g := range granted {
		out = append(out, g)
	}
	sort.Strings(out)
	return out, "", nil
}

func set(xs []string) map[string]bool {
	m := map[string]bool{}
	for _, x := range xs {
		m[x] = true
	}
	return m
}

// matchProcedure finds the first procedure whose predicate matches the
// objective. Its own requirements must be within the effective grants; a
// matching but unauthorised procedure is a denial, never a fallback.
func (s *session) matchProcedure() *protocol.Procedure {
	for i := range s.agent.Manifest.Procedures {
		p := &s.agent.Manifest.Procedures[i]
		re, err := regexp.Compile(p.Matches.ObjectiveRegex)
		if err != nil || !re.MatchString(s.wp.Objective) {
			continue
		}
		return p
	}
	return nil
}

func (s *session) deny(reason string, details []string) *protocol.RunReceipt {
	s.emit(protocol.EventDenied, map[string]any{"reason": reason, "details": details})
	s.receipt.Status = protocol.StatusDenied
	s.receipt.Denied = &protocol.DenialInfo{Reason: reason, Details: details}
	s.receipt.Summary = "denied: " + reason
	if s.receipt.Harness.Adapter == "" {
		s.receipt.Harness.Adapter = "none"
	}
	return s.finish()
}

// approvalGate checks an operation against the package's exact approval:
// the recomputed params hash, and the action, target and params
// themselves. A hash match alone proves nothing about what is about to
// happen; the operation is compared field by field.
func (s *session) approvalGate(action, target string, params map[string]any) (*protocol.ApprovalCheck, error) {
	a := s.wp.Approval
	if a == nil {
		return &protocol.ApprovalCheck{Detail: "no approval on the package"}, adapter.ErrNoApproval()
	}
	check := &protocol.ApprovalCheck{}
	h, err := protocol.ParamsHash(a.Params)
	if err != nil {
		return check, err
	}
	check.ParamsHashMatched = h == a.ParamsHash
	want, _ := protocol.Canonical(a.Params)
	got, _ := protocol.Canonical(nilToEmpty(params))
	check.OperationMatched = action == a.Action && target == a.Target && string(want) == string(got)
	switch {
	case !check.ParamsHashMatched:
		check.Detail = "paramsHash does not match the approved params"
		return check, fmt.Errorf("approval: %s", check.Detail)
	case !check.OperationMatched:
		check.Detail = fmt.Sprintf("operation %s on %q does not match the approved %s on %q", action, target, a.Action, a.Target)
		return check, fmt.Errorf("approval: %s", check.Detail)
	}
	check.Detail = "operation matches approval " + a.ApprovalRef
	return check, nil
}

func nilToEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// ---------------------------------------------------------------------
// the attempt loop
// ---------------------------------------------------------------------

type attemptResult struct {
	outcome adapter.Outcome
	err     error
}

func (s *session) drive(parent context.Context) *protocol.RunReceipt {
	runCtx, cancelRun := context.WithCancel(parent)
	defer cancelRun()
	if t := s.wp.Capabilities.Limits.Timeout; t != "" {
		if d, err := time.ParseDuration(t); err == nil && d > 0 {
			var cancelT context.CancelFunc
			runCtx, cancelT = context.WithTimeout(runCtx, d)
			defer cancelT()
		}
	}
	s.dir.start(runCtx, cancelRun)
	s.dir.drainNow()
	live := s.adapter.Enforcement()

	var last adapter.Outcome
	if s.seedSession != "" && s.opts.Continue != nil && s.opts.Continue.Harness.Adapter == s.adapter.Name() && live.Enforces(protocol.FeatSessionContinue) {
		last.SessionRef = s.seedSession
	}
	for {
		if s.dir.stopRequested() {
			s.receipt.Status = protocol.StatusStopped
			break
		}
		if reason := s.budgetExhausted(); reason != "" {
			s.receipt.Status = protocol.StatusFailed
			s.receipt.Summary = "budget exhausted: " + reason
			s.receipt.Evidence.Errors = append(s.receipt.Evidence.Errors, reason)
			break
		}
		n := s.attemptBase + len(s.receipt.Attempts) + 1
		attemptCtx, cancelAttempt := context.WithCancel(runCtx)
		s.dir.attemptStarted(cancelAttempt, live)
		instructions, applying := s.dir.takeInstructions()
		spec := s.spec(n, instructions, last.SessionRef)
		s.emit(protocol.EventAttemptStarted, map[string]any{"attempt": n, "adapter": s.adapter.Name(), "instructions": len(instructions), "resumed": spec.SessionRef != ""})
		for _, id := range applying {
			s.dir.applied(id)
		}
		started := s.now()
		res := s.runAttempt(attemptCtx, spec, live)
		cancelAttempt()
		boundary := s.dir.attemptEnded()
		out := res.outcome
		if res.err != nil {
			out.Status = protocol.StatusFailed
			out.EndReason = "adapter_error"
			out.Errors = append(out.Errors, res.err.Error())
		}
		s.spent = add(s.spent, out.Cost)
		s.receipt.Attempts = append(s.receipt.Attempts, protocol.Attempt{
			N: n, Adapter: s.adapter.Name(), StartedAt: started, EndedAt: s.now(),
			EndReason: endReason(out, boundary, runCtx), SessionRef: out.SessionRef, Cost: out.Cost,
		})
		if out.SessionRef != "" {
			s.receipt.Harness.SessionRefs = append(s.receipt.Harness.SessionRefs, out.SessionRef)
		}
		s.appendHistory(historyLine{Kind: "attempt", Attempt: n, Instructions: instructions, SessionRef: out.SessionRef, EndReason: out.EndReason})
		s.emit(protocol.EventAttemptEnded, map[string]any{"attempt": n, "status": out.Status, "endReason": out.EndReason, "boundary": boundary})
		last = out
		if out.SessionRef == "" && spec.SessionRef != "" {
			last.SessionRef = spec.SessionRef
		}

		if s.dir.stopRequested() {
			s.receipt.Status = protocol.StatusStopped
			break
		}
		if runCtx.Err() == context.DeadlineExceeded {
			s.receipt.Status = protocol.StatusFailed
			s.receipt.Summary = "no result within the time allowed"
			s.receipt.Evidence.Errors = append(s.receipt.Evidence.Errors, "timeout: "+s.wp.Capabilities.Limits.Timeout)
			break
		}
		switch boundary {
		case boundaryPause:
			s.dir.pauseApplied()
			s.emit(protocol.EventPaused, map[string]any{"attempt": n})
			if !s.dir.waitResumed(runCtx) {
				s.receipt.Status = protocol.StatusStopped
				break
			}
			s.emit(protocol.EventResumed, map[string]any{"attempt": n})
			if !live.Enforces(protocol.FeatSessionContinue) {
				last.SessionRef = ""
			}
			continue
		case boundarySteer:
			if !live.Enforces(protocol.FeatSessionContinue) {
				last.SessionRef = ""
			}
			continue
		}
		if s.dir.stopRequested() {
			s.receipt.Status = protocol.StatusStopped
			break
		}
		// A natural end. Instructions that arrived too late for this
		// attempt are not dropped: they start a continuation, unless the
		// run failed, in which case they are rejected below.
		if s.dir.hasInstructions() && out.Status != protocol.StatusFailed {
			if !live.Enforces(protocol.FeatSessionContinue) {
				last.SessionRef = ""
			}
			continue
		}
		s.receipt.Status = out.Status
		break
	}
	s.dir.finishRun()
	s.fill(last)
	return s.finish()
}

func endReason(out adapter.Outcome, boundary string, ctx context.Context) string {
	switch {
	case boundary == boundaryPause:
		return "paused"
	case boundary == boundarySteer:
		return "ended_for_instructions"
	case ctx.Err() == context.DeadlineExceeded:
		return "timeout"
	}
	if out.EndReason == "" {
		return out.Status
	}
	return out.EndReason
}

func (s *session) runAttempt(ctx context.Context, spec adapter.Spec, live adapter.Enforcement) attemptResult {
	ctl := adapter.Control{
		Emit:     s.emit,
		Applied:  s.dir.applied,
		Rejected: s.dir.rejected,
		Approval: s.approvalGate,
	}
	if live.Enforces(protocol.FeatLiveSteer) || live.Enforces(protocol.FeatPause) {
		ctl.Directives = s.dir.liveChannel()
	}
	done := make(chan attemptResult, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				done <- attemptResult{err: fmt.Errorf("adapter panicked: %v", r)}
			}
		}()
		out, err := s.adapter.Run(ctx, spec, ctl)
		done <- attemptResult{outcome: out, err: err}
	}()
	return <-done
}

func (s *session) spec(n int, instructions []string, sessionRef string) adapter.Spec {
	limits := s.remaining()
	schema, _ := s.agent.OutputSchema(procName(s.procedure))
	overlay, _, _ := s.agent.Overlay(s.adapter.Name())
	return adapter.Spec{
		Package:      s.wp,
		Agent:        s.agent,
		Attempt:      n,
		Workspace:    s.wp.Workspace.Path,
		Prompt:       Prompt(s.wp, s.agent, s.grants, instructions),
		Instructions: instructions,
		Grants:       s.grants,
		Limits:       limits,
		SessionRef:   sessionRef,
		OutputSchema: schema,
		Procedure:    s.procedure,
		Overlay:      overlay,
	}
}

func procName(p *protocol.Procedure) string {
	if p == nil {
		return ""
	}
	return p.Name
}

func add(a, b protocol.Cost) protocol.Cost {
	return protocol.Cost{USD: a.USD + b.USD, Turns: a.Turns + b.Turns, Tokens: a.Tokens + b.Tokens}
}

// remaining is what this attempt may still spend: the package limits less
// everything earlier attempts consumed. Budgets are cumulative.
func (s *session) remaining() protocol.Limits {
	l := s.wp.Capabilities.Limits
	if l.MaxUSD > 0 {
		l.MaxUSD = l.MaxUSD - s.spent.USD
		if l.MaxUSD < 0.01 {
			l.MaxUSD = 0.01
		}
	}
	if l.MaxTurns > 0 {
		l.MaxTurns = l.MaxTurns - s.spent.Turns
		if l.MaxTurns < 1 {
			l.MaxTurns = 1
		}
	}
	return l
}

func (s *session) budgetExhausted() string {
	l := s.wp.Capabilities.Limits
	if l.MaxUSD > 0 && s.spent.USD >= l.MaxUSD {
		return fmt.Sprintf("spend %.2f USD reached the limit of %.2f", s.spent.USD, l.MaxUSD)
	}
	if l.MaxTurns > 0 && s.spent.Turns >= l.MaxTurns {
		return fmt.Sprintf("%d turns reached the limit of %d", s.spent.Turns, l.MaxTurns)
	}
	return ""
}

// fill copies the final attempt's outcome onto the receipt, aligning the
// conditions to the contract by index and never reordering them.
func (s *session) fill(out adapter.Outcome) {
	r := s.receipt
	if r.Summary == "" {
		r.Summary = out.Summary
	}
	r.BlockedOn = out.BlockedOn
	n := len(s.wp.Completion.Conditions)
	conds := make([]protocol.ConditionProof, n)
	for i := 0; i < n; i++ {
		if i < len(out.Conditions) && (out.Conditions[i].Met || out.Conditions[i].Proof != "") {
			conds[i] = out.Conditions[i]
		} else {
			conds[i] = protocol.ConditionProof{Met: false, Proof: "no answer was reported for this condition"}
		}
	}
	r.Conditions = conds
	r.Evidence.Denials = out.Denials
	r.Evidence.Errors = append(r.Evidence.Errors, out.Errors...)
	r.Evidence.NoChange = out.Status == protocol.StatusNoChange
	r.Evidence.ExternalAction = out.ExternalAction
	r.Evidence.ApprovalCheck = out.ApprovalCheck
	if s.wp.Workspace.Kind == "git" && s.wp.Workspace.Path != "" {
		r.Evidence.FilesChanged = s.opts.ListChangedFiles(s.wp.Workspace.Path)
	}
	if r.Status == protocol.StatusStopped {
		r.Stop = s.dir.stopInfo(s.now())
		if r.Summary == "" || r.Summary == out.Summary {
			r.Summary = "stopped: " + r.Stop.Reason
		}
		if out.ExternalAction != nil {
			r.Uncertain = append(r.Uncertain, "an external action was recorded before the stop; it is not undone")
		}
	}
	if r.Status == "" {
		r.Status = protocol.StatusFailed
	}
}

// finish seals the receipt: directive summary, history, cost, digest.
func (s *session) finish() *protocol.RunReceipt {
	r := s.receipt
	s.dir.summarise(r)
	r.Cost = s.spent
	r.EndedAt = s.now()
	if r.Conditions == nil {
		r.Conditions = []protocol.ConditionProof{}
	}
	s.mu.Lock()
	r.Events.Emitted = s.eventSeq
	s.mu.Unlock()
	if c, ok := s.opts.Sink.(CoalescingSink); ok {
		r.Events.Coalesced = c.Coalesced()
	}
	s.mu.Lock()
	history := append([]historyLine(nil), s.history...)
	s.mu.Unlock()
	uri, hdigest, err := writeHistory(s.opts.HistoryDir, history)
	if err != nil {
		r.Uncertain = append(r.Uncertain, "instruction history could not be written: "+err.Error())
	}
	r.InstructionHistory = protocol.HistoryRef{URI: uri, Digest: hdigest}
	d, err := protocol.ReceiptDigest(*r)
	if err != nil {
		r.Uncertain = append(r.Uncertain, "receipt digest failed: "+err.Error())
	}
	r.ReceiptDigest = d
	return r
}
