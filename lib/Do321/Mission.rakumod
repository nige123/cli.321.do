unit module Do321::Mission;

#| The words of Mission Control: open the screen, start a run that
#| outlives the terminal, stop one, attach to one.  Each prints in the
#| family's shape (title first, a handful of rows, one next step) and
#| degrades to plain records in a pipe (--brief, --json).  None of them
#| ever prompts: a question with no terminal to answer it is a usage
#| error that names the flag.

use Do321::JSON;
use Do321::Look;
use Do321::Sys;
use Do321::RunDir;
use Do321::Fold;
use Do321::Host;
use Do321::Deck;

constant EXIT-OK      = 0;
constant EXIT-STOPPED = 3;
constant EXIT-USAGE   = 64;
constant EXIT-INTERNAL = 70;

my $ME = '321-mc';

# The pipe forms, kept here so this entry stands on the 321 it ships with.
#| DO_321_BRIEF=1: records, as --brief asks for them.
sub records-asked(--> Bool) { (%*ENV<DO_321_BRIEF> // '') eq '1' }
#| One record: fields joined by tabs, none carrying a tab or a newline.
sub record-line(*@fields --> Str) { @fields.map({ .Str.subst(/<[\t\n]>/, ' ', :g) }).join("\t") }
#| One live line, rewritten in place, and its wiping.
sub say-live($w, Str $text) { $w.print("\r\e[2K" ~ $text); $w.flush }
sub wipe-line($w) { $w.print("\r\e[2K"); $w.flush }

sub title(Str $what, Str $summary = '' --> Str) {
    $summary eq '' ?? "{icon()} $ME $what" !! "{icon()} $ME $what: $summary";
}

sub usage(Str $line --> Int) {
    note "$ME: $line";
    note next-text('see what Mission Control can do', "$ME help");
    EXIT-USAGE;
}

#| Whether the full screen may open: a person at a terminal on both ends,
#| who did not ask for a record (--json, --brief, DO_321_BRIEF=1) and
#| whose terminal can draw one (not TERM=dumb).  NO_COLOR is about colour
#| and does not stop it.
sub screen-allowed(@args --> Bool) is export {
    return False if @args.first('--json' | '--brief' | '--plain').defined;
    return False if records-asked();
    return False if (%*ENV<TERM> // '') eq 'dumb' || (%*ENV<TERM> // '') eq '';
    $*IN.t && $*OUT.t;
}

sub help-text(--> Str) {
    my @l = title('help', 'runs that outlive the terminal'), '',
        "  $ME                      open Mission Control (on a terminal)",
        "  $ME attach <run>         open it on one run",
        "  $ME runs                 every run, one record per line",
        '',
        "  $ME start <agent> <request...>   start a run that keeps going when you leave",
        "  $ME stop <run>           ask a run to stop; --force when its host is not answering",
        "  $ME restart <run>        run an ended run's request again, with its own budget",
        '',
        '  a run is named by its id or the last three characters of it',
        "  --brief or --json alone: the runs as records   --trust FILE: as for 321",
        '',
        next-text('start one and watch it', "$ME start helper tidy the README");
    @l.join("\n") ~ "\n";
}

#| Run Mission Control's command line; returns the exit code.
sub mc-main(@argv --> Int) is export {
    my @args = @argv;
    my %o = brief => records-asked(), json => False, trust => '', workspace => '', force => False, yes => False;
    my @rest;
    my $i = 0;
    while $i < @args {
        my $a = @args[$i];
        given $a {
            when '--brief'     { %o<brief> = True }
            when '--json'      { %o<json> = True }
            when '--plain'     { }
            when '--force'     { %o<force> = True }
            when '--yes'       { %o<yes> = True }
            when '--trust'     { return usage('--trust needs a file') if $i + 1 >= @args; %o<trust> = @args[++$i] }
            when '--workspace' { return usage('--workspace needs a directory') if $i + 1 >= @args; %o<workspace> = @args[++$i] }
            default            { @rest.append(@args[$i .. *]); last }
        }
        $i++;
    }
    # options may also follow the command word, before the run or agent
    if @rest && @rest[0] ne 'start' {
        my @r = @rest[0];
        for @rest[1 .. *] -> $a {
            given $a {
                when '--brief' { %o<brief> = True }
                when '--json'  { %o<json> = True }
                when '--force' { %o<force> = True }
                when '--yes'   { %o<yes> = True }
                when '--plain' { }
                default        { @r.push($a) }
            }
        }
        @rest = @r;
    }
    return usage('--json and --brief are two forms; ask for one') if %o<json> && %o<brief>;
    dress(False) if %o<json> || %o<brief>;
    %*ENV<DO_321_TRUST> = %o<trust>.IO.absolute if %o<trust> ne '';

    unless @rest {
        return run-deck() if screen-allowed(@argv);
        # a program asking for records gets the runs, not a screen of help
        return cmd-runs(%o) if %o<json> || %o<brief>;
        print help-text();
        return EXIT-USAGE;
    }
    given @rest[0] {
        when 'help' | '-h' | '--help' { print help-text(); return EXIT-OK }
        when 'tui'    { return screen-allowed(@argv) ?? run-deck() !! usage('Mission Control needs a terminal on both ends; in a pipe use --brief commands') }
        when 'host'   { return @rest == 2 ?? host-main(@rest[1]) !! usage('host takes one run directory') }
        when 'start'  { return cmd-start(%o, @rest[1 .. *]) }
        when 'stop'   { return cmd-stop(%o, @rest[1 .. *]) }
        when 'attach' { return cmd-attach(%o, @rest[1 .. *]) }
        when 'runs'   { return cmd-runs(%o) }
        when 'restart' { return cmd-restart(%o, @rest[1 .. *]) }
    }
    usage("'{@rest[0]}' is not a Mission Control word");
}

# ---------------------------------------------------------------- start

sub cmd-start(%o, @args --> Int) {
    my @words = @args;
    my $ws = %o<workspace>;
    if @words && @words[0] eq '--workspace' { return usage('--workspace needs a directory') if @words < 2; $ws = @words[1]; @words = @words[2 .. *] }
    return usage('say which agent and what it should do') if @words < 2;
    my ($name, @req) = @words;
    my ($r, $err) = launch-run($name, @req.join(' '), :workspace($ws), :via('321-mc start'));
    with $err { note "$ME: $err"; return $r.defined ?? EXIT-INTERNAL !! 5 }
    say-started(%o, $r, 'start');
}

sub say-started(%o, RunDir $r, Str $word --> Int) {
    if %o<json> { say encode-json(%( runId => $r.id, dir => $r.dir.Str, phase => 'starting' )); return EXIT-OK }
    if %o<brief> { say record-line($r.id, 'starting', $r.dir.Str); return EXIT-OK }
    my %run = $r.run;
    say title($word, "{%run<agent><displayName>} {$r.short}, {%run<agent><byline>}");
    say '';
    .say for row-lines('asked:', %run<request>);
    if %run<continues> ~~ Associative { .say for row-lines('again of:', "{%run<continues><runId>}, whose receipt is unchanged") }
    .say for row-lines('run:', "{$r.id}, keeps going when you close this terminal");
    .say for row-lines('workspace:', %run<workspace> ne '' ?? "{%run<workspace>}; you commit, the agent only edits" !! 'none');
    say '';
    say next-text('watch it, steer it or stop it', "$ME attach {$r.short}");
    EXIT-OK;
}

# ---------------------------------------------------------------- restart

#| A new run of an ended run's request.  It asks first on a terminal; in a
#| pipe it never asks, and --yes is the answer.
sub cmd-restart(%o, @args --> Int) {
    return usage('say which run to start again; its last three characters will do') unless @args == 1;
    my ($old, $err) = find-run(@args[0]);
    with $err { return usage($_) }
    with restart-refusal($old) { note "$ME: {who-of($old)}: $_"; note next-text('stop it', "$ME stop {$old.short}"); return EXIT-USAGE }
    my $q = restart-question($old);
    unless %o<yes> {
        return usage("$q Add --yes to start it") unless $*IN.t && $*OUT.t && !%o<json> && !%o<brief>;
        print "$q  y/N ";
        my $a = $*IN.get // '';
        unless $a.trim.lc eq 'y' | 'yes' { say 'nothing was started'; return EXIT-OK }
    }
    my ($r, $why) = restart-run($old, :via('321-mc restart'));
    with $why { note "$ME: $why"; return $r.defined ?? EXIT-INTERNAL !! 5 }
    say-started(%o, $r, 'restart');
}

# ---------------------------------------------------------------- stop

sub cmd-stop(%o, @args --> Int) {
    return usage('say which run to stop; its last three characters will do') unless @args == 1;
    my ($r, $err) = find-run(@args[0]);
    with $err { return usage($_) }
    my $who = who-of($r);
    if %o<force> {
        my %f = force-stop($r);
        unless %f<done> { say-result(%o, $r, 'unchanged', %f<why>); return EXIT-OK }
        my $n = @(%f<signalled>).elems;
        my $what = %f<receipt> ?? 'it had already written its receipt' !! 'recorded as lost in ended.json, with what was signalled';
        say-result(%o, $r, 'stopped by force', "{$n} process{$n == 1 ?? '' !! 'es'} signalled; $what", :signalled(%f<signalled>));
        return EXIT-STOPPED;
    }
    my ($id, $why) = request-stop($r, :reason("stopped with $ME stop"), :client($ME));
    with $why {
        say-result(%o, $r, 'unchanged', $why);
        return $why.starts-with('it is lost') ?? EXIT-LOST !! EXIT-OK;
    }
    # What came of it, from the run's own log: acknowledged within five
    # seconds, ended within forty.  A screen never says stopped before
    # the run does.
    my $tail = EventTail.new(:path($r.events-file));
    my $state = RunState.new;
    my $acked = False;
    my $t0 = now;
    my $live = pretty-on() && !%o<brief> && !%o<json>;
    loop {
        for $tail.poll -> %e {
            fold-event($state, %e);
            $acked = True if %e<kind> eq 'directive_delivered' && (%e<payload><directiveId> // '') eq $id;
        }
        # confirmed only when the host has swept what was below it and gone
        last if ($r.receipt-file.e || $r.ended-file.e) && !$r.live-file.e;
        if !$acked && now - $t0 > 5 {
            wipe-line($*OUT) if $live;
            say-result(%o, $r, 'unconfirmed', "no answer from the run in 5 seconds; it may still stop",
                :next("$ME stop {$r.short} --force"));
            return EXIT-LOST;
        }
        if now - $t0 > 45 {
            wipe-line($*OUT) if $live;
            say-result(%o, $r, 'stop in progress', "acknowledged, not finished after 45 seconds", :next("$ME stop {$r.short} --force"));
            return EXIT-LOST;
        }
        say-live($*OUT, "  {glyph('dot')} stop {$acked ?? 'acknowledged, the run is ending' !! 'requested'}") if $live;
        sleep 0.2;
    }
    wipe-line($*OUT) if $live;
    my %l = liveness($r);
    say-result(%o, $r, %l<outcome> // 'ended', ($r.receipt<summary> // %l<why> // ''), :swept($state.swept));
    %l<outcome> eq 'stopped' ?? EXIT-STOPPED !! EXIT-OK;
}

sub who-of(RunDir $r --> Str) {
    my %run = $r.run;
    "{(%run<agent><displayName> // %run<agent><name> // 'run')} {$r.short}";
}

sub say-result(%o, RunDir $r, Str $word, Str $detail, :@signalled, :@swept, Str :$next) {
    if %o<json> {
        say encode-json(%( runId => $r.id, result => $word, detail => $detail, signalled => @signalled, swept => @swept ));
        return;
    }
    if %o<brief> { say record-line($r.id, $word, $detail); return }
    say title('stop', who-of($r));
    say '';
    .say for row-lines('result:', $word);
    if $detail ne '' { .say for row-lines('detail:', $detail) }
    for @swept -> %p { .say for row-lines('swept:', "{%p<pid>} {%p<command>} ({%p<signal>})") }
    for @signalled -> %p { .say for row-lines('signalled:', "{%p<pid>} {%p<command>} ({%p<signal>})") }
    with $next { say ''; say next-text('stop it without its host', $next) }
}

# ---------------------------------------------------------------- attach

sub cmd-attach(%o, @args --> Int) {
    return usage('say which run; its last three characters will do') unless @args == 1;
    my ($r, $err) = find-run(@args[0]);
    with $err { return usage($_) }
    my %l = liveness($r);
    # a lost run answers lost, with its basis, before anything else
    if !screen-allowed(@*ARGS) || %o<brief> || %o<json> {
        if %o<json> { say encode-json(%( runId => $r.id, phase => %l<phase>, outcome => %l<outcome> // '', why => %l<why> )) }
        else { say record-line($r.id, %l<phase>, %l<outcome> // '', %l<why>) }
        return %l<phase> eq 'lost' || (%l<outcome> // '') eq 'lost' ?? EXIT-LOST !! EXIT-OK;
    }
    run-deck(:focus($r.id));
}

# ---------------------------------------------------------------- runs

#| Every run here with its phase, one record per line.  A stand-in for
#| the live section of `321 log` until that lands.
sub cmd-runs(%o --> Int) {
    my @rows;
    for all-runs() -> $r {
        my %l = liveness($r);
        my %run = $r.run;
        @rows.push(%( runId => $r.id, phase => %l<phase>, outcome => %l<outcome> // '', agent => %run<agent><id> // '',
                      request => %run<request> // '', why => %l<why> // '' ));
    }
    if %o<json> { say encode-json(%( runs => @rows )); return EXIT-OK }
    say record-line(.<runId>, .<phase>, .<outcome>, .<agent>, .<request>) for @rows;
    EXIT-OK;
}
