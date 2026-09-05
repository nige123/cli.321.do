// Package cli is the front door: `321 <agent> <request>` for people and
// `321 run` for machines, plus the small inspection commands.
//
// Reserved first words: run, agents, packages, trust, doctor, help,
// version. Anything else is an agent alias or a canonical id. A request is
// the remaining words joined by single spaces; it becomes the objective of
// a WorkPackage and is never handed to a shell.
package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/run"
	"cli.321.do/internal/trust"
	"cli.321.do/internal/wire"
)

// Version is stamped at build time.
var Version = "dev"

// Env is everything a command touches, so tests can substitute all of it.
type Env struct {
	Stdin       io.Reader
	Stdout      io.Writer
	Stderr      io.Writer
	Args        []string
	TrustPath   string // "" means the default
	Home        string // ~/.321; "" means the default
	Adapters    *adapter.Registry
	Interactive bool // stdin is a terminal
	Signals     bool
}

// Main runs the CLI and returns the exit code.
func Main(env Env) int {
	if env.Adapters == nil {
		env.Adapters = DefaultRegistry(env.Stderr)
	}
	args := env.Args
	g, rest, err := parseGlobal(args)
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		fmt.Fprint(env.Stderr, usage)
		return wire.ExitUsage
	}
	if g.trustPath != "" {
		env.TrustPath = g.trustPath
	}
	if len(rest) == 0 {
		fmt.Fprint(env.Stdout, usage)
		return wire.ExitUsage
	}
	switch rest[0] {
	case "help", "-h", "--help":
		fmt.Fprint(env.Stdout, usage)
		return 0
	case "version", "--version":
		fmt.Fprintln(env.Stdout, "321", Version)
		return 0
	case "run":
		return cmdRun(env, g, rest[1:])
	case "agents":
		return cmdAgents(env, g)
	case "packages":
		return cmdPackages(env, rest[1:])
	case "trust":
		return cmdTrust(env, rest[1:])
	case "doctor":
		return cmdDoctor(env)
	}
	return cmdAgent(env, g, rest[0], rest[1:])
}

// DefaultRegistry is the installed adapter set: the procedure executor and
// the fake (hidden, selectable only by name) and Claude Code.
func DefaultRegistry(stderr io.Writer) *adapter.Registry {
	r := adapter.NewRegistry()
	r.RegisterHidden(adapter.NewProcedure())
	r.RegisterHidden(adapter.NewFake(nil))
	r.Register(&adapter.ClaudeCode{Stderr: stderr, Transcript: stderr})
	return r
}

type global struct {
	trustPath      string
	workspace      string
	packageDir     string
	placement      string
	adapter        string
	attach         []string
	done           []string
	grant          []string
	nonInteractive bool
	jsonOut        bool
}

// parseGlobal reads options that precede the command word. Options after
// the agent name belong to the request text.
func parseGlobal(args []string) (global, []string, error) {
	var g global
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--" {
			return g, args[i+1:], nil
		}
		if !strings.HasPrefix(a, "-") {
			break
		}
		name, value, hasValue := strings.Cut(a, "=")
		need := func() (string, error) {
			if hasValue {
				return value, nil
			}
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", name)
			}
			i++
			return args[i], nil
		}
		var err error
		switch name {
		case "--trust":
			g.trustPath, err = need()
		case "--workspace":
			g.workspace, err = need()
		case "--package-dir":
			g.packageDir, err = need()
		case "--placement":
			g.placement, err = need()
		case "--adapter":
			g.adapter, err = need()
		case "--attach":
			var v string
			v, err = need()
			g.attach = append(g.attach, v)
		case "--done":
			var v string
			v, err = need()
			g.done = append(g.done, v)
		case "--grant":
			var v string
			v, err = need()
			g.grant = append(g.grant, v)
		case "--non-interactive":
			g.nonInteractive = true
		case "--json":
			g.jsonOut = true
		default:
			return g, nil, fmt.Errorf("unknown option %s", name)
		}
		if err != nil {
			return g, nil, err
		}
		i++
	}
	return g, args[i:], nil
}

func (env Env) trust() (*trust.Config, error) {
	p := env.TrustPath
	if p == "" {
		var err error
		p, err = trust.DefaultPath()
		if err != nil {
			return nil, err
		}
	}
	return trust.Load(p)
}

func (env Env) home() (string, error) {
	if env.Home != "" {
		return env.Home, nil
	}
	if h := os.Getenv("X321_HOME"); h != "" {
		return h, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".321"), nil
}

func (env Env) runner() *run.Runner { return &run.Runner{Adapters: env.Adapters} }

func cmdRun(env Env, g global, args []string) int {
	opts := wire.Options{
		PackageSource: "-",
		Stdin:         env.Stdin,
		Stdout:        env.Stdout,
		Stderr:        env.Stderr,
		Runner:        env.runner(),
		Signals:       env.Signals,
		PackageDir:    g.packageDir,
		Workspace:     g.workspace,
		Adapter:       g.adapter,
	}
	i := 0
	for i < len(args) {
		a := args[i]
		name, value, hasValue := strings.Cut(a, "=")
		need := func() (string, error) {
			if hasValue {
				return value, nil
			}
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", name)
			}
			i++
			return args[i], nil
		}
		var err error
		switch name {
		case "--package":
			opts.PackageSource, err = need()
		case "--workspace":
			opts.Workspace, err = need()
		case "--package-dir":
			opts.PackageDir, err = need()
		case "--receipt":
			opts.ReceiptPath, err = need()
		case "--events":
			opts.EventsPath, err = need()
		case "--run-id":
			opts.RunID, err = need()
		case "--history-dir":
			opts.HistoryDir, err = need()
		case "--adapter":
			opts.Adapter, err = need()
		default:
			err = fmt.Errorf("unknown option %s for run", name)
		}
		if err != nil {
			fmt.Fprintln(env.Stderr, "321 run:", err)
			return wire.ExitUsage
		}
		i++
	}
	cfg, err := env.trust()
	if err != nil {
		fmt.Fprintln(env.Stderr, "321 run:", err)
		return wire.ExitInternal
	}
	opts.Trust = cfg
	return wire.Serve(context.Background(), opts)
}

const usage = `321 - run an agent

  321 <agent> <request...>            ask a configured agent to do something here
  321 <publisher>/<agent> <request>   the same, by canonical id

Options before the agent:
  --workspace <dir>       where the work happens (default: the enclosing git repo, else none)
  --package-dir <dir>     load an unsigned local package from a directory (identity local/<name>)
  --attach <file>         make a file available to the agent (repeatable)
  --done <condition>      a completion condition, in order (repeatable)
  --grant <capability>    grant an optional capability within local policy (repeatable)
  --placement client|server|either
  --adapter <name>        insist on one adapter
  --non-interactive       never read steering from the terminal
  --json                  print events as JSON lines instead of a transcript
  --trust <file>          trust configuration (default ~/.321/trust.json)

Machine invocation:
  321 run --package <file|-> [--workspace <dir>] [--receipt <file>] [--events <file>]
          [--run-id <id>] [--history-dir <dir>] [--adapter <name>] [--package-dir <dir>]
      stdin:  the work package (when --package -), then work directives, one JSON object per line
      stdout: run events, then exactly one run receipt; a protocol error when no package can be identified

Inspection:
  321 agents                    configured packages, their trust and aliases
  321 packages validate <dir>   check a package directory against agent-package.v1
  321 packages digest <dir> [--write]
  321 trust show | check
  321 doctor                    installed adapters and what each actually enforces
  321 version | help

Exit codes: 0 completed or no change, 2 blocked, 3 stopped, 4 failed, 5 denied,
64 usage, 65 malformed input, 70 internal error.
`
