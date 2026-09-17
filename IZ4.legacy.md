# IZ4 before migration

`iz4 migrate` converted IZ4 to the Is For format on 2026-09-17. The new
file keeps only what the software is for, who it is for, and the
invariants that must remain true. Everything else it held is kept here
word for word, so nothing was lost. Move each part to wherever it now
belongs - the README, an ADR, tests or issues - or delete what no
longer matters.

## Invariant numbers

Invariants 0-4 are now the inherited foundation, so project invariants
were renumbered by adding 4:

| before | after |
|---|---|
| 1 | 5 |
| 2 | 6 |
| 3 | 7 |
| 4 | 8 |
| 5 | 9 |
| 6 | 10 |
| 7 | 11 |
| 8 | 12 |
| 9 | 13 |
| 10 | 14 |
| 11 | 15 |
| 12 | 16 |
| 13 | 17 |
| 14 | 18 |
| 15 | 19 |

## gist

321 is a free, harness-agnostic agent runtime and its command-line front
door. It accepts a neutral WorkPackage, resolves and loads an AgentPackage,
selects a capable installed harness adapter or a deterministic procedure,
enforces capability grants and exact approvals, executes with ordered
in-flight directives, and emits run events and an immutable receipt. It is
the same runtime whether a person types '321 <agent> <request>' at a
terminal or a work system delegates a package to it.

## behaviours

- A person runs '321 <agent> <request>' or '321 <publisher-domain>/<agent> <request>' and the request becomes a WorkPackage under local policy, executed through the same path a delegated package takes.
- A machine caller runs '321 run' with one WorkPackage and any number of ordered WorkDirectives over NDJSON, and reads RunEvents, directive acknowledgements and exactly one terminal RunReceipt back.
- Standalone use needs no 123 account, database or network service; a delegated package is owned by its issuer and the runtime never interprets the issuer's correlation references.
- Stop takes effect even when earlier directive sequence numbers are missing; clarify and steer stay ordered and are never silently dropped.
- A run that ended blocked can be continued once its question is answered: the same immutable package, a clarify directive, cost and attempt numbering carried forward, the old receipt preserved and linked from the new one.
- A package's deterministic procedure may call an externally bound tool (dp, bound by DP_BIN, never by a PATH lookup) through named operations that each carry their own capability: status needs deploy.read, plan needs deploy.plan, execute needs deploy.invoke. Parameters are validated against strict patterns and passed as an argument vector with no shell.
- A plan operation yields an immutable deployment-proposal.v1 on the receipt: exact revision, manifest and engine digests, operations in order, checks performed and not performed, blockers, rollback limits, and a digest over the canonical document. It is evidence of planning, never an approval.

## constraints

- Go standard library only for the runtime; the five public protocols and the fixtures under testdata are Apache-2.0 and carry no official agent content.
- Configuration is JSON under ~/.321 (trust and policy), because the runtime has no YAML dependency.
- One canonical JSON form for every digest, stated in internal/protocol/canonical.go and pinned by testdata/canonical: bytewise key order, no whitespace, minimal escaping, ES6 number rendering. A second implementation must reproduce the fixture bytes.

## decisions

- 2026-09-05: The publisher namespace for official agents is 321.do; the legal owner is Nige Ltd; 123.do is the commercial work system that consumes packages. One agent has one canonical identity.
- 2026-09-05: Package downloading, installation commands, online publisher enrolment and a registry service are deferred. Slice 0 loads only administrator-configured packages.
- 2026-09-05: deploy.read and deploy.plan join the capability vocabulary as the read-only halves of deployment authority, and the tool step kind joins procedures, so the 1DA slice runs status and planning deterministically through the existing Perl deployment engine with no model and no new deployment logic in Go.
- 2026-09-13: The runtime stays in Go. Raku++ (rakupp) was considered for building the 321 executable and rejected: it compiles Raku, so it would mean rewriting the runtime; Go already builds static binaries for every release target from one machine (CGO_ENABLED=0), while Raku++ cannot cross-compile, needs glibc 2.38 on Linux and has a proven recipe only for Linux x86_64, macOS and Windows x64; and the runtime's concurrency, child processes, signal handling and signing are where a young, fast-moving compiler is riskiest. Raku++ remains the route for tools written in Raku, such as spoz2.

## references


## Comments

    # What is this project supposed to do?
    # Humans and AI tools should treat this file as the authoritative
    # expression of intent.  Edit it directly or use `spoz2 add ...`.

