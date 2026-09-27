# cli.321.do: move the runtime from Go to Raku++, then make it the engine under iz4

> Status, 2026-09-27: done. Parity is v0.2.0 (the Go tree removed in the
> same commit); the integration is v0.3.0. The Raku++ differences met are
> recorded in the 321-rakupp-binaries skill's gotchas.

Work in this repository. Run `iz4 agent` first and follow the protocol it
prints: 321 keeps its own IZ4 (Invariants 5-19) and inherits 0-4. Report
every affected invariant when you finish. Load the `321-rakupp-binaries`
skill before writing any Raku, and read its `references/gotchas.md`.

## The decision

The owner has decided that 321 moves from Go to Raku++ (`rakupp`,
github.com/ash/rakupp, currently 4.0.1), shipping as one standalone binary
per platform exactly as iz4 does (nige123/cli.iz4.you,
`.github/workflows/binaries.yml`, `--aot --standalone`, Raku++ pinned by
version and checksum). After the port reaches parity, 321 becomes the agent
and harness engine under iz4, per `docs/iz4-integration-prompt.md`, which
applies unchanged except that its work is done in the Raku++ code, not the
Go. Do the port first; do not build the integration twice.

## What the port must preserve, byte for byte where it is a protocol

- The eight public schemas in `schemas/` are the contract with 123.do and
  with every issuer and reader of receipts. They do not change. Canonical
  JSON (sorted keys, the exact escaping the Go encoder produces), package
  digests, conditions digests, receipt digests and key ids must come out
  identical: `testdata/canonical` and the existing receipts are the golden
  vectors, and a receipt the Go binary produced must verify under the Raku++
  binary and the other way round.
- The command surface printed by `321` with no arguments, every exit code,
  every protocol-error code, `~/.321/trust.json` and `X321_TRUST`,
  `321 run --package` over NDJSON with directives on stdin and events then
  one receipt on stdout, `--continue`, `321 agents | packages | trust |
  doctor`, and the tool bindings (`DP_BIN` and the rest).
- All nineteen project invariants, especially: 5 (never interprets Track,
  Step, Entry or Action), 7 (no hard-coded agent names), 8 and 15
  (authority is an intersection; text grants nothing; shell never implies
  network), 9 (deny, never downgrade), 11 and 16 (immutable package, ordered
  conditions and their digest), 12 (never commits), 14 (loading executes
  and installs nothing), 17 and 19 (the execution boundary), 18 (cost
  carries its basis).
- The 123.do bridge: api.123.do issues work-package.v1 and validates
  run-receipt.v1 (`lib/Do/API/Engine/Work.pm`, `lib/Do/API/Work/*.pm`). Run
  its fixtures through the new binary before calling parity.
- The test doubles in `testdata/fakeclaude` and `testdata/fakeengine`, and
  every behaviour the Go tests pin (about 4,000 lines of tests over 7,500 of
  code). Port the tests, do not summarise them.

## What Raku++ 4.0.1 gives you, checked on this machine on 2026-09-27

- `use Data::Native` (answered by the compiler, nothing to install):
  `to-json`, `from-json`, `sha256-hex`, `sha512-hex`, `crypt_random_buf`.
  It is Raku++-only for now, so keep every use of it inside one module
  (`X321::Native` or similar) so a Rakudo shim can be swapped in later.
- `to-json` does not sort keys. Canonical JSON needs its own encoder; iz4
  has one in `lib/IZ4/Register.rakumod` (`json-encode`) to start from, and
  the golden vectors decide.
- NativeCall works, but do not use it: the runtime links no third-party
  libraries and must run alone in an empty directory (the skill's step 4).
- `Proc::Async` with `.kill(SIGTERM)`, `signal(SIGINT).tap`, `start` blocks,
  `await`, `Promise.in`, `race` and `run` all work. `try await $promise`
  catches as on Rakudo.
- Start-up is about 35 ms for a 12 MB `--aot` binary. Budget 50 ms for
  `321 version` and for reading a package; a run's time is the harness's.

The one gap: ed25519. Data::Native has no ed25519 and there is no core
module. Write signature verification in pure Raku (RFC 8032, Int
arithmetic, sha512 from Data::Native), pin it to the RFC 8032 test vectors
and to the signatures already in `testdata/trust`, and keep signing for the
test suite and `321 packages digest --write` only. Verification of one
signature per package load is the only hot path, and it is not hot.

## Traps met when iz4 was ported, so you do not meet them twice

A class named `Block` resolves to the core type (rename). `$*IN.get` on a
pipe returns Nil after the first line and `.lines` is not lazy: read with
`getc`. A junction passed as an argument autothreads the call: wrap in
`so(...)`. `%( )` inside `[ ]` flattens to pairs: use `$%( )`. `andthen`
returns Empty. `return` inside a block passed to a helper does not return
from the caller. `eqv` differs between List and Array. `\b` is `<|w>`,
`A-Z` is `A..Z`. Everything else that differed is in the skill's gotchas
file; record any new one there and at the call site.

## How to do it

1. Set up the suite seam first: tests run the CLI through one helper that
   swaps in a compiled file via `X321_TEST_BIN`, and CI runs the suite
   against the binary on Linux and macOS, as iz4's does.
2. Port in dependency order, one package at a time, each with its tests
   green under `rakupp -Ilib` before the next: protocol (types, validate,
   canonical) → digest (sha256, canonical, ed25519) → trust → tool
   (approval, redact, dp) → adapter (procedure, procedure_tool, claudecode)
   → run (runner, directives, evidence, prompt) → wire → cli (standalone,
   operator, commands).
3. Keep the Go tree in place until parity. Parity is: the full ported suite
   green against the compiled binary; the golden digests and receipts
   identical across both binaries; the 123.do fixtures accepted; the
   standalone check passing on Linux, macOS and Windows in CI.
4. Tag the parity release, then delete the Go tree in one commit that says
   so, and switch the release workflow to the Raku++ matrix with per-platform
   assets and `.sha256` files (`321-linux-x86_64`, `321-linux-aarch64`,
   `321-macos-universal`, `321-windows-x64.exe`), the names the iz4
   installer will fetch.
5. Then do `docs/iz4-integration-prompt.md`, sections 1 to 5, in the Raku++
   code.

## Verification before you report

- Suite green under `rakupp -Ilib` and against the compiled file; the
  binary runs alone with only the system PATH; dependency listing names only
  system libraries; `--aot: embedded N modules` lists every module and
  nothing left out.
- Cross-check: a package signed and a receipt produced by the Go binary
  verify under the Raku++ binary, and the reverse.
- `321 version`, `321 doctor`, `321 agents` and a `321 run --package -`
  round trip with `testdata/fakeclaude` behave as the Go binary did, with
  identical events and receipt fields.
- Report each affected invariant of 321's IZ4 with what was actually run.

## Not in scope

No changes to cli.iz4.you, api.123.do or any website. No new agents. No
NativeCall or third-party libraries. No change to any schema. Do not start
the iz4 integration until the parity tag exists.
