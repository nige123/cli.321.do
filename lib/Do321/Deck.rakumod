unit module Do321::Deck;

#| Mission Control's screen.  The crew's deck over the selected run's
#| conversation, an input line, and one footer that teaches the keys.
#| Below 80 columns or 22 rows the deck folds into a one-line strip.
#|
#| The screen is a reader of run directories and a writer of inbox files,
#| nothing else: closing it, or its crashing, stops no run.  Every word
#| on it comes from a run's events, its receipt or the kernel.  A run is
#| "running" only while its host is that very process; a control is
#| "confirmed" only on the run's own evidence; "quiet for 6m" is said,
#| never "stuck".
#|
#| model -> render(model, rows, cols) -> Canvas is pure, so the screens
#| are tested at every size without a terminal.

use Do321::JSON;
use Do321::Look;
use Do321::Sys;
use Do321::RunDir;
use Do321::Fold;
use Do321::Host;
use Do321::Term;
use Do321::Harnesses;

#| A control with no acknowledgement in this long is called unconfirmed.
constant ACK-TIMEOUT = 5;
#| An activity beat stops this long after the last event.
constant BEAT-QUIET = 20;
#| A living run with no event for this long is called quiet.
constant QUIET-WARN = 300;

#| The open control on a run, in its lifecycle words.
sub control-note($c --> Str) {
    for $c.sent.kv -> $id, @v {
        my ($kind, $at) = @v;
        next if $kind eq 'steer';
        my %ctl = $c.state.controls{$id} // {};
        my $st = %ctl<state> // 'requested';
        next if $st eq 'confirmed' | 'applied' | 'duplicate';
        return "$kind not delivered" if $st eq 'refused' | 'rejected';
        return "$kind unconfirmed" if $st eq 'requested' && now.Num - $at > ACK-TIMEOUT;
        return "$kind {$st eq 'acknowledged' | 'received' ?? 'acknowledged' !! $st}";
    }
    '';
}

#| Whether a run needs a person: lost, left unswept, waiting on an answer,
#| failed, or a control nobody acknowledged.
sub needs-you($c --> Bool) is export {
    so ($c.phase eq 'lost' || $c.live<unswept> || ($c.phase eq 'ended' && $c.outcome eq 'blocked' | 'failed' | 'lost')
        || control-note($c).contains('unconfirmed'));
}

sub filter-word(Str $f --> Str) {
    given $f { when 'active' { 'active runs' } when 'needs' { 'runs that need you' } default { 'every run' } }
}

class Crew is export {
    has RunDir $.rd;
    has EventTail $.tail;
    has RunState $.state = RunState.new;
    has %.run;
    has %.live is rw;
    has Num $.checked is rw = 0e0;
    has Int $.scroll is rw = 0;       # comms lines scrolled up from the bottom; 0 follows live
    has Int $.seen is rw = 0;         # comms lines when the person last looked
    has %.sent;                       # directive id -> [kind, time sent, text] for what this screen sent
    has %.status is rw;               # the host's status.json: a cache, never proof
    has Int $.procs is rw = 0;        # processes the host last noted below it
    has Int $.find-at is rw;          # a conversation line to bring into view, once
    has Int $.hit is rw;              # the found line, counted from the log's first line

    method id { $!rd.id }
    method short { $!rd.short }
    method name(--> Str) { (%!run<agent><displayName> // %!run<agent><name> // '?').uc.substr(0, 6) }
    method display(--> Str) { %!run<agent><displayName> // %!run<agent><name> // '?' }
    method byline(--> Str) { %!run<agent><byline> // '' }
    #| The harness the run is on: the one the runtime chose, else the one asked for.
    method harness(--> Str) { $!state.harness || ((%!run<harness> // {})<requested> // '') }
    method tag(--> Str) { self.harness ne '' ?? harness-tag(self.harness) !! '' }
    method request(--> Str) { (%!run<request> // '').subst(/\s+/, ' ', :g) }
    method phase(--> Str) { $!state.phase eq 'ended' ?? 'ended' !! %!live<phase> // $!state.phase }
    method outcome(--> Str) { $!state.outcome ne '' ?? $!state.outcome !! (%!live<outcome> // '') }
    method active(--> Bool) { so self.phase eq 'starting' | 'running' | 'held' | 'stopping' }
    #| Conversation lines so far, those dropped from memory included.
    method total(--> Int) { $!state.lines.elems + $!state.dropped }
    method unread(--> Int) { (self.total - $!seen) max 0 }
    #| Seconds since the host last wrote its status, or -1 when it never has.
    method heartbeat-age(--> Int) {
        my $at = %!status<heartbeatAt> // '';
        return -1 if $at eq '';
        my $t = try DateTime.new($at);
        $t.defined ?? (now - $t.Instant).Int max 0 !! -1;
    }

    #| Read what is new; check the kernel every two seconds.
    method refresh(--> Bool) {
        my @e = $!tail.poll;
        fold-event($!state, $_) for @e;
        my $changed = @e.elems > 0;
        if now.Num - $!checked > 2 || @e.first({ .<kind> eq 'receipt' | 'host_ended' }) {
            my %l = liveness($!rd);
            $changed ||= (%l<phase> // '') ne (%!live<phase> // '');
            %!live = %l;
            %!status = $!rd.status;
            $!procs = @((read-json-file($!rd.dir.add('tree.json')) // {})<processes> // []).elems;
            $!checked = now.Num;
        }
        $changed;
    }
}

class Model is export {
    has IO::Path $.home = home-dir();
    has @.crew;
    has Int $.sel is rw = 0;
    has Str $.mode is rw = 'input';      # input | nav | confirm | palette | new-agent | new-request
    has Str $.input is rw = '';
    has Int $.cursor is rw = 0;
    has Str $.flash is rw = '';
    has Num $.flash-at is rw = 0e0;
    has Int $.tick is rw = 0;
    has $.confirm is rw;                  # [question, action]
    has @.palette;
    has Int $.pal is rw = 0;
    has Str $.new-agent is rw = '';
    has Str $.new-harness is rw = '';
    has Str $.pick-harness is rw = '';
    has Bool $.quit is rw = False;
    has Num $.scanned is rw = 0e0;
    has Str $.filter is rw = 'all';       # all | active | needs
    has Str $.draft is rw = '';           # the input line, kept while finding

    #| The runs the deck shows, under the filter.
    method visible(--> List) {
        given $!filter {
            when 'active' { @!crew.grep(*.active).List }
            when 'needs'  { @!crew.grep({ needs-you($_) }).List }
            default       { @!crew.List }
        }
    }
    method selected(--> Crew) { self.visible[$!sel] // Crew }

    #| Find runs: every hosted run that is active, or ended in the last day.
    method scan() {
        my $keep = self.selected;
        my %have = @!crew.map({ .id => True });
        for all-runs($!home) -> $rd {
            next if %have{$rd.id} || !$rd.hosted;
            my $c = Crew.new(:$rd, :tail(EventTail.new(:path($rd.events-file))), :run($rd.run));
            $c.refresh;
            $c.seen = $c.total;      # what was said before this screen opened is not news
            next if !$c.active && run-older-than($c.run<launchedAt> // '', 86400);
            @!crew.push($c);
        }
        @!crew = @!crew.sort({ ($^a.active ?? 0 !! 1) <=> ($^b.active ?? 0 !! 1) || $^b.id cmp $^a.id });
        $!sel = (self.visible.first({ $keep.defined && .id eq $keep.id }, :k) // 0);
        $!scanned = now.Num;
    }

    method tell(Str $s) { $!flash = $s; $!flash-at = now.Num }
}

sub run-older-than(Str $iso, Int $secs --> Bool) {
    return False if $iso eq '';
    my $t = try DateTime.new($iso);
    return False without $t;
    now - $t.Instant > $secs;
}

sub ago(Str $iso --> Str) is export {
    return '' if $iso eq '';
    my $t = try DateTime.new($iso);
    return '' without $t;
    my $s = (now - $t.Instant).Int max 0;
    $s < 60 ?? "{$s}s" !! $s < 3600 ?? "{$s div 60}m" !! $s < 86400 ?? "{$s div 3600}h" !! "{$s div 86400}d";
}

sub met(Crew $c --> Str) {
    return '' if ($c.run<launchedAt> // '') eq '';
    my $from = try DateTime.new($c.run<launchedAt>);
    return '' without $from;
    my $to = $c.state.ended-at ne '' ?? (try DateTime.new($c.state.ended-at).Instant) // now !! now;
    my $s = ($to - $from.Instant).Int max 0;
    $s >= 3600 ?? sprintf('%d:%02d:%02d', $s div 3600, ($s div 60) % 60, $s % 60) !! sprintf('%d:%02d', $s div 60, $s % 60);
}

#| A run's state as a mark, a word and a tone: the deck's STATE column.
#| The beat strikes once in four ticks while events arrive, and stops when
#| they have not for BEAT-QUIET seconds.
sub crew-line(Crew $c, Int $tick, Bool :$narrow = False --> List) is export {
    my $s = $c.state;
    my $quiet = $s.last-at ne '' ?? (now - ((try DateTime.new($s.last-at).Instant) // now)) !! 0;
    my $ctl = control-note($c);
    given $c.phase {
        when 'starting' { return ('·', 'starting', 'dim') }
        when 'running' {
            my $beat = $quiet < BEAT-QUIET && $tick % 4 == 0;
            # a host whose heartbeat stopped is said so; liveness still decides lost
            my $hb = $c.heartbeat-age;
            return ('•', "no heartbeat for {$hb}s", 'wait') if $hb > HEARTBEAT-STALE && ($c.live<phase> // '') eq 'running';
            my $word = $quiet > QUIET-WARN ?? "quiet for {ago($s.last-at)}" !! $s.activity;
            $word ~= " · $ctl" if $ctl ne '';
            return ($beat ?? '●' !! '•', $word, $ctl.contains('unconfirmed') || $quiet > QUIET-WARN ?? 'wait' !! 'ok');
        }
        when 'held'     { return ('‖', 'held' ~ ($ctl ne '' ?? " · $ctl" !! ''), 'wait') }
        when 'stopping' { return ('●', 'stopping' ~ ('·' x (1 + $tick % 3)), 'wait') }
        when 'lost'     { return ('✗', 'lost: ' ~ ($c.live<why> // 'host gone'), 'bad') }
        when 'ended' {
            my $o = $c.outcome;
            my $when = $s.ended-at ne '' ?? " {ago($s.ended-at)} ago" !! '';
            given $o {
                when 'done'      { return ('✓', "done$when", 'ok') }
                when 'no_change' { return ('✓', "no change$when", 'ok') }
                when 'blocked'   { return ('?', 'waits on you' ~ ($narrow ?? '' !! ": {$s.summary}"), 'wait') }
                when 'stopped'   { return ('■', "stopped$when", 'dim') }
                when 'lost'      { return ('✗', 'lost: ' ~ ($c.live<why> // ''), 'bad') }
                default          { return ('✗', "$o$when", 'bad') }
            }
        }
    }
    ('?', $c.phase, 'dim');
}

# ------------------------------------------------------------ render

#| Draw the whole screen into a canvas.  Pure but for a find, which moves
#| the scroll once: the model and the size in, the canvas out.
#|
#| Three layouts: the strip below 80 columns or 22 rows; the deck over
#| the conversation; and from 150 columns the crew in a rail at the left,
#| the conversation in the middle and the run's evidence at the right.
sub render(Model $m, Int $rows, Int $cols --> Canvas) is export {
    my $cv = Canvas.new(:$rows, :$cols);
    return $cv if $rows < 6 || $cols < 30;
    my $strip = $cols < 80 || $rows < 22;
    my $rail = !$strip && $cols >= 150;
    my @all = $m.crew;
    my @crew = $m.visible;
    my $active = @all.grep(*.active).elems;
    my $waiting = @all.grep({ .phase eq 'ended' && .outcome eq 'blocked' }).elems;
    my $bad = @all.grep({ .phase eq 'lost' || (.phase eq 'ended' && .outcome eq 'failed' | 'lost') }).elems;
    my $done = @all.grep({ .phase eq 'ended' && .outcome eq 'done' | 'no_change' }).elems;
    my $usd = [+] @all.map({ .state.cost-reported ?? .state.usd !! 0 });
    my $reported = @all.first(*.state.cost-reported).defined;
    my $clock = DateTime.now.local;
    my $time = sprintf('%02d:%02d:%02d', $clock.hour, $clock.minute, $clock.second);
    my $empty = @all ?? "No {filter-word($m.filter)} right now.  v shows every run."
                     !! 'No runs yet.  Ctrl-N starts one; it keeps going when you close this screen.';
    my $row = 0;

    if $strip {
        # one line for the crew; the selected run's conversation takes the rest
        my $c = $cv.put(0, 0, "{icon()} 321 ", 'brand');
        for @crew.kv -> $i, $cr {
            my ($mark, $, $tone) = crew-line($cr, $m.tick, :narrow);
            my $label = "{$cr.short} {$cr.name}{$i != $m.sel && $cr.unread ?? '+' ~ $cr.unread !! ''} ";
            if $c + text-width($label) + 2 > $cols - 4 { $cv.put(0, $c, "+{@crew - $i}", 'dim'); last }
            my $st = $i == $m.sel ?? 'sel+bold' !! '';
            $c = $cv.put(0, $c, ($i == $m.sel ?? '▶' !! ' ') ~ $label, $st);
            $c = $cv.put(0, $c, $mark, $tone);
            $c = $cv.put(0, $c, ' ');
        }
        $cv.put(1, 0, '─' x $cols, 'dim');
        $row = 2;
        my $sc = $m.selected;
        if $sc.defined {
            my $right = "{met($sc)} · {ago($sc.state.last-at)}";
            $cv.put($row, 1, "{$sc.name} {$sc.short}{$sc.tag ne '' ?? ' · ' ~ $sc.tag !! ''} · {$sc.request}", 'bold', :max($cols - text-width($right) - 3));
            $cv.put($row, $cols - text-width($right) - 1, $right, 'dim');
            $row++;
        }
    }
    else {
        my $sum = "{$active} active";
        $sum ~= " · $waiting wait{$waiting == 1 ?? 's' !! ''} on you" if $waiting;
        $sum ~= " · $bad need{$bad == 1 ?? 's' !! ''} a look" if $bad;
        $sum ~= " · $done done" if $done && $cols >= 100;
        $sum ~= ' · ' ~ ($reported ?? sprintf('$%.2f reported', $usd) !! 'no cost reported') if $cols >= 100;
        $sum ~= " · showing {filter-word($m.filter)}" if $m.filter ne 'all';
        my $c = $cv.put(0, 0, "{icon()} 321 MISSION CONTROL", 'brand');
        $cv.put(0, $c + 3, $sum, 'dim', :max($cols - $c - 14));
        $cv.put(0, $cols - 9, $time, 'dim');
        $cv.put(1, 0, '─' x $cols, 'dim');
        $row = 2;
        $row = draw-deck($cv, $m, @crew, $row, $rows, $cols, $empty) unless $rail;
    }

    # --- the conversation, above the input line and the footer
    my $foot = $rows - 3;          # rule, input, footer rows
    my $sc = $m.selected;
    if $rail {
        my $rw = 30;
        my $ew = 40;
        my $mid = $rw + 2;
        my $mw = $cols - $ew - 1 - $mid - 1;
        for $row ..^ $foot -> $r { $cv.put($r, $rw, '│', 'dim'); $cv.put($r, $cols - $ew - 1, '│', 'dim') }
        draw-rail($cv, $m, @crew, $row, $foot, $rw, $empty);
        if $sc.defined {
            my $c = $cv.put($row, $mid, $sc.display, 'bold', :max($mw));
            $c = $cv.put($row, $c, ", {$sc.byline}", '', :max($mid + $mw - $c)) if $sc.byline ne '';
            $cv.put($row, $c, "  on {harness-name($sc.harness)}", 'dim', :max($mid + $mw - $c)) if $sc.harness ne '';
            draw-comms($cv, $sc, $row + 1, $foot, $mid, $mw);
            draw-evidence($cv, $sc, $row, $foot, $cols - $ew + 1, $ew - 1);
        }
        else { $cv.put($row + 1, $mid, $empty, 'dim', :max($mw)) }
    }
    elsif $sc.defined && $foot - $row > 0 {
        draw-comms($cv, $sc, $row, $foot, 0, $cols - 1, :narrow($cols < 80));
    }
    elsif !$sc.defined && $foot - $row > 2 && $strip {
        $cv.put($row + 1, 1, @all ?? $empty !! 'No runs yet.  Ctrl-N starts one.', 'dim');
    }

    # --- the input line and the footer
    $cv.put($foot, 0, '─' x $cols, 'dim');
    my ($prompt, $hint) = prompt-and-hint($m, $cols);
    my $pc = $cv.put($foot + 1, 1, $prompt, 'bold');
    $cv.put($foot + 1, $pc, ' ' ~ input-view($m, $cols - $pc - 2));
    # a flash never hides what a palette or a question needs to say
    my $flash = (now.Num - $m.flash-at < 6 && $m.mode eq 'input' | 'nav' | 'find') ?? $m.flash !! '';
    $cv.put($foot + 2, 1, $flash ne '' ?? $flash !! $hint, $flash ne '' ?? 'wait' !! 'dim');
    $cv;
}

#| The deck: a table of runs, never more than a third of the screen, then
#| who the selected run is.  Returns the next free row.
sub draw-deck(Canvas $cv, Model $m, @crew, Int $top, Int $rows, Int $cols, Str $empty --> Int) {
    my $row = $top;
    my $deck-max = (($rows div 3) - 1) max 3;
    my $wide = $cols >= 110;
    my @w = $wide ?? (6, 16, 0, 30, 9, 6, 6, 9) !! (5, 7, 0, 18, 6, 5, 0, 0);
    my $spare = $cols - 2 - @w.sum - 1;
    # the mission gets up to 44 columns; anything more goes to the state
    @w[2] = $spare min 44;
    @w[3] += $spare - @w[2];
    if $wide {
        $cv.put($row, 2, pad('RUN', @w[0]) ~ pad('CREW', @w[1]) ~ pad('MISSION', @w[2]) ~ pad('STATE', @w[3]) ~
            pad('MET', @w[4]) ~ pad('LAST', @w[5]) ~ pad('TOOLS', @w[6]) ~ 'COST', 'dim');
        $row++;
        $deck-max--;
    }
    my $first = 0;
    $first = $m.sel - $deck-max + 2 if $m.sel >= $deck-max - 1 && @crew > $deck-max;
    $first = 0 if $first < 0;
    my $shown = 0;
    for @crew.kv -> $i, $cr {
        next if $i < $first;
        if $shown == $deck-max - 1 && @crew - $i > 1 {
            my $rest = @crew - $i;
            $cv.put($row, 2, "and $rest more  ↑↓ to see them", 'dim');
            $row++;
            last;
        }
        my ($mark, $word, $tone) = crew-line($cr, $m.tick, :narrow(!$wide));
        my $sel = $i == $m.sel;
        $word ~= " · {$cr.unread} new" if !$sel && $cr.unread;
        my $c = $cv.put($row, 0, $sel ?? '▶ ' !! '  ', $sel ?? 'bold' !! '');
        $c = $cv.put($row, $c, pad($cr.short, @w[0]), $sel ?? 'bold' !! '');
        if $wide {
            # the agent first; the harness beside it, quieter
            my $nc = $cv.put($row, $c, pad($cr.name, 7), $sel ?? 'bold' !! '');
            $cv.put($row, $nc, fit($cr.tag, @w[1] - 8), 'dim');
            $c += @w[1];
        }
        else { $c = $cv.put($row, $c, pad($cr.name, @w[1] - 1) ~ ' ', $sel ?? 'bold' !! '') }
        $c = $cv.put($row, $c, pad($cr.request, @w[2] - 1) ~ ' ', $sel ?? 'bold' !! '');
        my $sc = $cv.put($row, $c, $mark ~ ' ', $tone);
        $cv.put($row, $sc, fit($word, @w[3] - 3), $tone eq 'ok' ?? '' !! $tone);
        $c += @w[3];
        $c = $cv.put($row, $c, pad(met($cr), @w[4]), 'dim');
        $c = $cv.put($row, $c, pad(ago($cr.state.last-at), @w[5]), 'dim');
        if $wide {
            $c = $cv.put($row, $c, pad($cr.state.tools.Str, @w[6]), 'dim');
            $cv.put($row, $c, $cr.state.cost-text, 'dim');
        }
        $cv.tint($row, 0, $cols, 'sel') if $sel;
        $row++;
        $shown++;
    }
    unless @crew {
        $cv.put($row, 2, $empty, 'dim');
        $row++;
    }
    $cv.put($row, 0, '─' x $cols, 'dim');
    $row++;
    my $sc = $m.selected;
    if $sc.defined {
        my $c = $cv.put($row, 1, $sc.display, 'bold');
        $c = $cv.put($row, $c, ", {$sc.byline}") if $sc.byline ne '';
        my $right = "{$sc.short}{$sc.harness ne '' ?? ' · on ' ~ harness-name($sc.harness) !! ''} · {$sc.state.attempts > 1 ?? "attempt {$sc.state.attempts} · " !! ''}{($sc.run<workspace> // '') || 'no workspace'}";
        $cv.put($row, ($c + 4) max ($cols - text-width($right) - 1), $right, 'dim', :max($cols - $c - 5));
    }
    $row + 1;
}

#| The crew as a rail: two rows a run, its state then its request.
sub draw-rail(Canvas $cv, Model $m, @crew, Int $top, Int $bottom, Int $w, Str $empty) {
    my $fits = ($bottom - $top) div 2;
    my $first = $m.sel >= $fits ?? $m.sel - $fits + 1 !! 0;
    my $r = $top;
    for @crew.kv -> $i, $cr {
        next if $i < $first;
        if $r + 1 >= $bottom { $cv.put($bottom - 1, 2, "and {@crew - $i} more  ↑↓", 'dim'); last }
        my $sel = $i == $m.sel;
        my ($mark, $word, $tone) = crew-line($cr, $m.tick, :narrow);
        $word ~= " · {$cr.unread} new" if !$sel && $cr.unread;
        my $c = $cv.put($r, 0, $sel ?? '▶ ' !! '  ', $sel ?? 'bold' !! '');
        $c = $cv.put($r, $c, "{$cr.short} " ~ pad($cr.name, 7), $sel ?? 'bold' !! '');
        $c = $cv.put($r, $c, $mark ~ ' ', $tone);
        $cv.put($r, $c, fit($word, $w - $c - 1), $tone eq 'ok' ?? 'dim' !! $tone);
        $cv.put($r + 1, 6, fit(($cr.tag ne '' ?? "{$cr.tag} · " !! '') ~ $cr.request, $w - 7), 'dim');
        if $sel { $cv.tint($r, 0, $w, 'sel'); $cv.tint($r + 1, 0, $w, 'sel') }
        $r += 2;
    }
    unless @crew { $cv.put($top + 1, 2, $_, 'dim', :max($w - 3)) for wrap($empty, $w - 3)[0] }
}

#| A run's evidence, each row from a file or the kernel, with its source
#| where the words alone would overclaim.
sub evidence-rows(Crew $c --> List) is export {
    my $s = $c.state;
    my %h = $c.rd.host;
    my $hb = $c.heartbeat-age;
    my @r;
    @r.push(['phase', $c.phase ~ ($c.outcome ne '' ?? ", {$c.outcome}" !! ''), '']);
    my $h = $c.harness;
    @r.push(['harness', $h ne '' ?? harness-name($h) ~ ($s.harness eq '' ?? ', asked for' !! '') !! 'not chosen yet', '']);
    with known-registry().get($h) -> $a {
        my %ab = abilities($a);
        @r.push(['cannot', %ab<cannot>.join(', '), 'wait']) if %ab<cannot>;
    }
    @r.push(['attempts', $s.attempts.Str, '']);
    @r.push(['tools', many-of($s.tools, 'call'), '']);
    @r.push(['cost', $s.cost-reported ?? "{$s.cost-text}, as the harness reported it" !! 'none reported yet', '']);
    @r.push(['host', %h<pid> ?? "pid {%h<pid>}" ~ ($hb >= 0 ?? ", heartbeat {$hb}s ago" !! '') !! 'not started yet',
             $hb > HEARTBEAT-STALE && $c.active ?? 'wait' !! '']);
    my $u = $c.status<usage>;
    if $u ~~ Associative && $c.active {
        my $n = ($u<processes> // 0).Int;
        @r.push(['below it', "$n process{$n == 1 ?? '' !! 'es'}", '']);
        @r.push(['cpu, mem', sprintf('%.1fs, %d MB', ($u<cpuSeconds> // 0).Num, (($u<rssBytes> // 0) / 1_048_576).Int), '']);
    }
    @r.push(['workspace', ($c.run<workspace> // '') || 'none', '']);
    my $ctl = control-note($c) || $s.open-control;
    @r.push(['control', $ctl || 'none open', $ctl.contains('unconfirmed') ?? 'wait' !! '']);
    @r.push(['receipt', $c.rd.receipt-file.e ?? 'written by the runtime' !! $c.rd.ended-file.e ?? 'none; ended.json has the basis' !! 'not yet', '']);
    @r.push(['log', many-of($c.total, 'line') ~ ($s.dropped ?? ", {$s.dropped} only in events.jsonl" !! ''), '']);
    @r.List;
}

sub draw-evidence(Canvas $cv, Crew $c, Int $top, Int $bottom, Int $left, Int $w) {
    $cv.put($top, $left, 'EVIDENCE', 'dim');
    my $r = $top + 1;
    for evidence-rows($c) -> @e {
        last if $r >= $bottom;
        $cv.put($r, $left, pad(@e[0], 10), 'dim');
        $cv.put($r, $left + 10, fit(@e[1], $w - 10), @e[2]);
        $r++;
    }
}

#| The selected run's conversation in a box, following the newest line
#| unless the person scrolled up, or a find asked for a line.
sub draw-comms(Canvas $cv, Crew $sc, Int $top, Int $bottom, Int $left, Int $width, Bool :$narrow = False) {
    my $rows = $bottom - $top;
    return if $rows <= 0;
    my @starts;
    my @lines = comms-lines($sc, $width, :$narrow, :@starts);
    my $total = @lines.elems;
    with $sc.find-at -> $i {
        $sc.scroll = ($total - (@starts[$i] // 0) - ($rows div 2)) max 0;
        $sc.find-at = Int;
    }
    my $scroll = $sc.scroll min ($total - $rows max 0);
    $sc.scroll = $scroll;
    my $end = $total - $scroll;
    my $start = ($end - $rows) max 0;
    my $r = $top;
    for @lines[$start ..^ $end] -> @l {
        my $c = $left;
        for @l -> ($text, $style) { $c = $cv.put($r, $c, $text, $style, :max(($left + $width - $c) max 0)) }
        $r++;
    }
    with $sc.hit -> $abs {
        my $h = $abs - $sc.state.dropped;
        if $h >= 0 && @starts[$h].defined {
            for @starts[$h] ..^ (@starts[$h + 1] // $total) -> $l {
                $cv.tint($top + $l - $start, $left, $left + $width, 'sel') if $start <= $l < $end;
            }
        }
    }
    if $scroll > 0 { $cv.put($bottom - 1, $left + $width - 21, pad("▼ {$scroll} more below", 21), 'dim') }
    else { $sc.seen = $sc.total }
}

sub input-view(Model $m, Int $w --> Str) {
    my $t = $m.mode eq 'input' | 'new-agent' | 'new-request' | 'find' | 'pick-harness' ?? $m.input !! '';
    $t = $t.subst("\n", '⏎', :g);
    text-width($t) > $w ?? '…' ~ $t.substr(* - ($w - 1)) !! $t;
}

#| Where the cursor goes: the end of the typed text on the input line.
sub cursor-at(Model $m, Int $rows, Int $cols --> List) is export {
    return (-1, 0) unless $m.mode eq 'input' | 'new-agent' | 'new-request' | 'find' | 'pick-harness';
    my ($prompt) = prompt-and-hint($m, $cols);
    my $pre = $m.input.substr(0, $m.cursor).subst("\n", '⏎', :g);
    my $col = 1 + text-width($prompt) + 1 + text-width($pre);
    ($rows - 2, $col min ($cols - 1));
}

sub prompt-and-hint(Model $m, Int $cols --> List) {
    my $sc = $m.selected;
    my $narrow = $cols < 100;
    given $m.mode {
        when 'confirm' { return ($m.confirm[0], 'y yes · any other key cancels') }
        when 'palette' {
            my @p = $m.palette;
            my $item = @p[$m.pal];
            return ("{$item<label>} ({$m.pal + 1}/{+@p})", "{$item<what>}   ↑↓ choose · Enter do it · Esc back");
        }
        when 'new-agent'   { return ('new run, agent ›', "the agent's name; 'bea on codex' picks the engine   Enter next · Esc cancel") }
        when 'new-request' { return ("new run for {$m.new-agent}{$m.new-harness ne '' ?? ' on ' ~ harness-name($m.new-harness) !! ''} ›", 'what it should do   Enter start · Esc cancel') }
        when 'pick-harness' {
            my @ready = harness-records().grep(*<ready>).map(*<name>);
            return ("run {$sc.defined ?? $sc.name ~ ' ' ~ $sc.short !! 'it'} again on ›", "one of: {@ready.join(', ') || 'none ready'}   Enter next · Esc cancel");
        }
        when 'find' { return ('find ›', "words in {$sc.defined ?? $sc.name ~ ' ' ~ $sc.short !! 'this run'}'s conversation   Enter older match · Esc back") }
        when 'nav' {
            return ('', $narrow
                ?? '↑↓ run · Enter type · h hold · r resume · s stop · v view · q leave'
                !! '↑↓ run   Enter type   h hold   r resume   s stop   n new   v view   ^F find   ^P actions   q leave');
        }
    }
    my $to = $sc.defined ?? "to {$sc.name} {$sc.short} ›" !! '›';
    ($to, $narrow
        ?? 'Enter send · Esc navigate · ^P actions · ^N new · ^D leave'
        !! 'Enter send   Esc navigate   ←→ run   PgUp/PgDn scroll   ^F find   ^P actions   ^N new run   ^D leave');
}

#| A run's conversation as screen lines: each a list of [text, style].
#| :@starts receives the first screen line of each conversation line.
sub comms-lines(Crew $c, Int $w, Bool :$narrow = False, :@starts --> List) is export {
    my @out;
    my $time-w = 7;
    my $who-w = ($c.name.chars + 1) max 4;
    if $c.state.dropped {
        @out.push([[' ' x $time-w, ''], [fit("· {$c.state.dropped} earlier lines are in {$c.rd.events-file}", $w - $time-w), 'dim']]);
    }
    for $c.state.lines -> $l {
        @starts.push(@out.elems);
        my $t = hhmm($l.at);
        my $mark = $l.mark;
        given $l.who {
            when 'tool' | 'note' {
                my $text = "· {$l.text}";
                my $room = $w - $time-w - $who-w - (text-width($mark) + 2);
                my @wr = wrap($text, $room max 10);
                for @wr.kv -> $i, $part {
                    my @row = [' ' ~ pad($i ?? '' !! $t, $time-w - 1), 'dim'], [' ' x $who-w, ''], [pad($part, $room), $l.tone eq '' ?? 'dim' !! $l.tone];
                    @row.push([' ' ~ $mark, $l.tone || 'dim']) if $i == 0 && $mark ne '';
                    @out.push(@row);
                }
            }
            when 'end' {
                for wrap($l.text, $w - $time-w - 3).kv -> $i, $part {
                    @out.push([[' ' ~ pad($i ?? '' !! $t, $time-w - 1), 'dim'], [($i ?? '  ' !! (crew-line($c, 0)[0] ~ ' ')), $l.tone], [$part, "bold+{$l.tone}"]]);
                }
            }
            default {
                my $who = $l.who eq 'you' ?? 'you' !! $c.name;
                my $room = $w - $time-w - $who-w - ($mark ne '' ?? text-width($mark) + 2 !! 0);
                my @wr = wrap($l.text, $room max 10);
                for @wr.kv -> $i, $part {
                    my @row = [' ' ~ pad($i ?? '' !! $t, $time-w - 1), 'dim'], [pad($i ?? '' !! $who, $who-w), 'bold'];
                    if $mark ne '' && $i == 0 { @row.push([pad($part, $room), '']); @row.push(['  ' ~ $mark, $l.tone || 'dim']) }
                    else { @row.push([$part, '']) }
                    @out.push(@row);
                }
            }
        }
    }
    # what this screen sent and the host has not yet delivered, echoed at
    # once, and called unconfirmed when no answer comes
    for $c.sent.kv -> $id, @v {
        next unless @v[0] eq 'steer' && !$c.state.controls{$id};
        my $late = now.Num - @v[1] > ACK-TIMEOUT;
        my $mark = $late ?? '… unconfirmed' !! '· sending';
        my $room = $w - $time-w - $who-w - text-width($mark) - 2;
        @out.push([[' ' x $time-w, ''], [pad('you', $who-w), 'bold'], [pad(fit((@v[2] // '').subst("\n", ' ', :g), $room), $room), ''], ['  ' ~ $mark, $late ?? 'wait' !! 'dim']]);
    }
    # a run that ended without a word from its log still says how it ended
    if !$c.state.lines.first(*.who eq 'end') && $c.phase eq 'ended' | 'lost' {
        my ($mark, $word, $tone) = crew-line($c, 0);
        @out.push([[' ' x $time-w, ''], ["$mark $word", "bold+$tone"]]);
    }
    @out.List;
}

# ------------------------------------------------------------ actions

sub actions-for(Model $m --> List) is export {
    my $c = $m.selected;
    my @a;
    if $c.defined {
        given $c.phase {
            when 'running' {
                @a.push(%( key => 'hold', label => 'Hold', what => 'ends the current step now and waits; Resume continues the conversation' ));
                @a.push(%( key => 'stop', label => 'Stop', what => "ends this run; the others keep running" ));
            }
            when 'held' {
                @a.push(%( key => 'resume', label => 'Resume', what => 'continues the conversation where it was held' ));
                @a.push(%( key => 'stop', label => 'Stop', what => 'ends this run; the others keep running' ));
            }
            when 'stopping' | 'starting' {
                @a.push(%( key => 'stop', label => 'Stop', what => 'ends this run; the others keep running' ));
            }
        }
        if $c.phase eq 'ended' | 'lost' {
            @a.push(%( key => 'restart', label => 'Run again', what => 'a new run of this request, with its own budget; this one stays as it ended' ));
            @a.push(%( key => 'restart-on', label => 'Run again on another harness', what => 'the same agent and request on another engine, as a new run; nothing carries over' ));
        }
        if $c.phase eq 'lost' || $c.live<unswept> || control-note($c).contains('unconfirmed') || ($c.phase eq 'stopping' && ($c.live<phase> // '') ne 'ended') {
            @a.push(%( key => 'force', label => 'Force stop', what => 'stops its host and everything below it, checked by process identity' ));
        }
    }
    @a.push(%( key => 'new', label => 'New run', what => 'start an agent on something; it keeps going when you leave' ));
    my $next = %( all => 'active', active => 'needs', needs => 'all' ){$m.filter};
    @a.push(%( key => 'view', label => "Show {filter-word($next)}", what => "the deck shows {filter-word($m.filter)} now" ));
    @a.push(%( key => 'follow', label => 'Follow live', what => 'scroll to the newest line and stay there' )) if $c.defined;
    @a.push(%( key => 'quit', label => 'Leave', what => 'close Mission Control; every run keeps going' ));
    @a.List;
}

sub send-control(Model $m, Str $kind) {
    my $c = $m.selected // return;
    my $id = try send-directive($c.rd, $kind, :reason("$kind from Mission Control"), :client('mission-control'));
    if $! { $m.tell("not sent: {$!.message}"); return }
    $c.sent{$id} = [$kind, now.Num, ''];
    $m.tell("{$kind} requested for {$c.name} {$c.short}");
}

sub do-action(Model $m, Str $key) is export {
    my $c = $m.selected;
    given $key {
        when 'hold'   { send-control($m, 'hold') if $c.defined && $c.phase eq 'running' }
        when 'resume' { send-control($m, 'resume') if $c.defined && $c.phase eq 'held' }
        when 'stop' {
            return unless $c.defined && $c.active;
            my @others = $m.crew.grep({ .active && .id ne $c.id }).map({ "{.name} {.short}" });
            my $rest = @others ?? " {@others.head(3).join(', ')}{@others > 3 ?? ' and others' !! ''} keep{@others == 1 ?? 's' !! ''} running." !! '';
            $m.confirm = ["Stop {$c.name} {$c.short}?$rest", 'stop-now'];
            $m.mode = 'confirm';
        }
        when 'force' {
            return unless $c.defined;
            $m.confirm = ["Force stop {$c.name} {$c.short}? Its processes are killed, checked by identity.", 'force-now'];
            $m.mode = 'confirm';
        }
        when 'stop-now'  { send-control($m, 'stop') }
        when 'force-now' {
            my $rd = $c.rd;
            $m.tell("force stop of {$c.name} {$c.short} in progress");
            start { my %f = force-stop($rd); $m.tell(%f<done> ?? "force stopped {$c.short}: {+@(%f<signalled>)} processes signalled" !! "not needed: {%f<why>}") }
        }
        when 'restart' {
            return unless $c.defined;
            with restart-refusal($c.rd) { $m.tell("not now: $_"); return }
            $m.pick-harness = '';
            $m.confirm = [restart-question($c.rd), 'restart-now'];
            $m.mode = 'confirm';
        }
        when 'restart-on' {
            return unless $c.defined;
            with restart-refusal($c.rd) { $m.tell("not now: $_"); return }
            $m.mode = 'pick-harness'; $m.input = ''; $m.cursor = 0;
        }
        when 'restart-now' {
            my ($rd, $err) = restart-run($c.rd, :harness($m.pick-harness));
            with $err { $m.tell("not started: $_"); return }
            $m.filter = 'all';
            $m.scan;
            $m.sel = $m.visible.first({ .id eq $rd.id }, :k) // 0;
            $m.tell("started {$rd.short}, again of {$c.short}{$m.pick-harness ne '' ?? ' on ' ~ harness-name($m.pick-harness) !! ''}; it has its own budget");
        }
        when 'view' { cycle-filter($m) }
        when 'new'    { $m.mode = 'new-agent'; $m.input = ''; $m.cursor = 0 }
        when 'follow' { .scroll = 0 with $c }
        when 'quit'   { $m.quit = True }
    }
}

sub cycle-filter(Model $m) {
    my $keep = $m.selected;
    $m.filter = %( all => 'active', active => 'needs', needs => 'all' ){$m.filter};
    $m.sel = $m.visible.first({ $keep.defined && .id eq $keep.id }, :k) // 0;
    $m.tell("showing {filter-word($m.filter)}: {+$m.visible} of {+$m.crew}");
}

#| Bring the next older line that says what was typed into view; past the
#| oldest, start again from the newest.
sub find-next(Model $m) {
    my $c = $m.selected // return;
    my $q = $m.input.trim.lc;
    if $q eq '' { $m.tell('type what to look for'); return }
    my @lines = $c.state.lines;
    my $d = $c.state.dropped;
    my @hits = @lines.grep({ .text.lc.contains($q) }, :k);
    unless @hits { $m.tell("no line of {$c.name} {$c.short} says '{$m.input.trim}'"); return }
    my $from = $c.hit.defined ?? $c.hit - $d !! @lines.elems;
    my @older = @hits.grep(* < $from);
    my $i = @older ?? @older.tail !! @hits.tail;
    $c.hit = $i + $d;
    $c.find-at = $i;
    my $nth = @hits.elems - @hits.first({ $_ == $i }, :k);
    $m.tell("match $nth of {+@hits}, {hhmm(@lines[$i].at)}" ~ (@older ?? '' !! (@hits > 1 && $from <= @hits.head ?? '; back to the newest' !! '')));
}

#| One key, applied to the model.  Returns whether anything changed.
sub handle-key(Model $m, Key $k, Int :$page = 10) is export {
    my $c = $m.selected;
    my sub move(Int $d) {
        my $n = $m.visible.elems;
        return unless $n;
        $m.sel = ($m.sel + $d) % $n;
    }
    my sub edit() {
        given $k.name {
            when 'char' | 'paste' {
                $m.input = $m.input.substr(0, $m.cursor) ~ $k.text ~ $m.input.substr($m.cursor);
                $m.cursor += $k.text.chars;
            }
            when 'alt-enter' | 'ctrl-j' { $m.input = $m.input.substr(0, $m.cursor) ~ "\n" ~ $m.input.substr($m.cursor); $m.cursor++ }
            when 'backspace' { if $m.cursor > 0 { $m.input = $m.input.substr(0, $m.cursor - 1) ~ $m.input.substr($m.cursor); $m.cursor-- } }
            when 'delete'    { $m.input = $m.input.substr(0, $m.cursor) ~ $m.input.substr($m.cursor + 1) if $m.cursor < $m.input.chars }
            when 'home' | 'ctrl-a' { $m.cursor = 0 }
            when 'end' | 'ctrl-e'  { $m.cursor = $m.input.chars }
            when 'ctrl-u' { $m.input = ''; $m.cursor = 0 }
            when 'left'  { $m.cursor-- if $m.cursor > 0 }
            when 'right' { $m.cursor++ if $m.cursor < $m.input.chars }
        }
    }
    # keys that mean the same everywhere
    given $k.name {
        when 'ctrl-d' | 'ctrl-c' { $m.quit = True; return }
        when 'ctrl-p' { $m.palette = actions-for($m); $m.pal = 0; $m.mode = 'palette'; return }
        when 'ctrl-n' { do-action($m, 'new'); return }
        when 'ctrl-l' { .scroll = 0 with $c; return }
        when 'ctrl-f' {
            return unless $c.defined;
            $m.draft = $m.input unless $m.mode eq 'find';
            $m.mode = 'find'; $m.input = ''; $m.cursor = 0;
            return;
        }
        when 'pgup'   { if $c.defined { $c.scroll += $page }; return }
        when 'pgdn'   { if $c.defined { $c.scroll = ($c.scroll - $page) max 0 }; return }
    }
    given $m.mode {
        when 'confirm' {
            my $action = $m.confirm[1];
            $m.mode = 'nav';
            $m.confirm = Nil;
            if $k.name eq 'char' && $k.text eq 'y' | 'Y' { do-action($m, $action) } else { $m.tell('cancelled; nothing was sent') }
        }
        when 'palette' {
            given $k.name {
                when 'up'    { $m.pal = ($m.pal - 1) % $m.palette.elems }
                when 'down' | 'tab' { $m.pal = ($m.pal + 1) % $m.palette.elems }
                when 'esc'   { $m.mode = 'nav' }
                when 'enter' { my $a = $m.palette[$m.pal]<key>; $m.mode = 'nav'; do-action($m, $a) }
            }
        }
        when 'find' {
            given $k.name {
                when 'esc'   { $m.mode = 'input'; $m.input = $m.draft; $m.cursor = $m.input.chars; $m.draft = ''; .hit = Int with $c }
                when 'enter' { find-next($m) }
                default      { edit(); .hit = Int with $c }
            }
        }
        when 'new-agent' {
            given $k.name {
                when 'esc'   { $m.mode = 'input'; $m.input = '' ; $m.cursor = 0 }
                when 'enter' {
                    if $m.input.trim eq '' { $m.tell('say which agent; 321 agents lists them'); return }
                    my ($who, $on) = $m.input.trim.split(/\s+ on \s+/, 2);
                    $m.new-harness = '';
                    with $on {
                        my ($name, $why) = check-harness(.trim);
                        with $why { $m.tell($why); return }
                        $m.new-harness = $name;
                    }
                    $m.new-agent = $who.trim; $m.input = ''; $m.cursor = 0; $m.mode = 'new-request';
                }
                default { edit() }
            }
        }
        when 'pick-harness' {
            given $k.name {
                when 'esc'   { $m.mode = 'nav'; $m.input = ''; $m.cursor = 0 }
                when 'enter' {
                    my ($name, $why) = check-harness($m.input.trim);
                    with $why { $m.tell($why); return }
                    return unless $c.defined;
                    $m.input = ''; $m.cursor = 0;
                    $m.pick-harness = $name;
                    $m.confirm = [restart-question($c.rd, :harness($name)), 'restart-now'];
                    $m.mode = 'confirm';
                }
                default { edit() }
            }
        }
        when 'new-request' {
            given $k.name {
                when 'esc'   { $m.mode = 'input'; $m.input = ''; $m.cursor = 0 }
                when 'enter' {
                    my ($agent, $req) = $m.new-agent, $m.input.trim;
                    return $m.tell('say what it should do') if $req eq '';
                    $m.mode = 'input'; $m.input = ''; $m.cursor = 0;
                    $m.tell("starting {$agent}…");
                    my ($rd, $err) = launch-run($agent, $req, :via('mission-control'), :harness($m.new-harness));
                    with $err { $m.tell("not started: $_") }
                    else { $m.filter = 'all'; $m.scan; $m.sel = $m.visible.first({ .id eq $rd.id }, :k) // 0; $m.tell("started {$agent} {$rd.short}; it keeps going when you leave") }
                }
                default { edit() }
            }
        }
        when 'nav' {
            given $k.name {
                when 'up' | 'left'    { move(-1) }
                when 'down' | 'right' | 'tab' { move(1) }
                when 'enter' | 'esc' { $m.mode = 'input' }
                when 'char' {
                    given $k.text {
                        when 'h' { do-action($m, 'hold') }
                        when 'r' { do-action($m, 'resume') }
                        when 's' { do-action($m, 'stop') }
                        when 'f' { do-action($m, 'force') if actions-for($m).first(*<key> eq 'force') }
                        when 'n' { do-action($m, 'new') }
                        when 'v' { cycle-filter($m) }
                        when 'q' { $m.quit = True }
                        when 'i' { $m.mode = 'input' }
                        when 'k' { move(-1) }
                        when 'j' { move(1) }
                    }
                }
            }
        }
        default {   # input
            given $k.name {
                when 'esc' { $m.mode = 'nav' }
                when 'tab' { move(1) }
                when 'shift-tab' { move(-1) }
                when 'up'   { if $c.defined { $c.scroll += 1 } }
                when 'down' { if $c.defined { $c.scroll = ($c.scroll - 1) max 0 } }
                when 'left' | 'right' {
                    if $m.input eq '' { move($k.name eq 'left' ?? -1 !! 1) } else { edit() }
                }
                when 'enter' {
                    my $text = $m.input.trim;
                    return if $text eq '';
                    return $m.tell('no run is selected; Ctrl-N starts one') unless $c.defined;
                    unless $c.phase eq 'running' | 'held' | 'starting' {
                        return $m.tell("{$c.name} {$c.short} has {$c.phase eq 'lost' ?? 'been lost' !! 'ended'}; Ctrl-N starts a new run");
                    }
                    my $id = try send-directive($c.rd, 'steer', :$text, :client('mission-control'));
                    if $! { $m.tell("not sent: {$!.message}"); return }
                    $c.sent{$id} = ['steer', now.Num, $text];
                    $m.input = ''; $m.cursor = 0;
                    $c.scroll = 0;
                    $m.tell(steer-note($c.harness));
                }
                default { edit() }
            }
        }
    }
}

# ------------------------------------------------------------ the loop

#| Open Mission Control.  Returns the exit code when the person leaves.
sub run-deck(Str :$focus = '' --> Int) is export {
    my $m = Model.new;
    $m.scan;
    if $focus ne '' { $m.sel = $m.visible.first({ .id eq $focus }, :k) // 0 }
    my $t = Terminal.new;
    my $restore = { $t.leave };
    $t.enter;
    LEAVE $t.leave;
    signal(SIGTERM, SIGHUP).tap({ $t.leave; exit 0 });
    my $keys = Channel.new;
    $t.key-reader($keys);
    my $resized = False;
    signal(SIGWINCH).tap({ $resized = True });
    my $dirty = True;
    my $last-draw = 0e0;
    my $last-tick = now.Num;
    until $m.quit {
        # keys first: input never waits for a draw
        while $keys.poll -> $k {
            my ($rows, $cols) = ($t.rows, $t.cols);
            handle-key($m, $k, :page(($rows - 12) max 5));
            $dirty = True;
            last if $m.quit;
        }
        last if $m.quit;
        if $resized { $resized = False; $t.size; $t.invalidate; $dirty = True }
        for $m.crew -> $c { $dirty = True if $c.refresh }
        if now.Num - $m.scanned > 1 { my $n = $m.crew.elems; $m.scan; $dirty = True if $m.crew.elems != $n }
        if now.Num - $last-tick >= 0.4 {
            $m.tick++;
            $last-tick = now.Num;
            $dirty = True if $m.crew.first(*.active) || True;
        }
        if $dirty && now.Num - $last-draw >= 1/30 {
            my ($rows, $cols) = ($t.rows, $t.cols);
            my $cv = render($m, $rows, $cols);
            my ($cr, $cc) = cursor-at($m, $rows, $cols);
            $t.draw($cv, :cursor-row($cr), :cursor-col($cc));
            $last-draw = now.Num;
            $dirty = False;
        }
        sleep 0.03;
    }
    $t.leave;
    my $live = $m.crew.grep(*.active).elems;
    say "{icon()} 321-mc: left Mission Control; " ~ ($live ?? "{many-of($live, 'run')} still going" !! 'nothing is running');
    say next-text('come back to them', '321-mc') if $live;
    0;
}
