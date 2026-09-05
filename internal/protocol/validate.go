package protocol

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Problem is one validation finding, addressed by a JSON-pointer-ish path.
type Problem struct {
	Path    string
	Message string
}

func (p Problem) String() string { return p.Path + ": " + p.Message }

// Problems is a list of findings that renders as one error.
type Problems []Problem

func (ps Problems) Error() string {
	if len(ps) == 0 {
		return "valid"
	}
	parts := make([]string, len(ps))
	for i, p := range ps {
		parts[i] = p.String()
	}
	return strings.Join(parts, "; ")
}

// OrNil returns nil when there are no problems so callers can use the
// ordinary err != nil idiom.
func (ps Problems) OrNil() error {
	if len(ps) == 0 {
		return nil
	}
	return ps
}

type collector struct{ ps Problems }

func (c *collector) add(path, format string, args ...any) {
	c.ps = append(c.ps, Problem{Path: path, Message: fmt.Sprintf(format, args...)})
}

func (c *collector) require(path, value string) bool {
	if strings.TrimSpace(value) == "" {
		c.add(path, "is required")
		return false
	}
	return true
}

func (c *collector) schema(path, got, want string) {
	if got != want {
		c.add(path, "must be %q (got %q)", want, got)
	}
}

func (c *collector) timestamp(path, value string, required bool) {
	if value == "" {
		if required {
			c.add(path, "is required")
		}
		return
	}
	if _, err := time.Parse(time.RFC3339Nano, value); err != nil {
		c.add(path, "must be an RFC 3339 timestamp")
	}
}

func (c *collector) vocab(path string, values []string, allowed []string) {
	set := map[string]bool{}
	for _, a := range allowed {
		set[a] = true
	}
	for i, v := range values {
		if !set[v] {
			c.add(fmt.Sprintf("%s[%d]", path, i), "unknown value %q", v)
		}
	}
}

func (c *collector) oneOf(path, value string, allowed ...string) {
	for _, a := range allowed {
		if value == a {
			return
		}
	}
	c.add(path, "must be one of %s (got %q)", strings.Join(allowed, ", "), value)
}

var relPathRe = regexp.MustCompile(`^[^/\\][^\\]*$`)

// safeRelPath is a path inside a package or workspace: relative, no
// backslashes, no "." or ".." segments, no absolute prefix.
func safeRelPath(p string) bool {
	if p == "" || !relPathRe.MatchString(p) {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// SafeRelPath is exported for the loaders that must enforce it.
func SafeRelPath(p string) bool { return safeRelPath(p) }

// ValidateAgentManifest checks an agent-package.v1 manifest for shape.
// It does not read files; the package loader does that.
func ValidateAgentManifest(m *AgentManifest) Problems {
	c := &collector{}
	c.schema("schema", m.Schema, SchemaAgentPackage)
	id, err := ParseAgentID(m.ID)
	if err != nil {
		c.add("id", "%v", err)
	}
	if c.require("name", m.Name) && !IsAgentName(m.Name) {
		c.add("name", "must be 2 to 32 lowercase letters or digits")
	}
	if err == nil && id.Name != m.Name {
		c.add("name", "must equal the name part of id (%q)", id.Name)
	}
	c.require("displayName", m.DisplayName)
	if c.require("version", m.Version) && !IsVersion(m.Version) {
		c.add("version", "must be a semantic version")
	}
	if err == nil {
		switch {
		case id.IsLocal():
			if m.Publisher.Domain != "" && m.Publisher.Domain != LocalDomain {
				c.add("publisher.domain", "a local package must not claim a publisher domain")
			}
		default:
			if m.Publisher.Domain != id.Domain {
				c.add("publisher.domain", "must equal the publisher part of id (%q)", id.Domain)
			}
		}
	}
	if m.Licence.SPDX == "" && m.Licence.URL == "" {
		c.add("licence", "needs spdx or url")
	}
	c.require("identity.role", m.Identity.Role)
	if len(m.Prompts) == 0 {
		c.add("prompts", "at least one prompt file is required")
	}
	for i, p := range m.Prompts {
		if !safeRelPath(p) {
			c.add(fmt.Sprintf("prompts[%d]", i), "must be a safe relative path")
		}
	}
	for i, p := range m.Skills {
		if !safeRelPath(p) {
			c.add(fmt.Sprintf("skills[%d]", i), "must be a safe relative path")
		}
	}
	for i, p := range m.Evaluations {
		if !safeRelPath(p) {
			c.add(fmt.Sprintf("evaluations[%d]", i), "must be a safe relative path")
		}
	}
	caps := Capabilities()
	c.vocab("capabilities.required", m.Capabilities.Required, caps)
	c.vocab("capabilities.optional", m.Capabilities.Optional, caps)
	c.vocab("capabilities.denied", m.Capabilities.Denied, caps)
	for _, r := range m.Capabilities.Required {
		for _, d := range m.Capabilities.Denied {
			if r == d {
				c.add("capabilities", "%q is both required and denied", r)
			}
		}
	}
	c.vocab("harness.requires", m.Harness.Requires, Features())
	for name, file := range m.Harness.Overlays {
		if !safeRelPath(file) {
			c.add("harness.overlays."+name, "must be a safe relative path")
		}
	}
	if len(m.Placement.Allowed) == 0 {
		c.add("placement.allowed", "at least one placement is required")
	}
	c.vocab("placement.allowed", m.Placement.Allowed, []string{PlacementClient, PlacementServer})
	if c.require("outputSchemas.default", m.OutputSchemas.Default) && !safeRelPath(m.OutputSchemas.Default) {
		c.add("outputSchemas.default", "must be a safe relative path")
	}
	for name, file := range m.OutputSchemas.ByProcedure {
		if !safeRelPath(file) {
			c.add("outputSchemas.byProcedure."+name, "must be a safe relative path")
		}
	}
	seen := map[string]bool{}
	for i, p := range m.Procedures {
		path := fmt.Sprintf("procedures[%d]", i)
		if c.require(path+".name", p.Name) {
			if seen[p.Name] {
				c.add(path+".name", "duplicate procedure name %q", p.Name)
			}
			seen[p.Name] = true
		}
		if p.Matches.ObjectiveRegex == "" {
			c.add(path+".matches", "objectiveRegex is required")
		} else if _, err := regexp.Compile(p.Matches.ObjectiveRegex); err != nil {
			c.add(path+".matches.objectiveRegex", "%v", err)
		}
		c.vocab(path+".requires", p.Requires, caps)
		if len(p.Steps) == 0 {
			c.add(path+".steps", "at least one step is required")
		}
		for j, s := range p.Steps {
			validateStep(c, fmt.Sprintf("%s.steps[%d]", path, j), s)
		}
	}
	return c.ps
}

var stepKinds = []string{"emit", "write", "assert", "blocked", "external_action", "no_change", "fail", "await_directive", "sleep"}

func validateStep(c *collector, path string, s ProcedureStep) {
	c.oneOf(path+".kind", s.Kind, stepKinds...)
	switch s.Kind {
	case "write":
		if !safeRelPath(s.Path) {
			c.add(path+".path", "must be a safe relative path inside the workspace")
		}
	case "assert":
		if s.Condition < 1 {
			c.add(path+".condition", "must be a 1-based condition index")
		}
	case "blocked":
		c.require(path+".question", s.Question)
	case "external_action":
		c.require(path+".action", s.Action)
	case "sleep":
		if _, err := time.ParseDuration(s.Duration); err != nil {
			c.add(path+".duration", "must be a Go duration")
		}
	}
}

// ValidateWorkPackage checks a work-package.v1 document for shape.
func ValidateWorkPackage(w *WorkPackage) Problems {
	c := &collector{}
	c.schema("schema", w.Schema, SchemaWorkPackage)
	if c.require("packageId", w.PackageID) && !IsULID(w.PackageID) {
		c.add("packageId", "must be a ULID")
	}
	c.require("issuer.kind", w.Issuer.Kind)
	c.require("issuer.id", w.Issuer.ID)
	c.timestamp("issuedAt", w.IssuedAt, true)
	c.timestamp("expiresAt", w.ExpiresAt, false)
	if w.SupersedesPackageID != "" && !IsULID(w.SupersedesPackageID) {
		c.add("supersedesPackageId", "must be a ULID")
	}
	for i, r := range w.Correlation.Refs {
		c.require(fmt.Sprintf("correlation.refs[%d].kind", i), r.Kind)
		c.require(fmt.Sprintf("correlation.refs[%d].id", i), r.ID)
	}
	if c.require("agent.id", w.Agent.ID) {
		if _, err := ParseAgentID(w.Agent.ID); err != nil {
			c.add("agent.id", "%v", err)
		}
	}
	if w.Agent.Version != "" && !IsVersion(w.Agent.Version) {
		c.add("agent.version", "must be a semantic version")
	}
	if w.Agent.Digest != "" && !IsDigest(w.Agent.Digest) {
		c.add("agent.digest", "must be sha256:<hex>")
	}
	c.oneOf("placement", w.Placement, PlacementClient, PlacementServer, PlacementEither)
	c.oneOf("workspace.kind", w.Workspace.Kind, "git", "none")
	c.oneOf("workspace.ownership", w.Workspace.Ownership, "caller", "runtime")
	if w.Workspace.Kind == "git" && w.Workspace.Path == "" {
		c.add("workspace.path", "is required for a git workspace")
	}
	c.require("objective", w.Objective)
	for i, a := range w.Context.Attachments {
		c.require(fmt.Sprintf("context.attachments[%d].name", i), a.Name)
	}
	if w.Completion.Conditions == nil {
		c.add("completion.conditions", "is required (an empty list is allowed)")
	}
	for i, cond := range w.Completion.Conditions {
		c.require(fmt.Sprintf("completion.conditions[%d]", i), cond)
	}
	if w.Completion.Landing != "" {
		c.oneOf("completion.landing", w.Completion.Landing, "commit", "none")
	}
	if w.Capabilities.Granted == nil {
		c.add("capabilities.granted", "is required (an empty list is allowed)")
	}
	c.vocab("capabilities.granted", w.Capabilities.Granted, Capabilities())
	if w.Capabilities.Limits.MaxUSD < 0 {
		c.add("capabilities.limits.maxUsd", "must not be negative")
	}
	if w.Capabilities.Limits.MaxTurns < 0 {
		c.add("capabilities.limits.maxTurns", "must not be negative")
	}
	if w.Capabilities.Limits.Timeout != "" {
		if _, err := time.ParseDuration(w.Capabilities.Limits.Timeout); err != nil {
			c.add("capabilities.limits.timeout", "must be a Go duration")
		}
	}
	if w.Capabilities.Limits.Network != "" {
		c.oneOf("capabilities.limits.network", w.Capabilities.Limits.Network, NetworkNone, NetworkProviderOnly, NetworkOpen)
	}
	for i, g := range w.Authority.May {
		c.require(fmt.Sprintf("authority.may[%d].capability", i), g.Capability)
	}
	if a := w.Approval; a != nil {
		c.require("approval.proposalRef", a.ProposalRef)
		c.require("approval.approvalRef", a.ApprovalRef)
		c.require("approval.approvedBy", a.ApprovedBy)
		c.require("approval.action", a.Action)
		if c.require("approval.paramsHash", a.ParamsHash) {
			if !IsDigest(a.ParamsHash) {
				c.add("approval.paramsHash", "must be sha256:<hex>")
			} else if h, err := ParamsHash(a.Params); err == nil && h != a.ParamsHash {
				c.add("approval.paramsHash", "does not match the canonical hash of approval.params")
			}
		}
	}
	return c.ps
}

// ValidateWorkDirective checks a work-directive.v1 frame, including that
// its digest is the digest of its own content.
func ValidateWorkDirective(d *WorkDirective) Problems {
	c := &collector{}
	c.schema("schema", d.Schema, SchemaWorkDirective)
	c.require("directiveId", d.DirectiveID)
	if c.require("packageId", d.PackageID) && !IsULID(d.PackageID) {
		c.add("packageId", "must be a ULID")
	}
	if d.Seq < 1 {
		c.add("seq", "must be a positive integer")
	}
	c.require("issuer.kind", d.Issuer.Kind)
	c.require("issuer.id", d.Issuer.ID)
	c.timestamp("issuedAt", d.IssuedAt, true)
	c.oneOf("kind", d.Kind, DirectiveClarify, DirectiveSteer, DirectivePause, DirectiveResume, DirectiveStop)
	switch d.Kind {
	case DirectiveClarify, DirectiveSteer:
		c.require("payload.text", d.Payload.Text)
	}
	if c.require("digest", d.Digest) {
		if want, err := DirectiveDigest(*d); err == nil && want != d.Digest {
			c.add("digest", "does not match the directive's content")
		}
	}
	return c.ps
}

// ValidateRunEvent checks a run-event.v1 frame.
func ValidateRunEvent(e *RunEvent) Problems {
	c := &collector{}
	c.schema("schema", e.Schema, SchemaRunEvent)
	c.require("eventId", e.EventID)
	c.require("packageId", e.PackageID)
	c.require("runId", e.RunID)
	if e.Seq < 1 {
		c.add("seq", "must be a positive integer")
	}
	c.timestamp("at", e.At, true)
	c.require("kind", e.Kind)
	return c.ps
}

// ValidateRunReceipt checks a run-receipt.v1 document, including that its
// digest is the digest of its own content and that conditions are present.
func ValidateRunReceipt(r *RunReceipt) Problems {
	c := &collector{}
	c.schema("schema", r.Schema, SchemaRunReceipt)
	c.require("receiptId", r.ReceiptID)
	if c.require("packageId", r.PackageID) && !IsULID(r.PackageID) {
		c.add("packageId", "must be a ULID")
	}
	c.require("runId", r.RunID)
	if c.require("agent.id", r.Agent.ID) {
		if _, err := ParseAgentID(r.Agent.ID); err != nil {
			c.add("agent.id", "%v", err)
		}
	}
	if r.Agent.Digest != "" && !IsDigest(r.Agent.Digest) {
		c.add("agent.digest", "must be sha256:<hex>")
	}
	c.require("harness.adapter", r.Harness.Adapter)
	if c.require("packageDigest", r.PackageDigest) && !IsDigest(r.PackageDigest) {
		c.add("packageDigest", "must be sha256:<hex>")
	}
	if c.require("conditionsDigest", r.ConditionsDigest) && !IsDigest(r.ConditionsDigest) {
		c.add("conditionsDigest", "must be sha256:<hex>")
	}
	if cn := r.Continues; cn != nil {
		c.require("continues.runId", cn.RunID)
		c.require("continues.receiptId", cn.ReceiptID)
		if c.require("continues.receiptDigest", cn.ReceiptDigest) && !IsDigest(cn.ReceiptDigest) {
			c.add("continues.receiptDigest", "must be sha256:<hex>")
		}
	}
	c.timestamp("startedAt", r.StartedAt, true)
	c.timestamp("endedAt", r.EndedAt, true)
	c.oneOf("status", r.Status, StatusCompleted, StatusNoChange, StatusBlocked, StatusFailed, StatusStopped, StatusDenied)
	if r.Conditions == nil {
		c.add("conditions", "is required (an empty list is allowed)")
	}
	if r.Directives.Received == nil || r.Directives.Applied == nil || r.Directives.Rejected == nil {
		c.add("directives", "received, applied and rejected lists are required")
	}
	if r.Status == StatusDenied && r.Denied == nil {
		c.add("denied", "is required when status is denied")
	}
	if r.Status == StatusStopped && r.Stop == nil {
		c.add("stop", "is required when status is stopped")
	}
	if c.require("receiptDigest", r.ReceiptDigest) {
		if want, err := ReceiptDigest(*r); err == nil && want != r.ReceiptDigest {
			c.add("receiptDigest", "does not match the receipt's content")
		}
	}
	return c.ps
}
