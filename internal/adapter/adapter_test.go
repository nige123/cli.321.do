package adapter

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
)

type stub struct {
	name string
	enf  Enforcement
	ok   bool
}

func (s stub) Name() string { return s.name }
func (s stub) Detect() Detection {
	if !s.ok {
		return Detection{Reason: "missing"}
	}
	return Detection{Available: true, Version: "t"}
}
func (s stub) Enforcement() Enforcement { return s.enf }
func (s stub) Run(context.Context, Spec, Control) (Outcome, error) {
	return Outcome{Status: protocol.StatusCompleted}, nil
}

func manifest(requires ...string) *protocol.AgentManifest {
	return &protocol.AgentManifest{Harness: protocol.HarnessSpec{Requires: requires}}
}

func pkg(grants []string, network string) *protocol.WorkPackage {
	return &protocol.WorkPackage{Capabilities: protocol.Grants{Granted: grants, Limits: protocol.Limits{Network: network, MaxTurns: 5, MaxUSD: 1}}}
}

func names(reqs []Requirement) []string {
	var out []string
	for _, r := range reqs {
		out = append(out, r.Feature)
	}
	return out
}

func TestRequirementsFollowFromGrantsNotProse(t *testing.T) {
	got := strings.Join(names(Requirements(manifest(), pkg([]string{protocol.CapShellRun}, ""), []string{protocol.CapShellRun})), ",")
	for _, want := range []string{protocol.FeatToolAllowlist, protocol.FeatNetworkDeny, protocol.FeatTurnLimit, protocol.FeatSpendLimit} {
		if !strings.Contains(got, want) {
			t.Errorf("shell.run under provider_only must require %s; got %s", want, got)
		}
	}
	got = strings.Join(names(Requirements(manifest(), pkg([]string{protocol.CapShellRun}, protocol.NetworkOpen), []string{protocol.CapShellRun})), ",")
	if strings.Contains(got, protocol.FeatNetworkDeny) {
		t.Errorf("an open network needs no network_deny: %s", got)
	}
	got = strings.Join(names(Requirements(manifest(protocol.FeatRepoScope), pkg(nil, ""), nil)), ",")
	if !strings.Contains(got, protocol.FeatRepoScope) || strings.Contains(got, protocol.FeatToolAllowlist) {
		t.Errorf("package requirements are honoured and no tools means no allowlist: %s", got)
	}
}

func TestSelectionDeniesWhatCannotBeEnforcedAndNeverPicksHiddenAdapters(t *testing.T) {
	llm := stub{name: "llm", ok: true, enf: Enforcement{protocol.FeatToolAllowlist: true, protocol.FeatStructuredOutput: true, protocol.FeatTurnLimit: true, protocol.FeatSpendLimit: true}}
	r := NewRegistry()
	r.RegisterHidden(NewFake(nil))
	r.Register(llm)
	reqs := Requirements(manifest(), pkg([]string{protocol.CapShellRun}, ""), []string{protocol.CapShellRun})
	if a, rej := r.Select(reqs, trust.AdapterPolicy{}, ""); a != nil {
		t.Fatalf("expected denial, got %s", a.Name())
	} else if len(rej) != 1 || !strings.Contains(rej[0].String(), protocol.FeatNetworkDeny) {
		t.Fatalf("rejection must name network_deny: %v", rej)
	}
	// The fake enforces everything but is hidden: only an explicit request selects it.
	if a, _ := r.Select(reqs, trust.AdapterPolicy{}, "fake"); a == nil || a.Name() != "fake" {
		t.Fatal("fake must be selectable by name")
	}
	if a, _ := r.Select(reqs, trust.AdapterPolicy{Preferred: []string{"fake"}}, ""); a == nil || a.Name() != "fake" {
		t.Fatal("fake must be selectable by policy preference")
	}
	open := Requirements(manifest(), pkg([]string{protocol.CapShellRun}, protocol.NetworkOpen), []string{protocol.CapShellRun})
	if a, _ := r.Select(open, trust.AdapterPolicy{}, ""); a == nil || a.Name() != "llm" {
		t.Fatal("llm should qualify once the network is open")
	}
	if a, rej := r.Select(open, trust.AdapterPolicy{Denied: []string{"llm"}}, ""); a != nil || len(rej) == 0 || !rej[0].Denied {
		t.Fatal("policy denial must be honoured")
	}
	if a, _ := r.Select(open, trust.AdapterPolicy{}, "nope"); a != nil {
		t.Fatal("an unknown adapter name selects nothing")
	}
}

func TestUnavailableAdaptersAreReportedNotChosen(t *testing.T) {
	r := NewRegistry(stub{name: "gone", ok: false, enf: Enforcement{protocol.FeatStructuredOutput: true}})
	a, rej := r.Select([]Requirement{{Feature: protocol.FeatStructuredOutput}}, trust.AdapterPolicy{}, "")
	if a != nil || len(rej) != 1 || rej[0].Unavailable == "" {
		t.Fatalf("expected unavailable rejection, got %v %v", a, rej)
	}
}

func TestClaudeCodeArgsDeriveToolsFromGrantsAndReportHonestly(t *testing.T) {
	c := &ClaudeCode{}
	spec := Spec{Prompt: "p", Grants: []string{protocol.CapRepoRead, protocol.CapRepoWrite}, Limits: protocol.Limits{MaxTurns: 7, MaxUSD: 2.5}, OutputSchema: []byte(`{"type":"object"}`), SessionRef: "sess-1", Overlay: []byte(`{"model":"claude-sonnet-5"}`)}
	args := strings.Join(c.Args(spec), " ")
	for _, want := range []string{"--permission-mode dontAsk", "--allowedTools Read,Glob,Grep,Edit,Write,TodoWrite", "--max-turns 7", "--max-budget-usd 2.50", "--resume sess-1", "--json-schema", "--model claude-sonnet-5", "--output-format stream-json"} {
		if !strings.Contains(args, want) {
			t.Errorf("missing %q in %s", want, args)
		}
	}
	if strings.Contains(args, "Bash") || strings.Contains(args, "WebFetch") {
		t.Error("ungranted tools must not appear")
	}
	enf := c.Enforcement()
	if enf.Enforces(protocol.FeatNetworkDeny) || enf.Enforces(protocol.FeatRepoScope) || enf.Enforces(protocol.FeatLiveSteer) || enf.Enforces(protocol.FeatPause) {
		t.Error("claude_code must not claim network_deny, repo_scope, live_steer or pause")
	}
	if !enf.Enforces(protocol.FeatToolAllowlist) || !enf.Enforces(protocol.FeatSessionContinue) || !enf.Enforces(protocol.FeatGracefulStop) {
		t.Error("claude_code enforcement report incomplete")
	}
	if c.Detect().Available && c.Detect().Version == "" {
		t.Error("available adapters report a version")
	}
}

func TestEnvelopeParsingPortedFromTheTUI(t *testing.T) {
	line := []byte(`{"type":"result","is_error":false,"result":"{\"status\":\"blocked\"}","session_id":"s","total_cost_usd":0.3,"num_turns":2,"permission_denials":[{"tool_name":"Bash"},"WebFetch",{"odd":1}],"structured_output":{"status":"blocked","summary":"need a file","blocked_on":"which file?","conditions":[{"met":true,"proof":"x"}]}}`)
	s, ok := ParseEnvelope(line)
	if !ok || !s.Blocked || s.BlockedOn != "which file?" || s.Summary != "need a file" || s.SessionRef != "s" || s.Turns != 2 {
		t.Fatalf("envelope misread: %+v", s)
	}
	if strings.Join(s.Denials, ",") != "Bash,WebFetch,{\"odd\":1}" {
		t.Fatalf("denials: %v", s.Denials)
	}
	if len(s.Conditions) != 1 || !s.Conditions[0].Met {
		t.Fatal("conditions not carried")
	}
	if _, ok := ParseEnvelope([]byte(`just prose`)); ok {
		t.Fatal("prose is not an envelope")
	}
	if _, ok := ParseEnvelope([]byte(`{"type":"assistant"}`)); ok {
		t.Fatal("a non-result object is not an envelope")
	}
	s2, _ := ParseEnvelope([]byte(`{"type":"result","is_error":true,"result":"boom","errors":["Reached maximum budget"]}`))
	if !s2.IsError || s2.Errors[0] != "Reached maximum budget" || s2.Summary != "boom" {
		t.Fatalf("error envelope misread: %+v", s2)
	}
}

func TestStreamConsumerRendersTranscriptEmitsToolEventsAndHidesPlumbing(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"init-session"}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/main.go"}}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"StructuredOutput","input":{}}]}}`,
		`{"type":"rate_limit_event"}`,
		`{"type":"result","result":"done","session_id":"z","num_turns":1}`,
	}, "\n")
	var transcript bytes.Buffer
	var kinds []string
	env, session := consumeStream(strings.NewReader(stream), &transcript, Control{Emit: func(k string, p map[string]any) { kinds = append(kinds, k) }})
	if env == nil || env.SessionRef != "z" {
		t.Fatal("envelope not returned")
	}
	if session != "init-session" {
		t.Fatalf("the init event's session id must be read so an interrupted attempt can resume: %q", session)
	}
	out := transcript.String()
	if !strings.Contains(out, "Read main.go") || !strings.Contains(out, "Looking") || !strings.Contains(out, "rate limited") {
		t.Fatalf("transcript: %q", out)
	}
	if strings.Contains(out, "StructuredOutput") {
		t.Fatal("plumbing must not appear")
	}
	if strings.Join(kinds, ",") != "progress,tool_call" {
		t.Fatalf("events: %v", kinds)
	}
	if env, _ := consumeStream(strings.NewReader(`{"type":"assistant"}`), &bytes.Buffer{}, Control{}); env != nil {
		t.Fatal("no result means no envelope")
	}
}

func TestProcedureExecutorRefusesUngrantedWritesAndEscapes(t *testing.T) {
	ws := t.TempDir()
	wp := &protocol.WorkPackage{Completion: protocol.Completion{Conditions: []string{"c1"}}}
	p := NewFake([]protocol.ProcedureStep{{Kind: "write", Path: "out.txt", Content: "x"}})
	out, _ := p.Run(context.Background(), Spec{Package: wp, Workspace: ws, Grants: nil}, Control{Emit: func(string, map[string]any) {}})
	if out.Status != protocol.StatusFailed || len(out.Denials) == 0 {
		t.Fatalf("write without a grant must be denied: %+v", out)
	}
	out, _ = p.Run(context.Background(), Spec{Package: wp, Workspace: ws, Grants: []string{protocol.CapRepoWrite}}, Control{Emit: func(string, map[string]any) {}})
	if out.Status != protocol.StatusCompleted {
		t.Fatalf("granted write should complete: %+v", out)
	}
	esc := NewFake([]protocol.ProcedureStep{{Kind: "write", Path: "../outside.txt", Content: "x"}})
	out, _ = esc.Run(context.Background(), Spec{Package: wp, Workspace: ws, Grants: []string{protocol.CapRepoWrite}}, Control{Emit: func(string, map[string]any) {}})
	if out.Status != protocol.StatusFailed {
		t.Fatal("an escaping path must fail")
	}
}

func TestProcedureExternalActionNeedsTheGate(t *testing.T) {
	wp := &protocol.WorkPackage{Completion: protocol.Completion{Conditions: []string{}}}
	p := NewFake([]protocol.ProcedureStep{{Kind: "external_action", Action: "send", Target: "x"}})
	out, _ := p.Run(context.Background(), Spec{Package: wp}, Control{Emit: func(string, map[string]any) {}})
	if out.Status != protocol.StatusFailed {
		t.Fatal("no gate means no external action")
	}
	var raw json.RawMessage
	_ = raw
}
