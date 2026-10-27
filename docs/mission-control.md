# Mission Control

Runs that outlive the terminal, watched and steered from one screen.
Processes do the work. Files carry the messages. Mission Control presents the state.

Until its words join `321`'s own command registry, Mission Control is a
separate entry, `321-mc`, built beside `321`:

    rakupp -I lib --aot --standalone bin/321-mc -o dist/321-mc

| Command | What it does |
|---|---|
| `321-mc` | opens Mission Control, only when stdin and stdout are terminals, without `--json` or `--brief` or `DO_321_BRIEF=1`, and with `TERM` not `dumb`; with `--brief` or `--json` it lists the runs as records; otherwise prints help and exits 64 |
| `321-mc start <agent> <request...>` | starts a run that keeps going when the terminal closes |
| `321-mc attach <run>` | opens Mission Control on one run; in a pipe, prints its phase |
| `321-mc stop <run>` | asks the run to stop through its inbox and waits for its own evidence |
| `321-mc stop <run> --force` | stops a run whose host is not answering, by process identity |
| `321-mc restart <run>` | a new run of an ended run's request, with its own id and budget; asks first on a terminal, and takes `--yes` in a pipe |
| `321-mc runs` | one record per run: id, phase, outcome, agent, request |

A run is named by its id or the last three characters of it.

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

- `321 run` ignores SIGTERM once its stdin has closed. When a host is
  killed outright, its runtime and harness keep running until
  `321-mc stop <run> --force` finds them through `tree.json`.
- The streaming Claude adapter is not built yet. It would give live
  steering, a true hold at the tool boundary, and interrupt.
- macOS has no `/proc`, subreaper or `setpriv`, so this is Linux first.
