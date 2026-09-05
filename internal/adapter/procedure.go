package adapter

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/tool"
)

// ProcedureAdapter executes a package's deterministic procedure without a
// model. It is also the fake adapter: given a Script it runs that instead,
// which is how tests drive every directive and cancellation path with no
// process, no network and no clock dependence beyond a step's own sleep.
//
// It enforces everything it claims by construction: the only operations it
// performs are the ones its steps name, each checked against the grants,
// the workspace boundary and the approval gate before it happens.
type ProcedureAdapter struct {
	AdapterName string
	Script      []protocol.ProcedureStep // fake mode when set
	// Tools are the externally bound programs a `tool` step may reach,
	// each by explicit configuration. Nil means no tool is bound.
	Tools tool.Registry
}

// NewProcedure returns the built-in procedure executor.
func NewProcedure() *ProcedureAdapter { return &ProcedureAdapter{AdapterName: "procedure"} }

// NewProcedureWithTools returns the procedure executor with tool bindings.
func NewProcedureWithTools(tools tool.Registry) *ProcedureAdapter {
	return &ProcedureAdapter{AdapterName: "procedure", Tools: tools}
}

// Bindings describes the bound tools for `321 doctor`.
func (p *ProcedureAdapter) Bindings() []string {
	var out []string
	for _, name := range p.Tools.Names() {
		t := p.Tools[name]
		state := "bound"
		if de, ok := t.(*tool.DeployEngine); ok {
			if de.Bound() {
				state = de.Bin
			} else {
				state = "not configured (set DEPLOY_ENGINE_BIN to the engine's explicit entry point)"
			}
			if ee, ok := de.Exec.(*tool.EngineExecutor); ok {
				state += "; execute ENABLED on " + strings.Join(ee.AllowedTargets, ", ") + " (DEPLOY_ENGINE_EXECUTE)"
			} else if de.Exec == nil {
				state += "; execute unavailable"
			}
		}
		var ops []string
		for _, o := range t.Ops() {
			ops = append(ops, o.Name+" ("+o.Capability+")")
		}
		out = append(out, fmt.Sprintf("%s: %s; operations: %s", name, state, strings.Join(ops, ", ")))
	}
	return out
}

// NewFake returns the deterministic fake adapter with an optional script.
func NewFake(script []protocol.ProcedureStep) *ProcedureAdapter {
	return &ProcedureAdapter{AdapterName: "fake", Script: script}
}

func (p *ProcedureAdapter) Name() string { return p.AdapterName }

func (p *ProcedureAdapter) Detect() Detection { return Detection{Available: true, Version: "built-in"} }

func (p *ProcedureAdapter) Enforcement() Enforcement {
	e := Enforcement{}
	for _, f := range protocol.Features() {
		e[f] = true
	}
	return e
}

// defaultScript is what the fake adapter does with no script: it asserts
// every condition met with a labelled proof and completes.
func defaultScript(wp *protocol.WorkPackage) []protocol.ProcedureStep {
	steps := []protocol.ProcedureStep{{Kind: "emit", Text: "fake adapter: starting"}}
	for i := range wp.Completion.Conditions {
		steps = append(steps, protocol.ProcedureStep{Kind: "assert", Condition: i + 1, Met: true, Proof: "fake adapter: asserted without evidence"})
	}
	return steps
}

func (p *ProcedureAdapter) Run(ctx context.Context, spec Spec, ctl Control) (Outcome, error) {
	var steps []protocol.ProcedureStep
	name := ""
	switch {
	case spec.Procedure != nil:
		steps = spec.Procedure.Steps
		name = spec.Procedure.Name
	case p.Script != nil:
		steps = p.Script
	default:
		steps = defaultScript(spec.Package)
	}
	out := Outcome{Status: protocol.StatusCompleted, EndReason: "completed", Summary: "procedure completed"}
	if name != "" {
		out.Summary = "procedure " + name + " completed"
	}
	conds := make([]protocol.ConditionProof, len(spec.Package.Completion.Conditions))
	touched := false
	turns := 0
	grants := map[string]bool{}
	for _, g := range spec.Grants {
		grants[g] = true
	}
	// Directives are applied the moment they arrive, between steps. An
	// await_directive step consumes one arrival: one that already came in
	// early, or the next one to come.
	arrived := 0

	for _, step := range steps {
		if err := ctx.Err(); err != nil {
			return stopped(out, conds, touched, turns), nil
		}
		n, err := p.drainDirectives(ctx, ctl, false)
		if err != nil {
			return stopped(out, conds, touched, turns), nil
		}
		arrived += n
		turns++
		if spec.Limits.MaxTurns > 0 && turns > spec.Limits.MaxTurns {
			out.Status = protocol.StatusFailed
			out.EndReason = "turn_limit"
			out.Errors = append(out.Errors, fmt.Sprintf("turn limit %d reached", spec.Limits.MaxTurns))
			return finish(out, conds, touched, turns), nil
		}
		switch step.Kind {
		case "emit":
			ctl.Emit(protocol.EventProgress, map[string]any{"text": step.Text})
		case "sleep":
			d, _ := time.ParseDuration(step.Duration)
			select {
			case <-ctx.Done():
				return stopped(out, conds, touched, turns), nil
			case <-time.After(d):
			}
		case "await_directive":
			if arrived > 0 {
				arrived--
				break
			}
			if _, err := p.drainDirectives(ctx, ctl, true); err != nil {
				return stopped(out, conds, touched, turns), nil
			}
		case "write":
			if !grants[protocol.CapRepoWrite] && !grants[protocol.CapFilesWrite] {
				out.Denials = append(out.Denials, "write "+step.Path)
				out.Status = protocol.StatusFailed
				out.EndReason = "denied"
				out.Errors = append(out.Errors, "write to "+step.Path+" is not granted")
				return finish(out, conds, touched, turns), nil
			}
			if spec.Workspace == "" {
				out.Status = protocol.StatusFailed
				out.EndReason = "no_workspace"
				out.Errors = append(out.Errors, "write requires a workspace")
				return finish(out, conds, touched, turns), nil
			}
			full, err := insideWorkspace(spec.Workspace, step.Path)
			if err != nil {
				out.Status = protocol.StatusFailed
				out.EndReason = "denied"
				out.Errors = append(out.Errors, err.Error())
				return finish(out, conds, touched, turns), nil
			}
			if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
				return failed(out, conds, err), nil
			}
			if err := os.WriteFile(full, []byte(step.Content), 0o644); err != nil {
				return failed(out, conds, err), nil
			}
			touched = true
			ctl.Emit(protocol.EventToolResult, map[string]any{"tool": "write", "path": step.Path})
		case "assert":
			if step.Condition >= 1 && step.Condition <= len(conds) {
				conds[step.Condition-1] = protocol.ConditionProof{Met: step.Met, Proof: step.Proof}
			}
		case "blocked":
			out.Status = protocol.StatusBlocked
			out.EndReason = "blocked"
			out.BlockedOn = step.Question
			out.Summary = "stopped to ask: " + step.Question
			return finish(out, conds, touched, turns), nil
		case "no_change":
			out.Status = protocol.StatusNoChange
			out.EndReason = "no_change"
			if step.Text != "" {
				out.Summary = step.Text
			}
			return finish(out, conds, touched, turns), nil
		case "fail":
			out.Status = protocol.StatusFailed
			out.EndReason = "failed"
			out.Errors = append(out.Errors, step.Text)
			return finish(out, conds, touched, turns), nil
		case "tool":
			r := p.runTool(ctx, spec, ctl, step, &out)
			if r.done {
				if r.stopped {
					return stopped(out, conds, touched, turns), nil
				}
				return finish(out, conds, touched, turns), nil
			}
		case "external_action":
			if ctl.Approval == nil {
				out.Status = protocol.StatusFailed
				out.EndReason = "denied"
				out.Errors = append(out.Errors, "external action with no approval gate")
				return finish(out, conds, touched, turns), nil
			}
			check, err := ctl.Approval(step.Action, step.Target, step.Params)
			out.ApprovalCheck = check
			if err != nil {
				out.Status = protocol.StatusFailed
				out.EndReason = "approval_mismatch"
				out.Denials = append(out.Denials, "external_action "+step.Action)
				out.Errors = append(out.Errors, err.Error())
				return finish(out, conds, touched, turns), nil
			}
			out.ExternalAction = &protocol.ExternalAction{
				ProposalRef: spec.Package.Approval.ProposalRef,
				ApprovalRef: spec.Package.Approval.ApprovalRef,
				Action:      step.Action,
				Target:      step.Target,
				Params:      step.Params,
				PerformedAt: protocol.Now(),
				Result:      "recorded by the procedure executor",
			}
			ctl.Emit(protocol.EventToolResult, map[string]any{"tool": "external_action", "action": step.Action, "target": step.Target})
		default:
			return failed(out, conds, fmt.Errorf("unknown step kind %q", step.Kind)), nil
		}
	}
	return finish(out, conds, touched, turns), nil
}

// drainDirectives applies live directives and reports how many were
// handled. With block set it waits for exactly one. A pause holds here
// until resume or cancellation; instructions received while paused are
// applied as they arrive but do not count as arrivals for await.
func (p *ProcedureAdapter) drainDirectives(ctx context.Context, ctl Control, block bool) (int, error) {
	if ctl.Directives == nil {
		if block {
			<-ctx.Done()
			return 0, ctx.Err()
		}
		return 0, nil
	}
	handle := func(d protocol.WorkDirective) error {
		switch d.Kind {
		case protocol.DirectivePause:
			ctl.Emit(protocol.EventPaused, map[string]any{"directiveId": d.DirectiveID})
			ctl.Applied(d.DirectiveID)
			for {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case r, ok := <-ctl.Directives:
					if !ok {
						<-ctx.Done()
						return ctx.Err()
					}
					switch r.Kind {
					case protocol.DirectiveResume:
						ctl.Applied(r.DirectiveID)
						ctl.Emit(protocol.EventResumed, map[string]any{"directiveId": r.DirectiveID})
						return nil
					case protocol.DirectivePause:
						ctl.Rejected(r.DirectiveID, "already paused")
					default:
						ctl.Emit(protocol.EventProgress, map[string]any{"instruction": r.Payload.Text, "directiveId": r.DirectiveID})
						ctl.Applied(r.DirectiveID)
					}
				}
			}
		case protocol.DirectiveResume:
			ctl.Rejected(d.DirectiveID, "not paused")
		case protocol.DirectiveClarify, protocol.DirectiveSteer:
			ctl.Emit(protocol.EventProgress, map[string]any{"instruction": d.Payload.Text, "directiveId": d.DirectiveID})
			ctl.Applied(d.DirectiveID)
		default:
			ctl.Rejected(d.DirectiveID, "unsupported live directive "+d.Kind)
		}
		return nil
	}
	if block {
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case d, ok := <-ctl.Directives:
			if !ok {
				<-ctx.Done()
				return 0, ctx.Err()
			}
			return 1, handle(d)
		}
	}
	n := 0
	for {
		select {
		case <-ctx.Done():
			return n, ctx.Err()
		case d, ok := <-ctl.Directives:
			if !ok {
				return n, nil
			}
			n++
			if err := handle(d); err != nil {
				return n, err
			}
		default:
			return n, nil
		}
	}
}

func insideWorkspace(ws, rel string) (string, error) {
	if !protocol.SafeRelPath(rel) {
		return "", fmt.Errorf("path %q is not a safe relative path", rel)
	}
	abs, err := filepath.Abs(ws)
	if err != nil {
		return "", err
	}
	full := filepath.Join(abs, filepath.FromSlash(rel))
	if full != abs && !strings.HasPrefix(full, abs+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q escapes the workspace", rel)
	}
	// Refuse to write through a symlinked parent that leaves the workspace.
	parent := filepath.Dir(full)
	for {
		if resolved, err := filepath.EvalSymlinks(parent); err == nil {
			absResolved, _ := filepath.EvalSymlinks(abs)
			if resolved != absResolved && !strings.HasPrefix(resolved, absResolved+string(filepath.Separator)) {
				return "", fmt.Errorf("path %q resolves outside the workspace", rel)
			}
			break
		}
		if parent == abs || parent == filepath.Dir(parent) {
			break
		}
		parent = filepath.Dir(parent)
	}
	return full, nil
}

func finish(out Outcome, conds []protocol.ConditionProof, touched bool, turns int) Outcome {
	out.Conditions = conds
	out.Cost.Turns = turns
	out.Cost.Basis = protocol.CostNone // deterministic: no model was used
	if !touched && out.Status == protocol.StatusCompleted && out.ExternalAction == nil && allMet(conds) && len(conds) == 0 {
		// Nothing asserted, nothing written: still a completion, but say so.
		out.Summary = strings.TrimSpace(out.Summary + " (no conditions were declared)")
	}
	return out
}

func stopped(out Outcome, conds []protocol.ConditionProof, touched bool, turns int) Outcome {
	out.Cost.Basis = protocol.CostNone
	out.Status = protocol.StatusStopped
	out.EndReason = "cancelled"
	out.Summary = "stopped before the procedure finished"
	return finish(out, conds, touched, turns)
}

func failed(out Outcome, conds []protocol.ConditionProof, err error) Outcome {
	out.Status = protocol.StatusFailed
	out.EndReason = "failed"
	out.Errors = append(out.Errors, err.Error())
	out.Conditions = conds
	return out
}

func allMet(conds []protocol.ConditionProof) bool {
	for _, c := range conds {
		if !c.Met {
			return false
		}
	}
	return true
}

// HashParams is a convenience for tests building approvals.
func HashParams(params map[string]any) string {
	h, err := protocol.ParamsHash(params)
	if err != nil {
		sum := sha256.Sum256(nil)
		return "sha256:" + hex.EncodeToString(sum[:])
	}
	return h
}

var errNoApproval = errors.New("no approval is attached to this package")

// ErrNoApproval is returned by an approval gate when the package carries
// no approval at all.
func ErrNoApproval() error { return errNoApproval }
