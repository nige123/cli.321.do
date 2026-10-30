unit module Do321::Screens;

use Do321::Screen;
use Do321::History;
use Do321::Commands;
use Do321::Result;

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
sub log-screen(@runs, %tally, Int :$days = 7, Str :$agent = '', Str :$dir = '',
               Int :$shown = 12, Bool :$capped = False, :%marks --> Screen) is export {
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
    @spend.push("{%tally<unstated>} said nothing about cost") if (%tally<unstated> // 0) > 0;
    @rows.push(Row.new(label => 'spend:', value => @spend.join('; ')));

    my @table = @runs.head($shown).map(-> $r {
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
        subtitle => [ many-of($days, "day"), ($capped ?? "the newest {many-of(%tally<runs>, 'run')}" !! many-of(%tally<runs>, 'run')), ($agent ne '' ?? "by $agent" !! ''), $dir ],
        blocks => [
            Rows.new(rows => @rows),
            |(@table ?? Table.new(heads => ['when', 'who', 'work', 'outcome'], rows => @table) !! ()),
            |(@runs > $shown
                ?? Note.new(text => "The newest $shown of the {many-of(@runs.elems, 'run')} in this window"
                    ~ ($capped ?? ', which is as far back as one reading goes: --days narrows it.' !! '. 321 receipt show <id> reads one in full.'))
                !! ()),
            Note.new(text => 'a receipt says what ran and what changed, never that the work is right'),
        ],
        next => @next,
        :$closer,
    );
}

#| Where a screen becomes lines.  A command calls this and never needs
#| the value types in its own namespace.
sub screen-text($s, Bool :$colour = False, Bool :$utf8 = True --> List) is export {
    screen-lines($s, :$colour, :$utf8);
}

#| A count that reads like English: one run, not 1 runs.
sub many-of(Int $n, Str $word --> Str) { "$n $word" ~ ($n == 1 ?? '' !! 's') }

#| The same facts as a machine document: the one envelope, with log's own
#| data under it.  A command never emits a screen when a document was
#| asked for, so the two are built from the same values side by side.
#| The envelope's word for what a receipt says happened, so that every
#| record a caller reads carries one of OUTCOMES and nothing else.  The
#| screen keeps a word of its own for a person in Do321::Screen, and that
#| one is never serialised: 'no change' with a space is in neither
#| OUTCOMES nor any receipt on disk, and a caller matching the envelope's
#| 'no_change' against it would find nothing.
#|
#| Where a receipt's status is not a word we can name, this says nothing
#| rather than guessing: naming it 'failed' would assert the work did not
#| finish, which we have not established.  All 993 receipts on this
#| machine carry one of the six it knows.  It lives here, not beside
#| OUTCOMES in Do321::Result, because Do321::Wire defines the same
#| exit-code names and so Do321::CLI cannot import Result as well.
sub outcome-of(Str $status --> Str) is export {
    my $w = $status.lc.subst(' ', '_', :g);
    return 'done' if $w eq 'completed';
    so($w eq any(OUTCOMES)) ?? $w !! '';
}

#| What became of a run, in one word a machine can read: the envelope
#| outcome once it has ended, and 'running' while it has not.  Never
#| empty: a blank field cannot be told from one a reader missed.
sub run-word(Str $status --> Str) is export {
    my $w = outcome-of($status);
    $w ne '' ?? $w !! $status.lc.subst(' ', '_', :g);
}

sub log-json(@runs, %tally, Int :$days = 7, Str :$agent = '', Str :$dir = '' --> Str) is export {
    result-json(result-document(
        command => 'log',
        outcome => 'done',
        dataSchema => 'log.v1',
        data => %(
            days      => $days,
            agent     => $agent,
            directory => $dir,
            runs      => @runs.elems,
            by        => %tally<by>,
            spend     => %( measured     => %tally<measured>,
                            measuredRuns => %tally<measured-runs>,
                            unreported   => %tally<unreported>,
                            modelless    => %tally<modelless>,
                            unstated     => %tally<unstated> ),
            recent    => @runs.map(-> $r { %(
                id        => $r.id,
                agent     => $r.agent,
                outcome   => outcome-of($r.status),
                status    => $r.status,
                objective => $r.objective,
                summary   => $r.summary,
                startedAt => $r.started.Str,
                seconds   => $r.seconds,
                cost      => %( usd => $r.usd, basis => $r.basis ),
                waitingOn => $r.waiting,
            ) }).List,
        ),
    ));
}
