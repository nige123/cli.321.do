unit module Do321::Help;

#| Help a person can hold in their head.
#|
#| '321 help' shows the handful of commands for everyday work and the
#| few for when intent must hold, and stops.  Everything else is one
#| step away: '321 help more' lists the rest in small groups, '321 help
#| machine' the commands a tool calls, and '321 help <command>' says
#| what one command is for, how to call it, and gives one example.  No
#| screen here is long, on purpose: a person reading help is in the
#| middle of something else.
#|
#| An action is a word, never a flag: '321 iz4 install', '321 key new'.
#| Flags only adjust how a command does its one thing.
#|
#| Examples are built from what is configured on this machine (the first
#| alias in the trust file) so they are the person's own commands.  When
#| nothing is configured the examples use 'helper', the unbranded fixture
#| name, never an official agent: the runtime hard-codes no agent name.

use Do321::Look;

#| What a capability lets an agent do, in the words a person weighing one
#| agent against another can read.  A capability with no plain words is
#| shown by its own name rather than guessed at.
constant %CAP-PLAIN = (
    'repo.read'     => 'read the files in your workspace',
    'repo.write'    => 'change files in your workspace',
    'shell.run'     => 'run shell commands there',
    'net.fetch'     => 'fetch things over the network',
    'files.read'    => 'read files outside the workspace',
    'files.write'   => 'write files outside the workspace',
    'model.text'    => 'ask a model for text',
    'deploy.read'   => 'read what is deployed',
    'deploy.plan'   => 'plan a deployment without carrying it out',
    'deploy.invoke' => 'carry out a deployment',
);
sub capability-plain(Str $cap --> Str) is export { %CAP-PLAIN{$cap} // $cap }

#| A topic: the words that name it, how it is shown in a list, the group
#| it is listed under, one line saying what it is for, how to call it, a
#| few lines more, and one example.  '<agent>' in any of them becomes the
#| person's own first agent.
class Topic is export {
    has Str $.name    is required;
    has Str $.shown   = '';
    has Str $.group   is required;
    has Str $.summary is required;
    has @.usage;
    has Str $.more = '';
    has Str $.example = '';
    method listed(--> Str) { $!shown ne '' ?? $!shown !! $!name }
}

sub t(Str $name, Str $group, Str $summary, @usage, Str $more = '', Str $example = '', Str :$shown = '') {
    Topic.new(:$name, :$shown, :$group, :$summary, :@usage, :$more, :$example);
}

constant EVERY-DAY is export = 'Every day';
constant HOLD      is export = 'When intent must hold';
constant MACHINE   is export = 'For tools';
constant RUNS      = 'Runs that outlive the terminal';
constant RUNS-MORE = 'Runs';
constant STEERING  = 'Steering a run';

#| Every command, in the order it is listed.
sub topics(--> List) is export {
    (
    t('ask', EVERY-DAY, 'hand an agent the work; the receipt says what happened',
      ['321 <agent> <request...>', '321 <publisher>/<agent> <request...>', '321 <agent> -                      (the request from standard input)'],
      'The request is plain words. It becomes the objective of a work package and is never handed to a shell. While it runs at a terminal, type to steer, /pause, /resume, /stop; Ctrl-C stops. The screen is the verdict, what changed and the receipt; --verbose before the name shows the trust, grants, every event and tool call. Other options: 321 help options.',
      '321 <agent> note: remember the milk', :shown('<agent> <request...>')),
    t('agents', EVERY-DAY, 'who you can ask here',
      ['321 agents', '321 agents <agent>'],
      'Each configured package with its trust level, version and alias, read from ~/.321/trust.json. With a name it is 321 whois: an introduction to that agent. 321 help trust says how one is added.',
      '321 agents'),
    t('status', EVERY-DAY, 'your last runs, and what to do next',
      ['321 status', '321 status --runs N'],
      'One screen: where you are and whether an IZ4 governs it, the agents, the deploy binding, whether receipts are signed, the last runs, and the next step the newest run that needs you is waiting for. A receipt says what ran and what changed, never that the work is right.',
      '321 status'),
    t('log', EVERY-DAY, 'what the crew has done, and what came of it',
      ['321 log', '321 log --days N', '321 log --agent NAME'],
      'The receipts read back, newest first: a count for each outcome that happened and none for an outcome that did not, what was actually spent and how many runs reported nothing, then a row per run with who did it and how it ended. The last seven days unless --days says otherwise. It reads receipts and changes nothing.',
      '321 log --days 30'),
    t('receipt', EVERY-DAY, 'what a receipt proves, and how to check one',
      ['321 receipt verify FILE', '321 receipt verify FILE --key B64'],
      'Every run ends with one marked word: completed, blocked (it needs your answer), failed, denied or stopped, the reasons beneath; then the files changed, the tools called, the cost with its basis, and the receipt\'s path. verify checks a receipt\'s digest against its content and its signature against a key: this 321\'s own, or --key. A receipt says what ran and what changed; it never says the work is right.',
      '321 receipt verify receipt.json', :shown('receipt verify FILE')),

    t('tui', RUNS, 'every run on one screen, watched and steered',
      ['321 tui', '321'],
      '321 alone at a terminal opens it too; in a pipe, 321 alone prints this help. Mission Control: a row per run with its agent, harness, state and cost, what each has done and said, and a line to steer the one you are on. Runs keep going when you close it. It needs a terminal on both ends; in a pipe, 321 start, 321 stop and --brief do the same work.',
      '321 tui'),
    t('start', RUNS-MORE, 'start a run that keeps going when you leave',
      ['321 start <agent> <request...>', '321 start --harness NAME --isolate <agent> <request...>'],
      'The run gets an id, a host process of its own and a budget, and goes on after this terminal closes. --harness asks for one harness; the run is refused if that harness cannot enforce what the agent needs. --isolate gives it a git worktree of its own, so two runs can work in one repository; a second writer in a shared workspace is refused. 321 harness can lists the harnesses.',
      '321 start <agent> tidy the README', :shown('start <agent> <request...>')),
    t('stop', RUNS-MORE, 'ask a run to stop, and wait for its own word',
      ['321 stop <run>', '321 stop <run> --force'],
      'Asks through the run\'s inbox and waits for the run to say it stopped. --force stops a run whose host is not answering, by process identity. A run is named by its id or the last three characters of it.',
      '321 stop 3by', :shown('stop <run>')),

    t('steer', STEERING, 'say something to a run while it works',
      ['321 steer <run> <words...>'],
      'The words go to the run through its inbox, and the result says whether the run took them. On Mission Control, typing on the input line does the same for the run you are on.',
      '321 steer 3by use the newer file', :shown('steer <run> <words...>')),
    t('hold', STEERING, 'end its current step now and wait',
      ['321 hold <run>'],
      'The run stops at the end of what it is doing and waits; nothing is lost. 321 resume carries it on. On Mission Control it is /hold, or h.',
      '321 hold 3by', :shown('hold <run>')),
    t('resume', STEERING, 'carry on a held run where it was',
      ['321 resume <run>'],
      'A held run carries on its conversation where it was held. On Mission Control it is /resume, or r.',
      '321 resume 3by', :shown('resume <run>')),

    t('attach', RUNS-MORE, 'open Mission Control on one run',
      ['321 attach <run>'],
      'Mission Control with that run selected. In a pipe it prints the run\'s phase instead.',
      '321 attach 3by', :shown('attach <run>')),
    t('restart', RUNS-MORE, "run an ended run's request again, with its own budget",
      ['321 restart <run>', '321 restart <run> --harness NAME'],
      'A new run with its own id and budget; the old receipt is unchanged. It asks first on a terminal and takes --yes in a pipe. --harness runs it on another harness.',
      '321 restart 3by', :shown('restart <run>')),

    t('iz4 install', HOLD, 'wire the project\'s IZ4 into the harness here',
      ['321 iz4 install', '321 iz4 install --advisory', '321 iz4 install --harness NAME'],
      'Writes the hooks that put the IZ4 before the agent, hold an edit or a shell command until it is checked, and check the finished turn, as strongly as the harness allows, then reads them back. Installing again changes nothing. --advisory wires the context alone: nothing is refused. --workspace DIR names another directory.',
      '321 iz4 install'),
    t('iz4 status', HOLD, 'what is enforced here, one verdict per harness',
      ['321 iz4 status', '321 iz4 status --verbose'],
      'A row per harness: its level (aware, checked or guarded) and what that is made of. --verbose lists every control and the warnings. It says what is wired, not what happened: a run\'s receipt records the checks that ran. 321 help enforcement explains the levels.',
      '321 iz4 status'),

    t('whois', 'Agents and trust', 'meet an agent: what it is for, how it works, what it may do',
      ['321 whois <agent>'],
      'An introduction in the package\'s own words: what it is for, its personality, how it speaks and how it decides, what each skill it carries says it does, what it asks to be allowed and what it refuses, and the trust it holds here. A run gets only what that, your grants and this machine\'s policy agree on. In a pipe, --brief gives id, version, level, byline and role.',
      '321 whois <agent>', :shown('whois <agent>')),
    t('trust', 'Agents and trust', 'the trust file: what may run here',
      ['321 trust show', '321 trust check'],
      '~/.321/trust.json (or --trust FILE) names every package that may run: a publisher\'s pinned package, checked by digest and signature; one pinned as development, digest only; or a local path. Short names are aliases you choose. check loads every one and says which fail. Without a trust file, --package-dir DIR runs an unsigned local package.',
      '321 trust check'),
    t('packages', 'Agents and trust', 'check, digest and read agent packages',
      ['321 packages validate DIR', '321 packages digest DIR [--write]', '321 packages show ID', '321 packages builtin prompt'],
      'A package is a directory with agent.json, a DIGEST and optionally a SIGNATURE. Loading one never runs anything in it and installs nothing. builtin prompt writes the built-in prompt-only package and prints its path: into a pipe, the path alone.',
      '321 packages validate ./my-package'),
    t('doctor', 'Agents and trust', 'what this machine can run and enforce',
      ['321 doctor', '321 doctor --verbose'],
      'A row per adapter 321 knows: whether it is here and how much it enforces; then the tools bound to procedures by explicit path, whether iz4 can be driven, the trust file and the policy in words. --verbose lists what each adapter enforces, feature by feature.',
      '321 doctor'),
    t('key', 'Agents and trust', 'this 321\'s receipt-signing key',
      ['321 key', '321 key new'],
      'With a key under ~/.321 every receipt this 321 writes is signed over its digest; the public half is what a checker pins. Alone it shows the key; new makes one.',
      '321 key new'),

    t('deploy', 'Deploying', 'look, plan, then go: the deploy tool and its boundary',
      ['321 <agent> status', '321 <agent> plan SERVICE TARGET', '321 <agent> go SERVICE TARGET'],
      'An agent\'s procedures call the dp tool at DP_BIN; nothing is found by PATH. plan gives an exact, checkable plan, and a plan is not an approval. At a terminal, typing the go is your approval: 321 plans first, binds the approval to that exact plan, checks nothing moved, then executes where DP_EXECUTE allows. 321 status shows the binding on this machine.',
      '321 <agent> plan app.web live', :shown('<agent> plan|go SERVICE TARGET')),

    t('harness detect', 'Harnesses', 'the agent environments 321 knows, and which are here',
      ['321 harness detect', '321 harness detect --verbose'],
      'A row per harness: whether it is installed and whether this project is wired into it. --verbose lists the controls it can be driven from: what it enforces, what it only advises, what it cannot do.',
      '321 harness detect'),
    t('harness can', 'Harnesses', 'what each harness can enforce when it runs an agent',
      ['321 harness can'],
      'A row per harness 321 can run an agent on: whether it is ready, what it enforces and what it cannot. An agent runs only on a harness that enforces what its package needs.',
      '321 harness can'),
    t('iz4 remove', 'Harnesses', 'take out only what 321 installed for IZ4',
      ['321 iz4 remove', '321 iz4 remove --harness NAME'],
      'Removes the hooks 321 wrote and nothing else; wiring an earlier iz4 made is left as it is.',
      '321 iz4 remove'),
    t('enforcement', 'Harnesses', 'what aware, checked and guarded mean',
      ['321 help enforcement'],
      'Four levels, as separate facts. aware: the agent is given the IZ4 before it works. checked: the finished turn is checked against it. guarded: an edit or a shell command is held until it is checked. verified is earned by a run and recorded on its receipt. A context in a prompt is told, never enforced, so aware alone refuses nothing.',
      '321 iz4 status'),
    t('hooks', 'Harnesses', 'the older direct wiring: see it, or take it out',
      ['321 hooks status --command CMD', '321 hooks remove --command CMD'],
      'An earlier iz4 wrote its own hook command into a harness. 321 no longer writes one: install is refused, status reports what is there, remove takes it out. 321 iz4 install adopts old wiring instead.',
      "321 hooks status --command 'iz4 hook'"),

    t('options', 'The tool', 'the options that go before the agent name',
      ['321 [options] <agent> <request...>',
       '  --workspace DIR        --package-dir DIR      --attach FILE',
       '  --done TEXT            --grant CAP            --adapter NAME',
       '  --placement client|server|either   --network none|provider_only|open',
       '  --non-interactive  --trust FILE  --verbose  --json  --brief  --plain'],
      'workspace: where the work happens. done: a completion condition, in order. grant: a capability in policy. network: the agent\'s own; shell never implies it. verbose: the whole run. json, brief, plain: for pipes.',
      "321 --done 'a note exists' <agent> note: remember the milk"),
    t('version', 'The tool', 'which 321 this is', ['321 version'], '', '321 version'),
    t('help', 'The tool', 'this help',
      ['321 help', '321 help COMMAND', '321 help more', '321 help machine'], '', '321 help status'),

    t('run', MACHINE, 'a work package in, events and a receipt out',
      ['321 run --package FILE|- [--workspace DIR] [--receipt FILE] [--events FILE]',
       '321 run --continue RECEIPT --package FILE'],
      'Standard input carries the package (with --package -), then directives, one JSON object per line; standard output carries run events, then exactly one receipt. --run-id, --history-dir, --adapter and --package-dir as for a person. continue resumes a blocked run of the same package: cost and attempts carry forward, the old receipt is linked. Schemas: schemas/*.v1.json.',
      '321 run --package work.json --receipt receipt.json'),
    t('hook', MACHINE, 'the glue a harness calls at one of its events',
      ['321 hook HARNESS CONTROLLER CONTROL'],
      'Reads the harness\'s native event on standard input, asks the controller, and answers in the harness\'s own terms. 321 iz4 install writes it into a project\'s settings; it is not typed by hand.',
      '321 hook claude_code iz4 filesystem_guard < event.json'),
    t('host', MACHINE, 'the process that keeps one run going',
      ['321 host DIR'],
      'What 321 start leaves running: it drives one run in its directory, takes steers and stops from the inbox there, and writes the status Mission Control reads. 321 start and 321 restart start it; a person does not.',
      '321 start <agent> <request...>', :shown('host DIR')),
    t('completion', MACHINE, 'what your shell offers when you press TAB',
      ['321 completion bash|zsh|fish', '321 completion words -- <typed...>    (a shell calls this)'],
      'Write the line your shell sources: bash in ~/.bashrc, zsh in ~/.zshrc, fish in ~/.config/fish/completions/321.fish. The script holds no list of its own; it asks 321 completion words, which reads the same registry dispatch and help read, so nothing goes stale. Completing starts nothing and asks for no authority.',
      '321 completion bash >> ~/.bashrc', :shown('completion bash|zsh|fish')),
    t('brief', MACHINE, 'pipeline mode: one tab-separated record per line',
      ['321 --brief COMMAND...', 'DO_321_BRIEF=1 321 COMMAND...'],
      'The result alone, no title, rows or next step; a failure is one line on standard error and the exit code; --json is the other form, not both. Records: status when agent status request waiting-on; agents id level version alias; trust check loads|failed id level why; packages validate valid id version digest; packages builtin and digest the value alone; a run kind text per event, then status package summary receipt waiting-on.',
      '321 --brief status | cut -f3'),
    )
}

sub topic(Str $name --> Topic) is export { topics().first({ .name eq $name }) // Topic }

sub topic-names(--> List) is export { topics().map(*.name).List }

#| The agent name used in examples: the first configured alias, else the
#| first configured id, else the unbranded 'helper'.
sub example-agent(%ctx --> Str) is export {
    my @a = @(%ctx<agents> // []);
    @a ?? @a[0].Str !! 'helper';
}

my sub own(Str $s, %ctx --> Str) { $s.subst('<agent>', example-agent(%ctx), :g) }

#| The mark in text, one line: the icon, then the name and what it is for.
sub text-logo(--> Str) is export {
    "{icon()} 321.do - Mission control for agents.";
}

my sub listing(Topic $t, Int $w, %ctx --> Str) { sprintf("  321 %-{$w}s %s", own($t.listed, %ctx), $t.summary) }

#| The first screen: what 321 is, the commands for everyday work, the
#| few for when intent must hold, and where the rest is.  Nothing more.
sub help-index(%ctx = %() --> Str) is export {
    my @l = '', text-logo(), '';
    for EVERY-DAY, RUNS, HOLD -> $g {
        @l.push: $g;
        @l.push: listing($_, 22, %ctx) for topics().grep({ .group eq $g });
        @l.push: '';
    }
    @l.push: '321 help COMMAND    more on one command, with an example';
    @l.push: '321 help more       the rest: runs, trust, deploying, harnesses, the tool';
    @l.push: '';
    own(@l.join("\n") ~ "\n", %ctx);
}

#| Everything not on the first screen, in small groups.  The commands a
#| tool calls are left to '321 help machine'.
sub help-more(%ctx = %() --> Str) is export {
    my @l = '', "{icon()} 321 help more: runs, trust, deploying, harnesses, the tool", '';
    for topics().map(*.group).unique.grep({ $_ ne EVERY-DAY && $_ ne RUNS && $_ ne HOLD && $_ ne MACHINE }) -> $g {
        @l.push: $g;
        @l.push: listing($_, 28, %ctx) for topics().grep({ .group eq $g });
        @l.push: '';
    }
    @l.push: '321 help COMMAND    more on one command, with an example';
    @l.push: '321 help machine    the commands a tool calls';
    @l.push: '';
    @l.push: 'Highlights appear only on a terminal: NO_COLOR, --plain or DO_321_COLOR=0 turns them off, DO_321_COLOR=1 keeps them; --json and --brief are for tools.';
    @l.push: '';
    own(@l.join("\n") ~ "\n", %ctx);
}

sub help-machine(%ctx = %() --> Str) is export {
    my @l = '', "{icon()} 321 help machine: what a work system, a harness or a CI job calls", '';
    @l.push: listing($_, 14, %ctx) for topics().grep({ .group eq MACHINE });
    @l.push: '';
    @l.push: 'Every command answers as a document with --json or, in pipeline mode, as';
    @l.push: 'one tab-separated record per line (--brief, or DO_321_BRIEF=1 for a';
    @l.push: 'session; 321 help brief lists the records). A run with --json prints';
    @l.push: 'events as JSON lines, then the receipt.';
    @l.push: 'Exit codes: 0 completed or no change, 2 blocked,';
    @l.push: '3 stopped, 4 failed, 5 denied, 64 usage, 65 malformed input, 70 internal.';
    @l.push: '';
    own(@l.join("\n") ~ "\n", %ctx);
}

#| One command: what it is for, how to call it, a little more, one example.
sub help-topic(Topic $t, %ctx = %() --> Str) is export {
    my @l = '', header($t.name, $t.summary), '';
    @l.push: "  $_" for $t.usage;
    if $t.more ne '' { @l.push: ''; @l.append: wrap-at($t.more, 76) }
    if $t.example ne '' { @l.push: '', 'For example:', "  {$t.example}" }
    @l.push: '';
    own(@l.join("\n") ~ "\n", %ctx);
}

# How many letters apart two words are: a slip of the fingers is one or two.
sub distance(Str $a, Str $b --> Int) {
    my @prev = 0 .. $b.chars;
    for 1 .. $a.chars -> $i {
        my @row = $i;
        for 1 .. $b.chars -> $j {
            my $cost = $a.substr($i - 1, 1) eq $b.substr($j - 1, 1) ?? 0 !! 1;
            @row.push: min(@prev[$j] + 1, @row[$j - 1] + 1, @prev[$j - 1] + $cost);
        }
        @prev = @row;
    }
    @prev[*-1];
}

#| Help for what was asked: nothing (the first screen), 'more', 'machine',
#| a command, or a word that begins some commands.  Returns the text and
#| whether the request was understood.
sub help-for(@words, %ctx = %() --> List) is export {
    my $asked = @words.join(' ').trim.lc;
    return (help-index(%ctx), True) if $asked eq '';
    return (help-more(%ctx), True) if $asked eq 'more' | 'all';
    return (help-machine(%ctx), True) if $asked eq 'machine' | 'tools';
    with topic($asked) { return (help-topic($_, %ctx), True) }
    # '321 help iz4 install --advisory': the action is part of the command it belongs to
    my @w = $asked.words;
    for (1 ..^ @w.elems).reverse -> $n {
        with topic(@w.head($n).join(' ')) { return (help-topic($_, %ctx), True) }
    }
    # 'iz4' is three commands: show the one when there is one, else name them
    my @under = topics().grep({ .name.starts-with("$asked ") });
    return (help-topic(@under[0], %ctx), True) if @under == 1;
    if @under {
        my @l = '', "321 $asked has more than one form:", '';
        @l.push: listing($_, 14, %ctx) for @under;
        @l.push: '';
        return (@l.join("\n") ~ "\n", True);
    }
    my @near = topics().grep({ .name.contains($asked) || $asked.contains(.name.words[0])
                               || distance($asked, .name) <= 2 }).head(3);
    my $hint = @near ?? " Did you mean: {@near.map({ '321 help ' ~ .name }).join(', ')}?" !! '';
    ("There is no 321 command '$asked'.$hint\n'321 help' lists the commands.\n", False);
}

# ------------------------------------------------------------ after a run

#| The next step for a finished run, from the receipt and what was typed.
#| It names a real next step for this outcome, in the person's own terms:
#| their agent alias, their request, the service and target the tool saw.
#| It never claims more than the receipt shows: a plan stays a plan, and
#| execution that is not enabled here is said to be not enabled here.
sub next-after-run(%r, Str :$invocation, Str :$prefix, Str :$workspace = '', Bool :$dp-bound = False, Str :$dp-execute = '' --> Str) is export {
    my $status = %r<status> // '';
    my @calls = @(%r<evidence><toolCalls> // []);
    my %p = (%r<evidence><proposal> // {}).Hash;
    my ($service, $target) = ((%p<service> // ''), (%p<target> // ''));
    my @allowed = $dp-execute.split(',').map(*.trim).grep(* ne '');
    my $deployed = %r<evidence><externalAction>.defined;
    my $not-performed = so @calls.grep({ (.<unavailable> // '') ne '' });

    if $status eq 'completed' || $status eq 'no_change' {
        my @files = @(%r<evidence><filesChanged> // []);
        if @files && $workspace ne '' {
            return next-text('review the changes, then commit them yourself; 321 never commits', "git -C $workspace diff");
        }
        if $deployed && $service ne '' {
            return next-text('check it is serving as you expect', "$prefix status $service $target");
        }
        if %p && %p<status> eq 'planned' && $service ne '' {
            return $target ∈ @allowed
                ?? next-text('if this plan is what you want deployed, type the go; typing it is your approval', "$prefix go $service $target")
                !! next-text("nothing will deploy from here: $target is not in DP_EXECUTE on this machine", "DP_EXECUTE=$target $prefix go $service $target");
        }
        if @calls.grep({ .<tool> eq 'dp' && .<op> eq 'status' && .<ok> }) {
            return next-text('name a service and a target to get an exact plan', "$prefix plan <service> <target>");
        }
        return next-text('ask the next thing the same way', "$prefix <request...>");
    }
    if $status eq 'blocked' {
        if $not-performed {
            return $target ne ''
                ?? next-text("nothing was deployed: executing on $target is not enabled on this machine (DP_EXECUTE)", "DP_EXECUTE=$target $invocation")
                !! next-text('nothing was performed: that step is not enabled on this machine', '321 help deploy');
        }
        my $q = (%r<blockedOn> // '').Str;
        return next-text("answer it in a new request: $q", "$invocation <answer>") if $q ne '';
        return next-text('it needs something it may not take itself; the lines above say what', '321 help receipt');
    }
    if $status eq 'failed' {
        my @errs = @(%r<evidence><errors> // []);
        return next-text('bind the deployment engine, then ask again', "DP_BIN=/path/to/dp $invocation")
            if @errs.grep(*.contains('DP_BIN'));
        return next-text('fix what the ! lines name, then ask again', $invocation);
    }
    if $status eq 'denied' {
        return next-text('see what this machine enforces against what the package needs', '321 doctor');
    }
    if $status eq 'stopped' {
        return next-text('ask again when ready', $invocation);
    }
    next-text('read the receipt', '321 help receipt');
}
