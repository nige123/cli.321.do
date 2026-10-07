# 321

`321` is a free, harness-agnostic agent runtime and its command-line front
door. It accepts a neutral work package, loads an agent package, selects a
capable installed harness adapter or a deterministic procedure, enforces
capability grants and exact approvals, executes with ordered in-flight
directives, and emits run events and an immutable receipt.

The runtime and the public protocols here are Apache-2.0. Agent packages are
separate products with their own licences; none of them live in this
repository. The runtime hard-codes no agent name.

```
321 <agent> <request words...>            a configured agent, by alias
321 <publisher-domain>/<agent> <request>   the same, by canonical id
321 run --package <file|->                 machine invocation over NDJSON
```

Standalone use needs no account, database or network service. When a work
system delegates a package, that system remains the owner of the work: the
runtime never interprets its correlation references and never touches its
records.

## Building

The runtime is written in Raku and ships as one standalone file per
system, built with Raku++ (`rakupp`, github.com/ash/rakupp), the same way
`iz4` is. It links no third-party library and needs nothing installed on
the machine that runs it.

```
rakupp -I lib bin/321 version                              # run from source
prove --ext .rakutest -e 'rakupp -Ilib' t/                 # the suite
rakupp -I lib --aot --standalone bin/321 -o dist/321       # one file
DO321_TEST_BIN=$PWD/dist/321 prove --ext .rakutest -e 'rakupp -Ilib' t/   # the suite against it
```

`.github/workflows/binaries.yml` builds `321-linux-x86_64`,
`321-linux-aarch64`, `321-macos-universal` and `321-windows-x64.exe` with a
pinned, checksum-verified Raku++, proves each file runs alone, runs the
suite against it, and on a `v*` tag publishes them as a GitHub release with
a `.sha256` beside each. During development invoke the binary by its build
path. Nothing here installs anything onto `PATH`.

## Identity

An agent's canonical identity is `<publisher-domain>/<name>`, for example
`example.test/helper`. Version and content digest are separate fields and
never part of the identity. A package with no publisher carries a
`local/<name>` identity and is always shown as unverified.

A manifest's publisher domain is a claim. Trust comes only from the loading
runtime's own configuration, described next.

The runtime is format-neutral about names: any name of two to thirty-two
lowercase letters or digits is accepted. Naming policy, such as who may use
digits or what is confusingly similar to whom, belongs to the systems that
seat packages, not to the runtime.

## Trust and aliases: `~/.321/trust.json`

Everything the runtime will run is configured by an administrator in
`~/.321/trust.json` (`X321_TRUST` overrides the path). See
`schemas/trust-config.v1.json`.

```json
{
  "schema": "trust-config.v1",
  "publishers": {
    "example.test": {
      "keys": [ { "keyId": "3f2a…", "publicKey": "<base64 ed25519>" } ],
      "packages": {
        "helper": { "path": "/opt/agents/example.test/helper", "version": "1.2.0",
                    "digest": "sha256:…" }
      }
    },
    "dev.example": {
      "packages": {
        "draft": { "path": "/home/me/agents/draft", "version": "0.1.0",
                   "digest": "sha256:…", "trust": "development" }
      }
    }
  },
  "local": { "scratch": { "path": "/home/me/agents/scratch" } },
  "aliases": { "helper": "example.test/helper", "draft": "dev.example/draft" },
  "policy": {
    "capabilityCeiling": ["repo.read", "repo.write", "shell.run", "model.text"],
    "limits": { "maxUsd": 5, "maxTurns": 60, "timeout": "30m" },
    "adapters": { "preferred": ["claude_code"] }
  }
}
```

Three trust levels exist, and a loaded package always says which it holds:

- **verified**: a publisher pin whose digest matches the content and whose
  `SIGNATURE` verifies against one of the publisher's pinned keys. The default
  for a publisher pin.
- **development**: a publisher pin with `"trust": "development"`. The digest
  must match; no signature is required; the package is labelled *unsigned,
  administrator-pinned* and is never reported as verified. This is how an
  unsigned package that declares a real publisher domain is used before it is
  signed.
- **local**: an unsigned `local/<name>` package, by path in the `local`
  section or by `--package-dir`. No publisher, no claim.

A manifest that declares a publisher domain cannot be loaded by path or as a
local package; the error tells you to pin it under that publisher. Its
identity is never rewritten to `local/<name>`.

Resolution of what a person types:

1. A name containing `/` is a canonical id and is looked up directly.
2. Otherwise the name must be an entry in `aliases`. A bare name that merely
   matches a configured publisher package is an error naming the canonical
   id, so that nothing is ever inferred from package contents.
3. A bare name that names an entry in `local` and nothing else resolves to
   `local/<name>`.
4. Anything ambiguous is an error listing the candidates.

Aliases are never replaced silently: there is no install command in this
release, and the configuration is edited by hand. An alias may not shadow a
reserved command (`run`, `agents`, `packages`, `trust`, `doctor`, `help`,
`version`).

Key rotation and ownership changes are explicit edits to this file. A new
owner of a domain inherits nothing in an existing installation.

### Not built in this release, deliberately

Package downloading, `install` and `update` commands, online publisher
enrolment (domain verification), a registry service, and receipt signing by
a worker key. Their boundaries are: enrolment would add keys under
`publishers.<domain>.keys` after a DNS or `.well-known` challenge;
installation would add a pin and, only with an explicit flag, an alias. Both
would write this same file and nothing else.

## Agent packages

A package is a directory with `agent.json` at its root (see
`schemas/agent-package.v1.json`), the files it references, a `DIGEST` file,
and optionally a `SIGNATURE` file. The unbranded fixtures under
`testdata/packages/` are complete examples.

The digest is sha256 over a canonical listing: every regular file except
`DIGEST`, `SIGNATURE` and `.git`, paths in forward-slash form sorted
bytewise, each contributing `<path>\0<sha256 of bytes>\n`. Symlinks,
absolute paths and anything resolving outside the root are refused, not
skipped. `321 packages digest <dir> --write` records it; `321 packages
validate <dir>` checks the manifest, every referenced file and the digest.

The signature is ed25519 over the digest string, stored as JSON
`{ "keyId", "algorithm": "ed25519", "value" }`. The key id is the first
sixteen hex characters of the sha256 of the public key. No signing command
ships here: signing is the publisher's own step with its own key handling.

Loading never executes anything in a package and never follows a reference
outside the package root.

A package declares capability requirements (`repo.read`, `repo.write`,
`shell.run`, `net.fetch`, `files.read`, `files.write`, `model.text`,
`deploy.read`, `deploy.plan`, `deploy.invoke`) and enforcement features it
requires of a harness, never a provider. Provider-specific tuning goes in `harness.overlays.<adapter>`.

A package may carry deterministic **procedures**: a predicate over the
objective and a list of steps that run with no model. A matching procedure
is chosen before any adapter, runs under the same grants and approval gate,
and produces the same receipt. Named groups in the predicate are captured
for the procedure's tool steps. A package whose last procedure matches
everything and blocks with a question is deterministic by construction: no
adapter is ever selected for it, and an unknown request is an explicit
unsupported answer, not a model's guess.

## Authority

Effective grants are the intersection of what the caller granted, the local
`policy.capabilityCeiling`, and the package's own declarations (its
`denied` list is removed; its `required` list must be present or the run is
denied). Neither prompt text, agent text nor a directive can widen them.

Adapters report what they actually enforce (`321 doctor`). From the grants
the runtime derives what must be enforced, for example: tools granted means
`tool_allowlist`; `shell.run` granted while agent network access is not
`open` means `network_deny`, because an unrestricted shell reaches the
network. If no installed adapter enforces everything required, the run is
denied with the reasons. There is no fallback to a less restricted run.

`limits.network` distinguishes agent-controlled network access from the
harness's own connection to its model provider: `provider_only` (the
default) allows the latter only.

Network authority is separate from shell authority. `shell.run` never
implies network access: the agent's network mode comes only from an
explicit grant (`--network open` at the terminal, `limits.network` in an
issued package, or local policy). With a shell granted and no open network,
an adapter that cannot deny the network to that shell is refused. The
default is `provider_only`.

An approved external action is checked before it happens: the runtime
recomputes `paramsHash` from `approval.params` and compares the operation it
is about to perform, action, target and params, with the approval. A hash
match alone is not enough. A standalone request carries no approval, so an
action that needs one stays blocked.

## Directives, replacement and receipts

While a run is in flight the caller may send ordered `work-directive.v1`
frames: `clarify`, `steer`, `pause`, `resume`, `stop`. Each is acknowledged
twice: `directive_received` when durably queued and `directive_applied` when
actually in effect, or `directive_rejected` with a reason. Duplicates by id
or sequence are acknowledged as `directive_duplicate` and applied once.

Ordinary directives wait for their predecessors; a gap that never fills is
reported at the end. `stop` never waits: it is applied as soon as it is
authenticated, the gap is recorded on the receipt, and it does not depend on
stdout draining or any buffer.

Adapters that cannot take a directive live still never drop it. With
session continuation the current attempt is ended gracefully and a new
attempt resumes the session with the accumulated instructions; without it,
the attempt finishes and a continuation attempt follows. Pause on such an
adapter ends the attempt and is acknowledged as applied only once the
process has ended; resume starts a new attempt. Continuation always stays on
the configured harness. Budgets are cumulative across attempts.

A change to objective, conditions, authority, workspace, grants, limits or
approved parameters is not a directive: it is a new immutable package with
`supersedesPackageId`. The old run is stopped with that reason; the receipt
records it.

A run that ended `blocked` can be continued once its question is answered:
`321 run --continue <old receipt>` with the SAME package and a `clarify`
directive. The contract is unchanged; attempt numbering, cumulative cost and
the harness session carry forward (the session only on the same adapter);
the old receipt is untouched and the new one links it under `continues`. A
receipt from a different package, or one whose digest no longer matches,
cannot be continued.

The receipt (`schemas/run-receipt.v1.json`) describes the runtime outcome at
the moment it ended: package and agent digests, adapter and session refs,
every attempt, every directive's disposition, the instruction history by
reference and digest, conditions aligned by index to the package's
completion conditions, evidence, cumulative cost, and stop or denial
details. Its `packageDigest` is the digest of the package exactly as the
runtime received it and `conditionsDigest` the digest of the ordered
condition list, so the issuer can prove the receipt answers the package it
issued, condition by condition. Its `receiptDigest` is over its own
canonical content.

## Tools, deployment planning and the execution boundary

A package's deterministic procedure may reach an external program through
a **tool step** (`{"kind":"tool","tool":"dp","op":"plan",
"params":{...}}`). A tool is bound by explicit configuration, never by a
command name on PATH, and exposes named operations that each carry their
own capability: `dp` offers `status` (`deploy.read`), `plan`
(`deploy.plan`) and `execute` (`deploy.invoke`). The runtime checks the
grant per operation, substitutes named captures from the procedure's
`objectiveRegex` into the declared parameters, validates every value
against a strict pattern (a `group.name` service, a target word, a commit
sha of 7 to 40 hex characters), builds an argument vector, runs the
executable with no shell, bounds the output, redacts anything that looks
like a credential, and records the call on the receipt (`evidence.toolCalls`).
An unknown parameter, an unsupported operation or a value that does not
match its pattern is refused before anything runs.

- `DP_BIN` names the deployment engine's entry point
  (deploy.321.do's `bin/dp`). Unset, the tool is present but not
  configured and a procedure that needs it fails saying so. `321 doctor`
  prints the binding.
- `DP_EXECUTE` names, as a comma-separated list, the targets on
  which an APPROVED deployment may be executed through the engine's own
  `go <service> <target>`. Unset, execute is unavailable: the call is
  recorded as not performed and the run ends blocked: "execution is
  unavailable here (DP_EXECUTE is unset)". A target not listed is refused before
  the engine is invoked; the engine's own words decide success (a failed
  gate, an aborted deploy or a rollback is a failure whatever the exit
  code). This is the executor the boundary below calls.
- A `plan` becomes a **deployment-proposal.v1** on the receipt
  (`evidence.proposal`, and `proposal.json` beside a standalone run's
  receipt): the engine-owned sections verbatim (exact revision, manifest
  digest, engine revision, observed state, ordered operations, checks
  performed and NOT performed, blockers, health, rollback), the package and
  agent that produced it, and `proposalDigest` over the canonical document.
  It is evidence of planning, never an approval, and never a claim that
  anything happened. A blocked plan (an ambiguous target, an unreachable
  host, an unresolvable revision) is recorded as a blocked proposal with the
  question.
- `execute` is performed only by a bound **executor**, which `DP_EXECUTE`
  supplies (the tests bind a recording fake). Without one, a supplied
  approval or a `deploy.invoke` grant changes nothing. Where an executor is
  bound, the **execution boundary** applies: the package must carry an `approval`
  whose `proposal` is the approved deployment proposal verbatim (its digest
  equal to `params.proposalDigest`), `deploy.invoke` must be granted, a
  fresh plan of the same target must immediately precede the execute step,
  and `tool.MatchApproval` must hold against that fresh observation: same
  service and target, the approved parameters' hash, the approved revision
  still resolving, the manifest digest and the deployed revision unchanged
  since the approved plan. Any of these failing is `approval_mismatch` with
  the reason on the receipt and nothing executed. Changed parameters mean a
  new proposal and a renewed approval.
- **Who approves a standalone `321 <agent> go`.** A person typing it at a
  terminal is the approval: the runner plans first, mints an `operator/`
  approval bound to that plan and grants `deploy.invoke`. Unattended (no
  terminal, or `--non-interactive`, as when an agent session in another
  repository deploys its work), nothing is assumed: the go is approved only
  by a **standing approval** the administrator wrote into local policy,
  matching the planned `service@target` (either side may be `*`):

  ```json
  "policy": {
    "standingApprovals": [
      { "action": "deploy", "targets": ["*@dev", "*@live"], "approvedBy": "nige" }
    ]
  }
  ```

  The approval it mints carries a `standing/` ref and names the approver
  ("nige (standing approval in local policy)"), and it is bound to the exact
  plan like any other. `DP_EXECUTE`, the capability ceiling, the fresh
  re-plan comparison and the engine's own gates, health check and rollback
  all still apply. Without a matching standing approval an unattended go is
  refused with `deploy.invoke` not granted, and nothing reaches the engine.
- A package that can never read or write files (no `repo.*`, `files.*` or
  `shell.run` capability) is given no workspace, so the repository the
  terminal happens to be in is never reported as evidence of its run.
- A receipt's `cost.basis` says where the figures come from: `none` (a
  deterministic run, no model), `harness`, `unreported` or `mixed`. A zero
  without a basis is unknown, not free.

The unbranded fixture `testdata/packages/example.test/operator` and the
recording stand-in `testdata/fakeengine/dp` are the public tests
of all of this; the official operator package lives in agents.321.do.

## Canonical JSON

Every digest and every cross-language hash uses one canonical form, stated
in full in `lib/Do321/JSON.rakumod` and pinned by the fixtures under
`testdata/canonical/`: object members sorted by UTF-8 byte order, no
whitespace, strings raw UTF-8 except `\"`, `\\`, `\b \f \n \r \t` and
`\u00xx` for other control characters, integer literals as digits with `-0`
as `0`, other numbers as the shortest round-tripping double in ES6
`Number.prototype.toString` form, and no trailing newline. The Perl consumer
in api.123.do is tested against the same fixture files. `testdata/protocol/`
holds shared positive and negative validation fixtures for both sides.

The runtime edits a caller-owned workspace and never commits. A commit is
the caller's act; the caller records it beside the receipt and links the two
by digest.

Identity concepts, kept distinct: **packageId** is the contract, **runId** the
execution of it, **attempt** a harness invocation within the run,
**receiptId** the report, and a harness **sessionRef** a provider-specific
continuation handle.

## Machine invocation

```
321 run --package <file|-> [--workspace <dir>] [--receipt <file>] [--events <file>]
        [--run-id <id>] [--history-dir <dir>] [--adapter <name>] [--package-dir <dir>]
```

- `--package -`: the first stdin frame is the `work-package.v1`; every later
  frame is a `work-directive.v1`. `--package <file>`: the file is the package
  and stdin carries only directives. The package is never required twice.
- Stdout carries `run-event.v1` frames (acknowledgements included) and then
  exactly one `run-receipt.v1`, last. When no package can be identified, a
  single `protocol-error.v1` frame is emitted instead, no receipt is
  fabricated, and the exit code is 65.
- A malformed directive line is answered with a `protocol-error.v1` naming
  the line; the run continues. Stdin closing means no more directives, not
  stop. SIGTERM and SIGINT are a stop from issuer `signal`.
- Events are buffered (4096). If the reader does not drain, progress-class
  events are coalesced and counted on the receipt; acknowledgements and
  lifecycle events are never dropped. The receipt is always written to
  `--receipt` when given, and stdout gets a bounded time to drain before
  exit.
- Exit codes: 0 completed or no change, 2 blocked, 3 stopped, 4 failed,
  5 denied, 64 usage, 65 malformed input, 70 internal.

## Adapters

- `claude_code`: drives the `claude` CLI in print mode. Enforces the tool
  allowlist (`--permission-mode dontAsk --allowedTools` derived from the
  grants), structured output, turn and spend limits, timeout, event stream,
  session continuation (`--resume`) and graceful stop. Does **not** enforce
  repository scope or network denial when a shell is granted, and cannot
  steer or pause live.
  - **Denial, not a weaker run.** A package that needs what the adapter
    cannot enforce — `shell.run` granted with `limits.network` `none` or
    `provider_only` (the default) — is denied before the harness is
    spawned, and the receipt says why. The only envelope this adapter can
    run B1LL in is therefore an explicit `network: open` in a trusted
    environment; nothing widens that silently.
  - **Steer and pause are boundaries.** A `steer`/`clarify` ends the current
    attempt (SIGTERM, graceful) and the next attempt resumes the harness
    session with the instruction in its prompt; `pause` ends the attempt and
    `resume` starts the next one the same way. A directive is acknowledged
    `applied` only when the attempt that carries it has started — never on
    receipt. The session id is read off the stream's `system/init` event, so
    an attempt interrupted before its result object can still be resumed.
  - `X321_CLAUDE_BINARY` names the harness executable for an isolated test
    environment without touching PATH; `testdata/fakeclaude/claude` is a
    controllable stand-in (`t/08-claudecode.rakutest`).
- `procedure`: the built-in executor for package procedures. Enforces
  everything by construction because it only performs the operations its
  steps name, each checked against the grants, the workspace boundary and
  the approval gate.
- `fake`: the same executor with a script, for tests and dry runs. Hidden:
  selected only by `--adapter fake` or `policy.adapters.preferred`.

## Harnesses, controllers and what protects the work

**321 knows how the harness works. IZ4 knows what must remain true.**

A harness is an agent environment: Claude Code today, others as their
adapters are written. Each one keeps configuration somewhere different,
exposes different lifecycle events, and changes them when it likes. 321 is
where that knowledge lives, for two purposes: a work system such as 123.do
uses it to *run* an agent, and a controller such as IZ4 uses it to *govern*
the environment around that agent.

A controller is something outside the harness that says what must hold while
an agent works. IZ4 is the first. 321 drives IZ4 wherever 321 is present.
IZ4 remains harness-independent and may also be driven directly by native
hooks, CI, Git integrations or other agent environments: 321 only ever runs
the `iz4` command and reads its result documents.

```
123.do    decides what work should happen, and who should do it
321       knows how to run that actor in this environment, which controls the
          harness exposes, and how to install and verify them
IZ4       knows the applicable invariants, whether an action or a change is
          compatible with them, and when a person must decide
```

### What a harness can do

```
$ 321 harness detect
claude_code    detected 2.1.292 (Claude Code)
    project wiring: .claude/settings.json (none yet)
    enforces: authoritative_context, pre_action, pre_tool, filesystem_guard, shell_guard, human_approval, post_run
    advises:  post_action, post_tool
    cannot:   network_guard, pre_commit, post_commit
```

Twelve controls are named (`lib/Do321/Protocol.rakumod`). An adapter gives
each a strength: **enforces** (an answer can stop the thing), **advises**
(text reaches the model and nothing more) or **none**. Anything an adapter
does not declare is none, and a strength outside the vocabulary is none, so
a typo can never read as protection. Controls are separate from the
enforcement features under *Adapters* above: a feature is authority the
adapter enforces for the runtime; a control is a point where a controller
can be told and can answer.

Claude Code can refuse a tool call before it runs, so writes, shell commands
and any other tool call can be intercepted, and a turn's end can be refused.
It cannot see network use from inside a shell command, and has no commit
hook of its own (a commit there is a shell command; Git's own pre-commit
hook is `iz4 gate --install-hook`, outside any harness). At an interactive
session a hook can ask the person to decide; a headless run has nobody to
ask, and `321 harness detect --json` reports both.

### Installing IZ4 into a harness

```
$ 321 iz4 install
IZ4 integration installed (.claude/settings.json).
Project: IZ4 enabled (/repo/IZ4)
Harness: claude_code

Context injection        yes
Filesystem guard         yes
Shell guard              yes
Network interception     no
Commit check             no
Human approval           yes (a guard asks the person at the session)
Post-run verification    yes

Effective enforcement: GUARDED (aware, checked, guarded)

Warning:
  Network interception is not available in claude_code: this harness cannot intercept it.
  Commit check is not available in claude_code: this harness cannot intercept it.
```

```
321 iz4 install [--workspace <dir>] [--harness <name>] [--advisory] [--json]
321 iz4 status  [--workspace <dir>] [--harness <name>] [--json]
321 iz4 remove  [--workspace <dir>] [--harness <name>] [--json]
```

Install detects the harnesses here, asks IZ4 whether one governs the
project, wires in everything the harness can enforce, and then reads the
wiring back: a control that should be there and is not makes the install a
failure, with nothing claimed. It is idempotent. It merges into the
harness's project settings, replacing and removing only its own entries for
that controller: every other setting and every other hook is kept, and a
settings file it cannot parse is not touched. `--advisory` wires the context
only, so nothing is refused; a full install can follow. An install never
takes away a moment that was already covered: `--advisory` over fuller
wiring leaves it as it is, and `321 iz4 remove` is the way to take wiring
out. With no IZ4 in the project, nothing is installed.

**Adopting wiring iz4 wrote itself.** Before iz4 0.15.0, iz4 wrote its own
commands (`iz4 hook session-start`, `pre-edit`, `stop`) into
`.claude/settings.json`. 321 leaves them alone until asked: status reports
them as `Managed by: legacy IZ4 wiring`, at AWARE. `321 iz4 install` then
adopts them, replacing each old command with 321's for the same moment,
once, so nothing runs twice; it reports the action as `adopted`, and
running it again changes nothing.

The hooks 321 writes never call the controller. They call 321:

```
harness event  ->  321 hook <harness> <controller> <control>  ->  iz4 check action | context | verify
```

`321 hook` reads the harness's native event, turns it into a generic action
(operation, target, parameters, repository, recipient, context), asks the
controller, and answers in the harness's own terms. For Claude Code a block
refuses the tool call with the reason; `needs_human` asks the person at an
interactive session, and in a headless run refuses and tells the agent to
put the proposal to a person; a warning lets the call through and says why;
an end of turn that does not pass is refused once, so the agent says what is
outstanding. A controller that cannot be driven lets the call through and
says so on stderr: a visible gap, never a silent pass. When Claude Code
changes its hook mechanism, `lib/Do321/ClaudeHooks.rakumod` changes and IZ4
does not.

### The levels, and what they do not mean

Four facts, reported separately because one can hold without another:

| Level | Means |
|---|---|
| `aware` | the agent was given the controller's context |
| `checked` | a change check ran |
| `guarded` | consequential operations were intercepted before they ran |
| `verified` | the finished result was checked, and passed |

The headline is the strongest of aware, checked and guarded. A status
reports what is *wired*; `verified` is earned by a run and appears only on
its receipt. A context in a prompt is never reported as interception, an
older direct wiring that only delivers the context counts for `aware` and
no more, and none of these is a proof: IZ4 itself says what each check did
not establish, and a natural-language invariant is not verified by a hook.

A harness with fewer controls gets what it has, and the report says what it
lacks:

```
$ 321 iz4 install --harness <one that only advises, and has no tool hooks>
Context injection        yes (advises only)
Filesystem guard         no
Shell guard              no
Post-run verification    yes

Effective enforcement: CHECKED (aware, checked)

Warning:
  Context injection only advises in <harness>: text reaches the model, nothing is refused.
  Filesystem guard is not available in <harness>: this harness cannot intercept it.
```

### What a run does

A model-driven run in a workspace that keeps an IZ4 needs nothing installed
first. 321:

1. asks IZ4 whether one governs the workspace (`iz4 discover`);
2. puts its context in the prompt ahead of the work (`iz4 context`), and
   re-reads it if the IZ4 changes between attempts;
3. uses the harness's interception points: wiring already installed in the
   project is counted, and what is missing is registered **for that run
   alone**, through the harness's own mechanism (`claude --settings`),
   without writing anything into the caller's workspace;
4. reads back a log the hooks write, so the receipt counts the hooks that
   really fired instead of assuming they did;
5. puts the finished work to IZ4 (`iz4 verify --worktree`, with the agent's
   own last words), which includes the change check.

`needs_human` and `block` end the run **blocked**, not completed, with the
proposal a person must decide on, or the reason, in `blockedOn`. A warning
and a check that could not run go on `uncertain`. The runtime never records
a person's agreement, and treats nothing as one: not the agent's text, not
silence, not the run continuing. Agreement is a person running
`iz4 approve` at a terminal.

The receipt carries the evidence under `evidence.controllers`:

```json
{ "name": "iz4", "harness": "claude_code",
  "subject": "/repo/IZ4", "digest": "sha256:9020...",
  "levels": ["aware", "checked", "guarded", "verified"],
  "controls": { "authoritative_context": "in the prompt",
                "filesystem_guard": "registered for this run (enforces)",
                "shell_guard": "registered for this run (enforces)",
                "post_run": "registered for this run (enforces)" },
  "checks": [ { "point": "context", "result": "pass" },
              { "point": "verify/structure", "result": "pass" },
              { "point": "verify/change", "result": "pass" },
              { "point": "verify/report", "result": "pass" },
              { "point": "verify", "result": "pass" } ],
  "hooksFired": 2, "humanDecision": "none was needed" }
```

Which IZ4 applied and its content identity, the harness, how each control
was operated, every check and its result, any gap, and whether a human
decision is outstanding. Procedures (no model) are outside all of this, and
a workspace with no IZ4 runs exactly as it did before. When an IZ4 is there
and `iz4` is missing, too old to be driven, or the IZ4 is invalid, the run
is not blocked: the receipt lists the IZ4 with no level claimed and says
why. `X321_IZ4` names the `iz4` to use and, when set, is the only one used.

### Adding a harness

Supporting a new agent environment means teaching 321 about it. IZ4 does
not change. An adapter (`role Adapter`, `lib/Do321/Adapter.rakumod`) already
says how to detect and launch its harness and which authority features it
enforces. For controllers it adds:

| Method | Says |
|---|---|
| `controls` | each control's strength in this harness; claim only what it really does |
| `headless-controls` | the same for a run 321 launches with nobody at the harness's prompt |
| `wiring-path` | where the harness keeps the wiring in a project |
| `install-controller` | wire a controller in for a set of controls: merge, replace only your own entries, be idempotent, die with a reason when you cannot |
| `remove-controller` | take out only that controller's wiring |
| `verify-controller` | what is really there, read back from the harness's own configuration |
| `translate-event` | a native hook event as a generic `Action` |
| `answer` | a `Verdict` as the exit code and output the harness understands |
| `final-words` | the agent's last words, from the harness's end-of-turn event |
| `can-register-hooks` | whether hooks can be handed over for a single run |

The minimum is `controls`: an adapter that declares none is reported as
having none, and IZ4 is still put in the prompt and verified at the end by
the runtime. Everything else raises what can honestly be claimed. Keep one
harness's knowledge in one module, as `ClaudeHooks.rakumod` does, and test
it against a stand-in: `new-fake(:controls(...))` is a harness with exactly
the controls it is given.

A second controller is a class that does `role Controller`
(`lib/Do321/Controller.rakumod`): `discover`, `context`, `wants`, and
whichever of `check-action`, `check-change` and `verify` it can answer. The
ones it leaves out answer `unavailable`, which is reported as a gap.

### The older hook command

`321 hooks install | status | remove --command "<cmd>"` writes a hook
command of somebody else's straight into a harness's settings (session
start always; pre-edit and stop with `--strict`). It predates controllers
and stays for callers that use it. `321 iz4 install` replaces such wiring
for IZ4 instead of running both.

## Prompt-only runs

`packages/prompt` is a local package for asking a question about a
repository and getting text back with nothing changed: it requires
`repo.read` and `model.text`, denies every write, shell and network
capability, and answers in `summary`. Under Claude Code the tool allowlist
enforces that (no Edit, Write or Bash), and with no shell granted the
default `provider_only` network is enforceable, so the run is admitted; a
harness that could not enforce it would be refused, never given a weaker
run. This is what iz4 hands 321 for suggest, review and test drafting:

```
321 --package-dir packages/prompt --non-interactive --json prompt <the question>
```

The answer is the receipt's `summary`; a `blocked` status carries what was
missing in `blockedOn`.

## Layout

```
schemas/               the canonical protocol documents (JSON Schema 2020-12)
bin/321                the entry point
lib/Do321/JSON         parsing, Go-shaped wire encoding, the canonical form, digests
lib/Do321/Shape        the protocol documents as field tables, in struct order
lib/Do321/Protocol     names, identity, ULIDs, timestamps, validators, document digests
lib/Do321/Ed25519      RFC 8032 in plain Raku, pinned to its test vectors
lib/Do321/Digest       package digest, DIGEST and SIGNATURE files
lib/Do321/Trust        trust configuration, alias resolution, package loading
lib/Do321/Async        a cancellation scope and a mailbox (context and channels)
lib/Do321/Tool         the bounded tool interface, dp, redaction, the execution boundary
lib/Do321/Adapter      adapter interface, selection, procedure/fake, claude_code
lib/Do321/Run          the runner: grants, attempts, directives, receipts
lib/Do321/Wire         the NDJSON machine protocol
lib/Do321/Controller   the controller seam, and the IZ4 driver
lib/Do321/ClaudeHooks  what 321 knows about Claude Code's hooks: wiring, translation, answers
lib/Do321/Enforcement  what is really wired, and the levels it adds up to
lib/Do321/Hooks        the older hook command, and the doctor's JSON
lib/Do321/CLI          the front door
packages/prompt        the local package for prompt-only runs
t/                     the suite; t/lib holds its helpers and the binary seam
testdata/packages      unbranded fixture packages
```

## Decisions

- 2026-09-05: The publisher namespace for official agents is `321.do`; the
  legal owner is Nige Ltd; 123.do is the commercial work system that
  consumes packages. One agent has one canonical identity.
- Configuration under `~/.321` is JSON, because the runtime takes no YAML
  dependency.
- 2026-09-13: The runtime stays in Go. Raku++ (rakupp) was considered for
  building the `321` executable and rejected: it compiles Raku, so it would
  mean rewriting the runtime; Go builds static binaries for every release
  target from one machine, while Raku++ cannot cross-compile and needs
  glibc 2.38 on Linux; and the runtime's concurrency, child processes,
  signal handling and signing are where a young compiler is riskiest.
- 2026-09-27: Reversed by the owner: the runtime moves from Go to Raku++,
  so that 321 and iz4 are built the same way and iz4 can install 321
  beside itself. The port reached parity in one day: every Go test suite
  ported, the shared fixtures and digests byte-identical, a package signed
  by either binary verified by the other, a receipt from either continued
  by the other, `help` and `doctor` byte-identical. Ed25519 is written in
  plain Raku (Raku++ has none). The concerns of 2026-09-13 were met, each
  with a recorded workaround: a process promise settles only inside an
  await, Proc::Async takes no environment (an `env -i` wrapper carries
  one), a Proc's stdin write blocks until the child exits, and `.lines` on
  a pipe waits for EOF. The cost stands: one build per system, and the
  Linux file needs glibc 2.38. The Go tree was removed in the same commit.
- 2026-10-07: Harness knowledge lives in 321, and nowhere else. 321 detects
  agent environments, knows each one's controls, installs, removes and
  verifies a controller's wiring, and translates native events; IZ4 exposes
  a small machine interface and installs itself into no environment. A
  harness changing its hook mechanism changes 321, not IZ4. Enforcement is
  reported as what is really wired or really ran, never more.

## Intent

`IZ4` beside this file says what the runtime is for, who it is for, and the
invariants that must remain true. Run `iz4 invariants` before changing
behaviour; a change to what must remain true goes into `IZ4` first.
