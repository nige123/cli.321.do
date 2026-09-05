package adapter

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/tool"
)

// A `tool` step reaches an externally bound program through the bounded
// tool interface. The runtime checks the grant the OPERATION needs (never
// the tool as a whole), substitutes the procedure's captures into the
// declared parameters, and lets the tool validate them and build its own
// argument vector. What comes back is recorded on the outcome as a
// ToolCall; a plan becomes a DeploymentProposal on the outcome's
// evidence; an operation the tool does not perform in this build ends the
// procedure as blocked, saying so.

type toolStepResult struct {
	done    bool // the procedure ends here
	stopped bool // ended by cancellation
}

func (p *ProcedureAdapter) runTool(ctx context.Context, spec Spec, ctl Control, step protocol.ProcedureStep, out *Outcome) toolStepResult {
	fail := func(reason, msg string) toolStepResult {
		out.Status = protocol.StatusFailed
		out.EndReason = reason
		out.Summary = msg
		out.Errors = append(out.Errors, msg)
		return toolStepResult{done: true}
	}
	t, ok := p.Tools[step.Tool]
	if !ok || t == nil {
		return fail("tool_unavailable", fmt.Sprintf("tool %q is not bound in this runtime", step.Tool))
	}
	op, ok := tool.OpOf(t, step.Op)
	if !ok {
		return fail("unsupported_operation", fmt.Sprintf("tool %q has no operation %q", step.Tool, step.Op))
	}

	// Authority is per operation.
	granted := false
	for _, g := range spec.Grants {
		if g == op.Capability {
			granted = true
		}
	}
	// An operation this build never performs ends the procedure here,
	// whatever the grants: nothing runs, the call is recorded as not
	// performed, and the answer says both facts.
	if op.Unavailable != "" {
		call := protocol.ToolCall{Tool: step.Tool, Op: step.Op, Capability: op.Capability, Ok: false, ExitCode: -1, Unavailable: op.Unavailable}
		out.ToolCalls = append(out.ToolCalls, call)
		ctl.Emit(protocol.EventToolResult, map[string]any{"tool": step.Tool, "op": step.Op, "ok": false, "exitCode": -1, "unavailable": op.Unavailable})
		out.Status = protocol.StatusBlocked
		out.EndReason = "execution_unavailable"
		out.BlockedOn = op.Unavailable
		if !granted {
			out.BlockedOn += "; " + op.Capability + " is not granted either"
		}
		if out.Proposal != nil {
			out.BlockedOn += fmt.Sprintf(" (proposal %s, digest %s)", out.Proposal.ProposalID, out.Proposal.ProposalDigest)
		}
		out.Summary = "prepared, not executed: " + op.Unavailable
		return toolStepResult{done: true}
	}
	if !granted {
		out.Denials = append(out.Denials, step.Tool+"."+step.Op)
		return fail("denied", fmt.Sprintf("%s %s needs %s, which is not granted", step.Tool, step.Op, op.Capability))
	}

	// THE EXECUTION BOUNDARY. A mutating operation with an executor bound
	// is performed only under an approval that names exactly this plan,
	// checked against a fresh observation taken by the preceding plan
	// step. The runtime never re-derives the plan itself: the approved
	// proposal is what the person saw; the fresh one is what is true now.
	if op.Mutates {
		if ex, ok := t.(tool.Executing); ok && ex.Executor() != nil {
			return p.runBoundary(spec, ctl, step, op, ex.Executor(), out)
		}
	}

	params := map[string]string{}
	for k, v := range step.Params {
		str, _ := v.(string)
		val := substitute(str, spec.Captures)
		if val != "" {
			params[k] = val
		}
	}
	ctl.Emit(protocol.EventToolCall, map[string]any{"tool": step.Tool, "op": step.Op, "params": params, "capability": op.Capability})

	res, err := t.Run(ctx, step.Op, params)
	call := protocol.ToolCall{Tool: step.Tool, Op: step.Op, Capability: op.Capability, Params: params}
	if err != nil {
		// A refused call: nothing ran. The refusal is the whole answer.
		call.Ok, call.ExitCode = false, -1
		out.ToolCalls = append(out.ToolCalls, call)
		if errors.Is(ctx.Err(), context.Canceled) {
			return toolStepResult{done: true, stopped: true}
		}
		if strings.Contains(err.Error(), "not configured") || strings.Contains(err.Error(), "not bound") {
			return fail("tool_unavailable", err.Error())
		}
		return fail("invalid_parameters", err.Error())
	}
	call.Argv = res.Argv
	call.Ok = res.Ok
	call.ExitCode = res.ExitCode
	call.DurationMs = res.Duration.Milliseconds()
	call.Unavailable = res.Unavailable
	call.OutputSHA = res.OutputDigest()
	call.Summary = tool.Summarise(step.Op, res.Data)
	out.ToolCalls = append(out.ToolCalls, call)
	ctl.Emit(protocol.EventToolResult, map[string]any{
		"tool": step.Tool, "op": step.Op, "ok": res.Ok, "exitCode": res.ExitCode,
		"argv": res.Argv, "output": capTail(res.Output, 4000), "truncated": res.Truncated,
	})

	if ctx.Err() != nil {
		return toolStepResult{done: true, stopped: true}
	}

	// An operation this build does not perform: say so, exactly.
	if res.Unavailable != "" {
		out.Status = protocol.StatusBlocked
		out.EndReason = "execution_unavailable"
		out.BlockedOn = res.Unavailable
		if out.Proposal != nil {
			out.BlockedOn += fmt.Sprintf(" (proposal %s, digest %s)", out.Proposal.ProposalID, out.Proposal.ProposalDigest)
		}
		out.Summary = "prepared, not executed: " + res.Unavailable
		return toolStepResult{done: true}
	}

	switch step.Op {
	case "plan":
		if res.Data == nil {
			return fail("engine_error", "the engine returned no plan document: "+capTail(res.Output, 1000))
		}
		prop := buildProposal(spec, res.Data)
		out.Proposal = prop
		ctl.Emit(protocol.EventProgress, map[string]any{"text": fmt.Sprintf("proposal %s (%s): %s", prop.ProposalID, prop.Status, call.Summary), "proposalId": prop.ProposalID, "proposalDigest": prop.ProposalDigest})
		if prop.Status != "planned" {
			out.Status = protocol.StatusBlocked
			out.EndReason = "blocked"
			out.BlockedOn = prop.Question
			out.Summary = "no plan: " + prop.Question
			return toolStepResult{done: true}
		}
		out.Summary = call.Summary
	case "status":
		if !res.Ok {
			return fail("engine_error", "status failed: "+capTail(res.Output, 1000))
		}
		if res.Data == nil {
			return fail("engine_error", "the engine returned no status document: "+capTail(res.Output, 1000))
		}
		out.Summary = call.Summary
	default:
		if !res.Ok {
			return fail("engine_error", step.Op+" failed: "+capTail(res.Output, 1000))
		}
		out.Summary = call.Summary
	}
	return toolStepResult{}
}

// substitute replaces {{name}} with the capture of that name; an unknown
// or empty capture yields the empty string, which the caller drops.
func substitute(s string, captures map[string]string) string {
	if !strings.Contains(s, "{{") {
		return s
	}
	out := s
	for name, val := range captures {
		out = strings.ReplaceAll(out, "{{"+name+"}}", val)
	}
	if strings.Contains(out, "{{") {
		// an unresolved placeholder is not a value
		return ""
	}
	return out
}

// buildProposal wraps the engine's plan document as a
// deployment-proposal.v1, carrying the engine-owned sections verbatim.
func buildProposal(spec Spec, data map[string]any) *protocol.DeploymentProposal {
	str := func(m map[string]any, k string) string { s, _ := m[k].(string); return s }
	obj := func(k string) map[string]any { m, _ := data[k].(map[string]any); return m }
	arr := func(k string) []any { a, _ := data[k].([]any); return a }
	strs := func(k string) []string {
		out := []string{}
		for _, v := range arr(k) {
			if s, ok := v.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	svc := obj("service")
	p := &protocol.DeploymentProposal{
		Schema:              protocol.SchemaDeploymentProposal,
		ProposalID:          protocol.NewULID(),
		PackageID:           spec.Package.PackageID,
		SupersedesPackageID: spec.Package.SupersedesPackageID,
		Operation:           "deploy",
		Status:              str(data, "status"),
		Question:            str(data, "question"),
		Service:             str(svc, "name"),
		Target:              str(svc, "target"),
		TargetHost:          obj("targetHost"),
		Repository:          obj("repository"),
		Revision:            obj("revision"),
		Manifest:            obj("manifest"),
		Engine:              obj("engine"),
		Observed:            obj("observed"),
		Operations:          arr("operations"),
		Checks:              arr("checks"),
		Unperformed:         strs("unperformed"),
		Blockers:            strs("blockers"),
		Health:              obj("health"),
		Rollback:            obj("rollback"),
		EngineCommands:      arr("commands"),
		ObservedAt:          str(data, "observedAt"),
	}
	if spec.Agent != nil {
		p.Agent = protocol.AgentRef{ID: spec.Agent.ID(), Version: spec.Agent.Manifest.Version, Digest: spec.Agent.Digest}
	}
	if p.Status == "" {
		p.Status = "blocked"
	}
	if p.Status == "blocked" && p.Question == "" {
		p.Question = "the engine could not plan and gave no reason"
	}
	if p.ObservedAt == "" {
		p.ObservedAt = protocol.Now()
	}
	p.ProposalDigest, _ = protocol.ProposalDigest(*p)
	return p
}

func (p *ProcedureAdapter) runBoundary(spec Spec, ctl Control, step protocol.ProcedureStep, op tool.Op, ex tool.Executor, out *Outcome) toolStepResult {
	call := protocol.ToolCall{Tool: step.Tool, Op: step.Op, Capability: op.Capability, Ok: false, ExitCode: -1}
	record := func() { out.ToolCalls = append(out.ToolCalls, call) }
	approval := spec.Package.Approval
	if approval == nil || approval.Proposal == nil {
		call.Unavailable = "no approval bound to a proposal is attached to this package"
		record()
		out.Status = protocol.StatusBlocked
		out.EndReason = "approval_required"
		out.BlockedOn = "executing needs a person's approval bound to a deployment proposal; none is attached to this package"
		if out.Proposal != nil {
			out.BlockedOn += fmt.Sprintf(" (a fresh plan was prepared: proposal %s, digest %s)", out.Proposal.ProposalID, out.Proposal.ProposalDigest)
		}
		out.Summary = "prepared, not executed: no approval"
		return toolStepResult{done: true}
	}
	approved := approval.Proposal
	fresh := out.Proposal
	if fresh == nil {
		call.Unavailable = "no fresh plan preceded the execution"
		record()
		out.Status = protocol.StatusFailed
		out.EndReason = "no_fresh_plan"
		out.Errors = append(out.Errors, "execution needs a fresh plan of the same target immediately before it")
		return toolStepResult{done: true}
	}
	check := &protocol.ApprovalCheck{}
	if h, err := protocol.ParamsHash(approval.Params); err == nil {
		check.ParamsHashMatched = h == approval.ParamsHash
	}
	var err error
	if fresh.Service != approved.Service || fresh.Target != approved.Target {
		err = fmt.Errorf("the fresh plan is for %s@%s, the approval for %s@%s", fresh.Service, fresh.Target, approved.Service, approved.Target)
	}
	var result string
	if err == nil {
		result, err = tool.Gate(approved, approval, tool.StateFrom(fresh, approved), ex)
	}
	if err != nil {
		check.OperationMatched = false
		check.Detail = err.Error()
		out.ApprovalCheck = check
		out.Denials = append(out.Denials, "execute "+approved.Service+"@"+approved.Target)
		call.Unavailable = "refused: " + err.Error()
		record()
		out.Status = protocol.StatusFailed
		out.EndReason = "approval_mismatch"
		out.Errors = append(out.Errors, "approval: "+err.Error())
		out.Summary = "not executed: " + err.Error()
		return toolStepResult{done: true}
	}
	check.OperationMatched = true
	check.Detail = "the fresh plan matches the approved proposal " + approved.ProposalID + " and the approval " + approval.ApprovalRef
	out.ApprovalCheck = check
	call.Ok = true
	call.ExitCode = 0
	call.Summary = result
	record()
	out.ExternalAction = &protocol.ExternalAction{
		ProposalRef: approval.ProposalRef,
		ApprovalRef: approval.ApprovalRef,
		Action:      "deploy",
		Target:      approved.Service + "@" + approved.Target,
		Params:      approval.Params,
		PerformedAt: protocol.Now(),
		Result:      result + " (executor: " + ex.Name() + ")",
	}
	ctl.Emit(protocol.EventToolResult, map[string]any{"tool": step.Tool, "op": step.Op, "ok": true, "executor": ex.Name(), "result": result})
	out.Summary = "executed under approval " + approval.ApprovalRef + ": " + result
	return toolStepResult{}
}
