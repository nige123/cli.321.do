// Package protocol holds the five public 321 protocols as Go types, their
// validators, and the small helpers (identity parsing, canonical JSON,
// ULIDs) every other package relies on. The JSON Schema documents under
// schemas/ are the canonical human-facing definition; the validators here
// enforce the same rules for the runtime and are pinned to those documents
// by tests.
//
// Nothing in this package knows about any work system. Correlation
// references are opaque strings that are echoed back verbatim.
package protocol

// Schema identifiers. Every frame on the wire and every document on disk
// carries one so a reader can refuse what it does not understand.
const (
	SchemaAgentPackage       = "agent-package.v1"
	SchemaWorkPackage        = "work-package.v1"
	SchemaWorkDirective      = "work-directive.v1"
	SchemaRunEvent           = "run-event.v1"
	SchemaRunReceipt         = "run-receipt.v1"
	SchemaProtocolError      = "protocol-error.v1"
	SchemaDeploymentProposal = "deployment-proposal.v1"
	SchemaTrustConfig        = "trust-config.v1"
)

// Capability vocabulary. Packages declare what they need in these terms;
// callers grant in these terms; adapters map them onto whatever the
// harness can actually restrict. deploy.invoke is privileged, but so are
// shell.run, repo.write, files.write and net.fetch: each carries authority
// and each is granted only where the selected adapter can enforce it.
const (
	CapRepoRead     = "repo.read"
	CapRepoWrite    = "repo.write"
	CapShellRun     = "shell.run"
	CapNetFetch     = "net.fetch"
	CapFilesRead    = "files.read"
	CapFilesWrite   = "files.write"
	CapModelText    = "model.text"
	CapDeployInvoke = "deploy.invoke"
	// deploy.read and deploy.plan are the read-only halves of deployment
	// authority: observing managed services, and preparing a plan for a
	// deployment. Neither performs one; only deploy.invoke does, and a
	// tool binding decides per operation which of the three it needs.
	CapDeployRead = "deploy.read"
	CapDeployPlan = "deploy.plan"
)

// Capabilities lists the whole vocabulary in declaration order.
func Capabilities() []string {
	return []string{
		CapRepoRead, CapRepoWrite, CapShellRun, CapNetFetch,
		CapFilesRead, CapFilesWrite, CapModelText, CapDeployInvoke,
		CapDeployRead, CapDeployPlan,
	}
}

// Enforcement features an adapter may honestly claim. A package's
// harness.requires names these, never a provider.
const (
	FeatToolAllowlist    = "tool_allowlist"
	FeatRepoScope        = "repo_scope"
	FeatNetworkDeny      = "network_deny"
	FeatStructuredOutput = "structured_output"
	FeatTurnLimit        = "turn_limit"
	FeatSpendLimit       = "spend_limit"
	FeatTimeout          = "timeout"
	FeatEventStream      = "event_stream"
	FeatLiveSteer        = "live_steer"
	FeatPause            = "pause"
	FeatSessionContinue  = "session_continue"
	FeatGracefulStop     = "graceful_stop"
)

// Features lists every enforcement feature in declaration order.
func Features() []string {
	return []string{
		FeatToolAllowlist, FeatRepoScope, FeatNetworkDeny, FeatStructuredOutput,
		FeatTurnLimit, FeatSpendLimit, FeatTimeout, FeatEventStream,
		FeatLiveSteer, FeatPause, FeatSessionContinue, FeatGracefulStop,
	}
}

// Network modes on a WorkPackage's limits. provider_only means the agent
// itself may not reach the network but the harness may reach its own model
// provider, which is a different connection under a different authority.
const (
	NetworkNone         = "none"
	NetworkProviderOnly = "provider_only"
	NetworkOpen         = "open"
)

// Placement values.
const (
	PlacementClient = "client"
	PlacementServer = "server"
	PlacementEither = "either"
)

// Directive kinds. Ordinary kinds are applied in sequence order; stop is
// applied the moment it is authenticated, whatever is missing before it.
const (
	DirectiveClarify = "clarify"
	DirectiveSteer   = "steer"
	DirectivePause   = "pause"
	DirectiveResume  = "resume"
	DirectiveStop    = "stop"
)

// Receipt outcome statuses.
const (
	StatusCompleted = "completed"
	StatusNoChange  = "no_change"
	StatusBlocked   = "blocked"
	StatusFailed    = "failed"
	StatusStopped   = "stopped"
	StatusDenied    = "denied"
)

// Event kinds emitted by the runtime.
const (
	EventStarted            = "started"
	EventAdapterSelected    = "adapter_selected"
	EventProcedureSelected  = "procedure_selected"
	EventAttemptStarted     = "attempt_started"
	EventAttemptEnded       = "attempt_ended"
	EventToolCall           = "tool_call"
	EventToolResult         = "tool_result"
	EventProgress           = "progress"
	EventDirectiveReceived  = "directive_received"
	EventDirectiveApplied   = "directive_applied"
	EventDirectiveRejected  = "directive_rejected"
	EventDirectiveDuplicate = "directive_duplicate"
	EventPaused             = "paused"
	EventResumed            = "resumed"
	EventStopping           = "stopping"
	EventCost               = "cost"
	EventDenied             = "denied"
)

// ---------------------------------------------------------------------
// agent-package.v1
// ---------------------------------------------------------------------

// AgentManifest is agent.json at the root of a package directory.
type AgentManifest struct {
	Schema      string     `json:"schema"`
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	DisplayName string     `json:"displayName"`
	Version     string     `json:"version"`
	Publisher   Publisher  `json:"publisher"`
	Owner       Owner      `json:"owner,omitempty"`
	Licence     Licence    `json:"licence"`
	Provenance  Provenance `json:"provenance,omitempty"`

	Identity   Identity    `json:"identity"`
	Prompts    []string    `json:"prompts"`
	Skills     []string    `json:"skills,omitempty"`
	Procedures []Procedure `json:"procedures,omitempty"`

	Capabilities  CapabilitySpec `json:"capabilities"`
	Harness       HarnessSpec    `json:"harness"`
	Placement     PlacementSpec  `json:"placement"`
	OutputSchemas OutputSchemas  `json:"outputSchemas"`
	Evaluations   []string       `json:"evaluations,omitempty"`
}

// Publisher is the namespace claim. Domain is a claim until trust
// configuration says otherwise. Empty for local packages.
type Publisher struct {
	Domain string `json:"domain"`
	URL    string `json:"url,omitempty"`
}

// Owner is legal-owner metadata. It proves nothing by itself.
type Owner struct {
	LegalName string `json:"legalName,omitempty"`
	URL       string `json:"url,omitempty"`
}

// Licence names the terms the package is offered under.
type Licence struct {
	SPDX string `json:"spdx,omitempty"`
	URL  string `json:"url,omitempty"`
}

// Provenance records where a build came from.
type Provenance struct {
	Source  string `json:"source,omitempty"`
	BuiltAt string `json:"builtAt,omitempty"`
	BuiltBy string `json:"builtBy,omitempty"`
}

// Identity is who the agent is, as instructions to a model.
type Identity struct {
	Role          string `json:"role"`
	Personality   string `json:"personality,omitempty"`
	Tone          string `json:"tone,omitempty"`
	DecisionStyle string `json:"decisionStyle,omitempty"`
}

// Procedure is a deterministic path through a fully specified operation.
// It runs without a model, under the same authority checks and into the
// same receipt as model-driven execution.
type Procedure struct {
	Name     string          `json:"name"`
	Matches  ProcedureMatch  `json:"matches"`
	Requires []string        `json:"requires,omitempty"`
	Steps    []ProcedureStep `json:"steps"`
}

// ProcedureMatch decides whether a procedure applies to a package.
type ProcedureMatch struct {
	ObjectiveRegex string `json:"objectiveRegex,omitempty"`
}

// ProcedureStep is one deterministic step. Kinds:
//
//	emit            progress text
//	write           write Content to Path inside the workspace (needs repo.write or files.write)
//	assert          record Condition (1-based) as Met with Proof
//	blocked         stop with a Question for a person
//	external_action perform Action on Target with Params; requires a matching approval
//	no_change       finish reporting nothing needed changing
//	fail            finish as failed with Text
//	await_directive block until a directive arrives (used by tests and interactive procedures)
//	sleep           wait Duration (Go duration string); a test convenience
type ProcedureStep struct {
	Kind      string         `json:"kind"`
	Tool      string         `json:"tool,omitempty"` // kind "tool": the bound tool's name
	Op        string         `json:"op,omitempty"`   // kind "tool": the operation
	Text      string         `json:"text,omitempty"`
	Path      string         `json:"path,omitempty"`
	Content   string         `json:"content,omitempty"`
	Condition int            `json:"condition,omitempty"`
	Met       bool           `json:"met,omitempty"`
	Proof     string         `json:"proof,omitempty"`
	Question  string         `json:"question,omitempty"`
	Action    string         `json:"action,omitempty"`
	Target    string         `json:"target,omitempty"`
	Params    map[string]any `json:"params,omitempty"`
	Duration  string         `json:"duration,omitempty"`
}

// CapabilitySpec is what a package needs, may use, and refuses.
type CapabilitySpec struct {
	Required []string `json:"required"`
	Optional []string `json:"optional,omitempty"`
	Denied   []string `json:"denied,omitempty"`
}

// HarnessSpec names enforcement features, never providers. Overlays map an
// adapter name to a file of provider-specific tuning inside the package.
type HarnessSpec struct {
	Requires []string          `json:"requires"`
	Overlays map[string]string `json:"overlays,omitempty"`
}

// PlacementSpec says where the package may run.
type PlacementSpec struct {
	Allowed []string `json:"allowed"`
}

// OutputSchemas names JSON Schema files inside the package.
type OutputSchemas struct {
	Default     string            `json:"default"`
	ByProcedure map[string]string `json:"byProcedure,omitempty"`
}

// ---------------------------------------------------------------------
// work-package.v1
// ---------------------------------------------------------------------

// WorkPackage is the immutable contract for one piece of work.
type WorkPackage struct {
	Schema              string      `json:"schema"`
	PackageID           string      `json:"packageId"`
	Issuer              Issuer      `json:"issuer"`
	IssuedAt            string      `json:"issuedAt"`
	ExpiresAt           string      `json:"expiresAt,omitempty"`
	IdempotencyKey      string      `json:"idempotencyKey,omitempty"`
	SupersedesPackageID string      `json:"supersedesPackageId,omitempty"`
	Correlation         Correlation `json:"correlation,omitempty"`

	Agent     AgentRef  `json:"agent"`
	Placement string    `json:"placement"`
	Workspace Workspace `json:"workspace"`

	Objective    string     `json:"objective"`
	Instructions string     `json:"instructions,omitempty"`
	Context      Context    `json:"context,omitempty"`
	Completion   Completion `json:"completion"`

	Capabilities Grants    `json:"capabilities"`
	Authority    Authority `json:"authority,omitempty"`
	Approval     *Approval `json:"approval,omitempty"`
	OutputSchema string    `json:"outputSchema,omitempty"`
}

// Issuer says who minted the package. Kind is "local" for standalone use
// and otherwise names the issuing system; the runtime treats both alike.
type Issuer struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
	URL  string `json:"url,omitempty"`
}

// Correlation carries the issuer's own references, opaque to the runtime.
type Correlation struct {
	Refs []Ref `json:"refs,omitempty"`
}

// Ref is one opaque correlation reference.
type Ref struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

// AgentRef pins which package must do the work.
type AgentRef struct {
	ID      string `json:"id"`
	Version string `json:"version,omitempty"`
	Digest  string `json:"digest,omitempty"`
}

// Workspace is where the work happens. Ownership "caller" means the caller
// owns commits and landing; the runtime only edits.
type Workspace struct {
	Kind      string `json:"kind"`
	Path      string `json:"path,omitempty"`
	Branch    string `json:"branch,omitempty"`
	Ownership string `json:"ownership"`
}

// Context is what the agent is told beyond the objective.
type Context struct {
	Lines       []string     `json:"lines,omitempty"`
	Attachments []Attachment `json:"attachments,omitempty"`
}

// Attachment is a file the caller makes available.
type Attachment struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256,omitempty"`
	URI    string `json:"uri,omitempty"`
}

// Completion is what done means, in the caller's order. The receipt's
// conditions align to these by index and the order is never changed.
type Completion struct {
	Conditions       []string `json:"conditions"`
	ExpectedEvidence []string `json:"expectedEvidence,omitempty"`
	Landing          string   `json:"landing,omitempty"`
}

// Grants are the capabilities the caller allows and the limits it sets.
type Grants struct {
	Granted []string `json:"granted"`
	Limits  Limits   `json:"limits"`
}

// Limits bound spend, turns, wall clock and network.
type Limits struct {
	MaxUSD   float64 `json:"maxUsd,omitempty"`
	MaxTurns int     `json:"maxTurns,omitempty"`
	Timeout  string  `json:"timeout,omitempty"`
	Network  string  `json:"network,omitempty"`
}

// Authority is the caller's prose authority block, carried verbatim.
type Authority struct {
	May              []AuthorityGrant `json:"may,omitempty"`
	MayNot           []string         `json:"mayNot,omitempty"`
	ApprovalRequired []string         `json:"approvalRequired,omitempty"`
}

// AuthorityGrant is one scoped permission in prose.
type AuthorityGrant struct {
	Capability string `json:"capability"`
	Scope      string `json:"scope,omitempty"`
}

// Approval binds this package to one exact approved action. The runtime
// recomputes ParamsHash from Params and also checks the operation it is
// about to perform against Action, Target and Params before performing it.
type Approval struct {
	ProposalRef string         `json:"proposalRef"`
	ApprovalRef string         `json:"approvalRef"`
	ApprovedBy  string         `json:"approvedBy"`
	Action      string         `json:"action"`
	Target      string         `json:"target,omitempty"`
	Params      map[string]any `json:"params"`
	ParamsHash  string         `json:"paramsHash"`
}

// ---------------------------------------------------------------------
// work-directive.v1
// ---------------------------------------------------------------------

// WorkDirective is one ordered in-flight instruction.
type WorkDirective struct {
	Schema      string           `json:"schema"`
	DirectiveID string           `json:"directiveId"`
	PackageID   string           `json:"packageId"`
	RunRef      string           `json:"runRef,omitempty"`
	Seq         int              `json:"seq"`
	Issuer      Issuer           `json:"issuer"`
	IssuedAt    string           `json:"issuedAt"`
	Kind        string           `json:"kind"`
	Payload     DirectivePayload `json:"payload,omitempty"`
	Digest      string           `json:"digest"`
}

// DirectivePayload is the instruction body.
type DirectivePayload struct {
	Text     string `json:"text,omitempty"`
	AnswerTo string `json:"answerTo,omitempty"`
	Reason   string `json:"reason,omitempty"`
}

// ---------------------------------------------------------------------
// run-event.v1
// ---------------------------------------------------------------------

// RunEvent is one line of progress, including directive acknowledgements.
type RunEvent struct {
	Schema    string         `json:"schema"`
	EventID   string         `json:"eventId"`
	PackageID string         `json:"packageId"`
	RunID     string         `json:"runId"`
	Attempt   int            `json:"attempt"`
	Seq       int            `json:"seq"`
	At        string         `json:"at"`
	Kind      string         `json:"kind"`
	Payload   map[string]any `json:"payload,omitempty"`
}

// ProtocolError is the one frame that is not a run event: the input could
// not be understood well enough to name a package, so no receipt exists.
type ProtocolError struct {
	Schema  string `json:"schema"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Line    int    `json:"line,omitempty"`
}

// ---------------------------------------------------------------------
// run-receipt.v1
// ---------------------------------------------------------------------

// RunReceipt is the immutable report of one run of one package.
type RunReceipt struct {
	Schema              string      `json:"schema"`
	ReceiptID           string      `json:"receiptId"`
	PackageID           string      `json:"packageId"`
	SupersedesPackageID string      `json:"supersedesPackageId,omitempty"`
	RunID               string      `json:"runId"`
	Issuer              Issuer      `json:"issuer"`
	Correlation         Correlation `json:"correlation,omitempty"`

	// PackageDigest is the digest of the canonical WorkPackage exactly as
	// the runtime received it; ConditionsDigest is the digest of its
	// ordered completion conditions. Together they let the issuer prove
	// the receipt answers the package it issued, condition by condition.
	PackageDigest    string `json:"packageDigest"`
	ConditionsDigest string `json:"conditionsDigest"`
	// Continues links a continuation run to the terminal receipt it
	// continues from, when a blocked run was answered later.
	Continues *Continuation `json:"continues,omitempty"`

	Agent    AgentRef    `json:"agent"`
	Harness  HarnessInfo `json:"harness"`
	Attempts []Attempt   `json:"attempts"`

	Directives         DirectiveSummary `json:"directives"`
	InstructionHistory HistoryRef       `json:"instructionHistory"`
	Events             EventSummary     `json:"events"`

	StartedAt string `json:"startedAt"`
	EndedAt   string `json:"endedAt"`

	Status     string           `json:"status"`
	Summary    string           `json:"summary,omitempty"`
	BlockedOn  string           `json:"blockedOn,omitempty"`
	Conditions []ConditionProof `json:"conditions"`
	Evidence   Evidence         `json:"evidence"`
	Cost       Cost             `json:"cost"`
	Stop       *StopInfo        `json:"stop,omitempty"`
	Denied     *DenialInfo      `json:"denied,omitempty"`
	Uncertain  []string         `json:"uncertain,omitempty"`

	ReceiptDigest string     `json:"receiptDigest"`
	Signature     *Signature `json:"signature,omitempty"`
}

// Continuation links a run to the terminal receipt it continues.
type Continuation struct {
	RunID         string `json:"runId"`
	ReceiptID     string `json:"receiptId"`
	ReceiptDigest string `json:"receiptDigest"`
	Attempts      int    `json:"attempts"` // attempts already spent before this run
}

// HarnessInfo names what executed the work.
type HarnessInfo struct {
	Adapter     string   `json:"adapter"`
	Version     string   `json:"version,omitempty"`
	Procedure   string   `json:"procedure,omitempty"`
	SessionRefs []string `json:"sessionRefs,omitempty"`
}

// Attempt is one harness invocation within the run.
type Attempt struct {
	N          int    `json:"n"`
	Adapter    string `json:"adapter"`
	StartedAt  string `json:"startedAt"`
	EndedAt    string `json:"endedAt"`
	EndReason  string `json:"endReason"`
	SessionRef string `json:"sessionRef,omitempty"`
	Cost       Cost   `json:"cost"`
}

// DirectiveSummary records what happened to every directive.
type DirectiveSummary struct {
	Received   []string            `json:"received"`
	Applied    []string            `json:"applied"`
	Rejected   []RejectedDirective `json:"rejected"`
	Duplicates []string            `json:"duplicates,omitempty"`
	Gaps       []SequenceGap       `json:"gaps,omitempty"`
}

// RejectedDirective is a directive the runtime refused, and why.
type RejectedDirective struct {
	DirectiveID string `json:"directiveId"`
	Reason      string `json:"reason"`
}

// SequenceGap records that a directive was applied although an earlier
// sequence number was never seen. Only stop may do this.
type SequenceGap struct {
	DirectiveID string `json:"directiveId"`
	ExpectedSeq int    `json:"expectedSeq"`
	ReceivedSeq int    `json:"receivedSeq"`
}

// HistoryRef points at the durable applied-instruction history.
type HistoryRef struct {
	URI    string `json:"uri,omitempty"`
	Digest string `json:"digest"`
}

// EventSummary counts what was emitted and what had to be coalesced.
type EventSummary struct {
	Emitted   int `json:"emitted"`
	Coalesced int `json:"coalesced"`
}

// ConditionProof is one completion condition as the run answered it.
type ConditionProof struct {
	Met   bool   `json:"met"`
	Proof string `json:"proof,omitempty"`
}

// Evidence is what the runtime can show at the moment it ends. It never
// contains a commit: committing is the caller's act and its evidence.
type Evidence struct {
	FilesChanged   []string            `json:"filesChanged,omitempty"`
	Artifacts      []Artifact          `json:"artifacts,omitempty"`
	ExternalAction *ExternalAction     `json:"externalAction,omitempty"`
	ApprovalCheck  *ApprovalCheck      `json:"approvalCheck,omitempty"`
	Denials        []string            `json:"denials,omitempty"`
	Errors         []string            `json:"errors,omitempty"`
	NoChange       bool                `json:"noChange,omitempty"`
	ToolCalls      []ToolCall          `json:"toolCalls,omitempty"`
	Proposal       *DeploymentProposal `json:"proposal,omitempty"`
}

// ToolCall records one bounded tool invocation a procedure made: the
// tool, the operation, the validated parameters, the exact argument
// vector, and how it ended. Output is kept redacted and capped in the
// run's events, never here in full.
type ToolCall struct {
	Tool        string            `json:"tool"`
	Op          string            `json:"op"`
	Capability  string            `json:"capability"`
	Params      map[string]string `json:"params,omitempty"`
	Argv        []string          `json:"argv,omitempty"`
	Ok          bool              `json:"ok"`
	ExitCode    int               `json:"exitCode"`
	DurationMs  int64             `json:"durationMs"`
	Unavailable string            `json:"unavailable,omitempty"`
	Summary     string            `json:"summary,omitempty"`
	OutputSHA   string            `json:"outputSha256,omitempty"`
}

// ---------------------------------------------------------------------
// deployment-proposal.v1
// ---------------------------------------------------------------------

// DeploymentProposal is the immutable record of a deployment PLAN: what
// would be done, to what, at which exact revision, under which engine,
// with which checks performed and which not. It is evidence of planning,
// never an approval and never a claim that anything happened. A future
// execution boundary validates an approval against this document's
// digest and the current state before it does anything.
//
// The engine-owned sections are carried as the engine wrote them
// (deployment-plan.v1), so the plan's meaning is the engine's alone.
type DeploymentProposal struct {
	Schema              string         `json:"schema"`
	ProposalID          string         `json:"proposalId"`
	PackageID           string         `json:"packageId"`
	SupersedesPackageID string         `json:"supersedesPackageId,omitempty"`
	Agent               AgentRef       `json:"agent"`
	Operation           string         `json:"operation"`
	Status              string         `json:"status"` // planned | blocked
	Question            string         `json:"question,omitempty"`
	Service             string         `json:"service,omitempty"`
	Target              string         `json:"target,omitempty"`
	TargetHost          map[string]any `json:"targetHost,omitempty"`
	Repository          map[string]any `json:"repository,omitempty"`
	Revision            map[string]any `json:"revision,omitempty"`
	Manifest            map[string]any `json:"manifest,omitempty"`
	Engine              map[string]any `json:"engine,omitempty"`
	Observed            map[string]any `json:"observed,omitempty"`
	Operations          []any          `json:"operations,omitempty"`
	Checks              []any          `json:"checks,omitempty"`
	Unperformed         []string       `json:"unperformed"`
	Blockers            []string       `json:"blockers"`
	Health              map[string]any `json:"health,omitempty"`
	Rollback            map[string]any `json:"rollback,omitempty"`
	EngineCommands      []any          `json:"engineCommands,omitempty"`
	ObservedAt          string         `json:"observedAt"`
	ProposalDigest      string         `json:"proposalDigest"`
}

// Artifact is a file the run produced.
type Artifact struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	URI    string `json:"uri,omitempty"`
}

// ExternalAction is the record of an approved action actually performed.
type ExternalAction struct {
	ProposalRef string         `json:"proposalRef"`
	ApprovalRef string         `json:"approvalRef"`
	Action      string         `json:"action"`
	Target      string         `json:"target,omitempty"`
	Params      map[string]any `json:"params"`
	PerformedAt string         `json:"performedAt"`
	Result      string         `json:"result,omitempty"`
}

// ApprovalCheck says what the runtime verified before an approved action.
type ApprovalCheck struct {
	ParamsHashMatched bool   `json:"paramsHashMatched"`
	OperationMatched  bool   `json:"operationMatched"`
	Detail            string `json:"detail,omitempty"`
}

// Cost is spend, cumulative where it appears on the receipt.
type Cost struct {
	USD    float64 `json:"usd"`
	Turns  int     `json:"turns"`
	Tokens int     `json:"tokens"`
	// Basis says where the figures come from, so a zero is never read as
	// "free" when it means "unknown": none (no model was used; the run
	// was deterministic), harness (reported by the harness), unreported
	// (a harness ran but reported no cost), mixed (attempts differ).
	Basis string `json:"basis,omitempty"`
}

// Cost bases.
const (
	CostNone       = "none"
	CostHarness    = "harness"
	CostUnreported = "unreported"
	CostMixed      = "mixed"
)

// StopInfo says who stopped the run and why.
type StopInfo struct {
	Issuer      Issuer `json:"issuer"`
	At          string `json:"at"`
	Reason      string `json:"reason,omitempty"`
	DirectiveID string `json:"directiveId,omitempty"`
}

// DenialInfo says why the runtime refused to execute.
type DenialInfo struct {
	Reason  string   `json:"reason"`
	Details []string `json:"details,omitempty"`
}

// Signature is an ed25519 signature over a digest string.
type Signature struct {
	KeyID     string `json:"keyId"`
	Algorithm string `json:"algorithm"`
	Value     string `json:"value"`
}
