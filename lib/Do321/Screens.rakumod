unit module Do321::Screens;

use Do321::Screen;
use Do321::History;
use Do321::Commands;

#| Facts in, a Screen out.  One function per screen, no printing, no
#| colour, no width: a command gathers what it knows and calls one of
#| these, and the renderer does the rest.  This is where the commands
#| move to, one at a time.

#| The mark a crew member wears, from its package.  Until a package names
#| one, its initial stands in: an identity is the publisher's, never the
#| runtime's, so nothing here holds a table of names
#| (official-agents-not-special.cli.321.do).
sub crew-mark(Str $agent, %marks --> Str) is export { (%marks{$agent} // '').Str }

#| What the crew has done, and what came of it.
sub log-screen(@runs, %tally, Int :$days = 7, Str :$agent = '', Str :$dir = '', :%marks --> Screen) is export {
    my @rows;
    # A row for each outcome that happened, and none for an outcome that
    # did not: a column of zeroes is something to read past, and reading
    # past things is how a real one gets missed.
    my sub count(Str $state, Str $what) {
        my $n = %tally<by>{$state} // 0;
        return if $n == 0;
        @rows.push(Row.new(label => "$state:", value => $what.subst('{n}', many-of($n, 'run'))));
    }
    count('done',      '{n} changed something and said what');
    count('no change', '{n} ran and changed nothing');
    count('blocked',   '{n} waiting on you');
    count('failed',    '{n} did not finish');
    count('denied',    '{n} refused before anything ran');
    count('stopped',   '{n} stopped by hand');

    # spend: only what a harness actually reported, and the rest said
    # plainly rather than rolled in
    my @spend = sprintf('$%.2f measured across %s', %tally<measured>, many-of(%tally<measured-runs>, 'run'));
    @spend.push("{%tally<unreported>} reported no cost") if %tally<unreported> > 0;
    @spend.push("{%tally<modelless>} used no model") if %tally<modelless> > 0;
    @rows.push(Row.new(label => 'spend:', value => @spend.join('; ')));

    my @table = @runs.map(-> $r {
        [ when-text($r.started), Who.new(mark => crew-mark($r.agent, %marks), name => $r.who),
          ($r.objective ne '' ?? $r.objective !! $r.summary), State.new(word => $r.state) ]
    });

    my @next;
    my $waiting = @runs.first({ .state eq 'blocked' });
    @next.push(Step.new(advice => 'the one waiting on you', command => "321 receipt show {$waiting.id.substr(0, 8)}")) with $waiting;
    my $last-failed = @runs.first({ .state eq 'failed' });
    @next.push(Step.new(advice => 'the last one that did not finish', command => "321 receipt show {$last-failed.id.substr(0, 8)}"))
        with ($waiting ?? Nil !! $last-failed);

    # Said last, and only where it is true: nothing waiting, nothing
    # unfinished, and something actually ran.  A period with nothing in it
    # is not an achievement, and is not congratulated.
    my $trouble = (%tally<by><blocked> // 0) + (%tally<by><failed> // 0) + (%tally<by><denied> // 0);
    my $did = (%tally<by><done> // 0);
    my $closer = $trouble == 0 && $did > 0
        ?? "All clear: {many-of($did, 'run')} did their work in the last $days days, and nothing is waiting on you."
        !! '';

    Screen.new(
        title => 'log',
        subtitle => [ "$days days", many-of(%tally<runs>, 'run'), ($agent ne '' ?? "by $agent" !! ''), $dir ],
        blocks => [
            Rows.new(rows => @rows),
            |(@table ?? Table.new(heads => ['when', 'who', 'work', 'outcome'], rows => @table) !! ()),
            Note.new(text => 'a receipt says what ran and what changed, never that the work is right'),
        ],
        next => @next,
        :$closer,
    );
}

#| A count that reads like English: one run, not 1 runs.
sub many-of(Int $n, Str $word --> Str) is export { "$n $word" ~ ($n == 1 ?? '' !! 's') }
