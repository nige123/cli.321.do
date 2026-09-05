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

// DeployEngine binds the deployment engine's explicit entry point
// (web.321.do's bin/deploy-engine) as a tool. The engine keeps every
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
// The binding is an explicit path (DEPLOY_ENGINE_BIN), never a command
// name looked up on PATH: the name `321` is ambiguous on this estate.
type DeployEngine struct {
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
func (d *DeployEngine) Executor() Executor { return d.Exec }

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

func (d *DeployEngine) Name() string { return "deploy_engine" }

func (d *DeployEngine) Ops() []Op {
	return []Op{
		{Name: "status", Capability: protocol.CapDeployRead},
		{Name: "plan", Capability: protocol.CapDeployPlan},
		{Name: "execute", Capability: protocol.CapDeployInvoke, Mutates: true, Unavailable: d.executeUnavailable()},
	}
}

func (d *DeployEngine) executeUnavailable() string {
	if d.Exec == nil {
		return ExecutionUnavailable
	}
	return ""
}

// Bound reports whether an executable is configured.
func (d *DeployEngine) Bound() bool { return d.Bin != "" }

// Argv builds the argument vector for an operation, refusing anything
// that is not a validated parameter. Exported so the surface is testable
// without a process. Every value is checked against a strict pattern, so
// no value can begin with "-" or carry a shell metacharacter; the vector
// is passed to exec directly, never to a shell.
func (d *DeployEngine) Argv(op string, params map[string]string) ([]string, error) {
	for k := range params {
		switch k {
		case "service", "target", "revision":
		default:
			return nil, fmt.Errorf("deploy_engine: unsupported parameter %q", k)
		}
	}
	service, target, revision := params["service"], params["target"], params["revision"]
	if service != "" && !serviceRe.MatchString(service) {
		return nil, fmt.Errorf("deploy_engine: service %q is not a group.name service name", service)
	}
	if target != "" && !targetRe.MatchString(target) {
		return nil, fmt.Errorf("deploy_engine: target %q is not a target name", target)
	}
	if revision != "" && !revisionRe.MatchString(revision) {
		return nil, fmt.Errorf("deploy_engine: revision %q is not a commit sha", revision)
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
			return nil, errors.New("deploy_engine: status takes no revision")
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
	return nil, fmt.Errorf("deploy_engine: unsupported operation %q", op)
}

func (d *DeployEngine) Run(ctx context.Context, op string, params map[string]string) (Result, error) {
	if _, ok := OpOf(d, op); !ok {
		return Result{}, fmt.Errorf("deploy_engine: unsupported operation %q", op)
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
		return Result{}, errors.New("deploy_engine: not configured (set DEPLOY_ENGINE_BIN to the engine's explicit entry point)")
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
		res.Output = Redact(fmt.Sprintf("deploy_engine: no answer within %s\n%s", timeout, stderr.String()))
		return res, nil
	}
	if runErr != nil && cmd.ProcessState == nil {
		return Result{}, fmt.Errorf("deploy_engine: process did not start: %v", runErr)
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
