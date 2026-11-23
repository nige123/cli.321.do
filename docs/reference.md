# 321 reference

How the runtime works, in detail: building, identity, trust, packages,
authority, directives and receipts, tools, adapters and harnesses.  The
short version is the [README](../README.md); the screen that watches runs
is [Mission Control](mission-control.md).

## Building

The runtime is written in Raku and ships as one standalone file per
system, built with Raku++ (`rakupp`, github.com/ash/rakupp), the same way
`iz4` is. It links no third-party library and needs nothing installed on
the machine that runs it.

```
rakupp -I lib bin/321 version                              # run from source
prove --ext .rakutest -e 'rakupp -Ilib' t/                 # the suite
rakupp -I lib --aot --standalone bin/321 -o dist/321       # one file
DO_321_TEST_BIN=$PWD/dist/321 prove --ext .rakutest -e 'rakupp -Ilib' t/   # the suite against it
```

`.github/workflows/binaries.yml` builds `321-linux-x86_64`,
`321-linux-aarch64`, `321-macos-universal` and `321-windows-x64.exe` with a
pinned, checksum-verified Raku++, proves each file runs alone, runs the
suite against it, and on a `v*` tag publishes them as a GitHub release with
a `.sha256` beside each. During development invoke the binary by its build
path. Nothing here installs anything onto `PATH`.

`tools/raku-land` makes the package the Raku ecosystem carries: `git archive`
of the release tag, so it holds the tool, its docs and its tests and nothing
`.gitattributes` marks `export-ignore`. `tools/raku-land check` installs that
package with its tests under Raku++ and dry-runs the upload;
`tools/raku-land upload` then asks a person at a terminal before sending it.
Never run a plain `fez upload` here: it sends the whole working tree.

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
`~/.321/trust.json` (`DO_321_TRUST` overrides the path). See
`schemas/trust-config.v1.json`. `321 trust network open` (or `none`,
`provider_only`) writes `policy.limits.network`, the network every run
started on this machine gets unless `--network` says otherwise for one
run; with no value it says what stands. `321 trust now 1` (or any number, or
`none`) writes `policy.now`: how many runs of one agent work at once
here, the rest waiting their turn, oldest first.

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

`321 agents` lists the packages configured here; `321 whois <name>` (or `321 agents <name>`) reads
one of them out for a person choosing between them: what it is for, what
each skill it carries says it does, and what it asks to be allowed and
refuses outright. Every word of that is the package's own, so it says why
you would ask this agent rather than another and never that the agent is
any good. `321 packages show <name>` is the same package as fields -
digest, trust, capability identifiers, placement.

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

The receipt keeps what 321 saw apart from what the agent said:

- The package's done conditions decide whether the work is done, not the
  agent's word. A run that would end `completed` or `no_change` with any
  condition answered unmet, or not answered at all, ends **blocked**, and
  `blockedOn` names them in their own words (`done conditions not met: 1
  of 2 (#2 the tests pass)`), so `--continue` can ask the agent to finish.
  The `met` and `proof` answers are still the agent's own: whenever there
  are conditions, `uncertain` says 321 did not check them. A run with no
  conditions is unaffected.
- `evidence.toolFailures` lists tool results the runtime saw fail on the
  harness's own event stream (`Bash: <error>`, `shell: exit 1`); a few are
  kept and the rest counted. Successful results are not listed.
- A blocked run carries `blockedEvidence`: `observed` when 321 saw the
  blocker itself (unmet conditions, a controller, a procedure step, or a
  failing tool, a denial or an error recorded on the run), `reported` when
  it is the agent's word alone. It records; it never changes the status.

A receipt can also be signed. `321 key new` makes this 321 an Ed25519 key
under `~/.321/key.json` (or `DO_321_HOME`); from then on every receipt it
writes carries `signature` over its `receiptDigest`, and `321 key` shows
the public half for an issuer to pin. `321 receipt verify <file> [--key
<base64>]` checks a receipt's digest against its content and its signature
against that key. Without a key receipts are unsigned, as before; the
digest check does not depend on the signature, and a receipt that was
signed cannot be altered and re-digested without the key.

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
  new proposal and a renewed approval. One case is said as what it is: when
  the fresh plan finds the target already at the approved revision, the run
  ends `no_change` (`already_deployed`), nothing executes, and the approval
  stands; there is nothing to deploy and no plan to make again.
- **Who approves a standalone `321 <agent> go`.** A person typing it at a
  terminal is the approval: the runner plans first, mints an `operator/`
  approval bound to that plan and grants `deploy.invoke`; the run header
  says so in an `approval:` row under the title. Unattended (no
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
  ("nige (standing approval in local policy)"), the header's `approval:`
  row says it was standing, and it is bound to the exact
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

## Choosing how a run is executed

A person names an agent and gives it work. Which model runs it, at what
effort, on which harness, is chosen for the job and written down before
the run starts. Three parts, each with one job:

| Part | Where | Does | Never |
|---|---|---|---|
| Curation | the agent package (`curation.json`) and `Do321::Curate` | reads what kind of work the request is and asks for a size of model and an effort, with reasons | names a vendor's model, grants anything, moves a limit |
| The plan | `Do321::Plan`, in the runtime | picks a harness that enforces the package first, then a model it can run; pins harness version, model, effort and skills under a digest | calls a model to decide |
| Connectors and adapters | `Do321::Models`, `role Adapter` | say what exists: a provider's models and list prices; what a harness can be asked for | appear anywhere else |

There is no model call in a routing decision: curation is rules and
recorded evidence.

```
321 choose b1ll fix the failing test     the plan and its reasons; runs nothing
321 b1ll fix the failing test            run it; the receipt says what it ran on
321 --profile deep b1ll ...              set the profile by hand
321 --model opus --effort high b1ll ...  or the model and the effort
321 models                               what each harness here can be asked for
```

### Curation (`curation.v1`)

One implementation, configured per agent by an optional file the package
manifest names (`"curation": "curation.json"`). An agent without one gets
the default below.

```json
{
  "schema": "curation.v1",
  "profiles": {
    "economy":  { "tier": "small",  "effort": "low" },
    "standard": { "tier": "medium", "effort": "medium" },
    "deep":     { "tier": "large",  "effort": "high" }
  },
  "order": ["economy", "standard", "deep"],
  "default": "standard",
  "tasks": [
    { "type": "read",   "profile": "economy",  "words": ["explain", "summarise", "list", "find", "review"] },
    { "type": "change", "profile": "standard", "words": ["fix", "add", "update", "implement"] },
    { "type": "design", "profile": "deep",     "words": ["design", "refactor", "migrate", "plan"] }
  ],
  "maxEscalations": 1
}
```

- A profile asks for a size class (`small`, `medium`, `large`) and an
  effort (`low` to `max`). The class is what keeps an agent's identity
  when models change: a new model takes its class's place.
- The kind of work is the task whose marking word comes first in the
  request, or `--task`. A request with no marking word gets `default`,
  and the plan says it was not guessed.
- **Evidence.** Earlier runs are comparable when they are by the same
  agent, on the same kind of work, in the same work context. Only runs a
  person gave an outcome (`321 outcome`) are weighed, and not until there
  are three. Under half accepted: one profile up. Four in five accepted on
  the profile below: one down. A budget below what comparable runs cost
  steps down. Runs that reported no cost are never counted as free.
- **Override.** `--task`, `--profile`, `--model`, `--effort` win, and the
  plan lists them under `overrides`. A model named by hand is not climbed
  past.
- Curation cannot carry `grants`, `capabilities`, `limits`, `permissions`
  or `network`, and a profile cannot name a model: such a file is refused
  and the run is denied before it starts.

### The plan (`execution-plan.v1`, on the receipt as `plan`)

`task`, `taskFrom` (`matched`, `stated`, `default`), `profile`, `harness`,
`harnessVersion`, `provider`, `model`, `modelName`, `tier`, `access`,
`effort`, `skills` (name, version, digest), `reasons`, `considered` (each
harness not used, and why), `overrides`, `ladder`, `maxEscalations`,
`escalated`, `evidence` and `planDigest`. Each entry of `attempts` says
the `model`, `effort` and `profile` that attempt ran on.

Order of selection: a harness must be installed, signed in and able to
enforce what the package needs; among those, local policy order; then the
smallest model of the class asked for that the harness reaches. A harness
that cannot take the effort asked for gets the nearest below, and the plan
says so. A run that nothing can execute as asked is denied before any
harness starts.

**Escalation is bounded.** When an attempt ends in a harness failure, the
next attempt moves one step up the plan's own ladder, at most `maxEscalations` times, never past
`limits.maxUsd`, never after an external action, and never when the run is
blocked on a person. The step and its reason are recorded in
`plan.escalated`; the next attempt is told not to repeat what was done.
An unmet done condition does not climb by default: it is as often
something missing on the machine as a model too small, and a larger model
cannot install it. An agent's curation may opt in with
`"escalateOn": ["harness_failure", "unmet_conditions"]`.

**Three different facts, kept apart.** `conditions[].met` is the agent's
own report. `evidence` is what the runtime observed (files changed, tool
calls, exit codes). `321 outcome accepted|corrected|rejected` is the
person's word, kept beside the receipt and never written into it.

### Cost

`cost.usd` on a receipt is what the harness reported (`cost.basis`
`harness`). A harness that reports none is `unreported`, shown as unknown.
List prices in `321 models` are for estimates only and are never added to
a receipt. A saving is only ever stated against a named baseline
(`321 value`).

### Adding a model provider

One file in `~/.321/models/`, and nothing else changes:

```json
{
  "schema": "model-connector.v1",
  "provider": "acme",
  "access": "harness",
  "auth": { "kind": "harness_login", "reference": "the harness signs in" },
  "pricing": { "asOf": "2026-11-01", "source": "acme.example/pricing" },
  "models": [
    { "id": "acme-mini", "alias": "mini", "tier": "small", "contextTokens": 200000,
      "efforts": ["low", "medium"], "price": { "input": 0.05, "output": 0.20 } }
  ]
}
```

`access` is `harness` when the harness signs in and calls the provider
itself, which is every connector built in: 321 holds no key and runs no
inference proxy. `runtime` is for a provider 321 itself would call; such a
connector is listed and no run is placed on it until an adapter drives it.
`auth.reference` names where a credential is kept (an environment
variable, a keychain entry); a connector that carries a key, token or
secret is refused. Leave `price` out when it is not known: the model is
then never used for a cost estimate. `321 models` shows the result, and
names any file it left out and why. The shared checks are in
`t/40-plan.rakutest` ("adding a provider is one file").

### Adding a harness for runs

The short way, for a command-line agent, is one class on `CommandHarness`:
[harness-authors.md](harness-authors.md) walks through it, from a template to a
pull request. What follows is the whole contract.

Beyond `detect`, `enforcement` and `run`, an adapter says what it can be
asked for, in `manifest`:

```raku
method manifest(--> Hash) {
    %( providers => ['acme'],        # model-connector providers it reaches
       access => 'harness',          # it signs in and calls the provider itself
       sets-model => True,           # a model can be named for one run
       efforts => [<low medium>],    # the effort settings it takes, least first
       reports => %( usd => False, tokens => True ),
       spend-cap => False )          # whether it holds a money limit itself
}
method executable(--> Str)  { ... }  # its executable as found here
method command-name(--> Str) { 'acme' }
method help-argv(--> List)  { ('run', '--help') }
method flags-used(--> List) { <--model --json> }
```

`run` receives `Spec.model` and `Spec.effort` (empty means the harness's
own default) and puts them on its command line. Claim only what the
harness does: `reports.usd` false makes every run there cost `unreported`;
no `pause` or `live_steer` in `enforcement` makes a hold or a steer end
the attempt and resume it, which the receipt records. The shared contract
is exercised by a stand-in in `t/40-plan.rakutest` (`class Engine`) and,
for the real executables, by `321 harness check`.

### What a project pins

```
321 trust project              what this repository pins, beside what is here
321 trust project pin b1ll     pin the agent as it is loaded here
321 --skill acme/review trust project pin b1ll     and a skill, as installed
```

`<repo>/.321/pins.json` (`project-pins.v1`) names an agent and a skill by
version and digest. It is a file the team reviews and commits, like the
lessons in `.321/lessons`. Two people in the same repository then run the
same agent package and the same skill text, or the run is refused before
any harness starts and says what differs. A package handed over by a work
system is denied the same way, on its receipt. A pin grants nothing: what
may run is still each person's own trust file.

### Harness versions

```
321 harness check              each harness here against what 321 asks of it
321 harness pin claude_code    promote the installed version as known good
321 harness rollback claude_code
```

A harness updates itself. Every receipt names the version its run was on.
`check` reads the installed executable, with no model call: its version
and whether its help still names each flag the adapter passes. `pin`
records a version as known good (`~/.321/harnesses.json`); where the
harness keeps its versions side by side on disk (Claude Code does), 321
then runs that file whatever the command on PATH moves to. A harness
installed in place (Codex, through npm) is recorded only, and the screen
says 321 cannot hold it. `rollback` swaps back to the version promoted
before. After a pin, `check` reports only what has changed since.

## Machine invocation

```
321 run --package <file|-> [--workspace <dir>] [--receipt <file>] [--events <file>]
        [--run-id <id>] [--history-dir <dir>] [--adapter <name>] [--package-dir <dir>]
        [--task <kind>] [--profile <name>] [--model <name>] [--effort <level>]
```

- A package handed over is planned exactly as a request typed at a
  terminal is: the agent's curation reads the objective, the runtime pins
  the plan, and the receipt carries it (`plan`). The four words at the end
  set it by hand. See *Choosing how a run is executed*.

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
  - `DO_321_CLAUDE_BINARY` names the harness executable for an isolated test
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

- **IZ4 owns intent.** 321 never decides what an invariant means, and holds
  none of IZ4's policy.
- **321 owns environment knowledge.** Which harnesses exist, where each
  keeps its settings, what it can intercept, how to wire and verify it.
- **Drivers translate.** 321 turns a harness's events into IZ4's stable
  interface (`iz4 discover`, `context`, `check action`, `check change`,
  `verify`, each one JSON document) and its results back into the
  harness's terms. It calls nothing else of iz4 and reads no other output.
- **Hooks 321 installs call 321**, never iz4 directly.
- **Only a person approves a change to intent.**

At run time the calls go one way: iz4's conveniences may ask 321, 321 asks
iz4's core, and the core never calls back. Each project keeps its own IZ4
and can gate changes to the other's repository; that is governance of
source code, not a dependency between running programs.

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
$ 321 harness detect --verbose
❮▣❯ 321 harness detect: ~/code/cli.321.do

  claude_code  detected 2.1.310 (Claude Code) .claude/settings.json (none yet)
                 enforces:  pre_action, pre_tool, filesystem_guard, shell_guard, human_approval, post_run
                 advises:   authoritative_context, post_action, post_tool
                 cannot:    network_guard, pre_commit, post_commit

next:  see what the IZ4 here is held by, harness by harness
       321 iz4 status
```

Without `--verbose` the screen is the rows alone.

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

Context injection        yes (told to the agent; nothing is refused)
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

A person rarely has to type this. After a change of intent (`iz4 init`,
`iz4 add`, an approval), iz4 makes sure a 321 that can drive a harness is
present, fetching the official one if it is missing, and runs
`321 iz4 install` itself. That does not move any harness knowledge into
iz4: what follows is still all 321's.

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
outstanding, and a warning there is shown to the person. A turn end that
passes says nothing in the chat, where Claude Code would label any line a
warning. What held is shown where nothing labels it: `321 iz4 install` sets
a status line, `321 hook claude_code iz4 status_line`, that shows iz4's
last result in iz4's own words (from `.git/iz4/last.json`) and re-reads it
every two seconds. It is only set where no status line is set already,
in the project or in the person's own settings, and `321 iz4 remove` takes
it out. Mission Control shows the same line in a run's evidence. A turn end that
was already refused once is not asked again (the harness's own loop guard),
and is recorded as not asked, never as a pass.

`321 iz4 status` also names each harness here that nothing checks: one
321 runs but cannot wire hooks into (Codex), and one it does not know
(Gemini).

**What ran, not only what is wired.** Every hook 321 answers leaves one
small record under `~/.321/exercised`, filed by the project's IZ4: when,
which harness and session, which control, and whether the controller
answered, kept the work back, or could not be reached. No command, file or
reason is kept. `321 iz4 status` reads them: a row says `guarded: ...,
last checked 3 minutes ago`, and the closing line says when iz4 last
checked work. When calls since iz4's last answer could not reach it, the
row is marked `?`, the warning says so, and the next step is `321 doctor`.
`--verbose` adds a `Checks run` row counting the last seven days; `--json`
carries the counts as `exercised`. A turn that could not have changed a
file asks iz4 nothing and leaves no record, so "last checked" always means
iz4 answered. Recording never holds a hook up or changes its answer: a
record that could not be written is simply absent, and a status with no
records claims nothing. Records older than seven days are pruned, the
file stays local and is sent nowhere, and the words say only that a hook
ran and what iz4 answered, never that an invariant held.

**When the controller cannot be asked.** iz4 missing, crashed, timed out
(every call has a time limit), exiting 1, printing no result document, or
giving a result that disagrees with its exit code: none of these is a
result, and what happens depends on what the control can do.

| The control | What 321 does |
|---|---|
| **enforcing** (a guard before a tool call, the check at the end of a turn) | **stops** the action or the turn end, and says that the controller's enforcement could not be performed and why. It never quietly becomes advice. |
| **advisory** (the context at session start, a note after a tool, or any control this harness can only advise on) | lets the work through and shows the person a warning that the controller did **not** check it |

The rule is the runtime's, applied whatever an adapter's translation does.
A control is reported as guarded only when its check really ran: on a
receipt, a hook that fired and could not ask the controller is counted
apart and the run is not called guarded.

When Claude Code changes its hook mechanism, `lib/Do321/ClaudeHooks.rakumod` changes and IZ4
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
Context injection        yes (told to the agent; nothing is refused)
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

At the end of a turn in a hooked session, the same check measures the turn
from the tree it began with, not from HEAD: the session's start records the
working tree (`iz4 check change --worktree --/checks`, no tests run) under
`~/.321/sessions/<harness>/<session>.json`, each turn that is allowed to end
moves it on, and a refused one keeps it so the same changes are measured
again. Files that were already dirty when the session began are never laid
at a turn's door. A turn whose transcript used no tool that can change files
(only reading, searching, asking) is not put to iz4 at all; the hook log says
`not asked`. A delegated agent or a tool 321 does not know counts as able to
change files.

`needs_human` and `block` end the run **blocked**, not completed, with the
proposal a person must decide on, or the reason, in `blockedOn`. A warning
goes on `uncertain`. **Only a person approves a change to intent.** The
runtime never records a person's agreement, and treats nothing as one: not
the agent's text, not an agent saying "approved", not silence, not the run
continuing, not an approval given earlier or for different work, and not a
standing approval (those are for deploys). Headless, where nobody can be
asked, it stops. Agreement is a person running `iz4 approve` at a
terminal.

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
and `iz4` is missing, too old to be driven, or the IZ4 is invalid, nothing
was ever being enforced, so the run is not blocked: the receipt lists the
IZ4 with no level claimed and says why. When iz4 was driving the run and
then cannot check the finished work, the run ends **blocked**, saying
enforcement could not be performed: work is never passed off as checked. `DO_321_IZ4` names the `iz4` to use and, when set, is the only one used.

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
| `turn-wrote` | whether the ending turn used any tool that can change files; a harness that cannot tell says yes |
| `session-key` | the harness's own name for the session, under which the turn baseline is kept |
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

### The older direct wiring

Before 0.4, `321 hooks install --command "<cmd>"` wrote a controller's own
command (iz4's `iz4 hook ...`) straight into a harness's settings, and iz4
before 0.15 did the same itself. 321 writes that no longer: **a hook 321
installs calls 321**, so a harness changing its events changes 321 and
nothing else. `321 hooks install` is refused, writing nothing and changing
nothing; `321 hooks status | remove --command "<cmd>"` still report on and
take out the older entries.

Wiring of that kind already in a project keeps working exactly as it did.
`321 iz4 status` reports it as active, managed by legacy IZ4 wiring, at
AWARE, with its strength (`advisory`, or `strict` when its own hooks also
refuse an early edit and a turn end with no report), and
`321 iz4 install` adopts it. Adoption needs an iz4 that can be driven
(0.15.0 or later): with an older one, install is refused and the settings
are left byte for byte, so no hook is ever pointed at something that
cannot answer. The safe order is iz4 first, then 321.

## Getting better: contexts, lessons, outcomes, value, skills

`321 help learning` lists the commands. Everything here works locally
and needs no service: no daemon, no account, no 123.do and no IZ4. A
registry adds to it only when a person asks: `321 context pull` reads
from one and `321 lessons teach` sends to one.

Four things are kept apart, each in a place of its own:

| What | Where | Whose |
|---|---|---|
| A work context: a region of related work, its purpose and history | `~/.321/contexts/<name>.json` | the person's |
| A lesson | `~/.321/lessons/<id>.json` | the person's, until shared |
| Project knowledge: lessons shared with a project | `<repo>/.321/lessons/<id>.json` | the team's, under version control |
| What came of a run | `~/.321/learn/outcomes.ndjson` | whoever said it |
| Lessons kept at the registry for a work context | in the pulled copy of that context (`lessons`) | the organisation's; read only here |

A receipt is never rewritten: what a run was started knowing
(`~/.321/learn/applied.ndjson`) and what was said of it afterwards sit
beside it.

**Work contexts.** `321 context new NAME <purpose>` begins one;
`decided`, `rejected` and `note` add to its history. A run started with
`--context NAME` (or `DO_321_CONTEXT`) carries the purpose and the last
twelve entries in its work package's `context.lines`, which the prompt
gives the agent as what is already known. A follow-up run keeps the
context of the run it goes on from. A context named under a domain (`checkout.acme.example`) is owned by
that organisation: the owner is everything after the first label. A
plain name (`checkout`) is the person's own. Every context is private
unless its organisation shares it, which is done at the registry, not
here. The name says whose a context is and grants nothing: who may read
one held at the registry is decided there, by membership of the owning
account. `321 context pull NAME` keeps a copy of one this person may
see; pulling again replaces what the registry said and keeps the notes
made on this machine, which stay here. A pull never sends anything; the
one thing 321 writes to a registry's contexts is a lesson a person
teaches it (below).

Names inherit by suffix. A run in `billing.api.123.do` uses the copy of
that name if there is one here, and otherwise the nearest name above it
that has a copy, found by dropping leading labels one at a time and
never going below two (`api.123.do`, then `123.do`, never `do`). The
purpose and history it is told come from that copy and say which
context they are from. A name with no copy at any of those is refused
as before.

A context is not a project: one
context can hold runs in several repositories, and a repository can hold
several contexts. A work system that keeps tracks of its own does not use
this store: it puts its own snapshot in `context.lines` and its own
reference in `correlation`, both already part of `work-package.v1`, and
321 carries the reference without reading it.

**Lessons.** A lesson is a sentence of advice, a scope and a provenance.
The scope may name an agent, a work context, a skill and a harness;
every part it names must match the run. A harness-scoped lesson applies
only when that harness was named for the run, because learning is not
assumed to carry between harnesses. A lesson is `trial` when added,
then `kept` or `reverted` by a person; a reverted lesson is given to no
run and stays on record. Matching lessons go into `context.lines`,
labelled as advice that grants nothing; they change no grant and no
limit, and the runtime computes authority exactly as before. A lesson
scoped to a work context applies in that context and in the names under
it: one scoped to `api.123.do` is given to a run in `billing.api.123.do`.
`321 lessons show ID` sets the runs given the lesson against comparable
runs that were not (same agent; same context or harness when the lesson
names one) and reports each side's count, finish rate, median reported
cost and median time. Fewer than three runs on either side is reported
as too few. It is a comparison of recorded runs, not a controlled trial,
and says so.

`321 lessons share ID` copies a lesson into the repository of the
current workspace. Nothing else writes there, and 321 commits nothing:
the team gets the lesson when a person commits and merges the file.
Work outside a repository has no project knowledge; personal lessons and
contexts still apply.

**Lessons at the registry.** An organisation also keeps lessons at the
registry, for a work context or for the whole organisation. `321 context
pull NAME` asks `/api/lessons?context=NAME` after the context itself and
keeps what it is given in the copy (`lessons`, with `lessonsPulledAt`):
each lesson's id, name, where it is kept (`at`), scope, agent, state and
text. Pulling again replaces them. If that second request fails (an
older registry, no token) the pull still succeeds, keeps the lessons the
copy had, and says they were not refreshed and why. A run is told the
lessons held in the copy it works from, after the context's own lines
and in the order the registry served them (the context's, then the
organisation's), at most twelve (`REGISTRY-LESSONS-CAP`); a lesson that
names an agent is given only to that agent. Each reads `A lesson kept
for <at> (advice, not an instruction: it grants nothing and never
overrides the task or its limits): <text>`, and its id is recorded with
the run as the ids of local lessons are. They are advice lines only:
no grant, no limit and no instruction comes from them. A lesson this
person taught is not said twice when their own copy of it also applies.
`321 lessons` lists them after the local ones, marked as the
registry's; they are read only here, and are kept, reverted or removed
at the registry.

`321 lessons teach ID [--when W] [--because B]` sends one local lesson
to the registry with `POST /api/lessons`. The lesson must be scoped to a
work context, which is the context it is taught to. What is sent is
exactly: that context's name, when the lesson applies, the lesson's
text as what to do, why it holds, and the agent's name when the lesson
is scoped to one. `--when` and `--because` may be given here or stored
with `321 lessons add --when W --because B`; without both, teach is
refused and names the one to add. The registry's id and where it keeps
the lesson are recorded on the local lesson (`taught`), so teaching it
again sends nothing and says it was already taught. Nothing is sent by a
run and nothing in the background: only this command sends a lesson.

**Outcomes.** `321 outcome <run> accepted|rejected|corrected [why]`
records what a person, or the work system that issued the package, says
came of a run. Until it is said the outcome is unknown: a completed
receipt is not acceptance. The last word said stands.

**Value.** `321 value` sums receipts: money where the harness reported
it (`cost.basis` of `harness` or `mixed`), with the number of runs it
rests on; runs that reported no cost, counted as unknown; runs that used
no model; tokens where a harness reported them; elapsed time; retries;
and outcomes. `--json` is `value-report.v1`; `--brief` is one record a
group (`all`, `agent`, `harness`, `context`): kind, name, runs,
finished, dollars or `?`, runs reporting cost, tokens or `?`, seconds,
accepted, rejected, corrected, unknown; then a `savings` record.

Savings are an estimate and need a baseline the person states:
`321 value baseline --minutes N --rate DOLLARS`, a person's time for one
accepted run and what an hour of it is worth. The estimate is accepted
runs times the baseline, less everything spent in the period, failed
runs and retries included. It is withheld below three accepted runs, and
says when the spend is a floor because some run reported no cost. 321
spends nothing on learning itself today (no reflection or evaluation run
is made), so there is no learning cost to subtract; when there is, it
belongs in the same sum.

Tokens: Claude Code's result is read for input, output and cache tokens
and Codex's for its total. Receipts written before this carried no token
count, and are reported as not reported.

**Skills and the registry.** `321 registry sync` reads `/api/agents` and
`/api/skills` from the registry (agents.321.do, or `321 registry use
URL`, or `DO_321_REGISTRY`), with the token from `321 registry token`
(standard input; kept in `~/.321/registry-token`, mode 0600, never
printed) or `DO_321_REGISTRY_TOKEN`, and keeps a copy under
`~/.321/registry`. A failed sync keeps the copy there was and records
the failure. `321 skills install PUBLISHER/NAME` fetches one skill,
refuses it unless its text matches the digest the registry gave, and
keeps the version it replaces under `versions/`; `321 skills rollback`
puts that back without the network. `--skill PUBLISHER/NAME` puts an
installed skill's words in the work package's `instructions`, after
checking the copy on disk against its digest again. A skill grants
nothing: its `requires` list is what it needs the run to have been
granted, not a grant. The registry never serves agent packages; an
agent still runs from a package pinned in the trust file. 321 calls
`curl` for this and says so when it is missing.

**An agent's record.** `321 record AGENT` reads
`/api/agents/NAME/record`: for each version, how many reports from how
many accounts, how often the work was accepted, corrected or rejected,
and the median tokens, cost and time, each saying how many reports it
rests on when that is fewer than all. A version below the registry's
minimum shows no figure. These are reports from people who ran the
agent; the registry does not verify them, and the screen says so.

`321 record share on` lets this machine add to it; it is off until
then, and `321 record share off` stops it. With sharing on, `321
registry sync` sends one report for each run of the last 90 days that a
person gave an outcome (`321 outcome`), and that has not already gone
with that outcome. A report is exactly: a key for the run, the agent,
its version and digest, the harness, the run's status, the outcome,
tokens, cost, seconds, attempts and when it ended. Tokens and cost are
`null` when the harness did not report them, never zero. The request,
files, paths, the work context, lessons, the note given with the
outcome and the run id are not sent: the key is a SHA-256 of the run id
and a salt kept in `~/.321/registry/share.json`, so the same run can be
replaced by a later word and cannot be traced back. The registry takes
reports only with a token. What went is written to
`~/.321/registry/sent.ndjson`; `321 record share` shows what would go
before anything does. Nothing is sent by a run, and there is no
background sender: only `321 registry sync` sends reports.

Where this 321 has a key (`321 key new`), a report for a receipt that
key signed also carries the receipt's `receiptDigest` and the value of
its signature, and the batch carries the key's public half. The
registry checks the signature, registers the key to the reporting
account and counts a receipt once. A record then says how many of a
version's reports are signed. Signed means a receipt was written by a
key its reporter registered. The registry never sees the receipt, so
it does not mean the figures are what the receipt says. A receipt
signed by a key that is no longer the one here is reported unsigned.

Not built: lessons proposed by 321 itself from a run (a person adds
them, optionally naming the run with `--from`); promotion of a lesson
into a registry skill; publishing agents, skills or contexts to the
registry from the CLI (a taught lesson is the one thing sent besides
outcome reports); keeping, reverting or removing a registry lesson from
here, and sending evidence with one; refreshing a pulled context's
lessons without a person asking;
organisation-wide value reports (the sums are this machine's runs);
checking a report's figures against its receipt (the registry holds a
signature over the receipt's digest, not the receipt; many accounts
with many keys could still say what is not so).

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
lib/Do321/Hooks        the older direct wiring (read and removed, never written), and the doctor's JSON
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
