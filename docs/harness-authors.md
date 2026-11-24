# Teach 321 a new harness

A harness is the program an agent runs in: Claude Code, Codex, or the
command-line agent you use. 321 can run a named agent on any harness it
has an adapter for, and an adapter for a command-line agent is one short
class. This page takes you from nothing to a pull request.

You need the repository, Raku++ (`rakupp`), and the harness itself
installed. No model is called by any test.

## 1. Start from the template

```
tools/new-harness acme "Acme Agent"
```

writes three files and tells you the three lines to add by hand:

| File | What it is |
|---|---|
| `lib/Do321/Harness/Acme.rakumod` | the adapter |
| `t/harness-acme.rakutest` | its tests, with the contract every adapter keeps |
| `testdata/fakeharness/acme` | a stand-in for the real command, so tests call no model |

## 2. Say the four things only you know

```raku
class Acme is CommandHarness is export {
    method name(--> Str)    { 'acme' }          # how --harness and trust files spell it
    method label(--> Str)   { 'Acme Agent' }    # how a person reads it
    method command(--> Str) { 'acme' }          # what is on PATH
    method args(Spec $spec --> List) {          # its arguments for one attempt
        ('run', '--quiet', |self.model-args($spec, '--model'))
    }
    method enforcement(--> Hash) { self.claims(FEAT-TIMEOUT, FEAT-GRACEFUL-STOP) }
}
```

That is a working adapter. `CommandHarness` does the rest: it finds the
command, asks its version, starts it in the workspace, writes the prompt
to its standard input, reads what it prints, stops it when the run is
cancelled (SIGTERM, then SIGKILL), and turns its last words into the
result. The prompt never goes on the command line, where every process
list would show it; if your harness only takes it as an argument, say
`method prompt-on-stdin(--> Bool) { False }` and it is passed last.

A run may be given more than its workspace: other repositories, a
directory, a file (`321 --with NAME`). They are in `$spec.resources`,
each a hash with `name`, `kind` (`git`, `dir`, `file`), `path` and
`access` (`read` or `write`). The prompt already tells the agent where
they are; if your harness confines file access to directories it is
told, pass them in `args`, and give write access only to those whose
`access` is `write`. Lessons earlier runs learnt about your harness
reach the agent in the prompt too, with nothing for you to do.

## 3. Claim only what the harness does

`enforcement` decides where your harness may be used. 321 never places a
package on a harness that cannot enforce what the package needs, so a
claim is a promise, and a missing claim is safe: the work goes elsewhere
or is refused with the reason.

| Claim | Make it when |
|---|---|
| `FEAT-TIMEOUT`, `FEAT-GRACEFUL-STOP` | it exits on SIGTERM. `CommandHarness` sends it. |
| `FEAT-STRUCTURED-OUTPUT` | it can be made to end with a JSON result document (see below) |
| `FEAT-TOOL-ALLOWLIST` | it has a flag that confines the agent to named tools, and `args` passes the tools the grants allow |
| `FEAT-NETWORK-DENY` | it runs commands where they cannot reach the network |
| `FEAT-TURN-LIMIT`, `FEAT-SPEND-LIMIT` | it has a flag for each and `args` passes `$spec.limits` |
| `FEAT-EVENT-STREAM` | it prints events as it goes and `read` reports them |
| `FEAT-SESSION-CONTINUE` | a later attempt can go on with `$spec.session-ref` |
| `FEAT-LIVE-STEER`, `FEAT-PAUSE` | it takes words or a hold while running |

Almost every package needs `FEAT-STRUCTURED-OUTPUT`, and any package that
grants tools needs `FEAT-TOOL-ALLOWLIST`. An adapter that claims neither
is correct and will be chosen for very little: these two are the ones
worth the work. Say in the module's opening comment how you checked each
claim and against which version, as `lib/Do321/Codex.rakumod` does. A
claim nobody checked is the one thing a reviewer will refuse.

## 4. Say what its output means

By default every line the harness prints is something the agent said,
and the last one is the summary. If the last message is a JSON object
with `status` (`changed`, `no_change` or `blocked`), `summary`,
`blocked_on` and `conditions` (`[{ "met": true, "proof": "..." }]`), it is
read as the run's result. `$spec.output-schema` holds the schema to hand
your harness if it takes one.

A harness that prints events overrides `read`:

```raku
method needs-finish(--> Bool) { True }   # a clean exit alone is not a finished turn
method read(Str $line, Reading $r) {
    my %e = (try parse-json($line)) // %();
    given %e<type> // '' {
        when 'session' { $r.session-is(%e<id>) }
        when 'tool'    { $r.tool(%e<name>, %e<target> // '') }
        when 'message' { $r.said-text(%e<text>) }
        when 'usage'   { $r.add-turn; $r.add-tokens(%e<tokens>.Int); $r.cost-usd(%e<usd>) }
        when 'error'   { $r.failed(%e<message> // '') }
        when 'done'    { $r.finish }
    }
}
```

Report only figures the harness printed. Money it never reported stays
`unreported` on the receipt; it is never shown as nothing.

## 5. Say what it can be asked for

```raku
method manifest(--> Hash) {
    %( providers => ['acme'],     # whose models it reaches; add them in ~/.321/models/ or Do321::Models
       access => 'harness',       # it signs in and calls the provider itself
       sets-model => True,        # --model works for one run
       efforts => [],             # the effort settings it takes, least first
       reports => %( usd => False, tokens => False ),
       spend-cap => False )
}
method ready(Str $path --> Str) { ... }            # '' when it can run; else "not logged in"
method help-argv(--> List)  { ('run', '--help') }  # for `321 harness check`
method flags-used(--> List) { <--quiet --model> }
```

`help-argv` and `flags-used` let `321 harness check` tell a person when a
new version of your harness drops a flag the adapter passes.

## 6. Register it

Three lines, which `tools/new-harness` prints for you:

- in `lib/Do321/CLI.rakumod`, with the other `use` lines:
  `use Do321::Harness::Acme;`
- in `default-registry`, in the same file:
  `.register(Acme.new(:binary(%*ENV<DO_321_ACME_BINARY> // ''), :stderr($stderr)))`
- in `META6.json` under `provides`:
  `"Do321::Harness::Acme": "lib/Do321/Harness/Acme.rakumod"`

Nothing else names a harness: every screen takes its name, its note and
what it can do from the adapter.

## 7. Test it, then try it

```
prove --ext .rakutest -e "rakupp -Ilib" t/harness-acme.rakutest
rakupp -I lib --aot --standalone bin/321 -o dist/321
dist/321 harness can            # your harness, what it enforces, whether it is ready
dist/321 harness check acme     # its version, and whether its help names your flags
```

`harness-contract-ok` in the test holds the adapter to the shape the
runtime reads. It cannot tell whether a claim is true: show that against
the real executable, and say how in the pull request.

## What a pull request needs

- the three files and the three lines;
- the suite green (`prove -j4 --ext .rakutest -e "rakupp -Ilib" t/`);
- for each claim in `enforcement`, how you checked it and on which
  version of the harness;
- no model called by any test: the stand-in under `testdata/fakeharness/`
  speaks for the real command.

Hooks, so that a controller such as IZ4 can check each action inside your
harness, are a second step: see "Adding a harness" in
[reference.md](reference.md).
