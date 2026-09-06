package cli

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/run"
	"cli.321.do/internal/trust"
	"cli.321.do/internal/wire"
)

// cmdAgent is `321 <agent> <request…>`: build a WorkPackage under local
// policy and run it through exactly the path a delegated package takes.
//
// Nothing here is a blanket approval. The effective grants are the
// package's required capabilities plus any --grant the person named,
// bounded by local policy. An action that needs an exact approval stays
// blocked: a standalone request carries no approval at all.
func cmdAgent(env Env, g global, name string, words []string) int {
	request := strings.TrimSpace(strings.Join(words, " "))
	if request == "" {
		fmt.Fprintf(env.Stderr, "321: what should %s do? Give the request after the agent name.\n", name)
		return wire.ExitUsage
	}
	cfg, err := env.trust()
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitInternal
	}
	var agent *trust.Loaded
	if g.packageDir != "" {
		agent, err = trust.LoadPath(g.packageDir)
		if err == nil && agent.ID() != name && agent.Manifest.Name != name {
			err = fmt.Errorf("the package at %s is %s, not %s", g.packageDir, agent.ID(), name)
		}
	} else {
		var res *trust.Resolution
		res, err = cfg.Resolve(name)
		if err == nil {
			agent, err = trust.LoadResolved(res)
		}
	}
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitDenied
	}

	workspace, kind := resolveWorkspace(g.workspace)
	if !touchesWorkspace(agent.Manifest) {
		// A package that can never read or write files gets no workspace:
		// whatever repository the terminal happens to be in is not
		// evidence of anything the run did.
		workspace, kind = "", "none"
	}
	wp, err := buildPackage(cfg, agent, g, request, workspace, kind)
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitUsage
	}

	// The CLI invocation is itself the human approval: for an interactive
	// operator `go`, plan first and attach an approval bound to that plan
	// so the go can execute (still only where DEPLOY_ENGINE_EXECUTE allows).
	if note := assumeOperatorApproval(env, g, cfg, agent, wp, request); note != "" {
		fmt.Fprintln(env.Stderr, "321:", note)
	}

	home, err := env.home()
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitInternal
	}
	runDir := filepath.Join(home, "runs", wp.PackageID)
	if err := os.MkdirAll(runDir, 0o700); err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitInternal
	}
	rawPackage, _ := json.Marshal(wp)
	_ = os.WriteFile(filepath.Join(runDir, "work-package.json"), append(rawPackage, '\n'), 0o600)

	fmt.Fprintf(env.Stderr, "321: %s (%s)\n", agent.Manifest.DisplayName, agent.Label)
	for _, w := range agent.Warnings {
		fmt.Fprintln(env.Stderr, "321: note:", w)
	}
	if kind == "git" {
		fmt.Fprintf(env.Stderr, "321: workspace %s (you commit; the agent only edits)\n", workspace)
	}
	fmt.Fprintf(env.Stderr, "321: grants %s\n", strings.Join(wp.Capabilities.Granted, ", "))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	directives := make(chan protocol.WorkDirective, 64)
	if env.Interactive && !g.nonInteractive {
		fmt.Fprintln(env.Stderr, "321: type to steer, /pause, /resume, /stop; Ctrl-C stops")
		go readSteering(ctx, env.Stdin, directives, wp.PackageID)
	}
	if env.Signals {
		go func() {
			sig := make(chan os.Signal, 1)
			signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
			defer signal.Stop(sig)
			select {
			case s := <-sig:
				directives <- localDirective(wp.PackageID, 1<<30, protocol.DirectiveStop, "", "signal "+s.String(), "signal")
			case <-ctx.Done():
			}
		}()
	}

	var sink run.Sink
	if g.jsonOut {
		enc := json.NewEncoder(env.Stdout)
		enc.SetEscapeHTML(false)
		sink = run.SinkFunc(func(e protocol.RunEvent) { _ = enc.Encode(e) })
	} else {
		sink = run.SinkFunc(func(e protocol.RunEvent) { renderEvent(env.Stdout, e) })
	}
	receipt := env.runner().Run(ctx, wp, agent, run.Options{
		Directives: directives,
		Sink:       sink,
		HistoryDir: runDir,
		Policy:     cfg.Policy,
		Adapter:    g.adapter,
		PackageRaw: rawPackage,
	})
	cancel()
	if b, err := json.MarshalIndent(receipt, "", "  "); err == nil {
		_ = os.WriteFile(filepath.Join(runDir, "receipt.json"), append(b, '\n'), 0o600)
	}
	if receipt.Evidence.Proposal != nil {
		if b, err := json.MarshalIndent(receipt.Evidence.Proposal, "", "  "); err == nil {
			_ = os.WriteFile(filepath.Join(runDir, "proposal.json"), append(b, '\n'), 0o600)
		}
	}
	if g.jsonOut {
		enc := json.NewEncoder(env.Stdout)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(receipt)
	} else {
		renderReceipt(env.Stdout, receipt, runDir)
	}
	return wire.ExitFor(receipt.Status)
}

// touchesWorkspace says whether a package could read or write files at
// all: only then does the enclosing repository become its workspace.
func touchesWorkspace(m *protocol.AgentManifest) bool {
	for _, c := range append(append([]string{}, m.Capabilities.Required...), m.Capabilities.Optional...) {
		switch c {
		case protocol.CapRepoRead, protocol.CapRepoWrite, protocol.CapFilesRead, protocol.CapFilesWrite, protocol.CapShellRun:
			return true
		}
	}
	return false
}

// resolveWorkspace picks the git repository enclosing dir, or none.
func resolveWorkspace(flag string) (string, string) {
	dir := flag
	if dir == "" {
		dir, _ = os.Getwd()
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", "none"
	}
	for p := abs; ; p = filepath.Dir(p) {
		if info, err := os.Stat(filepath.Join(p, ".git")); err == nil && (info.IsDir() || info.Mode().IsRegular()) {
			return p, "git"
		}
		if p == filepath.Dir(p) {
			break
		}
	}
	if flag != "" {
		return abs, "none"
	}
	return "", "none"
}

// buildPackage assembles a standalone WorkPackage. Grants are the package's
// required set plus explicitly requested optional ones, all inside the
// policy ceiling; anything outside is refused up front with the reason.
func buildPackage(cfg *trust.Config, agent *trust.Loaded, g global, request, workspace, kind string) (*protocol.WorkPackage, error) {
	m := agent.Manifest
	optional := map[string]bool{}
	for _, c := range m.Capabilities.Optional {
		optional[c] = true
	}
	grants := append([]string{}, m.Capabilities.Required...)
	for _, c := range g.grant {
		if !optional[c] {
			return nil, fmt.Errorf("--grant %s: the package does not list it as optional (required: %s; optional: %s)", c, strings.Join(m.Capabilities.Required, ", "), strings.Join(m.Capabilities.Optional, ", "))
		}
		grants = append(grants, c)
	}
	if ceiling := cfg.Policy.CapabilityCeiling; ceiling != nil {
		allowed := map[string]bool{}
		for _, c := range ceiling {
			allowed[c] = true
		}
		for _, c := range grants {
			if !allowed[c] {
				return nil, fmt.Errorf("local policy does not allow %s (policy.capabilityCeiling in %s)", c, cfg.Path())
			}
		}
	}
	placement := g.placement
	if placement == "" {
		placement = protocol.PlacementClient
	}
	limits := cfg.Policy.Limits
	// Network authority is separate and explicit: shell.run does not imply
	// it. The person states it with --network, or local policy does;
	// otherwise the default provider_only stands and an adapter that cannot
	// deny the network to a granted shell is refused.
	if g.network != "" {
		switch g.network {
		case protocol.NetworkNone, protocol.NetworkProviderOnly, protocol.NetworkOpen:
			limits.Network = g.network
		default:
			return nil, fmt.Errorf("--network must be none, provider_only or open")
		}
	}
	user := os.Getenv("USER")
	host, _ := os.Hostname()
	wp := &protocol.WorkPackage{
		Schema:       protocol.SchemaWorkPackage,
		PackageID:    protocol.NewULID(),
		Issuer:       protocol.Issuer{Kind: "local", ID: user + "@" + host},
		IssuedAt:     protocol.Now(),
		Agent:        protocol.AgentRef{ID: agent.ID(), Version: m.Version, Digest: agent.Digest},
		Placement:    placement,
		Workspace:    protocol.Workspace{Kind: kind, Path: workspace, Ownership: "caller"},
		Objective:    request,
		Completion:   protocol.Completion{Conditions: append([]string{}, g.done...)},
		Capabilities: protocol.Grants{Granted: grants, Limits: limits},
	}
	for _, a := range g.attach {
		abs, err := filepath.Abs(a)
		if err != nil {
			return nil, err
		}
		b, err := os.ReadFile(abs)
		if err != nil {
			return nil, fmt.Errorf("--attach %s: %v", a, err)
		}
		sum := sha256.Sum256(b)
		wp.Context.Attachments = append(wp.Context.Attachments, protocol.Attachment{
			Name: filepath.Base(abs), SHA256: hex.EncodeToString(sum[:]), URI: "file://" + filepath.ToSlash(abs),
		})
	}
	if ps := protocol.ValidateWorkPackage(wp); len(ps) > 0 {
		return nil, ps
	}
	return wp, nil
}

// readSteering turns terminal lines into local directives.
func readSteering(ctx context.Context, in io.Reader, ch chan<- protocol.WorkDirective, packageID string) {
	sc := bufio.NewScanner(in)
	seq := 0
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		seq++
		var d protocol.WorkDirective
		switch line {
		case "/pause":
			d = localDirective(packageID, seq, protocol.DirectivePause, "", "", "terminal")
		case "/resume":
			d = localDirective(packageID, seq, protocol.DirectiveResume, "", "", "terminal")
		case "/stop":
			d = localDirective(packageID, seq, protocol.DirectiveStop, "", "stopped at the terminal", "terminal")
		default:
			d = localDirective(packageID, seq, protocol.DirectiveSteer, line, "", "terminal")
		}
		select {
		case ch <- d:
		case <-ctx.Done():
			return
		}
	}
}

func localDirective(packageID string, seq int, kind, text, reason, issuer string) protocol.WorkDirective {
	user := os.Getenv("USER")
	d := protocol.WorkDirective{
		Schema:      protocol.SchemaWorkDirective,
		DirectiveID: "local-" + protocol.NewULID(),
		PackageID:   packageID,
		Seq:         seq,
		Issuer:      protocol.Issuer{Kind: "local", ID: user + "/" + issuer},
		IssuedAt:    protocol.Now(),
		Kind:        kind,
		Payload:     protocol.DirectivePayload{Text: text, Reason: reason},
	}
	d.Digest, _ = protocol.DirectiveDigest(d)
	return d
}

func renderEvent(w io.Writer, e protocol.RunEvent) {
	switch e.Kind {
	case protocol.EventProgress:
		if t, ok := e.Payload["text"].(string); ok && t != "" {
			fmt.Fprintln(w, t)
		} else if t, ok := e.Payload["instruction"].(string); ok {
			fmt.Fprintln(w, "  » instruction applied:", t)
		}
	case protocol.EventToolCall:
		if op, ok := e.Payload["op"]; ok {
			fmt.Fprintf(w, "  · tool %v %v %v\n", e.Payload["tool"], op, e.Payload["params"])
		} else {
			fmt.Fprintf(w, "  · %v %v\n", e.Payload["tool"], e.Payload["target"])
		}
	case protocol.EventToolResult:
		if op, ok := e.Payload["op"]; ok {
			fmt.Fprintf(w, "  · tool %v %v: ok=%v exit=%v\n", e.Payload["tool"], op, e.Payload["ok"], e.Payload["exitCode"])
		}
	case protocol.EventAdapterSelected:
		fmt.Fprintf(w, "  · adapter %v\n", e.Payload["adapter"])
	case protocol.EventProcedureSelected:
		fmt.Fprintf(w, "  · procedure %v (no model)\n", e.Payload["procedure"])
	case protocol.EventAttemptStarted:
		if n, _ := e.Payload["attempt"].(int); n > 1 {
			fmt.Fprintf(w, "  · attempt %d\n", n)
		}
	case protocol.EventDirectiveApplied:
		fmt.Fprintf(w, "  · applied %v\n", e.Payload["directiveId"])
	case protocol.EventDirectiveRejected:
		fmt.Fprintf(w, "  · could not apply %v: %v\n", e.Payload["directiveId"], e.Payload["reason"])
	case protocol.EventPaused:
		fmt.Fprintln(w, "  · paused")
	case protocol.EventResumed:
		fmt.Fprintln(w, "  · resumed")
	case protocol.EventStopping:
		fmt.Fprintln(w, "  · stopping")
	case protocol.EventDenied:
		fmt.Fprintf(w, "  · denied: %v\n", e.Payload["reason"])
		if d, ok := e.Payload["details"].([]string); ok {
			for _, x := range d {
				fmt.Fprintln(w, "    -", x)
			}
		}
	}
}

func renderReceipt(w io.Writer, r *protocol.RunReceipt, runDir string) {
	fmt.Fprintln(w)
	fmt.Fprintf(w, "%s: %s\n", strings.ToUpper(r.Status), r.Summary)
	if r.Status == protocol.StatusFailed || r.Status == protocol.StatusDenied {
		for _, e := range r.Evidence.Errors {
			fmt.Fprintf(w, "  ! %s\n", e)
		}
		if r.Denied != nil {
			fmt.Fprintf(w, "  ! %s\n", r.Denied.Reason)
			for _, d := range r.Denied.Details {
				fmt.Fprintf(w, "    %s\n", d)
			}
		}
	}
	if r.BlockedOn != "" {
		fmt.Fprintf(w, "Needs an answer: %s\n", r.BlockedOn)
	}
	for i, c := range r.Conditions {
		mark := "✗"
		if c.Met {
			mark = "✓"
		}
		fmt.Fprintf(w, "  %s %d. %s\n", mark, i+1, c.Proof)
	}
	if len(r.Evidence.FilesChanged) > 0 {
		fmt.Fprintf(w, "Changed: %s\n", strings.Join(r.Evidence.FilesChanged, ", "))
	}
	for _, c := range r.Evidence.ToolCalls {
		state := "ok"
		switch {
		case c.Unavailable != "":
			state = "not performed"
		case !c.Ok:
			state = fmt.Sprintf("exit %d", c.ExitCode)
		}
		fmt.Fprintf(w, "Tool: %s %s %s (%s)\n", c.Tool, c.Op, strings.Join(c.Argv, " "), state)
	}
	if p := r.Evidence.Proposal; p != nil {
		fmt.Fprintf(w, "Proposal: %s %s (%s) %s\n", p.ProposalID, p.Status, p.Operation, p.ProposalDigest)
		if p.Status == "planned" {
			sha, _ := p.Revision["sha"].(string)
			fmt.Fprintf(w, "  %s -> %s at %s; not run: %s\n", p.Service, p.Target, sha, strings.Join(p.Unperformed, ", "))
		}
		note := "it is a plan, not an approval, and nothing was deployed"
		if r.Evidence.ExternalAction != nil {
			note = "the plan that was approved and executed (see the receipt's externalAction)"
		}
		fmt.Fprintf(w, "  written to %s; %s\n", filepath.Join(runDir, "proposal.json"), note)
	}
	switch r.Cost.Basis {
	case protocol.CostNone:
		fmt.Fprintf(w, "Cost: none (no model was used)\n")
	case protocol.CostHarness:
		fmt.Fprintf(w, "Cost: $%.2f, %d turns, %d attempt(s), as the harness reported\n", r.Cost.USD, r.Cost.Turns, len(r.Attempts))
	case protocol.CostUnreported:
		fmt.Fprintf(w, "Cost: unknown (a harness ran and reported none), %d attempt(s)\n", len(r.Attempts))
	default:
		fmt.Fprintf(w, "Cost: $%.2f, %d turns, %d attempt(s) (%s)\n", r.Cost.USD, r.Cost.Turns, len(r.Attempts), r.Cost.Basis)
	}
	fmt.Fprintf(w, "Receipt: %s\n", filepath.Join(runDir, "receipt.json"))
}
