package run

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/protocol"
)

// These tests drive the REAL claude_code adapter — its argument surface,
// its stream reader, its SIGTERM handling and its --resume continuation —
// against a controllable stand-in for the `claude` executable
// (testdata/fakeclaude/claude). No model is involved; what is exercised
// is exactly the lifecycle the runner relies on for adapters that cannot
// steer or pause live.

func fakeClaude(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "testdata", "fakeclaude", "claude"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("fake claude not present: %v", err)
	}
	return p
}

func claudeRegistry(t *testing.T) *adapter.Registry {
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedure())
	r.Register(&adapter.ClaudeCode{Binary: fakeClaude(t), KillWait: 3 * time.Second})
	return r
}

func claudeEnv(t *testing.T, mode string) string {
	t.Helper()
	log := filepath.Join(t.TempDir(), "claude.log")
	t.Setenv("FAKE_CLAUDE_LOG", log)
	t.Setenv("FAKE_CLAUDE_MODE", mode)
	return log
}

func invocations(t *testing.T, log string) []string {
	t.Helper()
	b, err := os.ReadFile(log)
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func TestClaudeCodeDeniesNetworkNoneWithShellBeforeSpawning(t *testing.T) {
	agent := helper(t)
	log := claudeEnv(t, "complete")
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapShellRun}
	wp.Capabilities.Limits.Network = protocol.NetworkNone
	col := newCollector()
	r := (&Runner{Adapters: claudeRegistry(t)}).Run(context.Background(), wp, agent, Options{Sink: col})
	if r.Status != protocol.StatusDenied || r.Denied == nil {
		t.Fatalf("expected a denial: %s %+v", r.Status, r.Denied)
	}
	joined := strings.Join(r.Denied.Details, "\n")
	if !strings.Contains(joined, protocol.FeatNetworkDeny) || !strings.Contains(joined, "shell.run is granted") {
		t.Fatalf("the denial must name the unenforceable requirement: %s", joined)
	}
	if _, err := os.Stat(log); err == nil {
		t.Fatalf("the harness was spawned despite the denial: %s", strings.Join(invocations(t, log), "\n"))
	}
	if col.count(protocol.EventAdapterSelected) != 0 || len(r.Attempts) != 0 {
		t.Fatal("no adapter may be selected and no attempt made")
	}
}

func TestClaudeCodeProviderOnlyWithShellIsDeniedToo(t *testing.T) {
	agent := helper(t)
	log := claudeEnv(t, "complete")
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapShellRun}
	wp.Capabilities.Limits.Network = "" // the default: provider_only
	r := (&Runner{Adapters: claudeRegistry(t)}).Run(context.Background(), wp, agent, Options{})
	if r.Status != protocol.StatusDenied {
		t.Fatalf("provider_only with a shell is not enforceable either: %s", r.Status)
	}
	if _, err := os.Stat(log); err == nil {
		t.Fatal("the harness was spawned despite the denial")
	}
}

func TestClaudeCodeRunsWithAnEnforceableEnvelope(t *testing.T) {
	agent := helper(t)
	log := claudeEnv(t, "complete")
	wp := pkgFor(agent, "build it", "built", "and tested")
	wp.Capabilities.Granted = []string{protocol.CapRepoRead, protocol.CapRepoWrite, protocol.CapShellRun}
	wp.Capabilities.Limits = protocol.Limits{Network: protocol.NetworkOpen, MaxTurns: 8, MaxUSD: 1}
	t.Setenv("FAKE_CLAUDE_CONDITIONS", "2")
	col := newCollector()
	r := (&Runner{Adapters: claudeRegistry(t)}).Run(context.Background(), wp, agent, Options{Sink: col})
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted || len(r.Attempts) != 1 {
		t.Fatalf("expected one completed attempt: %s %+v %v", r.Status, r.Attempts, r.Evidence.Errors)
	}
	inv := invocations(t, log)
	if len(inv) != 1 {
		t.Fatalf("one invocation expected: %v", inv)
	}
	for _, want := range []string{"--permission-mode dontAsk", "--allowedTools", "Bash", "Edit", "--max-turns 8", "--max-budget-usd 1.00", "--json-schema"} {
		if !strings.Contains(inv[0], want) {
			t.Errorf("the surface must carry %q: %s", want, inv[0])
		}
	}
	if strings.Contains(inv[0], "WebFetch") {
		t.Error("net.fetch was not granted; WebFetch must not be allowed")
	}
	if len(r.Conditions) != 2 || !r.Conditions[0].Met || !r.Conditions[1].Met {
		t.Fatalf("conditions from the harness, by index: %+v", r.Conditions)
	}
	if r.Harness.Adapter != "claude_code" || len(r.Harness.SessionRefs) != 1 {
		t.Fatalf("harness: %+v", r.Harness)
	}
}

func TestClaudeCodeSteerInterruptsThenResumesAndAppliesAtTheBoundary(t *testing.T) {
	agent := helper(t)
	log := claudeEnv(t, "hang-until-resumed")
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: claudeRegistry(t)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil) // the stand-in is running and hanging
	steer := directive(wp.PackageID, 1, protocol.DirectiveSteer, "use the existing helper")
	ch <- steer
	col.wait(t, protocol.EventDirectiveReceived, nil)
	r := <-done
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted || len(r.Attempts) != 2 {
		t.Fatalf("expected two attempts and completion: %s %+v", r.Status, r.Attempts)
	}
	if r.Attempts[0].EndReason != "ended_for_instructions" {
		t.Fatalf("attempt 1 must end for instructions: %+v", r.Attempts[0])
	}
	if !strings.HasPrefix(r.Attempts[0].SessionRef, "fake-session-") {
		t.Fatalf("the interrupted attempt's session must be read off the init event: %+v", r.Attempts[0])
	}
	inv := invocations(t, log)
	if len(inv) != 2 {
		t.Fatalf("two harness invocations expected: %v", inv)
	}
	if !strings.Contains(inv[1], "--resume "+r.Attempts[0].SessionRef) {
		t.Fatalf("attempt 2 must resume the interrupted session: %s", inv[1])
	}
	if !strings.Contains(inv[1], "use the existing helper") || strings.Contains(inv[0], "existing helper") {
		t.Fatalf("the instruction reaches only the resumed prompt: %v", inv)
	}
	if !has(r.Directives.Applied, steer.DirectiveID) {
		t.Fatalf("the steer must be applied: %+v", r.Directives)
	}
	var order []string
	col.mu.Lock()
	for _, e := range col.events {
		switch e.Kind {
		case protocol.EventDirectiveReceived, protocol.EventDirectiveApplied, protocol.EventAttemptEnded, protocol.EventAttemptStarted:
			order = append(order, e.Kind)
		}
	}
	col.mu.Unlock()
	joined := strings.Join(order, ",")
	if !strings.Contains(joined, "directive_received,attempt_ended,attempt_started,directive_applied") {
		t.Fatalf("applied only once the resumed attempt has started, never on receipt: %s", joined)
	}
}

func TestClaudeCodePauseTerminatesTheProcessAndResumeContinuesTheSession(t *testing.T) {
	agent := helper(t)
	log := claudeEnv(t, "hang-until-resumed")
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: claudeRegistry(t)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil)
	pause := directive(wp.PackageID, 1, protocol.DirectivePause, "hold on")
	ch <- pause
	col.wait(t, protocol.EventPaused, nil)
	col.wait(t, protocol.EventDirectiveApplied, func(e protocol.RunEvent) bool { return e.Payload["directiveId"] == pause.DirectiveID })
	if inv := invocations(t, log); len(inv) != 1 {
		t.Fatalf("paused: the process has ended and no new one started: %v", inv)
	}
	if col.count(protocol.EventAttemptStarted) != 1 {
		t.Fatal("no attempt may start while paused")
	}
	ch <- directive(wp.PackageID, 2, protocol.DirectiveResume, "")
	r := <-done
	checkReceipt(t, r)
	if r.Status != protocol.StatusCompleted || len(r.Attempts) != 2 || r.Attempts[0].EndReason != "paused" {
		t.Fatalf("expected paused then a resumed attempt: %s %+v", r.Status, r.Attempts)
	}
	inv := invocations(t, log)
	if len(inv) != 2 || !strings.Contains(inv[1], "--resume "+r.Attempts[0].SessionRef) {
		t.Fatalf("resume must continue the interrupted session: %v", inv)
	}
	var order []string
	col.mu.Lock()
	for _, e := range col.events {
		switch e.Kind {
		case protocol.EventDirectiveApplied, protocol.EventAttemptEnded, protocol.EventPaused:
			order = append(order, e.Kind)
		}
	}
	col.mu.Unlock()
	if joined := strings.Join(order, ","); !strings.HasPrefix(joined, "attempt_ended,directive_applied,paused") && !strings.HasPrefix(joined, "attempt_ended,paused,directive_applied") {
		t.Fatalf("pause is applied only once the process has ended: %s", joined)
	}
}

func TestClaudeCodeStopTerminatesGracefullyAndReportsStopped(t *testing.T) {
	agent := helper(t)
	log := claudeEnv(t, "hang")
	wp := pkgFor(agent, "build it", "built")
	wp.Capabilities.Limits.Network = protocol.NetworkOpen
	ch := make(chan protocol.WorkDirective, 8)
	col := newCollector()
	done := make(chan *protocol.RunReceipt, 1)
	go func() {
		done <- (&Runner{Adapters: claudeRegistry(t)}).Run(context.Background(), wp, agent, Options{Directives: ch, Sink: col})
	}()
	col.wait(t, protocol.EventProgress, nil)
	stop := directive(wp.PackageID, 1, protocol.DirectiveStop, "enough")
	ch <- stop
	r := <-done
	checkReceipt(t, r)
	if r.Status != protocol.StatusStopped || r.Stop == nil || r.Stop.DirectiveID != stop.DirectiveID {
		t.Fatalf("expected a stop attributed to the directive: %s %+v", r.Status, r.Stop)
	}
	if len(r.Attempts) != 1 || r.Attempts[0].EndReason != "cancelled" {
		t.Fatalf("one attempt, ended by cancellation: %+v", r.Attempts)
	}
	if inv := invocations(t, log); len(inv) != 1 {
		t.Fatalf("stop must not start another attempt: %v", inv)
	}
	if !has(r.Directives.Applied, stop.DirectiveID) {
		t.Fatal("the stop is applied once the process has ended")
	}
}
