unit module Do321::History;

use Do321::JSON;
use Do321::Screen;

#| What the crew has actually done, read from the receipts.
#|
#| A receipt per run is already written; nobody could see them.  This
#| reads them back as facts - never as an opinion about whether the work
#| was any good, which no receipt can say.
#|
#| Two honesty rules it keeps, because a history is where they are easiest
#| to break:
#|
#|   an outcome is the receipt's own word.  'completed' and 'no change'
#|   are not the same thing and are never added together.
#|
#|   a total is only of what was measured.  Where a harness reported no
#|   cost, that run is counted as unreported, not as nothing
#|   (cost-carries-its-basis.cli.321.do).

#| One run, as a person would want it listed.
class Run is export {
    has Str      $.id is required;
    has Str      $.agent = '';
    has Str      $.objective = '';
    has Str      $.status = '';
    has Str      $.summary = '';
    has DateTime $.started;
    has Numeric  $.seconds = 0;
    has Numeric  $.usd = 0;
    has Str      $.basis = '';
    has Str      $.receipt = '';
    has Str      $.waiting = '';

    #| The word the screen says, and the mark it takes with it.
    method state(--> Str) { state-of($!status) }
    #| The crew member's short name: the last part of the id, which is
    #| what a person types.
    method who(--> Str) { $!agent.contains('/') ?? $!agent.split('/').tail !! $!agent }
}

my sub stamp(Str $iso --> DateTime) {
    try DateTime.new($iso) // DateTime.new(0);
}

#| The runs under a directory, newest first.  A run id is a ULID, so the
#| directory names already sort chronologically and the newest can be read
#| without touching the other nine hundred.  Reading stops at the window,
#| or at the cap, whichever comes first.
sub read-runs(
    IO::Path $dir,
    Int :$days = 7,
    Str :$agent = '',
    Int :$cap = 500,
    DateTime :$now = DateTime.now,
    --> List
) is export {
    return () unless $dir.d;
    my @out;
    my $floor = $now.earlier(:$days);
    for $dir.dir.grep(*.d).map(*.basename).sort.reverse -> $id {
        last if @out.elems >= $cap;
        my $r = $dir.add($id).add('receipt.json');
        next unless $r.e;
        my $doc = try parse-json($r.slurp);
        next unless $doc ~~ Associative;
        my $started = stamp(($doc<startedAt> // '').Str);
        # the names are in order, so the first run older than the window
        # is the last one worth opening
        last if $started < $floor;
        my $who = (($doc<agent> // {})<id> // '').Str;
        next if $agent ne '' && $who ne $agent && !$who.ends-with("/$agent");
        my $wp = $dir.add($id).add('work-package.json');
        my $objective = '';
        if $wp.e {
            my $w = try parse-json($wp.slurp);
            $objective = (($w // {})<objective> // '').Str if $w ~~ Associative;
        }
        my $ended = stamp(($doc<endedAt> // '').Str);
        @out.push(Run.new(
            :$id,
            agent     => $who,
            objective => $objective,
            status    => ($doc<status> // '').Str,
            summary   => ($doc<summary> // '').Str,
            :$started,
            seconds   => $ended > $started ?? ($ended - $started) !! 0,
            usd       => (($doc<cost> // {})<usd> // 0),
            basis     => (($doc<cost> // {})<basis> // '').Str,
            receipt   => $r.Str,
            waiting   => (($doc<stop> // {})<reason> // '').Str,
        ));
    }
    @out.List;
}

#| What the runs add up to.  Each outcome counted under its own word, and
#| the spend split into what was measured and what was not.
sub tally(@runs --> Hash) is export {
    my %by;
    %by{.state}++ for @runs;
    my @measured = @runs.grep({ .basis eq 'harness' });
    my @unreported = @runs.grep({ .basis eq 'unreported' });
    my @free = @runs.grep({ .basis eq 'none' });
    %(
        runs       => @runs.elems,
        by         => %by,
        measured   => ([+] @measured.map(*.usd)) // 0,
        measured-runs => @measured.elems,
        unreported => @unreported.elems,
        modelless  => @free.elems,
        waiting    => @runs.grep({ .state eq 'blocked' }).elems,
    );
}

#| How long ago, as a person says it.
sub when-text(DateTime $then, DateTime :$now = DateTime.now --> Str) is export {
    my $s = ($now - $then).Int;
    return 'just now'                      if $s < 90;
    return "{($s / 60).round} min ago"     if $s < 5400;
    return "{($s / 3600).round} hours ago" if $s < 172800;
    "{($s / 86400).round} days ago";
}
