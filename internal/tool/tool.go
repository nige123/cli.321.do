// Package tool is the bounded interface between a deterministic procedure
// and an external program the runtime binds by explicit configuration.
//
// A tool exposes named operations. Each operation carries its own
// capability requirement, so authority is checked per operation, never
// per tool: reading deployment status needs deploy.read, preparing a plan
// needs deploy.plan, and executing a deployment needs deploy.invoke. A
// procedure step names the tool and the operation; the runtime checks the
// grant, validates the parameters, builds an argument vector, runs the
// configured executable with no shell, bounds and redacts what comes
// back, and records the call on the receipt.
//
// Nothing here knows which agent is calling. A package that declares a
// tool step is treated exactly like any other package.
package tool

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"time"
)

// Op is one operation a tool offers.
type Op struct {
	Name       string
	Capability string
	Mutates    bool
	// Unavailable, when set, says this build never performs the operation:
	// a call is recorded as not performed with this message, whatever the
	// grants. The message names the fact, never a promise.
	Unavailable string
}

// Result is what one invocation produced.
type Result struct {
	Ok       bool
	ExitCode int
	// Output is the process output, redacted and capped.
	Output string
	// Data is the parsed JSON document the tool printed, when it printed
	// one; nil otherwise.
	Data map[string]any
	// Argv is the exact argument vector that ran (argv[0] excluded).
	Argv []string
	// Duration is the wall-clock time of the call.
	Duration time.Duration
	// Unavailable is set when the operation is not performed by design in
	// this build (an execution boundary that is not yet enabled). Nothing
	// ran; the message says so.
	Unavailable string
	// Truncated says the output was cut to the cap.
	Truncated bool
}

// OutputDigest is the sha256 of the redacted, capped output, for a
// receipt to reference without carrying it.
func (r Result) OutputDigest() string {
	sum := sha256.Sum256([]byte(r.Output))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// Tool is a bound external program.
type Tool interface {
	Name() string
	Ops() []Op
	// Run performs op with the validated params. It returns an error only
	// for a refused call (unknown op, bad parameter, no binding); a
	// process that ran and failed is a Result with Ok false.
	Run(ctx context.Context, op string, params map[string]string) (Result, error)
}

// Registry maps tool names to bound tools.
type Registry map[string]Tool

// Names lists the bound tools in order.
func (r Registry) Names() []string {
	var out []string
	for n := range r {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// OpOf finds an operation on a tool.
func OpOf(t Tool, name string) (Op, bool) {
	for _, o := range t.Ops() {
		if o.Name == name {
			return o, true
		}
	}
	return Op{}, false
}

// Executing is a tool whose execute operation can be performed by a
// configured Executor. Without one, execute is reported unavailable.
type Executing interface {
	Executor() Executor
}
