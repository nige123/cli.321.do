unit module Do321ScreenFixtures;

use Do321::Screen;

#| The screens the design is judged on, as semantic data: twelve moments a
#| person or a program actually meets, from a first run to a structured
#| failure.  The tests render these, and so does tools/snapshot-screens,
#| so what is reviewed is what the renderer does - never a hand-typed
#| mockup of it.
#|
#| The facts here are the real ones from this machine where they could be
#| read (version, host, adapter versions, the agents' own bylines, the
#| digest refusal) so a reviewer is judging a screen they could meet.

constant B1LL  is export = Byline.new(mark => '⬢', name => 'B1LL',   byline => 'builds, and brings the proof',    id => '321.do/b1ll', version => '0.1.0');
constant ODA   is export = Byline.new(mark => '⬡', name => '1DA',    byline => 'the deliberate deployer',         id => '321.do/1da',  version => '0.1.2');
constant PROMPT is export = Byline.new(mark => '◍', name => 'Prompt', byline => 'the plain-spoken page reader',    id => 'local/prompt', version => '0.1.0');

#| name => (one line saying what the moment is, the Screen)
sub fixtures(--> List) is export {
    (
    # ---------------------------------------------------------- discovering
    'first-run' => ('a completely new user, with nothing configured yet', Screen.new(
        title => '',
        subtitle => ['0.4.5', 'throo', 'nothing configured yet'],
        blocks => [
            Note.new(text => '321 hands a piece of work to an agent and keeps the receipt. Nothing changes a file or deploys anything without authority you grant.'),
            Rows.new(rows => [
                Row.new(label => 'here:',    value => '/home/s3/web.321.do (git), IZ4 guarded in claude_code'),
                Row.new(label => 'harness:', value => 'claude_code 2.1.311 — a model can run here'),
                Row.new(label => 'agents:',  value => 'none yet'),
            ]),
        ],
        next => [ Step.new(advice => 'try the reader that comes with 321: it only reads, and its receipt says what it cost', command => '321 try') ],
        then => Step.new(advice => 'pin an agent of your own', command => '321 help trust'),
    )),

    # The first action a newcomer takes.  It must be safe, it must be
    # whole - a real run, a real receipt - and it must not pretend to be
    # free: it asks a model.  So the screen says what it is about to do
    # before it does it, and what it cost after.
    'try' => ('the first thing a newcomer runs, and the first receipt they own', Screen.new(
        title => 'try',
        byline => PROMPT,
        blocks => [
            Note.new(text => 'It reads the files it can see here, answers one question about them in text, and changes nothing. It asks a model to do that, so it costs: the receipt will say exactly what.'),
            Rows.new(rows => [
                Row.new(label => 'workspace:', value => '/home/s3/web.321.do (git) — read only'),
                Row.new(label => 'granted:',   value => 'repo.read, and nothing else: no shell, no network, no writing'),
            ]),
            Said.new(mark => '◍', who => 'Prompt', text => 'This is the public website for 321, a Perl and Mojolicious site rendered on the server. It explains what 321 is for, profiles the agents, and links to the documentation and releases.'),
            Upshot.new(state => 'no change', sentence => 'it answered from the files here and changed nothing'),
            Rows.new(rows => [
                Row.new(label => 'cost:',    value => '$0.31, 2 turns, 1 attempt, as the harness reported'),
                Row.new(label => 'receipt:', value => '~/.321/runs/01M5Y6QK8WVD3ZPT1XHN4JCR7B/receipt.json'),
            ]),
        ],
        next => [ Step.new(advice => 'ask it something of your own', command => '321 prompt <request…>') ],
        then => Step.new(advice => 'pin an agent of your own, and meet the crew', command => '321 help trust'),
    )),

    'completion' => ('someone pressing TAB to find a command', Screen.new(
        title => 'help completion',
        subtitle => ['bash, zsh and fish', 'one registry, the same as dispatch'],
        blocks => [
            Note.new(text => 'What the shell offers, as the engine itself answers it:'),
            # what the engine actually answers, not what would look good:
            # these are the candidates from lib/Do321/Complete.rakumod
            Table.new(heads => ['typed', 'offered'], rows => (
                ['321 a⇥',           'agents'],
                ['321 agents ⇥',     'check'],
                ['321 1da ⇥',        'go  plan  status'],
                ['321 --grant ⇥',    'repo.read  repo.write  shell.run  net.fetch  …'],
                ['321 receipt ⇥',    'show  verify'],
                ['321 agnets',       'did you mean agents?'],
            )),
            Note.new(text => 'Completion reads the registry and the trust file, and takes 0.5ms. It runs no agent, loads no package, writes nothing and asks for no authority.'),
        ],
        next => [ Step.new(advice => 'install it for this shell', command => '321 completion bash >> ~/.bashrc') ],
    )),

    # -------------------------------------------------------------- working
    'work-starting' => ('an agent beginning work: the live line, before anything is known', Screen.new(
        title => 'b1ll: wrap the status rows at the real terminal width',
        byline => B1LL,
        blocks => [
            Rows.new(rows => [ Row.new(label => 'workspace:', value => '/home/s3/cli.321.do (git); you commit, the agent only edits') ]),
        ],
    )),

    'work-said' => ('the agent has said something, and it is marked as its own words', Screen.new(
        title => 'b1ll: wrap the status rows at the real terminal width',
        byline => B1LL,
        blocks => [
            Rows.new(rows => [ Row.new(label => 'workspace:', value => '/home/s3/cli.321.do (git); you commit, the agent only edits') ]),
            Said.new(mark => '⬢', who => 'B1LL', text => 'The widths are nailed down in three places — 54, 72 and 76. I am taking them from the terminal instead, clamped so a narrow window still reads, and leaving a pipe at 72. Running the suite before I touch anything.'),
        ],
    )),

    # ------------------------------------------------------------ completing
    'done' => ('a successful operation and its evidence', Screen.new(
        title => 'b1ll: wrap the status rows at the real terminal width',
        byline => B1LL,
        blocks => [
            Upshot.new(state => 'done', sentence => 'the rows fold at the terminal width, clamped 40 to 100'),
            Rows.new(rows => [
                Row.new(label => 'changed:', value => 'lib/Do321/Screen.rakumod, t/21-screen.rakutest'),
                Row.new(label => 'checked:', value => '1652 tests just now, 51s'),
                Row.new(label => 'cost:',    value => '$0.31, 3 turns, 1 attempt, as the harness reported'),
                Row.new(label => 'receipt:', value => '~/.321/runs/01M5Y4X5ETGV2YPW3C6F4T2XE2/receipt.json'),
            ]),
            Note.new(text => 'nothing is committed: the change is yours to read, then commit'),
        ],
        next => [ Step.new(advice => 'read it', command => 'git diff') ],
        then => Step.new(advice => 'every event and tool call', command => '321 --verbose b1ll …'),
    )),

    'no-change' => ('a no-change outcome: it ran, it answered, it changed nothing', Screen.new(
        title => 'prompt: in one sentence, what is this repository for?',
        byline => PROMPT,
        blocks => [
            Upshot.new(state => 'no change', sentence => 'answered from README.md and changed nothing'),
            Said.new(mark => '◍', who => 'Prompt', text => 'This repository is the server-rendered public website for 321, the meta harness that keeps your agents the same while the harness underneath can be swapped.'),
            Rows.new(rows => [
                Row.new(label => 'cost:',    value => '$0.34, 3 turns, 1 attempt, as the harness reported'),
                Row.new(label => 'receipt:', value => '~/.321/runs/01M5Y4X5ETGV2YPW3C6F4T2XE2/receipt.json'),
            ]),
        ],
        next => [ Step.new(advice => 'ask the next thing', command => '321 prompt <request…>') ],
    )),

    'blocked' => ('a blocked action waiting on a person, with nothing done', Screen.new(
        title => '1da: go 123.web live',
        byline => ODA,
        blocks => [
            Upshot.new(state => 'blocked', sentence => 'a plan is ready and nothing has been deployed'),
            Rows.new(rows => [
                Row.new(label => 'needs:',   value => 'your word for this exact plan'),
                Row.new(label => 'plan:',    value => '123.web → live at 2d8417c, written to the receipt'),
                Row.new(label => 'not done:', value => 'deploy.invoke is not granted, so no step was executed'),
                Row.new(label => 'cost:',    value => 'none (no model was used)'),
                Row.new(label => 'receipt:', value => '~/.321/runs/01M5NB9K2TQ4D7WZ1XCJ8PLV3M/receipt.json'),
            ]),
        ],
        next => [ Step.new(advice => 'read the plan, then run it with the grant it needs', command => '321 --grant deploy.invoke 1da go 123.web live') ],
        exit => 2,
    )),

    # the failure case, and the word matters: nothing failed, 321 refused.
    # 'denied' is what the machine says too, so a person and a program read
    # the same word for the same event.
    'denied' => ('a refusal with a recovery step that actually recovers it', Screen.new(
        title => 'b1ll',
        blocks => [
            Upshot.new(state => 'denied', sentence => 'the package moved since you pinned it, so nothing ran'),
            Rows.new(rows => [
                Row.new(label => 'pinned:',  value => 'sha256:be4cfffeb67dfe42d6… in ~/.321/trust.json'),
                Row.new(label => 'on disk:', value => 'sha256:fa04f4d3e6bf0aa6cc… at /home/s3/agents.321.do/packages/321.do/b1ll'),
                Row.new(label => 'changed:', value => 'identity.byline added (1 field)'),
            ]),
            Note.new(text => '321 will not run a package whose content you have not pinned.'),
        ],
        next => [ Step.new(advice => 'see what moved, then pin it if it is yours', command => '321 trust diff b1ll') ],
        exit => 5,
    )),

    'history' => ('a returning user, seeing what the crew has actually done', Screen.new(
        title => 'log',
        subtitle => ['7 days', '26 runs', '~/.321/runs'],
        blocks => [
            Rows.new(rows => [
                Row.new(label => 'done:',    value => '19 runs changed something and said what'),
                Row.new(label => 'no change:', value => '5 ran and changed nothing'),
                Row.new(label => 'waiting:', value => '1 is waiting on you'),
                Row.new(label => 'failed:',  value => '1 did not run at all'),
            ]),
            Table.new(heads => ['when', 'who', 'work', 'outcome'], rows => (
                ['just now',     Who.new(mark => '⬢', name => 'b1ll'),   'wrap the status rows at the real width', State.new(word => 'done')],
                ['11 min ago',   Who.new(mark => '⬡', name => '1da'),    'go 123.web live',                        State.new(word => 'blocked')],
                ['21 hours ago', Who.new(mark => '◍', name => 'prompt'), 'what is this repository for',            State.new(word => 'no change')],
                ['2 days ago',   Who.new(mark => '⬢', name => 'b1ll'),   'fix the failing status test',            State.new(word => 'done')],
            )),
            Note.new(text => 'a receipt says what ran and what changed, never that the work is right'),
        ],
        next => [ Step.new(advice => 'the one waiting on you', command => '321 receipt show 01M5NB9K') ],
    )),
    )
}
