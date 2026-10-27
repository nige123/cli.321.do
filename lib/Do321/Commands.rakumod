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
    #| A seam is a command another program calls and reads: it prints its
    #| record and no screen whenever stdout is not a terminal, and a shell
    #| does not offer it to a person.
    has Bool $.seam = False;
}

constant EVERY-DAY is export = 'Every day';
constant HOLD      is export = 'When intent must hold';
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
    Cmd.new(name => 'try', group => EVERY-DAY, what => 'read this directory with the reader that comes with 321'),
    Cmd.new(name => 'agents', group => EVERY-DAY, what => 'who you can ask here, and what one of them is for',
        subs => (Word.new(name => 'check', what => 'load every configured package and say which fail'),)),
    Cmd.new(name => 'status', group => EVERY-DAY, what => 'where you are, and anything waiting on you',
        flags => (Flag.new(name => '--runs', :takes, what => 'how many recent runs to list'),)),
    Cmd.new(name => 'log', group => EVERY-DAY, what => 'what the crew has done, and what came of it',
        flags => (Flag.new(name => '--days', :takes, what => 'how far back to look'),
                  Flag.new(name => '--agent', :takes, values => 'agent', what => 'one crew member only'))),
    Cmd.new(name => 'receipt', group => EVERY-DAY, what => 'what a receipt proves, and how to check one',
        subs => (Word.new(name => 'verify', what => "check a receipt's digest and signature", values => 'file'),
                 Word.new(name => 'show', what => 'read a receipt as a person', values => 'file')),
        flags => (Flag.new(name => '--key', :takes, what => 'the public key to check a signature against'),)),

    Cmd.new(name => 'iz4', group => HOLD, what => "wire this project's IZ4 into the harnesses here",
        subs => (Word.new(name => 'install', what => 'wire it in'),
                 Word.new(name => 'status', what => 'what is enforced here, one verdict per harness'),
                 Word.new(name => 'remove', what => 'take out only what 321 installed')),
        flags => (Flag.new(name => '--harness', :takes, values => 'harness', what => 'one harness only'),
                  Flag.new(name => '--advisory', what => 'advise rather than hold'))),

    Cmd.new(name => 'trust', group => TRUST, what => 'the trust file: what may run here',
        subs => (Word.new(name => 'show', what => 'what is pinned, and where it lives'),
                 Word.new(name => 'diff', what => 'what has moved since you pinned it', values => 'agent'),
                 Word.new(name => 'check', what => 'load every package and say which fail'))),
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
        subs => (Word.new(name => 'detect', what => 'what is installed, and what this project is wired into'),)),
    Cmd.new(name => 'hooks', group => HARNESS, what => 'the older direct wiring: see it, or take it out',
        subs => (Word.new(name => 'status', what => 'what is wired'), Word.new(name => 'remove', what => 'take it out'))),

    Cmd.new(name => 'completion', group => TOOL, what => 'what a shell should offer when you press TAB',
        subs => (Word.new(name => 'bash', what => 'print the script for bash'),
                 Word.new(name => 'zsh', what => 'print the script for zsh'),
                 Word.new(name => 'fish', what => 'print the script for fish'),
                 Word.new(name => 'words', what => 'the candidates for a typed line (a shell calls this)'))),
    Cmd.new(name => 'help', group => TOOL, what => 'the commands, or one of them with an example'),
    Cmd.new(name => 'version', group => TOOL, what => 'which 321 this is'),

    Cmd.new(name => 'run', group => MACHINE, :seam, what => 'a work package in, events and a receipt out'),
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
