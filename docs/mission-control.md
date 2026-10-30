# Mission Control

Runs that outlive the terminal, watched and steered from one screen.
Processes do the work. Files carry the messages. Mission Control presents the state.

Mission Control is part of `321`: its words are `321`'s own, in the
registry that help, typo suggestions and shell completion all read.

| Command | What it does |
|---|---|
| `321 tui`, or `321` alone | opens Mission Control (`321` alone in a pipe prints help, as before), only when stdin and stdout are terminals, without `--json` or `--brief` or `DO_321_BRIEF=1`, and with `TERM` not `dumb`; with `--brief` or `--json` it lists the runs as records instead |
| `321 start <agent> <request...>` | starts a run that keeps going when the terminal closes |
| `321 attach <run>` | opens Mission Control on one run; in a pipe, prints its phase |
| `321 stop <run>` | asks the run to stop through its inbox and waits for its own evidence |
| `321 stop <run> --force` | stops a run whose host is not answering, by process identity |
| `321 start --harness <name> --isolate <agent> <request...>` | the same, on the harness named, in a worktree of its own |
| `321 restart <run>` | a new run of an ended run's request, with its own id and budget; asks first on a terminal, and takes `--yes` in a pipe; `--harness` runs it on another engine |
| `321 harness can` | the harnesses this machine has, whether 321 drives each, and what each can enforce |
| `321 tui --brief` | one record per run: id, phase, outcome, agent, harness, request |

A run is named by its id or the last three characters of it.

Each Mission Control session writes `~/.321/logs/tui.log` (yours alone:
0600 in a 0700 directory; `DO_321_TUI_LOG` names another file): every key
and what it changed, every line sent, everything the screen said back,
and any error with its backtrace. A single character being typed is
logged as `typed`, never itself; a line sent is logged whole. Past 1 MB
the log starts again, keeping one before as `tui.log.1`.

## How a run is hosted

`start` builds the work package through the CLI's own builder, so trust,
grants and the policy ceiling are exactly those of `321 <agent> <request>`.
A run started here carries no approval. It then starts a host in a
session of its own with `setsid`. The host:

- records who it is in `host.json`: pid, start time, boot id;
- runs the unchanged runtime, `321 run --package FILE`, as its child, under
  `setpriv --pdeathsig TERM`;
- is the only writer of `events.jsonl`;
- takes requests from `inbox/`, numbers them in arrival order, and hands
  them to the runtime as directives;
- is the subreaper of everything below it. When the runtime ends, it stops
  whatever the agent left running and records each process.

The runtime writes the receipt, and nothing changes a receipt.

## The screen

Below 80 columns or 22 rows the crew folds into one line. From 150
columns the crew is a rail at the left, the conversation is in the middle,
and the selected run's evidence is at the right: harness, attempts, tools,
cost with its basis, the host and its heartbeat, the processes below it
with their CPU and memory, the open control, the receipt.

| Key | Does |
|---|---|
| Enter | sends what is typed to the selected run as a steer |
| Esc | between typing and moving among runs |
| `v` | shows every run, the active ones, or the ones that need you |
| Ctrl-F | finds words in the conversation; Enter again for the next older |
| Ctrl-P | every action, Run again among them for an ended run |

A run that said something since you last looked at it is marked new. A
steer is shown at once as sending, and as unconfirmed when its run has not
taken it within five seconds. A running run whose host has not written its
status for ten seconds says so; whether it is lost is still decided by
the kernel, not by the silence.

## Agents and harnesses

An agent is the crew: its name, role, character and package, installed
once. A harness is the engine a run uses: Claude Code, Codex, or 321's own
procedure executor. A run binds one agent package to one harness, one
workspace and one request:

    agent + harness + mission = run

So Bea on Claude Code and Bea on Codex are two runs, each with its own id,
log, inbox, receipt and controls, and stopping one never touches the
other. The screen leads with the agent and shows the harness beside it,
quieter: `BEA  claude` and `BEA  codex`. The evidence pane lists what that
harness can and cannot do.

**What a harness can do comes from its adapter.** Each adapter states
which features it enforces (tool allowlist, network off, turn and spend
limits, structured output, event stream, resume, graceful stop, live
steer, hold). Mission Control turns those claims into words ("steer
between steps", "keeps the network off", "no spend limit") and offers
only the controls that follow from them. Nothing on the screen is keyed
to a provider's name, so a new adapter is shown correctly as soon as it
is registered.

| | Claude Code | Codex |
|---|---|---|
| tools held to the grant | yes, by an allowlist | no: its sandbox limits effects, not tools; its web search and MCP servers run outside it |
| network off | no | yes, by its sandbox (tried: no host resolves) |
| turn and spend limits | yes | no |
| steer | between steps | between steps |
| hold | ends the step | ends the step |
| cost | dollars, as it reports them | tokens only, with the cost marked unreported |

**Choosing a harness.** `--harness` names one, and `bea on codex` in the
new-run line does the same. Without one, the runtime picks the first
harness able to enforce what the package needs. Either way, the runtime
checks the choice again: a harness that cannot enforce a requirement is
refused, never used with the requirement waived.

**Workspaces.** Two runs that can write never share a workspace. A second
one is refused and told about `--isolate`, which gives the run a git
worktree of the workspace at its last commit, under `~/.321/worktrees`.
Changes not yet committed are not in it. The run never commits. You
review what it did there, take it, and remove the worktree with
`git worktree remove`.

**Running again on another harness** makes a new run of the same request
with its own budget. It names the old run and that run's receipt
digest, gets a fresh worktree if the old run had one, and carries no
approval or grant. Nothing of the old harness's session moves across.

## The run directory

`~/.321/runs/<run-id>/`, mode 0700. Each file has one writer.

| File | Writer | Meaning |
|---|---|---|
| `run.json` | launcher, once | what was launched; `continues` names the run it is again of, and that run's receipt digest |
| `work-package.json` | launcher, once | the package as issued |
| `host.json` | host, once | who is running it |
| `live` | host | exists from host start until the end is written |
| `events.jsonl` | host | what happened, in order, `seq` without gaps |
| `status.json` | host, atomic replace | a cache of the folded state, never proof, with `usage`: CPU and memory of the processes below the host, from `/proc` |
| `tree.json` | host, each heartbeat | the processes below the host, by identity |
| `inbox/` | any client | `<ULID>-<kind>.json`, written whole and renamed in |
| `receipt.json` | the runtime, once | the outcome |
| `ended.json` | first to prove it | an end the host could not record, with its basis |

The inbox carries `steer`, `clarify`, `hold`, `resume` and `stop`, and
nothing else. No file can approve, grant or widen anything. A directive is
read only when it is a regular file, owned by this user, private, well
formed, and addressed to this run. Anything else is moved to
`inbox/rejected/` and logged as `directive_refused`.

`~/.321/runs` must be on a local filesystem. On NFS, SMB or FUSE a
rename or an exclusive create may not mean the same thing to every
reader, so `start` refuses and says to set `DO_321_HOME`.

A run's log keeps everything up to 64 MB. Past that the agent's own words
are dropped and the log says so once (`log_truncated`); tool calls,
controls and the end are still recorded. A screen keeps the newest 2,000
lines of a conversation in memory and says how many earlier ones are only
in `events.jsonl`.

## Phase and outcome

`phase` says where a run is in its life: starting, running, blocked, held,
stopping, ended, lost. `outcome` says how it ended: the receipt's word,
or `lost` when it ended and nobody knows how. A run is `running` only
while its host is that very process. A pid whose start time or boot
differs is not the host. A receipt always wins over `ended.json`.

`stop` and `attach` exit 6 for a lost run. `lost` and exit 6 are
Mission Control's own until they are agreed into the shared outcome
vocabulary.

## What hold and steer do today

Today's Claude Code adapter has no live input. **Hold** ends the agent's
current step now and waits, and **resume** continues the same
conversation. **Steer** ends the current step, and the agent continues
with your words. The screen says "taken" when the runtime has applied a
steer. It never says the agent obeyed.

## Known gaps

- Codex is registered, and is chosen only where its claims cover the
  package. It has a sandbox, not a tool allowlist, so a package with tool
  grants is refused on it, and the receipt names what it cannot enforce.
  Whether a sandbox may count for some grants, per grant and with its
  basis in the receipt, is the owner's decision. Codex also needs
  `codex login`.
- 123.do cannot yet ask for or limit a harness. The owner's trust policy
  (`adapters.preferred` and `adapters.denied`) already can. A work
  package field for it is a change to the shared contract with 123.do,
  and is proposed rather than made.

- `321 run` ignores SIGTERM once its stdin has closed. When a host is
  killed outright, its runtime and harness keep running until
  `321 stop <run> --force` finds them through `tree.json`.
- The streaming Claude adapter is not built yet. It would give live
  steering, a true hold at the tool boundary, and interrupt.
- macOS has no `/proc`, subreaper or `setpriv`, so this is Linux first.
