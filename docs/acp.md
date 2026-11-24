# ACP: what it would give 321, and what it would not

Written 2026-11-24 while building the Claude Code path for 123.do. Nothing
here is built. It records what was checked so the next harness choice is
made from facts.

## What ACP is

The Agent Client Protocol is JSON-RPC 2.0 over a child process's stdin and
stdout, made for editors that drive coding agents. A client starts the
agent, calls `initialize`, `session/new` (or `session/load`), then
`session/prompt`; the agent streams `session/update` notifications (text,
tool calls, plans) and may call back into the client for file reads and
writes, terminals and `session/request_permission`. `session/cancel` ends
the turn in progress.

Agents that speak it: Claude Code and Codex through adapters published by
Zed, Gemini CLI natively, Google's Antigravity through `agy acp`, and
several others.

## What it would give 321

- **One adapter for many harnesses.** A single `acp` adapter could run any
  agent that speaks the protocol, where today each harness is its own
  class.
- **A permission callback.** `session/request_permission` reaches the
  client before a tool runs, so 321 could refuse a tool call outside the
  package's grants without a harness-specific hook. That is real
  enforcement of the tool allowlist.
- **File and terminal calls through the client.** When an agent asks the
  client to read, write or run, 321 sees the path and the command. That is
  a natural place for the workspace boundary.
- **A structured stream** of updates, which maps onto 321's run events.

## What it would not give

- **No steer and no pause in the middle of a turn.** The protocol has
  prompt and cancel. A steer stays what it is today: end the turn, start
  the next one with the instruction. Codex's own app-server protocol has
  `turn/steer` and `turn/interrupt`; ACP does not.
- **No network control.** A command the agent runs in its own terminal, or
  a fetch it makes itself, is not visible to the client. `network: none`
  with a shell stays unenforceable, so it stays denied.
- **No guarantee every agent routes files and commands through the
  client.** An adapter may advertise the client capabilities and the
  agent may still act on its own. What 321 can claim depends on each
  agent, and must be tested per agent before it is claimed.
- **No cost or usage report** in the protocol. Spend caps and cost on the
  receipt would come from each agent's own flags, or be unreported.
- **No structured final answer.** 321's done conditions need the agent to
  say, per condition, met or not, with proof. Over ACP that is a prompt
  convention parsed from text, weaker than Claude Code's `--json-schema`.

## Keys and terms

ACP carries no credentials. Each agent reads its own provider's key or
login, so the provider-key scoping 321 does for Claude Code (an agent is
launched without other providers' keys) applies unchanged. Using Claude
Code through ACP is still using Claude Code: the same terms apply to whose
credentials it runs on.

## Recommendation

Keep Claude Code on its own adapter: it enforces more than ACP can carry
(tool allowlist on the command line, structured output, turn and spend
limits, session resume). Add an `acp` adapter when a second harness is
wanted that has no adapter of its own, claiming only what the protocol and
that agent were shown to enforce, and denying a package that needs more.
Codex is better driven through its app-server, which has the live steer
ACP lacks.
