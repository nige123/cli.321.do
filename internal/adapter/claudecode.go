package adapter

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"cli.321.do/internal/protocol"
)

// ClaudeCode drives the `claude` CLI in non-interactive print mode. It is
// the adapter extracted from tui.123.do's backend_claude_code.go, with the
// tool surface derived from the grants instead of hard-coded, and with an
// honest enforcement report.
//
// What it enforces and how:
//
//	tool_allowlist     --permission-mode dontAsk --allowedTools <mapped grants>
//	structured_output  --json-schema; the result carries structured_output
//	turn_limit         --max-turns
//	spend_limit        --max-budget-usd
//	timeout            the runner's context deadline plus SIGTERM
//	event_stream       --output-format stream-json is read line by line
//	session_continue   --resume <session id> on a later attempt
//	graceful_stop      SIGTERM, then SIGKILL after a wait
//
// What it does not enforce, and says so:
//
//	repo_scope   a granted Bash can write anywhere the user can
//	network_deny a granted Bash can reach the network; WebFetch is only
//	             absent from the allowlist, and the harness itself always
//	             reaches its model provider
//	live_steer   print mode takes no input after the prompt
//	pause        the process cannot be suspended safely; the runner ends
//	             the attempt and resumes the session instead
type ClaudeCode struct {
	Binary     string        // "" means "claude"; the CLI sets it from X321_CLAUDE_BINARY
	KillWait   time.Duration // grace after SIGTERM; default 15s
	Stderr     io.Writer     // where the harness's stderr is teed; nil discards
	Transcript io.Writer     // readable transcript of the stream; nil discards
}

// ClaudeCodeTools maps neutral grants onto Claude Code tool names. It is
// the whole policy: under dontAsk anything not listed is denied.
var ClaudeCodeTools = map[string][]string{
	protocol.CapRepoRead:   {"Read", "Glob", "Grep"},
	protocol.CapFilesRead:  {"Read", "Glob", "Grep"},
	protocol.CapRepoWrite:  {"Edit", "Write"},
	protocol.CapFilesWrite: {"Edit", "Write"},
	protocol.CapShellRun:   {"Bash"},
	protocol.CapNetFetch:   {"WebFetch", "WebSearch"},
}

func (c *ClaudeCode) Name() string { return "claude_code" }

func (c *ClaudeCode) binary() string {
	if c.Binary != "" {
		return c.Binary
	}
	return "claude"
}

func (c *ClaudeCode) Detect() Detection {
	path, err := exec.LookPath(c.binary())
	if err != nil {
		return Detection{Reason: c.binary() + " is not on PATH"}
	}
	out, err := exec.Command(path, "--version").Output()
	if err != nil {
		return Detection{Available: true, Version: "unknown"}
	}
	return Detection{Available: true, Version: strings.TrimSpace(string(out))}
}

func (c *ClaudeCode) Enforcement() Enforcement {
	return Enforcement{
		protocol.FeatToolAllowlist:    true,
		protocol.FeatStructuredOutput: true,
		protocol.FeatTurnLimit:        true,
		protocol.FeatSpendLimit:       true,
		protocol.FeatTimeout:          true,
		protocol.FeatEventStream:      true,
		protocol.FeatSessionContinue:  true,
		protocol.FeatGracefulStop:     true,
		protocol.FeatRepoScope:        false,
		protocol.FeatNetworkDeny:      false,
		protocol.FeatLiveSteer:        false,
		protocol.FeatPause:            false,
	}
}

// overlay is the optional per-package tuning file for this adapter.
type overlay struct {
	Model string `json:"model,omitempty"`
}

// Args is the whole invocation, exported so the surface is testable
// without a process.
func (c *ClaudeCode) Args(spec Spec) []string {
	tools := ToolNames(spec.Grants, ClaudeCodeTools)
	tools = append(tools, "TodoWrite")
	args := []string{
		"-p", spec.Prompt,
		"--output-format", "stream-json", "--verbose",
		"--permission-mode", "dontAsk",
		"--allowedTools", strings.Join(tools, ","),
	}
	if len(spec.OutputSchema) > 0 {
		args = append(args, "--json-schema", string(spec.OutputSchema))
	}
	if spec.Limits.MaxTurns > 0 {
		args = append(args, "--max-turns", strconv.Itoa(spec.Limits.MaxTurns))
	}
	if spec.Limits.MaxUSD > 0 {
		args = append(args, "--max-budget-usd", strconv.FormatFloat(spec.Limits.MaxUSD, 'f', 2, 64))
	}
	if spec.SessionRef != "" {
		args = append(args, "--resume", spec.SessionRef)
	}
	if len(spec.Overlay) > 0 {
		var o overlay
		if json.Unmarshal(spec.Overlay, &o) == nil && o.Model != "" {
			args = append(args, "--model", o.Model)
		}
	}
	return args
}

func (c *ClaudeCode) Run(ctx context.Context, spec Spec, ctl Control) (Outcome, error) {
	start := time.Now()
	cmd := exec.CommandContext(ctx, c.binary(), c.Args(spec)...)
	if spec.Workspace != "" {
		cmd.Dir = spec.Workspace
	}
	cmd.Env = os.Environ()
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = c.KillWait
	if cmd.WaitDelay == 0 {
		cmd.WaitDelay = 15 * time.Second
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return Outcome{}, fmt.Errorf("claude_code: %v", err)
	}
	var errBuf bytes.Buffer
	if c.Stderr != nil {
		cmd.Stderr = io.MultiWriter(&errBuf, c.Stderr)
	} else {
		cmd.Stderr = &errBuf
	}
	if err := cmd.Start(); err != nil {
		return Outcome{}, fmt.Errorf("claude_code: process did not start: %v", err)
	}
	transcript := c.Transcript
	if transcript == nil {
		transcript = io.Discard
	}
	env, session := consumeStream(stdout, transcript, ctl)
	runErr := cmd.Wait()
	if cmd.ProcessState == nil {
		return Outcome{}, fmt.Errorf("claude_code: no exit status: %v", runErr)
	}
	out := Outcome{Cost: protocol.Cost{}, SessionRef: session}
	if env != nil {
		out.Summary = env.Summary
		if env.SessionRef != "" {
			out.SessionRef = env.SessionRef
		}
		out.Cost = protocol.Cost{USD: env.CostUSD, Turns: env.Turns}
		out.Denials = env.Denials
		out.Errors = env.Errors
		out.Conditions = env.Conditions
		out.BlockedOn = env.BlockedOn
	}
	exit := cmd.ProcessState.ExitCode()
	switch {
	case ctx.Err() != nil:
		out.Status = protocol.StatusStopped
		out.EndReason = "cancelled"
		if out.Summary == "" {
			out.Summary = "stopped before the harness finished"
		}
	case runErr != nil && env == nil:
		out.Status = protocol.StatusFailed
		out.EndReason = "process_failed"
		out.Errors = append(out.Errors, fmt.Sprintf("exit %d: %s", exit, capTail(errBuf.String(), 2048)))
	case exit != 0 && env == nil:
		out.Status = protocol.StatusFailed
		out.EndReason = "process_failed"
		out.Errors = append(out.Errors, fmt.Sprintf("exit %d: %s", exit, capTail(errBuf.String(), 2048)))
	case env != nil && env.Blocked:
		out.Status = protocol.StatusBlocked
		out.EndReason = "blocked"
	case env != nil && env.IsError:
		out.Status = protocol.StatusFailed
		out.EndReason = "harness_error"
		if len(out.Errors) == 0 && env.TerminalReason != "" {
			out.Errors = append(out.Errors, "the harness stopped: "+env.TerminalReason)
		}
	case env != nil && env.NoChange:
		out.Status = protocol.StatusNoChange
		out.EndReason = "no_change"
	case env == nil:
		out.Status = protocol.StatusFailed
		out.EndReason = "no_result"
		out.Errors = append(out.Errors, "the harness exited without a result object")
	default:
		out.Status = protocol.StatusCompleted
		out.EndReason = "completed"
	}
	ctl.Emit(protocol.EventCost, map[string]any{"usd": out.Cost.USD, "turns": out.Cost.Turns, "durationMs": time.Since(start).Milliseconds()})
	return out, nil
}

// envelope mirrors the result object the harness prints last. Only the
// fields the runtime reads are listed.
type envelope struct {
	Type           string            `json:"type"`
	IsError        bool              `json:"is_error"`
	Result         string            `json:"result"`
	StopReason     string            `json:"stop_reason"`
	TerminalReason string            `json:"terminal_reason"`
	SessionID      string            `json:"session_id"`
	TotalCostUSD   float64           `json:"total_cost_usd"`
	NumTurns       int               `json:"num_turns"`
	Denials        []json.RawMessage `json:"permission_denials"`
	Structured     *structured       `json:"structured_output"`
	Errors         []string          `json:"errors"`
}

type structured struct {
	Status     string `json:"status"`
	Summary    string `json:"summary"`
	BlockedOn  string `json:"blocked_on"`
	Conditions []struct {
		Met   bool   `json:"met"`
		Proof string `json:"proof"`
	} `json:"conditions"`
}

// Summary is the harness's own account of a run.
type Summary struct {
	Summary        string
	StopReason     string
	TerminalReason string
	IsError        bool
	SessionRef     string
	CostUSD        float64
	Turns          int
	Denials        []string
	Blocked        bool
	BlockedOn      string
	Errors         []string
	NoChange       bool
	Conditions     []protocol.ConditionProof
}

// ParseEnvelope reads a result object out of one line. The second return
// is false for anything that is not one.
func ParseEnvelope(line []byte) (Summary, bool) {
	var env envelope
	if err := json.Unmarshal(line, &env); err != nil || env.Type != "result" {
		return Summary{}, false
	}
	s := Summary{
		Summary:        env.Result,
		StopReason:     env.StopReason,
		TerminalReason: env.TerminalReason,
		IsError:        env.IsError,
		SessionRef:     env.SessionID,
		CostUSD:        env.TotalCostUSD,
		Turns:          env.NumTurns,
		Denials:        denialNames(env.Denials),
		Errors:         env.Errors,
	}
	if o := env.Structured; o != nil {
		if o.Summary != "" {
			s.Summary = o.Summary
		}
		s.Blocked = o.Status == "blocked"
		s.BlockedOn = o.BlockedOn
		s.NoChange = o.Status == "no_change"
		for _, c := range o.Conditions {
			s.Conditions = append(s.Conditions, protocol.ConditionProof{Met: c.Met, Proof: c.Proof})
		}
	}
	return s, true
}

func denialNames(raw []json.RawMessage) []string {
	if len(raw) == 0 {
		return nil
	}
	names := make([]string, 0, len(raw))
	for _, d := range raw {
		var name string
		if json.Unmarshal(d, &name) == nil {
			names = append(names, name)
			continue
		}
		var obj struct {
			ToolName string `json:"tool_name"`
		}
		if json.Unmarshal(d, &obj) == nil && obj.ToolName != "" {
			names = append(names, obj.ToolName)
			continue
		}
		names = append(names, string(d))
	}
	return names
}

const maxStreamLine = 8 * 1024 * 1024

type streamEvent struct {
	Type      string `json:"type"`
	Subtype   string `json:"subtype"`
	SessionID string `json:"session_id"`
	Message   struct {
		Content []struct {
			Type  string          `json:"type"`
			Text  string          `json:"text"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		} `json:"content"`
	} `json:"message"`
}

// consumeStream reads the harness's event stream, writing a readable
// transcript, emitting tool events, and returning the result envelope or
// nil when the stream carried none.
//
// The session id is also read off the stream's first `system/init` event,
// so an attempt the runner interrupts (a steer or pause boundary, which
// SIGTERMs the process before any result object) can still be resumed.
func consumeStream(r io.Reader, transcript io.Writer, ctl Control) (*Summary, string) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxStreamLine)
	var env *Summary
	var session string
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if s, ok := ParseEnvelope(line); ok {
			s := s
			env = &s
			continue
		}
		var ev streamEvent
		if json.Unmarshal(line, &ev) != nil {
			continue
		}
		switch ev.Type {
		case "system":
			if ev.Subtype == "init" && ev.SessionID != "" {
				session = ev.SessionID
			}
		case "rate_limit_event":
			io.WriteString(transcript, "  · rate limited, waiting\n")
		case "assistant":
			for _, c := range ev.Message.Content {
				switch c.Type {
				case "tool_use":
					if c.Name == "StructuredOutput" {
						continue
					}
					target := toolTarget(c.Input)
					io.WriteString(transcript, "  · "+strings.TrimSpace(c.Name+" "+target)+"\n")
					if ctl.Emit != nil {
						ctl.Emit(protocol.EventToolCall, map[string]any{"tool": c.Name, "target": target})
					}
				case "text":
					if t := strings.TrimSpace(c.Text); t != "" {
						io.WriteString(transcript, t+"\n")
						if ctl.Emit != nil {
							ctl.Emit(protocol.EventProgress, map[string]any{"text": capTail(t, 500)})
						}
					}
				}
			}
		}
	}
	return env, session
}

func toolTarget(input json.RawMessage) string {
	if len(input) == 0 {
		return ""
	}
	var in struct {
		FilePath string `json:"file_path"`
		Command  string `json:"command"`
		Pattern  string `json:"pattern"`
	}
	if json.Unmarshal(input, &in) != nil {
		return ""
	}
	switch {
	case in.FilePath != "":
		return filepath.Base(in.FilePath)
	case in.Command != "":
		return firstLine(in.Command, 60)
	case in.Pattern != "":
		return firstLine(in.Pattern, 40)
	}
	return ""
}

func firstLine(s string, max int) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}

func capTail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "[…truncated…]" + s[len(s)-n:]
}
