package tool

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"

	"cli.321.do/internal/protocol"
)

// DP binds the deployment engine's explicit entry point
// (deploy.321.do's bin/dp) as a tool. The engine keeps every
// deployment mechanic; this binding only decides which of its
// subcommands a procedure may reach, with which arguments, and under
// which capability.
//
// Operations in this build:
//
//	status   deploy.read     `status [service] [target] --json`
//	plan     deploy.plan     `plan <service> <target> [--revision <sha>] --json`
//	execute  deploy.invoke   NOT PERFORMED: reported as unavailable, nothing runs
//
// The binding is an explicit path (DP_BIN), never a command
// name looked up on PATH: the name `321` is ambiguous on this estate.
type DP struct {
	// Bin is the executable. Empty means the tool is not bound.
	Bin string
	// Timeout bounds one call; zero means DefaultTimeout.
	Timeout time.Duration
	// MaxOutput caps captured output in bytes; zero means DefaultMaxOutput.
	MaxOutput int
	// Env replaces the process environment when non-nil (tests).
	Env []string
	// Exec performs an approved deployment. Nil, as in every production
	// binding of this build, means execute is reported unavailable.
	Exec Executor
}

// Executor exposes the configured executor, if any.
func (d *DP) Executor() Executor { return d.Exec }

const (
	DefaultTimeout   = 2 * time.Minute
	DefaultMaxOutput = 256 * 1024
	// ExecutionUnavailable is the message every execute call returns in
	// this build. It names the fact, not a promise.
	ExecutionUnavailable = "execution is unavailable in this development slice: the proposal was prepared and nothing was deployed"
)

var (
	serviceRe  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$`)
	targetRe   = regexp.MustCompile(`^[a-z][a-z0-9-]{0,15}$`)
	revisionRe = regexp.MustCompile(`^[0-9a-f]{7,40}$`)
)

func (d *DP) Name() string { return "dp" }

func (d *DP) Ops() []Op {
	return []Op{
		{Name: "status", Capability: protocol.CapDeployRead},
		{Name: "plan", Capability: protocol.CapDeployPlan},
		{Name: "execute", Capability: protocol.CapDeployInvoke, Mutates: true, Unavailable: d.executeUnavailable()},
	}
}

func (d *DP) executeUnavailable() string {
	if d.Exec == nil {
		return ExecutionUnavailable
	}
	return ""
}

// Bound reports whether an executable is configured.
func (d *DP) Bound() bool { return d.Bin != "" }

// Argv builds the argument vector for an operation, refusing anything
// that is not a validated parameter. Exported so the surface is testable
// without a process. Every value is checked against a strict pattern, so
// no value can begin with "-" or carry a shell metacharacter; the vector
// is passed to exec directly, never to a shell.
func (d *DP) Argv(op string, params map[string]string) ([]string, error) {
	for k := range params {
		switch k {
		case "service", "target", "revision":
		default:
			return nil, fmt.Errorf("dp: unsupported parameter %q", k)
		}
	}
	service, target, revision := params["service"], params["target"], params["revision"]
	if service != "" && !serviceRe.MatchString(service) {
		return nil, fmt.Errorf("dp: service %q is not a group.name service name", service)
	}
	if target != "" && !targetRe.MatchString(target) {
		return nil, fmt.Errorf("dp: target %q is not a target name", target)
	}
	if revision != "" && !revisionRe.MatchString(revision) {
		return nil, fmt.Errorf("dp: revision %q is not a commit sha", revision)
	}
	switch op {
	case "status":
		argv := []string{"status"}
		if service != "" {
			argv = append(argv, service)
		}
		if target != "" {
			argv = append(argv, target)
		}
		if revision != "" {
			return nil, errors.New("dp: status takes no revision")
		}
		return append(argv, "--json"), nil
	case "plan", "execute":
		// The engine itself asks when a service or target is missing; the
		// vector carries exactly what was given, in positional order.
		argv := []string{"plan"}
		if service != "" {
			argv = append(argv, service)
		}
		if target != "" {
			if service == "" {
				// A lone target would be read as a service name by the
				// engine; make the ambiguity explicit instead.
				argv = append(argv, "", target)
			} else {
				argv = append(argv, target)
			}
		}
		if revision != "" {
			argv = append(argv, "--revision", revision)
		}
		return append(argv, "--json"), nil
	}
	return nil, fmt.Errorf("dp: unsupported operation %q", op)
}

func (d *DP) Run(ctx context.Context, op string, params map[string]string) (Result, error) {
	if _, ok := OpOf(d, op); !ok {
		return Result{}, fmt.Errorf("dp: unsupported operation %q", op)
	}
	argv, err := d.Argv(op, params)
	if err != nil {
		return Result{}, err
	}
	if o, _ := OpOf(d, op); o.Unavailable != "" {
		// The boundary exists so a caller cannot smuggle execution through
		// planning parameters; it is not enabled. Nothing is run.
		return Result{Ok: false, ExitCode: -1, Unavailable: o.Unavailable, Argv: nil}, nil
	}
	if !d.Bound() {
		return Result{}, errors.New("dp: not configured (set DP_BIN to the engine's explicit entry point)")
	}
	timeout := d.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	maxOut := d.MaxOutput
	if maxOut <= 0 {
		maxOut = DefaultMaxOutput
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	start := time.Now()
	cmd := exec.CommandContext(runCtx, d.Bin, argv...)
	if d.Env != nil {
		cmd.Env = d.Env
	} else {
		cmd.Env = os.Environ()
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &limited{w: &stdout, max: maxOut}
	cmd.Stderr = &limited{w: &stderr, max: 16 * 1024}
	runErr := cmd.Run()
	res := Result{Argv: argv, Duration: time.Since(start)}
	if cmd.ProcessState != nil {
		res.ExitCode = cmd.ProcessState.ExitCode()
	} else {
		res.ExitCode = -1
	}
	if runCtx.Err() == context.DeadlineExceeded {
		res.Output = Redact(fmt.Sprintf("dp: no answer within %s\n%s", timeout, stderr.String()))
		return res, nil
	}
	if runErr != nil && cmd.ProcessState == nil {
		return Result{}, fmt.Errorf("dp: process did not start: %v", runErr)
	}
	raw := stdout.Bytes()
	res.Truncated = stdout.Len() >= maxOut
	res.Ok = res.ExitCode == 0
	if doc, ok := parseDoc(raw); ok && !res.Truncated {
		res.Data = RedactMap(doc)
		b, _ := json.Marshal(res.Data)
		res.Output = string(b)
	} else {
		res.Output = Redact(strings.TrimSpace(stdout.String() + "\n" + stderr.String()))
	}
	return res, nil
}

// parseDoc reads one JSON object from the output.
func parseDoc(raw []byte) (map[string]any, bool) {
	dec := json.NewDecoder(bytes.NewReader(bytes.TrimSpace(raw)))
	dec.UseNumber()
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil || doc == nil {
		return nil, false
	}
	return normalise(doc).(map[string]any), true
}

// normalise turns json.Number into float64 or int64-valued float so the
// canonical form is stable across languages.
func normalise(v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			x[k] = normalise(val)
		}
		return x
	case []any:
		for i, val := range x {
			x[i] = normalise(val)
		}
		return x
	case json.Number:
		if f, err := x.Float64(); err == nil {
			return f
		}
		return x.String()
	}
	return v
}

// limited writes at most max bytes and drops the rest.
type limited struct {
	w   *bytes.Buffer
	max int
}

func (l *limited) Write(p []byte) (int, error) {
	room := l.max - l.w.Len()
	if room > 0 {
		if len(p) > room {
			l.w.Write(p[:room])
		} else {
			l.w.Write(p)
		}
	}
	return len(p), nil
}

// Summarise renders a compact human line from a status or plan document.
func Summarise(op string, data map[string]any) string {
	if data == nil {
		return ""
	}
	switch op {
	case "status":
		services, _ := data["services"].([]any)
		var parts []string
		for _, s := range services {
			m, _ := s.(map[string]any)
			name, _ := m["name"].(string)
			ubic, _ := m["ubic"].(string)
			state := "not running"
			if r, _ := m["running"].(bool); r {
				state = "running"
			}
			parts = append(parts, fmt.Sprintf("%s %s (%s)", name, state, ubic))
		}
		sort.Strings(parts)
		if len(parts) == 0 {
			return "no services matched"
		}
		return fmt.Sprintf("%d service(s): %s", len(parts), strings.Join(parts, "; "))
	case "plan":
		status, _ := data["status"].(string)
		if status != "planned" {
			q, _ := data["question"].(string)
			return "plan blocked: " + q
		}
		svc, _ := data["service"].(map[string]any)
		rev, _ := data["revision"].(map[string]any)
		name, _ := svc["name"].(string)
		target, _ := svc["target"].(string)
		sha, _ := rev["sha"].(string)
		unperformed, _ := data["unperformed"].([]any)
		return fmt.Sprintf("planned: deploy %s to %s at %s; %d check(s) not run", name, target, short(sha), len(unperformed))
	}
	return ""
}

func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}

// EngineExecutor performs an approved deployment by calling the engine's
// own `go <service> <target>` through the same explicit entry point. It is
// bound only when DP_EXECUTE names the targets it may act on;
// a target not named is refused before anything runs. The engine keeps
// every deployment mechanic; this only invokes it and reports its words.
type EngineExecutor struct {
	Bin            string
	AllowedTargets []string
	Timeout        time.Duration
	Env            []string
}

func (e *EngineExecutor) Name() string { return "dp go" }

// Allowed says whether execution may reach target at all.
func (e *EngineExecutor) Allowed(target string) bool {
	for _, t := range e.AllowedTargets {
		if t == target {
			return true
		}
	}
	return false
}

func (e *EngineExecutor) Execute(p *protocol.DeploymentProposal, a *protocol.Approval) (string, error) {
	if !e.Allowed(p.Target) {
		return "", fmt.Errorf("execution on target %q is not enabled here (DP_EXECUTE lists: %s)", p.Target, strings.Join(e.AllowedTargets, ", "))
	}
	if !serviceRe.MatchString(p.Service) || !targetRe.MatchString(p.Target) {
		return "", fmt.Errorf("the approved proposal names an invalid service or target")
	}
	if e.Bin == "" {
		return "", errors.New("no engine executable is configured")
	}
	timeout := e.Timeout
	if timeout <= 0 {
		timeout = 15 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	argv := []string{"go", p.Service, p.Target}
	cmd := exec.CommandContext(ctx, e.Bin, argv...)
	if e.Env != nil {
		cmd.Env = e.Env
	} else {
		cmd.Env = os.Environ()
	}
	var out bytes.Buffer
	cmd.Stdout = &limited{w: &out, max: 64 * 1024}
	cmd.Stderr = cmd.Stdout
	err := cmd.Run()
	text := Redact(strings.TrimSpace(out.String()))
	tail := text
	if len(tail) > 2000 {
		tail = "…" + tail[len(tail)-2000:]
	}
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("engine go did not finish within %s: %s", timeout, tail)
	}
	if err != nil {
		return "", fmt.Errorf("engine go failed: %v: %s", err, tail)
	}
	// The engine's go reports a failed gate, an aborted deploy or a
	// rollback in words and exits 0; read them rather than the exit code.
	lower := strings.ToLower(text)
	for _, bad := range []string{"deploy aborted", "rolled back", "[fail]", "did not recover", "can't reach"} {
		if strings.Contains(lower, bad) {
			return "", fmt.Errorf("engine go did not succeed: %s", tail)
		}
	}
	return "engine go " + p.Service + " " + p.Target + " completed: " + tail, nil
}
