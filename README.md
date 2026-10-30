# 321

**Mission control for agents.** You give the order. 321 launches the work
on a harness, such as Claude Code or Codex, and keeps you in command:
steer, hold, stop. [321.do](https://321.do)

## Why use it

- **Agent tools change every month. Your agents should not.** An agent is
  the same whichever harness runs it. 321 places it on one that can
  enforce what it needs, and refuses one that cannot.
- **You stay in command.** Watch every run on one screen, and steer, hold
  or stop any of them while it works.
- **Proof, not promises.** Every run ends with a receipt you can check:
  what ran, what changed and what it cost.
- **Your machine, your server, your repository.** No account, no service.
  Free, Apache-2.0.

## What it does

```
321 <agent> <request...>        hand an agent the work; the receipt says what happened
321                             Mission Control: every run on one screen
321 start <agent> <request...>  a run that keeps going when you close the terminal
321 steer <run> <words...>      say something to it while it works
321 stop <run>                  ask it to stop, and wait for its own word
```

Inside Mission Control the same words start with a slash: `/start`,
`/steer`, `/hold`, `/stop`. Anything else you type goes to the run you are on.
The agents are listed at [321.do/agents](https://321.do/agents).

## Install

Download the file for your system from
[321.do/download](https://321.do/download) or the
[releases](https://github.com/nige123/cli.321.do/releases). Check it,
then put it on your `PATH`:

```
sha256sum -c 321-linux-x86_64.sha256
chmod +x 321-linux-x86_64 && mv 321-linux-x86_64 ~/.local/bin/321
321 doctor
```

Each file stands alone. To build one from source, use
[Raku++](https://github.com/ash/rakupp):

```
rakupp -I lib --aot --standalone bin/321 -o dist/321
```

## More

`321 help` shows the commands. The details are in
[docs/reference.md](docs/reference.md) and
[docs/mission-control.md](docs/mission-control.md).
