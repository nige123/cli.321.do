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

## Harness hooks

A harness that runs a command before a session starts, before an edit and
before a turn ends can insist on a protocol's mechanical steps. The command
is somebody else's (iz4's `iz4 hook`, say: JSON on stdin, text for the model
on stdout, exit 2 to refuse). 321 knows the harnesses' settings files, event
names and quirks, so it writes the wiring and keeps up with them:

```
321 hooks install --workspace . --command "iz4 hook" [--strict] [--json]
321 hooks status  --workspace . --command "iz4 hook" [--json]
321 hooks remove  --workspace . --command "iz4 hook" [--json]
```

Install merges: every setting and every hook that is not ours is kept, ours
are replaced, and a second install changes nothing. Session start is always
wired; `--strict` wires pre-edit and stop, the two that refuse. The record
each command prints, one per harness, says which events are wired and
whether the harness enforces them (pre-edit and stop can refuse) or only
advises (session start can only inject). Only Claude Code is known in this
release, and the wiring it writes is exactly what `iz4 agent install
--hooks --strict` writes, so the two agree. `321 doctor --json` reports the
same per adapter, beside what each enforces.

## The IZ4 protocol on a run

When a package's workspace keeps an IZ4 (the file, in the workspace or a
parent up to the repository root) and `iz4` is on PATH (or named by
`X321_IZ4`), every model-driven run is under the IZ4 protocol:

- before the first attempt, the packet `iz4 agent packet` prints goes into
  the prompt, under "Project intent (IZ4)", ahead of the work, marked as
  project data and not instructions; if the IZ4 changes between attempts
  it is re-read, and the history records both;
- a run that ends completed or no_change is checked with `iz4 hook stop`
  against its summary: a run that changed files and gave no per-invariant
  report ends **blocked**, not completed, with the reason in `blockedOn`;
- the invariants the report itself marks uncertain or conflicting are
  listed under `uncertain` on the receipt.

Procedures (no model) are outside it. When the workspace keeps an IZ4 and
iz4 is not installed, the run is not blocked, and the receipt says under
`uncertain` that the protocol was not applied. The runtime never reads the
IZ4 itself: it runs `iz4` and treats its output as data.

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
lib/Do321/Hooks        harness hook wiring and the doctor's JSON
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

## Intent

`IZ4` beside this file says what the runtime is for, who it is for, and the
invariants that must remain true. Run `iz4 invariants` before changing
behaviour; a change to what must remain true goes into `IZ4` first.
