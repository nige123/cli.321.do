// Package adapter defines what a harness adapter is, what it may honestly
// claim to enforce, and how one is chosen for a package.
//
// An adapter is a way of executing an attempt. It receives the effective
// grants and limits, a rendered prompt or a procedure, a directive channel
// it may or may not be able to act on live, and an approval gate for any
// external action. It returns an outcome. It never decides authority: the
// runner computed the grants before the adapter saw them, and an adapter
// that cannot enforce a required restriction is never selected.
package adapter

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
)

// Detection is whether an adapter can run here at all.
type Detection struct {
	Available bool
	Version   string
	Reason    string
}

// Enforcement is the adapter's own account of which features it actually
// enforces. A feature absent from the map is not enforced. This is what
// `321 doctor` prints and what selection reads; prompt text never counts.
type Enforcement map[string]bool

// Enforces reports one feature.
func (e Enforcement) Enforces(feature string) bool { return e[feature] }

// Spec is one attempt's input.
type Spec struct {
	Package      *protocol.WorkPackage
	Agent        *trust.Loaded
	Attempt      int
	Workspace    string // absolute path, or "" when the package has none
	Prompt       string // rendered for this attempt, instructions included
	Instructions []string
	Grants       []string
	Limits       protocol.Limits // remaining for this attempt
	SessionRef   string          // continuation from an earlier attempt
	OutputSchema []byte
	Procedure    *protocol.Procedure // set when executing a package procedure
	Overlay      []byte              // adapter-specific tuning from the package
}

// ApprovalGate checks an operation the adapter is about to perform against
// the package's exact approval. The runner supplies it.
type ApprovalGate func(action, target string, params map[string]any) (*protocol.ApprovalCheck, error)

// Control is what the adapter can say and hear while it runs.
type Control struct {
	// Emit publishes a progress event.
	Emit func(kind string, payload map[string]any)
	// Directives carries live directives to adapters that enforce
	// live_steer or pause. Adapters that do not must not read it.
	Directives <-chan protocol.WorkDirective
	// Applied and Rejected acknowledge a live directive.
	Applied  func(directiveID string)
	Rejected func(directiveID, reason string)
	// Approval gates any external action.
	Approval ApprovalGate
}

// Outcome is what one attempt produced.
type Outcome struct {
	Status         string // completed | no_change | blocked | failed | stopped
	EndReason      string
	Summary        string
	BlockedOn      string
	Conditions     []protocol.ConditionProof
	SessionRef     string
	Cost           protocol.Cost
	Denials        []string
	Errors         []string
	ExternalAction *protocol.ExternalAction
	ApprovalCheck  *protocol.ApprovalCheck
}

// Adapter executes attempts.
type Adapter interface {
	Name() string
	Detect() Detection
	Enforcement() Enforcement
	Run(ctx context.Context, spec Spec, ctl Control) (Outcome, error)
}

// Requirement is one feature the package or its grants make mandatory.
type Requirement struct {
	Feature string
	Reason  string
}

// Requirements derives what must be enforced for this package under these
// effective grants. Package requirements are taken as stated; the rest
// follow from what the grants make reachable.
func Requirements(m *protocol.AgentManifest, wp *protocol.WorkPackage, grants []string) []Requirement {
	var reqs []Requirement
	add := func(f, why string) {
		for _, r := range reqs {
			if r.Feature == f {
				return
			}
		}
		reqs = append(reqs, Requirement{Feature: f, Reason: why})
	}
	for _, f := range m.Harness.Requires {
		add(f, "the package requires it")
	}
	has := func(c string) bool {
		for _, g := range grants {
			if g == c {
				return true
			}
		}
		return false
	}
	toolish := has(protocol.CapRepoRead) || has(protocol.CapRepoWrite) || has(protocol.CapShellRun) ||
		has(protocol.CapNetFetch) || has(protocol.CapFilesRead) || has(protocol.CapFilesWrite)
	if toolish {
		add(protocol.FeatToolAllowlist, "tools are granted, so the harness must confine them to the grant")
	}
	add(protocol.FeatStructuredOutput, "the package declares an output schema")
	if wp.Capabilities.Limits.MaxTurns > 0 {
		add(protocol.FeatTurnLimit, "a turn limit is set")
	}
	if wp.Capabilities.Limits.MaxUSD > 0 {
		add(protocol.FeatSpendLimit, "a spend limit is set")
	}
	network := EffectiveNetwork(wp)
	if network != protocol.NetworkOpen && has(protocol.CapShellRun) {
		add(protocol.FeatNetworkDeny, "shell.run is granted but agent network access is "+network+", so an unrestricted shell would bypass it")
	}
	return reqs
}

// EffectiveNetwork is the package's network mode with the default applied:
// an unspecified mode means the agent may reach nothing beyond the
// harness's own model provider.
func EffectiveNetwork(wp *protocol.WorkPackage) string {
	if wp.Capabilities.Limits.Network == "" {
		return protocol.NetworkProviderOnly
	}
	return wp.Capabilities.Limits.Network
}

// Rejection says why one adapter was not chosen.
type Rejection struct {
	Adapter     string
	Unavailable string
	Missing     []string
	Denied      bool
}

func (r Rejection) String() string {
	switch {
	case r.Denied:
		return r.Adapter + ": denied by policy"
	case r.Unavailable != "":
		return r.Adapter + ": unavailable: " + r.Unavailable
	default:
		return r.Adapter + ": cannot enforce " + strings.Join(r.Missing, ", ")
	}
}

// Registry holds the installed adapters in registration order. Hidden
// adapters (the procedure executor and the fake) are never chosen by
// selection on their own merits: only by name, through the caller's
// explicit adapter choice or the policy's preferred list.
type Registry struct {
	adapters []Adapter
	hidden   map[string]bool
}

// NewRegistry builds a registry.
func NewRegistry(adapters ...Adapter) *Registry {
	r := &Registry{}
	for _, a := range adapters {
		r.Register(a)
	}
	return r
}

// Register adds an adapter.
func (r *Registry) Register(a Adapter) { r.adapters = append(r.adapters, a) }

// RegisterHidden adds an adapter that selection ignores unless it is named.
func (r *Registry) RegisterHidden(a Adapter) {
	if r.hidden == nil {
		r.hidden = map[string]bool{}
	}
	r.hidden[a.Name()] = true
	r.adapters = append(r.adapters, a)
}

// Get finds an adapter by name.
func (r *Registry) Get(name string) (Adapter, bool) {
	for _, a := range r.adapters {
		if a.Name() == name {
			return a, true
		}
	}
	return nil, false
}

// All lists the adapters in registration order.
func (r *Registry) All() []Adapter { return append([]Adapter(nil), r.adapters...) }

// Select chooses the first adapter, in policy preference order, that is
// available and enforces every requirement. It returns the rejections so
// a denial can say exactly why nothing qualified.
func (r *Registry) Select(reqs []Requirement, policy trust.AdapterPolicy, only string) (Adapter, []Rejection) {
	denied := map[string]bool{}
	for _, d := range policy.Denied {
		denied[d] = true
	}
	preferred := map[string]bool{}
	for _, p := range policy.Preferred {
		preferred[p] = true
	}
	ordered := r.ordered(policy.Preferred)
	var rejections []Rejection
	for _, a := range ordered {
		if only != "" && a.Name() != only {
			continue
		}
		if r.hidden[a.Name()] && only != a.Name() && !preferred[a.Name()] {
			continue
		}
		if denied[a.Name()] {
			rejections = append(rejections, Rejection{Adapter: a.Name(), Denied: true})
			continue
		}
		det := a.Detect()
		if !det.Available {
			rejections = append(rejections, Rejection{Adapter: a.Name(), Unavailable: det.Reason})
			continue
		}
		enf := a.Enforcement()
		var missing []string
		for _, q := range reqs {
			if !enf.Enforces(q.Feature) {
				missing = append(missing, fmt.Sprintf("%s (%s)", q.Feature, q.Reason))
			}
		}
		if len(missing) > 0 {
			rejections = append(rejections, Rejection{Adapter: a.Name(), Missing: missing})
			continue
		}
		return a, rejections
	}
	if only != "" {
		if _, ok := r.Get(only); !ok {
			rejections = append(rejections, Rejection{Adapter: only, Unavailable: "no such adapter"})
		}
	}
	return nil, rejections
}

func (r *Registry) ordered(preferred []string) []Adapter {
	rank := map[string]int{}
	for i, p := range preferred {
		rank[p] = i
	}
	out := append([]Adapter(nil), r.adapters...)
	sort.SliceStable(out, func(i, j int) bool {
		ri, oki := rank[out[i].Name()]
		rj, okj := rank[out[j].Name()]
		switch {
		case oki && okj:
			return ri < rj
		case oki:
			return true
		case okj:
			return false
		}
		return false
	})
	return out
}

// ToolNames maps neutral grants onto an adapter's tool vocabulary using
// the table the adapter supplies. Unknown grants map to nothing, which is
// the safe direction.
func ToolNames(grants []string, table map[string][]string) []string {
	seen := map[string]bool{}
	var out []string
	for _, g := range grants {
		for _, t := range table[g] {
			if !seen[t] {
				seen[t] = true
				out = append(out, t)
			}
		}
	}
	return out
}
