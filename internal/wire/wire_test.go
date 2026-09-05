package wire

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/run"
	"cli.321.do/internal/trust"
)

func localHelperDir(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "testdata", "packages", "local", "helper"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func registry(script []protocol.ProcedureStep) *adapter.Registry {
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedure())
	r.RegisterHidden(adapter.NewFake(script))
	return r
}

func pkg(t *testing.T, objective string) *protocol.WorkPackage {
	t.Helper()
	l, err := trust.LoadPath(localHelperDir(t))
	if err != nil {
		t.Fatal(err)
	}
	return &protocol.WorkPackage{
		Schema: protocol.SchemaWorkPackage, PackageID: protocol.NewULID(), Issuer: protocol.Issuer{Kind: "test", ID: "t"}, IssuedAt: protocol.Now(),
		Agent: protocol.AgentRef{ID: l.ID(), Digest: l.Digest}, Placement: protocol.PlacementClient,
		Workspace: protocol.Workspace{Kind: "none", Ownership: "caller"}, Objective: objective,
		Completion: protocol.Completion{Conditions: []string{"done"}}, Capabilities: protocol.Grants{Granted: []string{}},
	}
}

func directive(pkgID string, seq int, kind, text string) []byte {
	d := protocol.WorkDirective{Schema: protocol.SchemaWorkDirective, DirectiveID: "w" + string(rune('0'+seq)), PackageID: pkgID, Seq: seq,
		Issuer: protocol.Issuer{Kind: "test", ID: "t"}, IssuedAt: protocol.Now(), Kind: kind, Payload: protocol.DirectivePayload{Text: text, Reason: text}}
	d.Digest, _ = protocol.DirectiveDigest(d)
	b, _ := json.Marshal(d)
	return append(b, '\n')
}

// frames splits stdout into decoded objects and returns their schemas.
func frames(t *testing.T, out []byte) ([]map[string]any, []string) {
	t.Helper()
	var objs []map[string]any
	var schemas []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		if len(bytes.TrimSpace(sc.Bytes())) == 0 {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("stdout carried a non-JSON line: %q", sc.Text())
		}
		objs = append(objs, m)
		schemas = append(schemas, m["schema"].(string))
	}
	return objs, schemas
}

func serve(t *testing.T, opts Options, stdin io.Reader, script []protocol.ProcedureStep) (int, []map[string]any, []string) {
	t.Helper()
	var out bytes.Buffer
	opts.Stdin = stdin
	opts.Stdout = &out
	opts.Stderr = io.Discard
	opts.Runner = &run.Runner{Adapters: registry(script)}
	if opts.PackageDir == "" && opts.Trust == nil {
		opts.PackageDir = localHelperDir(t)
	}
	code := Serve(context.Background(), opts)
	objs, schemas := frames(t, out.Bytes())
	return code, objs, schemas
}

func TestPackageOnStdinThenDirectivesThenOneReceiptLast(t *testing.T) {
	wp := pkg(t, "steer me")
	pb, _ := json.Marshal(wp)
	var in bytes.Buffer
	in.Write(pb)
	in.WriteByte('\n')
	in.Write(directive(wp.PackageID, 1, protocol.DirectiveSteer, "left"))
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	code, objs, schemas := serve(t, Options{PackageSource: "-", Adapter: "fake"}, &in, script)
	if code != ExitCompleted {
		t.Fatalf("exit %d; frames %v", code, schemas)
	}
	if schemas[len(schemas)-1] != protocol.SchemaRunReceipt {
		t.Fatalf("the receipt must be last: %v", schemas)
	}
	n := 0
	for _, s := range schemas {
		if s == protocol.SchemaRunReceipt {
			n++
		}
	}
	if n != 1 {
		t.Fatal("exactly one receipt")
	}
	for _, s := range schemas[:len(schemas)-1] {
		if s != protocol.SchemaRunEvent {
			t.Fatalf("only run events before the receipt: %v", schemas)
		}
	}
	last := objs[len(objs)-1]
	if last["status"] != protocol.StatusCompleted {
		t.Fatalf("status %v", last["status"])
	}
	applied := last["directives"].(map[string]any)["applied"].([]any)
	if len(applied) != 1 || applied[0] != "w1" {
		t.Fatalf("applied: %v", applied)
	}
}

func TestPackageFromFileWithDirectivesOnStdin(t *testing.T) {
	wp := pkg(t, "steer me")
	pb, _ := json.Marshal(wp)
	path := filepath.Join(t.TempDir(), "wp.json")
	os.WriteFile(path, pb, 0o600)
	in := bytes.NewReader(directive(wp.PackageID, 1, protocol.DirectiveSteer, "x"))
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	receiptPath := filepath.Join(t.TempDir(), "receipt.json")
	code, _, schemas := serve(t, Options{PackageSource: path, Adapter: "fake", ReceiptPath: receiptPath}, in, script)
	if code != ExitCompleted || schemas[len(schemas)-1] != protocol.SchemaRunReceipt {
		t.Fatalf("exit %d frames %v", code, schemas)
	}
	b, err := os.ReadFile(receiptPath)
	if err != nil {
		t.Fatal(err)
	}
	var r protocol.RunReceipt
	if err := json.Unmarshal(b, &r); err != nil || len(protocol.ValidateRunReceipt(&r)) > 0 {
		t.Fatalf("receipt file invalid: %v %v", err, protocol.ValidateRunReceipt(&r))
	}
}

func TestMalformedFirstFrameIsAProtocolErrorNotAReceipt(t *testing.T) {
	code, objs, schemas := serve(t, Options{PackageSource: "-"}, strings.NewReader("this is not json\n"), nil)
	if code != ExitMalformed || len(schemas) != 1 || schemas[0] != protocol.SchemaProtocolError {
		t.Fatalf("exit %d frames %v", code, schemas)
	}
	if objs[0]["code"] != "malformed_json" {
		t.Fatalf("code %v", objs[0]["code"])
	}
	code, objs, _ = serve(t, Options{PackageSource: "-"}, strings.NewReader(`{"schema":"work-directive.v1"}`+"\n"), nil)
	if code != ExitMalformed || objs[0]["code"] != "not_a_work_package" {
		t.Fatalf("a directive first is not a package: %d %v", code, objs[0])
	}
	code, objs, _ = serve(t, Options{PackageSource: "-"}, strings.NewReader(""), nil)
	if code != ExitMalformed || objs[0]["code"] != "no_package" {
		t.Fatalf("empty stdin: %d %v", code, objs[0])
	}
	code, objs, _ = serve(t, Options{PackageSource: "-"}, strings.NewReader(`{"schema":"work-package.v1"}`+"\n"), nil)
	if code != ExitMalformed || objs[0]["code"] != "unidentified_package" {
		t.Fatalf("a package with no id gets no receipt: %d %v", code, objs[0])
	}
}

func TestAnInvalidButIdentifiedPackageGetsADeniedReceipt(t *testing.T) {
	wp := pkg(t, "")
	pb, _ := json.Marshal(wp)
	code, objs, _ := serve(t, Options{PackageSource: "-"}, bytes.NewReader(append(pb, '\n')), nil)
	if code != ExitDenied || objs[len(objs)-1]["status"] != protocol.StatusDenied {
		t.Fatalf("exit %d last %v", code, objs[len(objs)-1]["status"])
	}
}

func TestAMalformedDirectiveLineIsReportedAndTheRunContinues(t *testing.T) {
	wp := pkg(t, "go")
	pb, _ := json.Marshal(wp)
	var in bytes.Buffer
	in.Write(pb)
	in.WriteString("\n{not json\n")
	in.WriteString(`{"schema":"run-event.v1"}` + "\n")
	in.Write(directive(wp.PackageID, 1, protocol.DirectiveSteer, "ok"))
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	code, objs, schemas := serve(t, Options{PackageSource: "-", Adapter: "fake"}, &in, script)
	if code != ExitCompleted {
		t.Fatalf("exit %d", code)
	}
	errs := 0
	for i, s := range schemas {
		if s == protocol.SchemaProtocolError {
			errs++
			if objs[i]["line"] == nil {
				t.Fatal("a directive-line error names its line")
			}
		}
	}
	if errs != 2 {
		t.Fatalf("expected two protocol errors, got %d: %v", errs, schemas)
	}
}

func TestStdinClosingIsNotAStop(t *testing.T) {
	wp := pkg(t, "go")
	pb, _ := json.Marshal(wp)
	script := []protocol.ProcedureStep{{Kind: "sleep", Duration: "30ms"}, {Kind: "assert", Condition: 1, Met: true, Proof: "ok"}}
	code, objs, _ := serve(t, Options{PackageSource: "-", Adapter: "fake"}, bytes.NewReader(append(pb, '\n')), script)
	if code != ExitCompleted || objs[len(objs)-1]["status"] != protocol.StatusCompleted {
		t.Fatalf("EOF must not stop the run: %d %v", code, objs[len(objs)-1]["status"])
	}
}

func TestStopArrivesEvenWhenStdoutIsNotDrainedAndTheReceiptFileIsStillWritten(t *testing.T) {
	wp := pkg(t, "chatty")
	pb, _ := json.Marshal(wp)
	// A script that emits far more than the buffer holds, then waits for a
	// directive. The reader is a pipe nobody reads.
	var steps []protocol.ProcedureStep
	for i := 0; i < EventBuffer+500; i++ {
		steps = append(steps, protocol.ProcedureStep{Kind: "emit", Text: "noise"})
	}
	steps = append(steps, protocol.ProcedureStep{Kind: "await_directive"})
	pr, pw := io.Pipe()
	in, inW := io.Pipe()
	receiptPath := filepath.Join(t.TempDir(), "receipt.json")
	opts := Options{PackageSource: "-", Adapter: "fake", Stdin: in, Stdout: pw, Stderr: io.Discard, ReceiptPath: receiptPath,
		Runner: &run.Runner{Adapters: registry(steps)}, PackageDir: localHelperDir(t)}
	done := make(chan int, 1)
	go func() { done <- Serve(context.Background(), opts) }()
	go func() {
		inW.Write(append(pb, '\n'))
		time.Sleep(100 * time.Millisecond)
		inW.Write(directive(wp.PackageID, 7, protocol.DirectiveStop, "stop now"))
	}()
	// Let the runtime block on its full buffer for a moment before we
	// start draining stdout; the stop must already have taken effect.
	var drained bytes.Buffer
	var mu sync.Mutex
	go func() {
		time.Sleep(300 * time.Millisecond)
		mu.Lock()
		defer mu.Unlock()
		io.Copy(&drained, pr)
	}()
	select {
	case code := <-done:
		if code != ExitStopped {
			t.Fatalf("exit %d", code)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("the run did not stop while stdout was blocked")
	}
	pw.Close()
	b, err := os.ReadFile(receiptPath)
	if err != nil {
		t.Fatal("receipt file must be written even when stdout is slow")
	}
	var r protocol.RunReceipt
	json.Unmarshal(b, &r)
	if r.Status != protocol.StatusStopped || r.Events.Coalesced == 0 {
		t.Fatalf("expected a stopped receipt with coalesced events: %s %+v", r.Status, r.Events)
	}
	if len(r.Directives.Gaps) != 1 {
		t.Fatalf("stop bypassed the gap: %+v", r.Directives.Gaps)
	}
}

func TestExitCodesFollowStatus(t *testing.T) {
	cases := map[string]int{protocol.StatusCompleted: 0, protocol.StatusNoChange: 0, protocol.StatusBlocked: 2, protocol.StatusStopped: 3, protocol.StatusFailed: 4, protocol.StatusDenied: 5}
	for s, want := range cases {
		if ExitFor(s) != want {
			t.Errorf("%s -> %d, want %d", s, ExitFor(s), want)
		}
	}
}

func TestAnUnloadableAgentYieldsADeniedReceiptNamingThePackage(t *testing.T) {
	wp := pkg(t, "go")
	wp.Agent.ID = "example.test/nobody"
	pb, _ := json.Marshal(wp)
	var out bytes.Buffer
	code := Serve(context.Background(), Options{PackageSource: "-", Stdin: bytes.NewReader(append(pb, '\n')), Stdout: &out, Stderr: io.Discard,
		Runner: &run.Runner{Adapters: registry(nil)}, Trust: &trust.Config{Schema: protocol.SchemaTrustConfig}})
	objs, _ := frames(t, out.Bytes())
	last := objs[len(objs)-1]
	if code != ExitDenied || last["status"] != protocol.StatusDenied || last["packageId"] != wp.PackageID {
		t.Fatalf("exit %d last %v", code, last)
	}
}

func TestContinueFromAReceiptFile(t *testing.T) {
	wp := pkg(t, "ask me")
	pb, _ := json.Marshal(wp)
	first := filepath.Join(t.TempDir(), "r1.json")
	blocked := []protocol.ProcedureStep{{Kind: "blocked", Question: "which file?"}}
	code, _, _ := serve(t, Options{PackageSource: "-", Adapter: "fake", ReceiptPath: first}, bytes.NewReader(append(pb, '\n')), blocked)
	if code != ExitBlocked {
		t.Fatalf("first run exit %d", code)
	}
	var in bytes.Buffer
	in.Write(pb)
	in.WriteByte('\n')
	in.Write(directive(wp.PackageID, 1, protocol.DirectiveClarify, "calc.go"))
	script := []protocol.ProcedureStep{{Kind: "await_directive"}, {Kind: "assert", Condition: 1, Met: true, Proof: "answered"}}
	code, objs, _ := serve(t, Options{PackageSource: "-", Adapter: "fake", ContinueFrom: first}, &in, script)
	if code != ExitCompleted {
		t.Fatalf("continuation exit %d", code)
	}
	last := objs[len(objs)-1]
	cont, _ := last["continues"].(map[string]any)
	if cont == nil || cont["attempts"] != float64(1) {
		t.Fatalf("continuation link missing: %v", last["continues"])
	}
	code, objs, _ = serve(t, Options{PackageSource: "-", ContinueFrom: filepath.Join(t.TempDir(), "missing.json")}, bytes.NewReader(append(pb, '\n')), nil)
	if code != ExitMalformed || objs[0]["code"] != "continue_unreadable" {
		t.Fatalf("an unreadable continuation is a protocol error: %d %v", code, objs[0])
	}
}
