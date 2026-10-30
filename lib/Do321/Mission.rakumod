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
use Do321::Term;
use Do321::Harnesses;
use Do321::RunWords;

constant EXIT-OK      = 0;
constant EXIT-STOPPED = 3;
constant EXIT-USAGE   = 64;
constant EXIT-INTERNAL = 70;

my $ME = '321';

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
    note next-text('see what Mission Control can do', "$ME help tui");
    EXIT-USAGE;
}

#| Whether the full screen may open: a person at a terminal on both ends,
#| who did not ask for a record (--json, --brief, DO_321_BRIEF=1) and
#| whose terminal can draw one (not TERM=dumb).  NO_COLOR is about colour
#| and does not stop it.
sub screen-allowed(@args --> Bool) is export {
    return False unless screen-supported();
    return False if @args.first('--json' | '--brief' | '--plain').defined;
    return False if records-asked();
    return False if (%*ENV<TERM> // '') eq 'dumb' || (%*ENV<TERM> // '') eq '';
    $*IN.t && $*OUT.t;
}

sub help-text(--> Str) {
    my @l = title('help', 'runs that outlive the terminal'), '',
        "  $ME tui                  open Mission Control (on a terminal)",
        "  $ME attach <run>         open it on one run",
        "  $ME tui --brief          every run, one record per line",
        "  $ME harness can          the harnesses an agent can run on, and what each can do",
        '',
        "  $ME start <agent> <request...>   start a run that keeps going when you leave; --harness, --isolate",
        "  $ME stop <run>           ask a run to stop; --force when its host is not answering",
        "  $ME restart <run>        run an ended run's request again, with its own budget; --harness",
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
    my %o = brief => records-asked(), json => False, trust => '', workspace => '', force => False, yes => False, harness => '', isolate => False;
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
            when '--harness'   { return usage('--harness needs a name; 321 harness can lists them') if $i + 1 >= @args; %o<harness> = @args[++$i] }
            when '--isolate'   { %o<isolate> = True }
            default            { @rest.append(@args[$i .. *]); last }
        }
        $i++;
    }
    # the forms a pipe asks for may also follow the command word; a run
    # word's own options are its own (Do321::RunWords), and a request or a
    # steer is never searched for options at all
    if @rest && @rest[0] ne 'start' | 'steer' {
        my @r = @rest[0];
        for @rest[1 .. *] -> $a {
            given $a {
                when '--brief' { %o<brief> = True }
                when '--json'  { %o<json> = True }
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
        # in a pipe, the screen's rows as records
        when 'tui'    { return cmd-runs(%o) if %o<json> || %o<brief>; return usage('Mission Control does not run on Windows yet; 321 tui --brief lists the runs') unless screen-supported(); return screen-allowed(@argv) ?? run-deck() !! usage('Mission Control needs a terminal on both ends; in a pipe, 321 tui --brief lists the runs') }
        when 'host'   { return @rest == 2 ?? host-main(@rest[1]) !! usage('host takes one run directory') }
        when 'start'  { return cmd-start(%o, @rest[1 .. *]) }
        when 'stop'   { return cmd-stop(%o, @rest[1 .. *]) }
        when 'attach' { return cmd-attach(%o, @rest[1 .. *]) }
        when 'runs'   { return cmd-runs(%o) }
        when 'restart' { return cmd-restart(%o, @rest[1 .. *]) }
        when 'hold'   { return cmd-control(%o, 'hold', @rest[1 .. *]) }
        when 'resume' { return cmd-control(%o, 'resume', @rest[1 .. *]) }
        when 'steer'  { return cmd-control(%o, 'steer', @rest[1 .. *]) }
        when 'harnesses' { return cmd-harnesses(%o) }
    }
    usage("'{@rest[0]}' is not a Mission Control word");
}

# ---------------------------------------------------------------- start

sub cmd-start(%o, @args --> Int) {
    my %w = parse-run-words('start', @args);
    with %w<error> { return usage($_) }
    my $ws = %w<workspace> ne '' ?? %w<workspace> !! %o<workspace>;
    my $harness = %w<harness> ne '' ?? %w<harness> !! %o<harness>;
    my ($r, $err) = launch-run(%w<agent>, %w<words>, :workspace($ws), :via('321 start'), :$harness, :isolate(%w<isolate> || %o<isolate>));
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
    my $asked = (%run<harness> // {})<requested> // '';
    .say for row-lines('harness:', $asked ne '' ?? harness-name($asked) !! 'the first one able to enforce what the agent needs');
    my %iso = (%run<isolation> // {}).Hash;
    if %iso {
        .say for row-lines('workspace:', "a worktree of {%iso<of>} at {%iso<base>.substr(0, 7)}, in {%iso<path>}");
        .say for row-lines('', 'changes not yet committed there are not in it; the run never commits');
    }
    else { .say for row-lines('workspace:', %run<workspace> ne '' ?? "{%run<workspace>}; you commit, the agent only edits" !! 'none') }
    say '';
    say next-text('watch it, steer it or stop it', "$ME attach {$r.short}");
    EXIT-OK;
}

# ---------------------------------------------------------------- restart

#| A new run of an ended run's request.  It asks first on a terminal; in a
#| pipe it never asks, and --yes is the answer.
sub cmd-restart(%o, @args --> Int) {
    my %w = parse-run-words('restart', @args);
    with %w<error> { return usage($_) }
    %o<harness> = %w<harness> if %w<harness> ne '';
    %o<yes> ||= %w<yes>;
    my ($old, $err) = find-run(%w<run>);
    with $err { return usage($_) }
    with restart-refusal($old) { note "$ME: {who-of($old)}: $_"; note next-text('stop it', "$ME stop {$old.short}"); return EXIT-USAGE }
    my $h = '';
    if %o<harness> ne '' {
        my ($name, $why) = check-harness(%o<harness>);
        with $why { note "$ME: $why"; return EXIT-USAGE }
        $h = $name;
    }
    my $q = restart-question($old, :harness($h));
    unless %o<yes> {
        return usage("$q Add --yes to start it") unless $*IN.t && $*OUT.t && !%o<json> && !%o<brief>;
        print "$q  y/N ";
        my $a = $*IN.get // '';
        unless $a.trim.lc eq 'y' | 'yes' { say 'nothing was started'; return EXIT-OK }
    }
    my ($r, $why) = restart-run($old, :via('321 restart'), :harness($h));
    with $why { note "$ME: $why"; return $r.defined ?? EXIT-INTERNAL !! 5 }
    say-started(%o, $r, 'restart');
}

# ---------------------------------------------------------------- stop

sub cmd-stop(%o, @args --> Int) {
    my %w = parse-run-words('stop', @args);
    with %w<error> { return usage($_) }
    %o<force> ||= %w<force>;
    my ($r, $err) = find-run(%w<run>);
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

sub say-result(%o, RunDir $r, Str $word, Str $detail, :@signalled, :@swept, Str :$next, Str :$verb = 'stop') {
    if %o<json> {
        say encode-json(%( runId => $r.id, result => $word, detail => $detail, signalled => @signalled, swept => @swept ));
        return;
    }
    if %o<brief> { say record-line($r.id, $word, $detail); return }
    say title($verb, who-of($r));
    say '';
    .say for row-lines('result:', $word);
    if $detail ne '' { .say for row-lines('detail:', $detail) }
    for @swept -> %p { .say for row-lines('swept:', "{%p<pid>} {%p<command>} ({%p<signal>})") }
    for @signalled -> %p { .say for row-lines('signalled:', "{%p<pid>} {%p<command>} ({%p<signal>})") }
    with $next { say ''; say next-text('stop it without its host', $next) }
}

# ---------------------------------------------------------------- attach

# ---------------------------------------------------------------- hold, resume, steer

#| Hold, resume or steer one run, and say whether it took it: the host
#| records each directive it hands the runtime, so 'delivered' is the
#| run's own word, never ours.
sub cmd-control(%o, Str $kind, @args --> Int) {
    my %w = parse-run-words($kind, @args);
    with %w<error> { return usage($_) }
    my ($r, $err) = find-run(%w<run>);
    with $err { return usage($_) }
    my %l = liveness($r);
    unless %l<phase> eq 'running' | 'held' | 'starting' {
        say-result(%o, $r, 'unchanged', "it has {%l<phase> eq 'lost' ?? 'been lost' !! 'ended'}; nothing was sent", :verb($kind));
        return %l<phase> eq 'lost' ?? EXIT-LOST !! EXIT-OK;
    }
    my $id = try send-directive($r, $kind, :text(%w<words>), :reason("$kind with $ME $kind"), :client($ME));
    if $! { note "$ME: not sent: {$!.message}"; return EXIT-INTERNAL }
    my $tail = EventTail.new(:path($r.events-file));
    my $t0 = now;
    my $word = '';
    until $word ne '' || now - $t0 > 5 {
        for $tail.poll -> %e {
            next unless (%e<payload><directiveId> // '') eq $id;
            $word = 'delivered' if %e<kind> eq 'directive_delivered';
            $word = 'refused: ' ~ (%e<payload><reason> // '') if %e<kind> eq 'directive_refused';
        }
        sleep 0.2 if $word eq '';
    }
    my $detail = $word eq '' ?? 'not taken in 5 seconds; it waits in the inbox'
              !! $word ne 'delivered' ?? ''
              !! $kind eq 'steer' ?? steer-note((%($r.run<harness> // {}))<requested> // '')
              !! $kind eq 'hold' ?? 'its current step ends now, and it waits; resume carries on'
              !! 'it carries on where it was held';
    say-result(%o, $r, $word ne '' ?? $word !! 'sent', $detail, :verb($kind));
    $word.starts-with('refused') ?? EXIT-USAGE !! EXIT-OK;
}

sub cmd-attach(%o, @args --> Int) {
    my %w = parse-run-words('attach', @args);
    with %w<error> { return usage($_) }
    my ($r, $err) = find-run(%w<run>);
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
        # a run started elsewhere has no run.json: its package and receipt say who and what
        my %wp = %run ?? %() !! ((read-json-file($r.package-file, :group-ok) // {}).Hash);
        my %rc = %run ?? %() !! $r.receipt;
        @rows.push(%( runId => $r.id, phase => %l<phase>, outcome => %l<outcome> // '',
                      agent => %run<agent><id> // (%rc<agent> // {})<id> // '',
                      harness => ((%run<harness> // {})<requested> || (%rc<harness> // {})<adapter> // ''),
                      request => %run<request> // %wp<objective> // '', why => %l<why> // '' ));
    }
    if %o<json> { say encode-json(%( runs => @rows )); return EXIT-OK }
    say record-line(.<runId>, .<phase>, .<outcome>, .<agent>, .<harness>, .<request>) for @rows;
    EXIT-OK;
}

# ---------------------------------------------------------------- harnesses

#| The engines this machine has, whether 321 drives each, and what each
#| can do for a person watching a run.
sub cmd-harnesses(%o --> Int) {
    my @h = harness-records();
    if %o<json> { say encode-json(%( harnesses => @h )); return EXIT-OK }
    if %o<brief> {
        say record-line(.<name>, (.<ready> ?? 'ready' !! .<available> ?? 'not driven' !! 'not installed'), .<version>,
            .<enforces>.join(','), .<cannot>.join(',')) for @h;
        return EXIT-OK;
    }
    my $ready = @h.grep(*<ready>).elems;
    say title('harness can', "{$ready} of {+@h} ready");
    say '';
    for @h -> %h {
        my $state = %h<ready> ?? "ready, {%h<version>}" !! %h<available> ?? "installed ({%h<version>}); this 321 does not drive it yet" !! "not here: {%h<reason>}";
        .say for row-lines(%h<display> ~ ':', $state);
        if %h<available> {
            .say for row-lines('  enforces:', %h<enforces>.join(', '));
            .say for row-lines('  cannot:', %h<cannot>.join(', ') || 'nothing it is asked for');
        }
    }
    say '';
    say next-text('run an agent on one', "$ME start --harness {(@h.first(*<ready>) // @h[0] // {})<name> // 'NAME'} <agent> <request...>");
    EXIT-OK;
}
