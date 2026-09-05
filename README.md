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

Go 1.26 or later, standard library only.

```
go build -o 321 .
go test -race ./...
```

During development invoke the binary by its build path. Nothing here
installs anything onto `PATH`.

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
`deploy.invoke`) and enforcement features it requires of a harness, never a
provider. Provider-specific tuning goes in `harness.overlays.<adapter>`.

A package may carry deterministic **procedures**: a predicate over the
objective and a list of steps that run with no model. A matching procedure
is chosen before any adapter, runs under the same grants and approval gate,
and produces the same receipt.

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

The receipt (`schemas/run-receipt.v1.json`) describes the runtime outcome at
the moment it ended: package and agent digests, adapter and session refs,
every attempt, every directive's disposition, the instruction history by
reference and digest, conditions aligned by index to the package's
completion conditions, evidence, cumulative cost, and stop or denial
details. Its `receiptDigest` is over its own canonical content.

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
  steer or pause live; the runtime handles those at attempt boundaries.
- `procedure`: the built-in executor for package procedures. Enforces
  everything by construction because it only performs the operations its
  steps name, each checked against the grants, the workspace boundary and
  the approval gate.
- `fake`: the same executor with a script, for tests and dry runs. Hidden:
  selected only by `--adapter fake` or `policy.adapters.preferred`.

## Layout

```
schemas/            the canonical protocol documents (JSON Schema 2020-12)
internal/protocol   Go types, validators, canonical JSON, identity, ULIDs
internal/digest     package digest and ed25519 signatures
internal/trust      trust configuration, alias resolution, package loading
internal/adapter    adapter interface, selection, procedure/fake, claude_code
internal/run        the runner: grants, attempts, directives, receipts
internal/wire       the NDJSON machine protocol
internal/cli        the front door
testdata/packages   unbranded fixture packages
```

`SPOZ2` beside this file states what the runtime is supposed to do; read it
before changing behaviour and add to it first.
