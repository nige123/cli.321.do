# Copyright Nige Ltd. Author: Nigel Hamilton.
unit module Do321::Exercised;

#| What the hooks really did for a project: one small record per hook
#| call, kept under ~/.321/exercised, so that `321 iz4 status` can say
#| when the controller last checked work here and not only what is wired.
#|
#| A record is deliberately small: when, which harness and session, which
#| control, and the outcome.  No command, no file, no reason: those are
#| the hook's business at the moment, and nothing kept here is evidence
#| against a person later.  Recording never stops a hook: a line that
#| cannot be written is simply not there, and a status with no records
#| says nothing ran, never that something was wrong.
#|
#| Outcomes:
#|   checked      the controller answered, and the work went on
#|   refused      the controller answered, and kept the work back
#|   unanswered   the controller could not be asked
#|   delivered    the context was given (told, never checked)
#|
#| A hook that owed no question (a turn that could not have changed a
#| file) writes no record, so "last checked" always means the controller
#| really answered.

use Data::Native;
use Do321::JSON;
use Do321::Protocol;
use Do321::Controller;

constant OUT-CHECKED    is export = 'checked';
constant OUT-REFUSED    is export = 'refused';
constant OUT-UNANSWERED is export = 'unanswered';
constant OUT-DELIVERED  is export = 'delivered';

sub outcomes(--> List) is export { (OUT-CHECKED, OUT-REFUSED, OUT-UNANSWERED, OUT-DELIVERED) }

my constant DAYS  = 7;        # records older than this are pruned: the window a status reports
my constant BYTES = 400_000;  # and past this size the newest KEEP lines are kept, whatever their age
my constant KEEP  = 2000;

#| Where a project's records live: one file per project, named by a digest
#| of the key (the IZ4's path, or the workspace when there is none).
sub exercised-file(IO::Path $home, Str $key --> IO::Path) is export {
    $home.add('exercised').add(sha256-hex($key.IO.absolute.Str.encode).substr(0, 16) ~ '.ndjson');
}

#| The outcome to record for one hook call, from the controller's answer;
#| '' when there is nothing to record.
sub exercised-outcome(Str $control, Verdict $v --> Str) is export {
    return '' unless $v.asked;
    return OUT-UNANSWERED unless $v.ran;
    return OUT-DELIVERED if $control eq CTRL-AUTHORITATIVE-CONTEXT;
    $v.stops ?? OUT-REFUSED !! OUT-CHECKED;
}

#| Append one record: a whole line in one append, since several sessions
#| write at once.  Never throws and never holds the hook up: the hook's
#| answer is the same whether or not this line lands.
sub record-exercised(IO::Path $home, Str $key, Str $harness, Str $session, Str $control, Str $outcome) is export {
    return if $outcome eq '';
    my $f = exercised-file($home, $key);
    try {
        mkdir-private($home);
        mkdir-p($f.parent);
        my $fh = $f.open(:a);
        $fh.print(encode-json(%( at => now-stamp(), harness => $harness, session => $session, control => $control, outcome => $outcome )) ~ "\n");
        $fh.close;
        prune($f);
    }
}

#| Keep the file to the window: once its oldest record is older than DAYS,
#| everything older goes.  The first line says whether there is anything
#| to do, so the usual call reads one line.  A line another session
#| appends during the rare rewrite can be lost; that costs a count in a
#| status, never an answer.
sub prune(IO::Path $f) {
    my $first = try $f.open.lines.head;
    return without $first;
    my $oldest = at-of($first);
    my $since = now - DAYS * 86400;
    return if ($oldest.defined && $oldest >= $since) && $f.s < BYTES;
    my @keep = $f.lines.grep({ my $t = at-of($_); $t.defined && $t >= $since });
    @keep = @keep.tail(KEEP) if @keep.elems > KEEP;
    $f.spurt(@keep.join("\n") ~ (@keep ?? "\n" !! ''));
}

#| A record's time as an Instant, or Nil.
sub at-of(Str $line) {
    my $r = try parse-json($line);
    return Nil unless $r ~~ Associative;
    my $t = try parse-time(($r<at> // '').Str);
    $t.defined ?? $t.Instant !! Nil;
}

#| What the records say for one harness: the counts of the last :days,
#| when the controller last answered, and how many calls since that answer
#| could not reach it.  An empty hash when the harness has no records.
#| It says a hook ran and what the controller answered, never that an
#| invariant held or the work is safe.
sub exercised-summary(IO::Path $home, Str $key, Str $harness, Int :$days = DAYS --> Hash) is export {
    my $f = exercised-file($home, $key);
    return %() unless $f.f;
    my $since = now - $days * 86400;
    my %n = outcomes().map({ $_ => 0 });
    my ($answered, $latest, $unanswered-since) = '', '', 0;
    for $f.lines -> $l {
        my $r = try parse-json($l);
        next unless $r ~~ Associative && ($r<harness> // '') eq $harness && (%n{$r<outcome> // ''}:exists);
        my $at = ($r<at> // '').Str;
        my $t = try parse-time($at);
        next without $t;
        $latest = $at;
        if $r<outcome> eq OUT-CHECKED || $r<outcome> eq OUT-REFUSED { $answered = $at; $unanswered-since = 0 }
        elsif $r<outcome> eq OUT-UNANSWERED { $unanswered-since++ }
        %n{$r<outcome>}++ if $t.Instant >= $since;
    }
    return %() if $latest eq '';
    %( schema => 'exercised.v1', days => $days, |%n, lastAnswered => $answered, latest => $latest, unansweredSince => $unanswered-since );
}

#| How long ago, in words read once: just now, 3 minutes ago, 2 hours ago,
#| 4 days ago.
sub ago-words(Str $iso --> Str) is export {
    my $t = try parse-time($iso);
    return '' without $t;
    my $s = (now - $t.Instant).Int max 0;
    return 'just now' if $s < 60;
    my ($n, $unit) = $s < 3600 ?? ($s div 60, 'minute') !! $s < 86400 ?? ($s div 3600, 'hour') !! ($s div 86400, 'day');
    "$n {$unit}{$n == 1 ?? '' !! 's'} ago";
}

#| The clause a status row adds after what is wired: what really happened.
#| Something to act on comes first; otherwise when the controller last
#| answered; '' when there is nothing to say.
sub exercised-words(%x, Str :$controller = 'the controller' --> Str) is export {
    return '' unless %x;
    my $u = %x<unansweredSince> // 0;
    return ", but $u check{$u == 1 ?? '' !! 's'} could not reach $controller" if $u > 0;
    return '' if (%x<lastAnswered> // '') eq '';
    ", last checked {ago-words(%x<lastAnswered>)}";
}

#| The counts as one row, for --verbose.
sub exercised-row(%x --> Str) is export {
    return '' unless %x;
    my @p = "{%x<checked>} checked";
    @p.push("{%x<refused>} kept back") if %x<refused>;
    @p.push("{%x<unanswered>} unanswered") if %x<unanswered>;
    "{@p.join(', ')} in the last {%x<days>} days" ~ ((%x<latest> // '') ne '' ?? "; latest {ago-words(%x<latest>)}" !! '');
}
