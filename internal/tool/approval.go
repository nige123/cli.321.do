package tool

import (
	"errors"
	"fmt"
	"sync"

	"cli.321.do/internal/protocol"
)

// The future execution boundary.
//
// Nothing in this build executes a deployment. What exists is the check
// that boundary will make, so the approval shape and the proposal shape
// are settled now and tested against a recording fake: an approval binds
// to one proposal's digest and to the exact parameters that matter
// (service, target, revision, manifest digest); execution re-derives the
// digest from the proposal it holds, compares the parameters, and refuses
// if the relevant current state has moved since the plan was observed.
// Changed parameters mean a new proposal and a renewed approval; nothing
// here can be widened by editing the approval alone.

// CurrentState is what the boundary re-observes immediately before acting.
type CurrentState struct {
	ManifestDigest   string
	DeployedRevision string
	RevisionExists   bool
}

// ApprovalParams are the parameters an approval of a deployment carries.
func ApprovalParams(p *protocol.DeploymentProposal) map[string]any {
	sha, _ := p.Revision["sha"].(string)
	md, _ := p.Manifest["digest"].(string)
	return map[string]any{
		"proposalId":     p.ProposalID,
		"proposalDigest": p.ProposalDigest,
		"service":        p.Service,
		"target":         p.Target,
		"revision":       sha,
		"manifestDigest": md,
	}
}

// MatchApproval decides whether approval authorises executing proposal
// now. It returns nil only when every binding holds.
func MatchApproval(p *protocol.DeploymentProposal, a *protocol.Approval, now CurrentState) error {
	if p == nil {
		return errors.New("no proposal")
	}
	if a == nil {
		return errors.New("no approval is attached")
	}
	if p.Status != "planned" {
		return fmt.Errorf("the proposal is %s, not planned", p.Status)
	}
	d, err := protocol.ProposalDigest(*p)
	if err != nil || d != p.ProposalDigest {
		return errors.New("the proposal does not match its own digest")
	}
	if a.Action != "deploy" {
		return fmt.Errorf("the approval is for %q, not deploy", a.Action)
	}
	if want := p.Service + "@" + p.Target; a.Target != want {
		return fmt.Errorf("the approval targets %q, the proposal %q", a.Target, want)
	}
	h, err := protocol.ParamsHash(a.Params)
	if err != nil || h != a.ParamsHash {
		return errors.New("paramsHash does not match the approved params")
	}
	want := ApprovalParams(p)
	wantC, _ := protocol.Canonical(want)
	gotC, _ := protocol.Canonical(a.Params)
	if string(wantC) != string(gotC) {
		return errors.New("the approved parameters are not this proposal's: a changed service, target, revision or manifest needs a new proposal and a renewed approval")
	}
	md, _ := p.Manifest["digest"].(string)
	if now.ManifestDigest != md {
		return errors.New("the manifest has changed since the plan was observed; plan again")
	}
	if obs, _ := p.Observed["deployedRevision"].(string); obs != "" && now.DeployedRevision != obs {
		return errors.New("the deployed revision has changed since the plan was observed; plan again")
	}
	if !now.RevisionExists {
		return errors.New("the approved revision is no longer reachable")
	}
	return nil
}

// Executor is what the boundary calls after MatchApproval holds. It
// returns a short account of what it did. The only implementation in this
// build records; it never deploys.
type Executor interface {
	Name() string
	Execute(p *protocol.DeploymentProposal, a *protocol.Approval) (string, error)
}

// RecordingExecutor records what it was asked to execute.
type RecordingExecutor struct {
	mu    sync.Mutex
	Calls []string
}

func (r *RecordingExecutor) Name() string { return "recording" }

func (r *RecordingExecutor) Execute(p *protocol.DeploymentProposal, a *protocol.Approval) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.Calls = append(r.Calls, p.ProposalID+" under "+a.ApprovalRef)
	return "recorded by the recording executor; nothing was deployed", nil
}

// Gate runs the check and, only if it holds, the executor.
func Gate(p *protocol.DeploymentProposal, a *protocol.Approval, now CurrentState, ex Executor) (string, error) {
	if err := MatchApproval(p, a, now); err != nil {
		return "", err
	}
	return ex.Execute(p, a)
}

// StateFrom reads the current state off a FRESH plan of the same target,
// taken immediately before execution, for comparison with the approved
// proposal.
func StateFrom(fresh, approved *protocol.DeploymentProposal) CurrentState {
	if fresh == nil {
		return CurrentState{}
	}
	md, _ := fresh.Manifest["digest"].(string)
	dep, _ := fresh.Observed["deployedRevision"].(string)
	freshSha, _ := fresh.Revision["sha"].(string)
	approvedSha := ""
	if approved != nil {
		approvedSha, _ = approved.Revision["sha"].(string)
	}
	return CurrentState{
		ManifestDigest:   md,
		DeployedRevision: dep,
		RevisionExists:   fresh.Status == "planned" && freshSha != "" && freshSha == approvedSha,
	}
}
