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
