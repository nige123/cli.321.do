package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/run"
	"cli.321.do/internal/tool"
	"cli.321.do/internal/trust"
)

// Operator approval: the CLI invocation IS the human approval.
//
// A deployment's execution boundary requires an approval bound to the
// exact plan being executed (protocol.Approval + tool.MatchApproval). In
// the delegated (123) flow that approval is a person's reaction in the
// app, minted asynchronously, long after the plan was seen — so the
// boundary re-plans and compares, to catch drift across that gap.
//
// At a terminal there is no gap: a person typing `321 1da go <svc>
// <target>` IS exercising the authority. So the standalone runner, for an
// interactive operator, plans first (read-only), mints an approval bound
// to that exact proposal, attaches it, and runs the go. The go re-plans
// and the boundary compares fresh-against-approved exactly as in the
// delegated flow; the two plans are milliseconds apart, so a genuine
// change between them (and only that) still refuses. Nothing here widens
// the boundary: execution remains gated by DEPLOY_ENGINE_EXECUTE, the
// engine still health-gates and rolls back, and a plan that does not come
// back `planned` mints no approval at all.
//
// This applies ONLY to the standalone `321 <agent>` path a person drives.
// A server-issued package (`321 run --package`) never enters here: its
// authority is the approval the API attached, verified the same way.

// isOperatorDeployGo reports whether this standalone invocation is a person
// asking a deployment-capable agent to `go`, and returns the equivalent
// read-only `plan` request to observe first. It is deliberately narrow:
// interactive only, the agent must list deploy.invoke as an optional
// capability, and the objective's verb must be `go`.
func isOperatorDeployGo(env Env, g global, agent *trust.Loaded, request string) (planRequest string, ok bool) {
	if !env.Interactive || g.nonInteractive {
		return "", false
	}
	invokable := false
	for _, c := range agent.Manifest.Capabilities.Optional {
		if c == protocol.CapDeployInvoke {
			invokable = true
		}
	}
	if !invokable {
		return "", false
	}
	fields := strings.Fields(request)
	if len(fields) == 0 || fields[0] != "go" {
		return "", false
	}
	// The go and plan procedures share the same tail grammar (service,
	// target, optional revision); only the verb differs.
	fields[0] = "plan"
	return strings.Join(fields, " "), true
}

// assumeOperatorApproval, when this is an interactive operator `go`, plans
// the deployment read-only, and if a concrete plan comes back mints an
// operator approval bound to it and attaches it to wp (granting
// deploy.invoke within local policy). It returns a one-line note to show
// the person, or "" when nothing was assumed (not a go, an ambiguous or
// blocked plan, or policy forbids deploy.invoke) — in which case the go
// runs unchanged and surfaces its own outcome.
func assumeOperatorApproval(env Env, g global, cfg *trust.Config, agent *trust.Loaded, wp *protocol.WorkPackage, request string) string {
	planRequest, ok := isOperatorDeployGo(env, g, agent, request)
	if !ok {
		return ""
	}
	// Granting deploy.invoke on the operator's behalf is the substance of
	// "the invocation is the approval". If local policy's ceiling forbids
	// it, the operator cannot authorise it here — leave the go to block.
	if ceiling := cfg.Policy.CapabilityCeiling; ceiling != nil {
		allowed := false
		for _, c := range ceiling {
			if c == protocol.CapDeployInvoke {
				allowed = true
			}
		}
		if !allowed {
			return ""
		}
	}

	proposal := operatorPlan(env, g, cfg, agent, planRequest)
	if proposal == nil || proposal.Status != "planned" {
		return "" // no concrete plan to approve; the go will explain itself
	}

	by := os.Getenv("USER")
	if host, err := os.Hostname(); err == nil && host != "" {
		by += "@" + host
	}
	approval, err := mintOperatorApproval(proposal, by)
	if err != nil {
		return ""
	}
	wp.Approval = approval
	if !hasCapability(wp.Capabilities.Granted, protocol.CapDeployInvoke) {
		wp.Capabilities.Granted = append(wp.Capabilities.Granted, protocol.CapDeployInvoke)
	}
	if ps := protocol.ValidateWorkPackage(wp); len(ps) > 0 {
		// A malformed package here is a bug, not the operator's fault; fall
		// back to running the go without the assumed approval.
		wp.Approval = nil
		return ""
	}
	sha, _ := proposal.Revision["sha"].(string)
	return fmt.Sprintf("operator approval assumed (you typed the command): deploy %s to %s at %s — execution proceeds only where DEPLOY_ENGINE_EXECUTE enables it",
		proposal.Service, proposal.Target, shortSHA(sha))
}

// operatorPlan runs the read-only plan procedure quietly and returns the
// proposal it produced, or nil.
func operatorPlan(env Env, g global, cfg *trust.Config, agent *trust.Loaded, planRequest string) *protocol.DeploymentProposal {
	// A plan touches no workspace: 1DA reads and writes no files.
	planWP, err := buildPackage(cfg, agent, g, planRequest, "", "none")
	if err != nil {
		return nil
	}
	raw, _ := json.Marshal(planWP)
	receipt := env.runner().Run(context.Background(), planWP, agent, run.Options{
		Sink:       run.SinkFunc(func(protocol.RunEvent) {}),
		Policy:     cfg.Policy,
		Adapter:    g.adapter,
		PackageRaw: raw,
	})
	if receipt == nil {
		return nil
	}
	return receipt.Evidence.Proposal
}

// mintOperatorApproval builds an approval bound to exactly this proposal,
// with the parameters and hash the execution boundary re-verifies.
func mintOperatorApproval(p *protocol.DeploymentProposal, by string) (*protocol.Approval, error) {
	params := tool.ApprovalParams(p)
	hash, err := protocol.ParamsHash(params)
	if err != nil {
		return nil, err
	}
	return &protocol.Approval{
		ProposalRef: "operator/" + p.ProposalID,
		ApprovalRef: "operator/" + protocol.NewULID(),
		ApprovedBy:  by,
		Action:      "deploy",
		Target:      p.Service + "@" + p.Target,
		Params:      params,
		ParamsHash:  hash,
		Proposal:    p,
	}, nil
}

func hasCapability(granted []string, cap string) bool {
	for _, c := range granted {
		if c == cap {
			return true
		}
	}
	return false
}

func shortSHA(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
