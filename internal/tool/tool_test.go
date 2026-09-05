package tool

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cli.321.do/internal/protocol"
)

func fakeEngine(t *testing.T) (*DeployEngine, string) {
	t.Helper()
	bin, err := filepath.Abs(filepath.Join("..", "..", "testdata", "fakeengine", "deploy-engine"))
	if err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "engine.log")
	env := append(os.Environ(), "FAKE_ENGINE_LOG="+log)
	return &DeployEngine{Bin: bin, Env: env, Timeout: 20 * time.Second}, log
}

func invocations(log string) []string {
	b, err := os.ReadFile(log)
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func TestArgvIsStrictAndNeverAShell(t *testing.T) {
	d := &DeployEngine{}
	good := []struct {
		op     string
		params map[string]string
		want   string
	}{
		{"status", nil, "status --json"},
		{"status", map[string]string{"service": "alpha.web"}, "status alpha.web --json"},
		{"status", map[string]string{"service": "alpha.web", "target": "live"}, "status alpha.web live --json"},
		{"plan", map[string]string{"service": "alpha.web", "target": "live"}, "plan alpha.web live --json"},
		{"plan", map[string]string{"service": "alpha.web", "target": "live", "revision": "0f94b03"}, "plan alpha.web live --revision 0f94b03 --json"},
		{"plan", map[string]string{"target": "live"}, "plan  live --json"},
	}
	for _, c := range good {
		argv, err := d.Argv(c.op, c.params)
		if err != nil || strings.Join(argv, " ") != c.want {
			t.Errorf("%s %v: %v %q, want %q", c.op, c.params, err, strings.Join(argv, " "), c.want)
		}
	}
	bad := []struct {
		op     string
		params map[string]string
	}{
		{"status", map[string]string{"service": "alpha.web; rm -rf /"}},
		{"status", map[string]string{"service": "--force"}},
		{"status", map[string]string{"service": "-v"}},
		{"plan", map[string]string{"service": "alpha.web", "target": "live$(touch x)"}},
		{"plan", map[string]string{"service": "alpha.web", "target": "live", "revision": "HEAD"}},
		{"plan", map[string]string{"service": "alpha.web", "target": "live", "revision": "master"}},
		{"plan", map[string]string{"service": "alpha.web", "target": "live", "revision": "--revision"}},
		{"plan", map[string]string{"service": "alpha.web", "target": "live", "force": "yes"}},
		{"plan", map[string]string{"service": "alpha.web", "target": "live", "command": "go"}},
		{"status", map[string]string{"revision": "0f94b03"}},
		{"restart", map[string]string{"service": "alpha.web"}},
		{"go", map[string]string{"service": "alpha.web", "target": "live"}},
	}
	for _, c := range bad {
		if argv, err := d.Argv(c.op, c.params); err == nil {
			t.Errorf("%s %v must be refused, built %q", c.op, c.params, argv)
		}
	}
}

func TestStatusAndPlanRunTheBoundEngineAndParseItsDocument(t *testing.T) {
	d, log := fakeEngine(t)
	res, err := d.Run(context.Background(), "status", map[string]string{"target": "live"})
	if err != nil || !res.Ok || res.Data == nil {
		t.Fatalf("status: %v %+v", err, res)
	}
	if s := Summarise("status", res.Data); !strings.Contains(s, "alpha.web running") || !strings.Contains(s, "beta.web not running") {
		t.Errorf("summary: %s", s)
	}
	res, err = d.Run(context.Background(), "plan", map[string]string{"service": "alpha.web", "target": "live", "revision": "0f94b03"})
	if err != nil || !res.Ok || res.Data["status"] != "planned" {
		t.Fatalf("plan: %v %+v", err, res)
	}
	rev, _ := res.Data["revision"].(map[string]any)
	if rev["sha"] != "0f94b03" || rev["source"] != "requested" {
		t.Errorf("revision: %v", rev)
	}
	inv := invocations(log)
	if len(inv) != 2 || strings.TrimSpace(inv[0]) != "status live --json" || !strings.HasPrefix(inv[1], "plan alpha.web live --revision 0f94b03 --json") {
		t.Errorf("invocations: %q", inv)
	}
}

func TestExecuteIsNotPerformedInThisBuild(t *testing.T) {
	d, log := fakeEngine(t)
	res, err := d.Run(context.Background(), "execute", map[string]string{"service": "alpha.web", "target": "live", "revision": "0f94b03"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Unavailable == "" || res.Ok || res.Argv != nil {
		t.Fatalf("execute must be reported unavailable and run nothing: %+v", res)
	}
	if _, statErr := os.Stat(log); statErr == nil {
		t.Fatalf("the engine was invoked: %v", invocations(log))
	}
}

func TestUnboundAndUnknownAreRefusedWithoutRunning(t *testing.T) {
	d := &DeployEngine{}
	if _, err := d.Run(context.Background(), "status", nil); err == nil || !strings.Contains(err.Error(), "not configured") {
		t.Fatalf("unbound: %v", err)
	}
	d, log := fakeEngine(t)
	if _, err := d.Run(context.Background(), "restart", map[string]string{"service": "alpha.web"}); err == nil {
		t.Fatal("restart must be refused")
	}
	if _, err := d.Run(context.Background(), "plan", map[string]string{"service": "alpha.web", "target": "live", "revision": "master"}); err == nil {
		t.Fatal("a branch name is not a revision")
	}
	if _, statErr := os.Stat(log); statErr == nil {
		t.Fatalf("a refused call must not reach the engine: %v", invocations(log))
	}
}

func TestOutputIsRedactedAndCapped(t *testing.T) {
	d, _ := fakeEngine(t)
	d.Env = append(d.Env, "FAKE_ENGINE_SECRET=sk-ant-verysecretvalue1234567890")
	res, err := d.Run(context.Background(), "plan", map[string]string{"service": "alpha.web", "target": "live"})
	if err != nil || !res.Ok {
		t.Fatal(err)
	}
	if strings.Contains(res.Output, "verysecret") {
		t.Fatalf("secret leaked into output: %s", res.Output)
	}
	eng, _ := res.Data["engine"].(map[string]any)
	if eng["token"] != "<redacted>" {
		t.Errorf("a value under a sensitive key must be replaced: %v", eng["token"])
	}
	if note, _ := eng["note"].(string); strings.Contains(note, "verysecret") {
		t.Errorf("an assignment inside a string must be redacted: %s", note)
	}
	if got := Redact("Authorization: Bearer abcdefghijklmnop token=xyz123456 -----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY----- ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ"); strings.Contains(got, "abcdefghijklmnop") || strings.Contains(got, "xyz123456") || strings.Contains(got, "\nabc\n") || strings.Contains(got, "ghp_ABC") {
		t.Errorf("redaction: %s", got)
	}
	d.MaxOutput = 200
	res, _ = d.Run(context.Background(), "plan", map[string]string{"service": "alpha.web", "target": "live"})
	if !res.Truncated || res.Data != nil || len(res.Output) > 400 {
		t.Errorf("a capped output is marked truncated and not parsed as a document: %+v", res.Truncated)
	}
}

func proposalFixture(t *testing.T) *protocol.DeploymentProposal {
	t.Helper()
	p := &protocol.DeploymentProposal{
		Schema: protocol.SchemaDeploymentProposal, ProposalID: protocol.NewULID(), PackageID: protocol.NewULID(),
		Agent: protocol.AgentRef{ID: "example.test/operator", Version: "0.1.0"}, Operation: "deploy", Status: "planned",
		Service: "alpha.web", Target: "live",
		Revision:    map[string]any{"sha": "0f94b03cf776c9b4ca9fe028d6879557f8d06bb3", "source": "requested"},
		Manifest:    map[string]any{"digest": "sha256:" + strings.Repeat("3", 64)},
		Observed:    map[string]any{"deployedRevision": strings.Repeat("1", 40)},
		Unperformed: []string{"tests"}, Blockers: []string{}, ObservedAt: "2026-09-05T12:00:00Z",
	}
	p.ProposalDigest, _ = protocol.ProposalDigest(*p)
	if ps := protocol.ValidateDeploymentProposal(p); len(ps) > 0 {
		t.Fatalf("fixture invalid: %v", ps)
	}
	return p
}

func approvalFor(p *protocol.DeploymentProposal) *protocol.Approval {
	params := ApprovalParams(p)
	h, _ := protocol.ParamsHash(params)
	return &protocol.Approval{ProposalRef: p.ProposalID, ApprovalRef: "approval-1", ApprovedBy: "user:1",
		Action: "deploy", Target: p.Service + "@" + p.Target, Params: params, ParamsHash: h}
}

func TestTheFutureBoundaryMatchesTheExactProposalAndCurrentState(t *testing.T) {
	p := proposalFixture(t)
	a := approvalFor(p)
	now := CurrentState{ManifestDigest: p.Manifest["digest"].(string), DeployedRevision: strings.Repeat("1", 40), RevisionExists: true}
	ex := &RecordingExecutor{}
	if _, err := Gate(p, a, now, ex); err != nil {
		t.Fatalf("a matching approval against unchanged state must pass: %v", err)
	}
	if len(ex.Calls) != 1 {
		t.Fatalf("executed once: %v", ex.Calls)
	}

	refuse := func(name string, p2 *protocol.DeploymentProposal, a2 *protocol.Approval, st CurrentState) {
		t.Helper()
		ex := &RecordingExecutor{}
		if _, err := Gate(p2, a2, st, ex); err == nil {
			t.Errorf("%s: must be refused", name)
		}
		if len(ex.Calls) != 0 {
			t.Errorf("%s: the executor must not be called: %v", name, ex.Calls)
		}
	}
	// a changed revision on the proposal: the approval's params no longer match
	p2 := *p
	p2.Revision = map[string]any{"sha": strings.Repeat("9", 40), "source": "requested"}
	p2.ProposalDigest, _ = protocol.ProposalDigest(p2)
	refuse("changed revision", &p2, a, now)
	// a tampered approval: params edited without a new hash
	a2 := *a
	a2.Params = map[string]any{}
	for k, v := range a.Params {
		a2.Params[k] = v
	}
	a2.Params["revision"] = strings.Repeat("9", 40)
	refuse("edited params", p, &a2, now)
	// the hash re-made over edited params: the proposal still disagrees
	a3 := a2
	a3.ParamsHash, _ = protocol.ParamsHash(a3.Params)
	refuse("re-hashed params", p, &a3, now)
	// a different target
	a4 := *a
	a4.Target = "alpha.web@dev"
	refuse("other target", p, &a4, now)
	// state moved since planning
	refuse("manifest changed", p, a, CurrentState{ManifestDigest: "sha256:other", DeployedRevision: now.DeployedRevision, RevisionExists: true})
	refuse("deployed revision moved", p, a, CurrentState{ManifestDigest: now.ManifestDigest, DeployedRevision: strings.Repeat("5", 40), RevisionExists: true})
	refuse("revision gone", p, a, CurrentState{ManifestDigest: now.ManifestDigest, DeployedRevision: now.DeployedRevision, RevisionExists: false})
	// a blocked proposal is not executable however it is approved
	pb := *p
	pb.Status = "blocked"
	pb.ProposalDigest, _ = protocol.ProposalDigest(pb)
	refuse("blocked proposal", &pb, approvalFor(&pb), now)
	// no approval at all
	refuse("no approval", p, nil, now)
	// a proposal whose digest was tampered
	pt := *p
	pt.ProposalDigest = "sha256:" + strings.Repeat("0", 64)
	refuse("tampered digest", &pt, a, now)
}

func TestTheEngineExecutorRunsGoOnlyOnAllowedTargets(t *testing.T) {
	bin, _ := filepath.Abs(filepath.Join("..", "..", "testdata", "fakeengine", "deploy-engine"))
	log := filepath.Join(t.TempDir(), "engine.log")
	env := append(os.Environ(), "FAKE_ENGINE_LOG="+log, "FAKE_ENGINE_ALLOW_GO=1")
	ex := &EngineExecutor{Bin: bin, AllowedTargets: []string{"dev"}, Env: env, Timeout: 20 * time.Second}
	p := proposalFixture(t)
	a := approvalFor(p)
	// live is not allowed: refused before the engine is invoked
	if _, err := ex.Execute(p, a); err == nil || !strings.Contains(err.Error(), "not enabled") {
		t.Fatalf("live must be refused: %v", err)
	}
	if _, statErr := os.Stat(log); statErr == nil {
		t.Fatal("the engine must not be invoked for a disallowed target")
	}
	pd := *p
	pd.Target = "dev"
	pd.ProposalDigest, _ = protocol.ProposalDigest(pd)
	res, err := ex.Execute(&pd, approvalFor(&pd))
	if err != nil || !strings.Contains(res, "completed") {
		t.Fatalf("dev: %v %s", err, res)
	}
	if inv := invocations(log); len(inv) != 1 || strings.TrimSpace(inv[0]) != "go alpha.web dev" {
		t.Fatalf("argv: %q", inv)
	}
	// the engine reports a failed gate in words, exit 0: that is a failure
	ex.Env = append(env, "FAKE_ENGINE_GO_FAILS=1")
	if _, err := ex.Execute(&pd, approvalFor(&pd)); err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("a rolled-back deploy must be reported as a failure: %v", err)
	}
}
