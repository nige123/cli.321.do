unit module Do321::Commands;

#| The command registry: what 321 can be asked, in one place.
#|
#| Dispatch, help, a suggestion after a typo and what a shell offers at a
#| TAB all read this list, so none of them can drift from another.  A
#| command advertised in help that dispatch does not know, or a flag a
#| shell offers that the parser refuses, is then impossible rather than
#| merely unlikely.
#|
#| It carries no behaviour.  Nothing here runs anything.

#| A flag: how it is spelt, whether it takes a value, and the values worth
#| offering where they are a closed list.
class Flag is export {
    has Str $.name is required;
    has Bool $.takes = False;
    has Str $.values = '';        # a closed list by name, or '' for anything
    has Str $.what is required;
}

#| A word that follows a command, and what may follow that.
class Word is export {
    has Str $.name is required;
    has Str $.what is required;
    has Str $.values = '';        # 'file', 'dir', 'shell', 'agent', 'harness', ''
}

class Cmd is export {
    has Str  $.name is required;
    has Str  $.group is required;
    has Str  $.what is required;
    has Word @.subs;
    has Flag @.flags;
    #| What its one argument is, where it takes one instead of a word of
    #| its own: 'agent', 'file', 'dir'.  A shell offers those.
    has Str  $.values = '';
    #| A seam is a command another program calls and reads: it prints its
    #| record and no screen whenever stdout is not a terminal, and a shell
    #| does not offer it to a person.
    has Bool $.seam = False;
}

constant EVERY-DAY is export = 'Every day';
constant HOLD      is export = 'When intent must hold';
constant RUNS      is export = 'Runs that outlive the terminal';
constant RUNS-MORE is export = 'Runs';
constant STEERING  is export = 'Steering a run';
constant LEARN     is export = 'Getting better';
constant TRUST     is export = 'Agents and trust';
constant DEPLOY    is export = 'Deploying';
constant HARNESS   is export = 'Harnesses';
constant TOOL      is export = 'The tool';
constant MACHINE   is export = 'For a program';

#| The capabilities a grant can name.  The same list the protocol
#| enforces; offered at a TAB so nobody has to remember the spelling.
constant CAPABILITIES is export = <repo.read repo.write shell.run net.fetch files.read files.write model.text deploy.read deploy.plan deploy.invoke>;
constant NETWORKS     is export = <none provider_only open>;
constant PLACEMENTS   is export = <client server either>;
constant SHELLS       is export = <bash zsh fish>;

#| The options that go before the agent's name, and before any command.
sub global-flags(--> List) is export {
    (
    Flag.new(name => '--trust',           :takes, values => 'file',      what => 'the trust file to read instead of ~/.321/trust.json'),
    Flag.new(name => '--workspace',       :takes, values => 'dir',       what => 'where the work happens'),
    Flag.new(name => '--package-dir',     :takes, values => 'dir',       what => 'run an unsigned local package by path'),
    Flag.new(name => '--placement',       :takes, values => 'placement', what => 'where the run may happen'),
    Flag.new(name => '--adapter',         :takes, values => 'adapter',   what => 'which harness to run on'),
    Flag.new(name => '--network',         :takes, values => 'network',   what => "the agent's own network access"),
    Flag.new(name => '--context',         :takes, values => 'context',   what => 'the work context this run belongs to'),
    Flag.new(name => '--skill',           :takes,                       what => 'an installed skill to give this run; it adds no permission'),
    Flag.new(name => '--attach',          :takes, values => 'file',      what => 'a file to put in front of the agent'),
    Flag.new(name => '--done',            :takes,                       what => 'a completion condition, in order'),
    Flag.new(name => '--grant',           :takes, values => 'capability', what => 'a capability to grant within policy'),
    Flag.new(name => '--non-interactive',                               what => 'never wait for a person'),
    Flag.new(name => '--verbose',                                       what => 'the whole run: trust, grants, every event and tool call'),
    Flag.new(name => '--json',                                          what => 'one result document, for a program'),
    Flag.new(name => '--brief',                                         what => 'pipeline mode: tab-separated records'),
    Flag.new(name => '--plain',                                         what => 'the pipe form on a terminal'),
    )
}

#| Every command, in the order help shows them.
sub commands(--> List) is export {
    (
    # '321 try', the first thing a newcomer runs, is designed and not here
    # yet: it asks the built-in reader about this directory, so its screen
    # is the run's screen, and that is the next command to move onto
    # Do321::Screens.  The registry says what 321 does, so a word it does
    # not answer is not listed and no shell offers one.
    Cmd.new(name => 'agents', group => EVERY-DAY, what => 'who you can ask here, and what one of them is for',
        subs => (Word.new(name => 'check', what => 'load every configured package and say which fail'),)),
    Cmd.new(name => 'whois', group => TRUST, values => 'agent',
        what => 'meet an agent: what it is for, how it works, what it may do'),
    Cmd.new(name => 'status', group => EVERY-DAY, what => 'where you are, and anything waiting on you',
        flags => (Flag.new(name => '--runs', :takes, what => 'how many recent runs to list'),)),
    Cmd.new(name => 'log', group => EVERY-DAY, what => 'what the crew has done, and what came of it',
        flags => (Flag.new(name => '--days', :takes, what => 'how far back to look'),
                  Flag.new(name => '--agent', :takes, values => 'agent', what => 'one crew member only'))),
    Cmd.new(name => 'receipt', group => EVERY-DAY, what => 'what a receipt proves, and how to check one',
        subs => (Word.new(name => 'verify', what => "check a receipt's digest and signature", values => 'file'),
                 Word.new(name => 'show', what => 'read a receipt as a person', values => 'file')),
        flags => (Flag.new(name => '--key', :takes, what => 'the public key to check a signature against'),)),

    Cmd.new(name => 'value', group => LEARN, what => 'what the work cost, and what it saved, with the evidence',
        subs => (Word.new(name => 'baseline', what => 'say what accepted work would have taken you, so savings can be estimated'),),
        flags => (Flag.new(name => '--days', :takes, what => 'how far back to look'),
                  Flag.new(name => '--agent', :takes, values => 'agent', what => 'one agent only'),
                  Flag.new(name => '--context', :takes, values => 'context', what => 'one work context only'),
                  Flag.new(name => '--minutes', :takes, what => 'baseline: a person\'s minutes for one accepted run'),
                  Flag.new(name => '--rate', :takes, what => 'baseline: what an hour of that time is worth, in dollars'))),
    Cmd.new(name => 'outcome', group => LEARN, what => 'say what came of a run: accepted, rejected or corrected',
        subs => (Word.new(name => 'accepted', what => 'the result was what was wanted'),
                 Word.new(name => 'rejected', what => 'it was not'),
                 Word.new(name => 'corrected', what => 'it was, after a person put it right'))),
    Cmd.new(name => 'context', group => LEARN, what => 'related runs, their purpose and history',
        subs => (Word.new(name => 'new', what => 'begin one: a name and what it is for'),
                 Word.new(name => 'show', what => 'its purpose, history, runs and cost'),
                 Word.new(name => 'pull', what => 'keep a copy of one your organisation holds at the registry'),
                 Word.new(name => 'decided', what => 'record a decision'),
                 Word.new(name => 'rejected', what => 'record an approach that was tried and rejected'),
                 Word.new(name => 'note', what => 'record anything else worth knowing'))),
    Cmd.new(name => 'lessons', group => LEARN, what => 'what agents have learnt here: see, add, compare, keep or revert',
        subs => (Word.new(name => 'add', what => 'a lesson, tried from the next run it applies to'),
                 Word.new(name => 'show', what => 'one lesson, and the runs with it against the runs without'),
                 Word.new(name => 'keep', what => 'it helps: keep it'),
                 Word.new(name => 'revert', what => 'it does not: stop applying it'),
                 Word.new(name => 'remove', what => 'delete it'),
                 Word.new(name => 'share', what => 'put it in this project, for the team')),
        flags => (Flag.new(name => '--agent', :takes, values => 'agent', what => 'for one agent'),
                  Flag.new(name => '--context', :takes, values => 'context', what => 'for one work context'),
                  Flag.new(name => '--skill', :takes, what => 'for one skill'),
                  Flag.new(name => '--harness', :takes, values => 'harness', what => 'for one harness'),
                  Flag.new(name => '--from', :takes, what => 'the run it was learnt from'))),

    Cmd.new(name => 'skills', group => LEARN, what => 'skills on this machine, and those the registry offers you',
        subs => (Word.new(name => 'available', what => 'what the registry offers you, from the last sync'),
                 Word.new(name => 'install', what => 'fetch one by name, check it, keep the version it replaces'),
                 Word.new(name => 'show', what => 'what one is, where it came from, what it asks for'),
                 Word.new(name => 'rollback', what => 'put back the version that was here before'),
                 Word.new(name => 'remove', what => 'take one off this machine')),
        flags => (Flag.new(name => '--version', :takes, what => 'install: that version, not the newest'),)),
    Cmd.new(name => 'registry', group => LEARN, what => 'the agent registry: what it is, when it was last read, your token',
        subs => (Word.new(name => 'sync', what => 'read what you may see, and keep a copy'),
                 Word.new(name => 'token', what => 'set your token, read from standard input'),
                 Word.new(name => 'use', what => 'name another registry'))),
    Cmd.new(name => 'record', group => LEARN, what => 'how an agent has done, as those who ran it reported',
        subs => (Word.new(name => 'share', what => 'whether what you said of your runs is sent, and what would go'),)),

    Cmd.new(name => 'iz4', group => HOLD, what => "wire this project's IZ4 into the harnesses here",
        subs => (Word.new(name => 'install', what => 'wire it in'),
                 Word.new(name => 'status', what => 'what is enforced here, one verdict per harness'),
                 Word.new(name => 'remove', what => 'take out only what 321 installed')),
        flags => (Flag.new(name => '--harness', :takes, values => 'harness', what => 'one harness only'),
                  Flag.new(name => '--advisory', what => 'advise rather than hold'))),

    Cmd.new(name => 'trust', group => TRUST, what => 'the trust file: what may run here',
        subs => (Word.new(name => 'show', what => 'what is pinned, and where it lives'),
                 Word.new(name => 'diff', what => 'what has moved since you pinned it', values => 'agent'),
                 Word.new(name => 'check', what => 'load every package and say which fail'),
                 Word.new(name => 'network', what => 'the network every run started here gets; say it to set it', values => 'network'),
                 Word.new(name => 'now', what => 'how many runs of one agent work at once; the rest wait their turn'))),
    Cmd.new(name => 'packages', group => TRUST, what => 'check, digest and read agent packages',
        subs => (Word.new(name => 'validate', what => 'read a package and say what is wrong with it', values => 'dir'),
                 Word.new(name => 'digest', what => "compute a package's digest", values => 'dir'),
                 Word.new(name => 'show', what => 'read a package as a person', values => 'agent'),
                 Word.new(name => 'builtin', what => 'write the built-in package and print its path')),
        flags => (Flag.new(name => '--write', what => 'write the digest into the package'),)),
    Cmd.new(name => 'doctor', group => TRUST, what => 'what this machine can run and enforce'),
    Cmd.new(name => 'key', group => TRUST, what => "this 321's receipt-signing key",
        subs => (Word.new(name => 'new', what => 'make one'), Word.new(name => 'show', what => 'the public half'))),

    Cmd.new(name => 'harness', group => HARNESS, what => 'the agent environments 321 knows, and which are here',
        subs => (Word.new(name => 'detect', what => 'what is installed, and what this project is wired into'),
                 Word.new(name => 'can', what => 'what each can enforce when it runs an agent'))),
    Cmd.new(name => 'hooks', group => HARNESS, what => 'the older direct wiring: see it, or take it out',
        subs => (Word.new(name => 'status', what => 'what is wired'), Word.new(name => 'remove', what => 'take it out'))),

    Cmd.new(name => 'completion', group => TOOL, what => 'what a shell should offer when you press TAB',
        subs => (Word.new(name => 'bash', what => 'print the script for bash'),
                 Word.new(name => 'zsh', what => 'print the script for zsh'),
                 Word.new(name => 'fish', what => 'print the script for fish'),
                 Word.new(name => 'words', what => 'the candidates for a typed line (a shell calls this)'))),
    Cmd.new(name => 'help', group => TOOL, what => 'the commands, or one of them with an example'),
    Cmd.new(name => 'version', group => TOOL, what => 'which 321 this is'),

    Cmd.new(name => 'tui', group => RUNS, what => 'Mission Control: every run on one screen, watched and steered'),
    Cmd.new(name => 'start', group => RUNS-MORE, values => 'agent', what => 'start a run that keeps going when you leave',
        flags => (Flag.new(name => '--harness', :takes, values => 'harness', what => 'which harness it runs on'),
                  Flag.new(name => '--isolate', what => 'a git worktree of its own'),
                  Flag.new(name => '--workspace', :takes, values => 'dir', what => 'where the work happens'),
                  Flag.new(name => '--package', :takes, values => 'file', what => 'host a work package something else issued'),
                  Flag.new(name => '--continue', :takes, values => 'file', what => 'the receipt a hosted package goes on from'))),
    Cmd.new(name => 'stop', group => RUNS-MORE, what => 'ask a run to stop, and wait for its own word',
        flags => (Flag.new(name => '--force', what => 'when its host is not answering'),)),
    Cmd.new(name => 'attach', group => RUNS-MORE, what => 'open Mission Control on one run'),
    Cmd.new(name => 'steer', group => STEERING, what => 'say something to a run while it works'),
    Cmd.new(name => 'hold', group => STEERING, what => 'end its current step now and wait'),
    Cmd.new(name => 'resume', group => STEERING, what => 'carry on a held run where it was'),
    Cmd.new(name => 'restart', group => RUNS-MORE, what => "run an ended run's request again, with its own budget",
        flags => (Flag.new(name => '--harness', :takes, values => 'harness', what => 'run it on another harness'),
                  Flag.new(name => '--yes', what => 'without asking, in a pipe'))),

    Cmd.new(name => 'run', group => MACHINE, :seam, what => 'a work package in, events and a receipt out'),
    Cmd.new(name => 'host', group => MACHINE, :seam, what => 'be the process that keeps one run going'),
    Cmd.new(name => 'hook', group => MACHINE, :seam, what => 'the glue a harness calls at one of its events'),
    )
}

sub command(Str $name --> Cmd) is export { commands().first({ .name eq $name }) }
sub command-names(--> List) is export { commands().map(*.name).List }

#| The words a person is offered: the seams are left out, because a person
#| does not type them.
sub offered-names(--> List) is export { commands().grep({ !.seam }).map(*.name).List }

#| The nearest command to something that is not one, for a message that
#| says 'did you mean': one edit away, or a prefix.
sub nearest(Str $word --> Str) is export {
    return '' if $word eq '';
    my @near = offered-names().grep({ .starts-with($word) || $word.starts-with($_) || levenshtein($word, $_) <= 2 });
    @near.sort({ levenshtein($word, $_) }).head // '';
}

sub levenshtein(Str $a, Str $b --> Int) is export {
    my @prev = ^($b.chars + 1);
    for $a.comb.kv -> $i, $x {
        my @cur = ($i + 1,);
        for $b.comb.kv -> $j, $y {
            @cur.push(($x eq $y ?? @prev[$j] !! @prev[$j] + 1) min @prev[$j + 1] + 1 min @cur[$j] + 1);
        }
        @prev = @cur;
    }
    @prev.tail;
}
