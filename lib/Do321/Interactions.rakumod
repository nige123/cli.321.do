# Copyright Nige Ltd. Author: Nigel Hamilton.
unit module Do321::Interactions;

#| 321's own record of how it is used: one line for each command a person
#| types, kept under ~/.321/logs/cli.log, so the people who shape 321 can
#| read back where its words helped and where they got in the way, rather
#| than guess.  Mission Control keeps its own, tui.log, key by key.
#|
#| A line says: when, the command word and the options and arguments
#| around it, which form the answer took (screen, plain, brief or json),
#| whether a terminal was there and how wide, how it ended (the exit
#| code), how long it took, and one note 321 made for itself along the
#| way (which usage help it had to show, say).  The person's own prose,
#| a request to an agent, a steer, words to find, is counted, never kept:
#| it is theirs, and the run's own files already hold it.
#|
#| It is the person's alone: 0600 in a 0700 directory, never sent
#| anywhere, and it starts again past LOG-MAX bytes keeping one before.
#| It is never on the path of an answer: a line that cannot be written is
#| simply not there.  DO_321_INTERACTIONS=0 keeps nothing; the hooks a
#| harness calls and the processes 321 starts for itself write nothing.

use Do321::JSON;
use Do321::Protocol;

constant LOG-MAX = 1_000_000;

sub interactions-on(--> Bool) is export { (%*ENV<DO_321_INTERACTIONS> // '1') ne '0' }

sub interactions-path(IO::Path $home --> IO::Path) is export {
    return %*ENV<DO_321_CLI_LOG>.IO if %*ENV<DO_321_CLI_LOG>;
    $home.add('logs').add('cli.log');
}

#| The one note a command may leave for the record, in 321's own words:
#| 'usage status: it takes --json, not --all'.  The first one said stays.
my Str $NOTE = '';
sub interaction-note(Str $what) is export { $NOTE = $what if $NOTE eq '' }
sub take-interaction-note(--> Str) is export { my $n = $NOTE; $NOTE = ''; $n }

#| Append one record, a whole line in one append.  Never throws.
sub record-interaction(IO::Path $home, %rec) is export {
    return unless interactions-on();
    my $f = interactions-path($home);
    try {
        mkdir-private($home);
        mkdir-private($f.parent);
        if $f.e && $f.s > LOG-MAX { $f.rename($f.Str ~ '.1') }
        my $fh = $f.open(:a);
        $fh.print(encode-json(%( at => now-stamp(), |%rec )) ~ "\n");
        $fh.close;
        $f.chmod(0o600);
    }
}

#| The records, oldest first, for anyone reading the log back.
sub read-interactions(IO::Path $home --> List) is export {
    my $f = interactions-path($home);
    return () unless $f.e;
    $f.lines.map({ try parse-json($_) }).grep(Associative).List;
}
