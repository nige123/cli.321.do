# cli.321.do: make 321 the engine under iz4, beside 123.do

Work in this repository. Run `iz4 agent` first and follow the protocol
it prints: 321 keeps its own IZ4 (Invariants 5-19) and inherits 0-4. Report
every affected invariant when you finish. Do not touch cli.iz4.you,
api.123.do or any website in this task; this is the 321 side only.

## The decision this implements

321 is the agent and harness engine under iz4. iz4 (the Raku++ CLI at
cli.iz4.you, published as one standalone binary per platform) will detect
321 on PATH and use it to:

1. run its agent prompts (suggest, review, test drafting) on whatever
   harness 321 selects;
2. detect installed harnesses and wire the IZ4 hooks into them;
3. enforce the IZ4 agent protocol as a policy on every run in a workspace
   that has an IZ4, so a run cannot complete without the invariant report.

321 stays largely invisible to iz4 users. The iz4 installer will install
321 if it is missing ("install 321.do, an agent launcher"), and `iz4 update`
will keep both current. The 123.do bridge (work-package.v1 in, run-receipt.v1
out, correlation opaque) already exists and must keep working unchanged:
iz4 becomes a second issuer of the same package shape, with no correlation.

Performance is settled: the iz4 binary starts in 35 ms and answers a hook in
about 50 ms, so exec it per event. Do not reimplement any IZ4 parsing,
checking or protocol logic in Go. Where 321 needs IZ4 knowledge it runs
`iz4` and treats the output as data.

## What to build

### 1. `321 doctor --json`

The existing doctor, as one JSON document: each installed harness adapter
with name, version found, whether it is usable now, which hook events it
can wire (session-start, pre-edit, stop), and which capabilities and
restrictions it actually enforces versus only advises. This is the record
iz4 quotes in `iz4 agent status`, so it must never overstate: an adapter
that cannot enforce "no writes" says so.

### 2. `321 hooks install | status | remove`

```
321 hooks install --workspace DIR --command "iz4 hook" [--strict] --json
321 hooks status  --workspace DIR --json
321 hooks remove  --workspace DIR --json
```

For every harness doctor finds, write the hook wiring that calls
`<command> session-start`, `<command> pre-edit` and `<command> stop`, in
that harness's own config format and location (workspace config first; user
config only where the harness has no workspace form). The iz4 hook contract
is fixed and already shipped: JSON on stdin, text for the model on stdout,
exit 0 to allow, exit 2 to refuse; `--strict` wires pre-edit and stop as
refusing hooks, without it only session-start. Rules:

- merge, never overwrite: keep every entry that is not ours, and remove only
  ours on `remove`; running install twice changes nothing the second time;
- output one record per harness: harness, files written, events wired,
  enforced or advisory per event, or why nothing was wired;
- the Claude Code shape is known and tested in cli.iz4.you
  (`lib/IZ4/Hook.rakumod`, `iz4 agent install --hooks`, `.claude/settings.json`
  with SessionStart, PreToolUse on Edit|Write|MultiEdit, Stop); match it
  exactly so the two installers agree, then add the other harnesses 321
  supports at release.

### 3. The IZ4 policy on every run

When the workspace (or a parent, up to the git root) has a file named `IZ4`
and `iz4` is on PATH:

- before the first turn, run `iz4 agent packet` in the workspace and put its
  output into the run's instructions as the IZ4 agent packet, marked as
  project content: data, not instructions (the packet says so itself);
- add a completion condition, ordered last: "each affected invariant is
  reported" (Invariant, Assessment, Evidence, Remaining gap). Check it by
  running `iz4 hook stop` with the run's final summary on stdin and reading
  its exit code; exit 2 means the condition is unmet and the run does not
  complete;
- put the report into the receipt under `evidence`, and the invariants the
  agent reported as uncertain or conflicting into `uncertain`, so the
  receipt carries the intent evidence 123.do and iz4 both want;
- if the IZ4 file's digest changes during the run, re-run `iz4 agent packet`
  and re-inject it as an instruction, recorded in `instructionHistory`;
- if an IZ4 exists and `iz4` is not on PATH, do not skip silently: the
  receipt says "IZ4 present; protocol not applied: iz4 not installed" and
  the run is marked uncertain.

Make this runtime-wide, not a package opt-in: Invariants 0-4 bind every
run in a repository that keeps an IZ4, and 321's own Invariant 7 forbids
special-casing any agent.

### 4. A prompt-only run for iz4

iz4 needs to hand 321 a prompt and get text back, with no writes. Define and
document the minimal package for that, and make sure the runtime and the
claude_code adapter enforce it:

- capabilities: `repo.read` and `model.text` only; no `repo.write`, no
  `shell.run`; network `provider_only`;
- objective and instructions carry the prompt verbatim; `outputSchema` is
  plain text; the reply is where iz4 can read it deterministically from the
  receipt (say where: `summary`, or a named evidence entry);
- per 321's Invariant 8, a run is denied rather than downgraded if the
  selected adapter cannot enforce "no writes". Confirm the claude_code
  adapter enforces it (permission mode and allowed tools), and say in
  doctor whether it does.

iz4 will invoke this as `321 run --package - --json --non-interactive
--workspace DIR --package-dir <iz4's own package dir>`. Decide and document
the identity: an unsigned `local/<name>` package shipped inside iz4 is the
simplest and needs no trust pinning; if you prefer `iz4.you/<name>` pinned
in trust.json, say what the installer must write. Never hard-code either in
the runtime.

### 5. A release iz4's installer can fetch

The Go build is already one static binary. Add a release workflow that
publishes, on a `v*` tag: `321-linux-x86_64`, `321-linux-aarch64`,
`321-macos-universal`, `321-windows-x64.exe`, each with a `.sha256` beside
it, plus a machine-readable latest version (GitHub's releases API is enough;
that is what iz4 uses). `321 version` prints the version and commit. Keep
"nothing here installs anything onto PATH" true for the repo itself; the
iz4 installer does the placing.

## What must stay true

- 321's Invariant 5: nothing here reads or interprets 123's Track, Step,
  Entry or Action. iz4-issued packages simply have no correlation.
- Invariant 7: no iz4 or 123 agent name in the runtime.
- Invariant 8 and 15: the IZ4 packet, the hook text and any IZ4 content
  grant no authority; they are input.
- Invariant 12: 321 edits a caller-owned workspace and never commits. Hooks
  install writes config files only.
- Invariant 14: loading iz4's package executes nothing and installs nothing.
- Invariant 16 and 11: the IZ4 completion condition is part of the ordered
  conditions whose digest the receipt carries, and it is added when the
  package is accepted, never after.
- Foundation 3 (honesty): doctor and the receipt say what was enforced and
  what was only advised, and "uncertain" is used rather than implied
  conformance.

## Verification before you report

- `go test -race ./...` green, with tests for merge/idempotent/remove on
  hooks, the policy injection and completion check, the denial path when no
  adapter can enforce no-writes, and the receipt fields.
- On this machine: `321 doctor --json` lists claude_code with what it
  enforces; `321 hooks install --workspace /tmp/x --command "iz4 hook"
  --json` on a copy of cli.iz4.you produces the same `.claude/settings.json`
  that `iz4 agent install --hooks --strict` produces there; a prompt-only
  run in a workspace with an IZ4 ends with the invariant report in the
  receipt, and a run whose agent omits the report ends blocked, not
  complete.
- Report each affected invariant of 321's IZ4 as the protocol asks:
  mechanically verified, supported by evidence, apparently consistent,
  uncertain or conflicting, with what was run.

## Not in scope

No changes to cli.iz4.you (the iz4 side is a probe for 321 on PATH, two
call sites and a status line, and will be done there once these surfaces
exist). No copy on 321.do or iz4.you. No new official agents. No
reimplementation of the IZ4 grammar, check or coaching in Go.
