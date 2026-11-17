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
use Do321::RunWords;
use Do321::TuiLog;
use Do321::Controller;
use Do321::Learn;

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
    given $f { when 'active' { 'active runs' }; when 'needs' { 'runs that need you' }; default { 'every run' } }
}

class Crew is export {
    has RunDir $.rd;
    has EventTail $.tail;
    has RunState $.state = RunState.new;
    has %.run;
    has %.live is rw;
    has Num $.checked is rw = 0e0;
    has Int $.scroll-max is rw = 0;   # how far up the conversation goes, as last drawn
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
    #| The style the agent's name wears: its own accent, as 123 shows the
    #| same agent, else the amber 123 falls back to.
    method accent(--> Str) { my $c = (%!run<agent><color> // '').Str; $c ~~ / ^ '#' <xdigit> ** 6 $ / ?? $c !! 'wait' }
    #| The harness the run is on: the one the runtime chose, else the one asked for.
    method harness(--> Str) { $!state.harness || ((%!run<harness> // {})<requested> // '') }
    #| The harness by its name, so 'Claude Code' is never read as the model.
    method tag(--> Str) { self.harness ne '' ?? harness-name(self.harness) !! '' }
    method request(--> Str) { (%!run<request> // '').subst(/\s+/, ' ', :g) }
    #| Where the work came from, when something other than this machine
    #| issued it: the issuer and the references it gave, in its own words
    #| ('api.123.do: track nige.123.do, step 200').  '' for a run started
    #| here; nothing is said that the package did not carry.
    method origin(--> Str) {
        my %i = %!run<issuer> ~~ Associative ?? %!run<issuer>.Hash !! {};
        return '' if (%i<kind> // 'local') eq 'local' || (%i<id> // '') eq '';
        my @refs = @(%!run<refs> // []).grep(Associative).grep({ (.<kind> // '') ne '' && (.<id> // '') ne '' })
            .map({ "{.<kind>} {.<id>}" });
        %i<id> ~ (@refs ?? ': ' ~ @refs.join(', ') !! '');
    }
    method phase(--> Str) { $!state.phase eq 'ended' ?? 'ended' !! %!live<phase> // $!state.phase }
    method outcome(--> Str) { $!state.outcome ne '' ?? $!state.outcome !! (%!live<outcome> // '') }
    method active(--> Bool) { so self.phase eq 'starting' | 'queued' | 'running' | 'held' | 'stopping' }
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

#| A run's zone on its agent's trackline.  Now is everything in hand:
#| at work, held, starting, stopping, and a run that ended waiting on a
#| person, which is the person's move until it is answered.
sub track-zone($c, Bool :$answered = False --> Str) is export {
    given $c.phase {
        when 'queued' { 'next' }
        when 'starting' | 'running' | 'held' | 'stopping' { 'now' }
        when 'ended' { $c.outcome eq 'blocked' && !$answered ?? 'now' !! 'done' }
        default { 'done' }
    }
}

class Model is export {
    has IO::Path $.home = home-dir();
    has @.crew;
    has Int $.sel is rw = 0;
    has Str $.mode is rw = 'input';      # input | nav | confirm | find
    has Str $.input is rw = '';
    has Int $.cursor is rw = 0;
    has Str $.flash is rw = '';
    has Num $.flash-at is rw = 0e0;
    has Int $.tick is rw = 0;
    has $.confirm is rw;                  # [question, action]
    has Str $.pick-harness is rw = '';
    has $.log is rw;                      # a TuiLog, when there is a terminal
    has Bool $.quit is rw = False;
    has Num $.scanned is rw = 0e0;
    has Str $.filter is rw = 'all';       # all | active | needs
    has Str $.draft is rw = '';           # the input line, kept while finding
    has Bool $.want-editor is rw = False; # Ctrl-G asked for the draft in $EDITOR
    has Bool $.evidence is rw = False;    # on tracklines: the run's evidence beside its conversation, when asked for
    has Bool $.zoom is rw = False;        # on tracklines: the cursor's job alone, its conversation the rest
    has Str $.layout is rw = 'table';     # table | lines: a row a run, or a trackline an agent

    #| Where a draft waits while an editor has it: the person's alone.
    method draft-file(--> IO::Path) { private-dir($!home.add('tmp')).add("draft-{$*PID}.md") }

    #| The runs the deck shows, under the filter.
    method visible(--> List) {
        given $!filter {
            when 'active' { self.ordered(@!crew.grep(*.active)) }
            when 'needs'  { self.ordered(@!crew.grep({ needs-you($_) })) }
            default       { self.ordered(@!crew) }
        }
    }
    #| The runs in the order the screen walks them: as the table lists
    #| them, or, on tracklines, agent by agent and oldest first along
    #| each line, so the arrows move through time and the lines hold still.
    method ordered(@runs --> List) {
        return @runs.List unless $!layout eq 'lines';
        my %z = self.zones;
        my %rank = done => 0, now => 1, next => 2;
        @runs.sort({ $^a.name cmp $^b.name || %rank{%z{$^a.id}} <=> %rank{%z{$^b.id}} || $^a.id cmp $^b.id }).List;
    }
    #| Where each run sits on its agent's trackline: done, now or next.  A
    #| run that waits on a person is still now, until another run goes on
    #| from it: then it has been answered, and is done.
    method zones(--> Hash) {
        my %answered = @!crew.map({ |(((.run<continues> // {})<runId> // '') => True, ((.run<follows> // {})<runId> // '') => True) });
        %( @!crew.map({ .id => track-zone($_, :answered(%answered{.id}.so)) }) );
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

    method tell(Str $s) {
        # the home directory is said the short way, so the advice fits the line
        my $home = $*HOME.Str;
        $!flash = $home.chars > 1 ?? $s.subst($home, '~', :g) !! $s;
        $!flash-at = now.Num;
        .note("said: $s") with $!log;
    }
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

#| Whether marks may move.  DO_321_MOTION=0 keeps every mark still: the
#| words carry the state alone, as they must for a reader who cannot or
#| would rather not follow a blink.
sub motion(--> Bool) is export { (%*ENV<DO_321_MOTION> // '1') ne '0' }

#| A run's state as a mark, a word and a tone: the deck's STATE column.
#| The marks are the family's: ◉ is a run at work, as 123 marks what is
#| being done now, and it blinks to ◌ once in four ticks while events
#| arrive; the beat stops when they have not for BEAT-QUIET seconds.  A
#| tick is done, a question waits on a person, a cross did not happen.
sub crew-line(Crew $c, Int $tick, Bool :$narrow = False --> List) is export {
    my $s = $c.state;
    my $quiet = $s.last-at ne '' ?? (now - ((try DateTime.new($s.last-at).Instant) // now)) !! 0;
    my $ctl = control-note($c);
    given $c.phase {
        when 'starting' { return ('·', 'starting', 'dim') }
        # waiting its turn: nothing has run, and the word says behind whom
        when 'queued'   { return ('▫', ($s.activity.starts-with('queued') ?? $s.activity !! 'queued') ~ ($ctl ne '' ?? " · $ctl" !! ''), 'dim') }
        when 'running' {
            my $beat = motion() && $quiet < BEAT-QUIET && $tick % 4 == 0;
            # a host whose heartbeat stopped is said so; liveness still decides lost
            my $hb = $c.heartbeat-age;
            return ('◌', "no heartbeat for {$hb}s", 'wait') if $hb > HEARTBEAT-STALE && ($c.live<phase> // '') eq 'running';
            my $word = $quiet > QUIET-WARN ?? "quiet for {ago($s.last-at)}" !! $s.activity;
            $word ~= " · $ctl" if $ctl ne '';
            return ($beat ?? '◌' !! '◉', $word, $ctl.contains('unconfirmed') || $quiet > QUIET-WARN ?? 'wait' !! 'now');
        }
        when 'held'     { return ('‖', 'held' ~ ($ctl ne '' ?? " · $ctl" !! ''), 'wait') }
        when 'stopping' { return ('◉', 'stopping' ~ (motion() ?? '·' x (1 + $tick % 3) !! ''), 'wait') }
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
    my $lines = !$strip && $m.layout eq 'lines';
    my $rail = !$strip && !$lines && $cols >= 150;
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
    my $empty = @all ?? "No {filter-word($m.filter)} right now.  /view all shows every run."
                     !! 'No runs yet.  /start <agent> <request...> begins one; it keeps going when you close this screen.';
    my $row = 0;
    # a large screen has a panel at the right: the key to the shapes, and
    # the keys that act on the job under the cursor.  The work keeps the
    # rest, and is drawn as if the screen ended where the panel begins.
    my $pw = $lines && $cols >= PANEL-FROM && $rows >= 30 ?? PANEL-WIDTH !! 0;
    my $w = $cols - ($pw ?? $pw + 1 !! 0);

    if $strip {
        # one line for the crew; the selected run's conversation takes the rest
        my $c = $cv.put(0, 0, "{icon()} 321 ", 'brand');
        for @crew.kv -> $i, $cr {
            my ($mark, $, $tone) = crew-line($cr, $m.tick, :narrow);
            my $label = "{$cr.short} {$cr.name}{$i != $m.sel && $cr.unread ?? '+' ~ $cr.unread !! ''} ";
            if $c + text-width($label) + 2 > $cols - 4 { $cv.put(0, $c, "+{@crew - $i}", 'dim'); last }
            my $st = ($i == $m.sel ?? 'sel+bold+' !! 'bold+') ~ $cr.accent;
            $c = $cv.put(0, $c, ($i == $m.sel ?? '▸' !! ' ') ~ $label, $st);
            $c = $cv.put(0, $c, $mark, $tone);
            $c = $cv.put(0, $c, ' ');
        }
        $cv.put(1, 0, '─' x $cols, 'rule');
        $row = 2;
        my $sc = $m.selected;
        if $sc.defined {
            my $right = "{met($sc)} · {ago($sc.state.last-at)}";
            my $nc = $cv.put($row, 1, $sc.name, 'bold+' ~ $sc.accent);
            $cv.put($row, $nc, " {$sc.short}{$sc.tag ne '' ?? ' · ' ~ $sc.tag !! ''}{$sc.origin ne '' ?? ' · from ' ~ $sc.origin !! ''} · {$sc.request}", 'bold', :max($cols - $nc - text-width($right) - 2));
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
        $cv.put(1, 0, '─' x $cols, 'rule');
        $row = 2;
        if $lines { $row = draw-tracks($cv, $m, @crew, $row, $rows, $w, $empty, :panel(?$pw)) }
        elsif !$rail { $row = draw-deck($cv, $m, @crew, $row, $rows, $cols, $empty) }
    }

    # --- the conversation, above the input line and the footer
    # the rule, the input area (it grows with what is typed), the footer
    my %area = input-area($m, $rows, $cols);
    my $ih = %area<height>;
    my $foot = $rows - 2 - $ih;
    my $sc = $m.selected;
    if $rail {
        my $rw = 30;
        my $ew = 40;
        my $mid = $rw + 2;
        my $mw = $cols - $ew - 1 - $mid - 1;
        for $row ..^ $foot -> $r { $cv.put($r, $rw, '│', 'rule'); $cv.put($r, $cols - $ew - 1, '│', 'rule') }
        draw-rail($cv, $m, @crew, $row, $foot, $rw, $empty);
        if $sc.defined {
            my $c = $cv.put($row, $mid, $sc.display, 'bold+' ~ $sc.accent, :max($mw));
            $c = $cv.put($row, $c, ", {$sc.byline}", '', :max($mid + $mw - $c)) if $sc.byline ne '';
            $cv.put($row, $c, "  on {harness-name($sc.harness)}", 'dim', :max($mid + $mw - $c)) if $sc.harness ne '';
            draw-comms($cv, $sc, $row + 1, $foot, $mid, $mw);
            draw-evidence($cv, $sc, $row, $foot, $cols - $ew + 1, $ew - 1);
        }
        else { $cv.put($row + 1, $mid, $empty, 'dim', :max($mw)) }
    }
    elsif $lines && $m.evidence && $sc.defined && $w >= 100 && $foot - $row > 0 {
        # the evidence, when a person asks to look: beside what the run says
        my $ew = 40;
        for $row ..^ $foot -> $r { $cv.put($r, $w - $ew - 1, '│', 'rule') }
        draw-comms($cv, $sc, $row, $foot, 0, $w - $ew - 2);
        draw-evidence($cv, $sc, $row, $foot, $w - $ew + 1, $ew - 1);
    }
    elsif $sc.defined && $foot - $row > 0 {
        draw-comms($cv, $sc, $row, $foot, 0, $w - 1, :narrow($cols < 80));
    }
    elsif !$sc.defined && $foot - $row > 2 && $strip {
        $cv.put($row + 1, 1, @all ?? $empty !! 'No runs yet.  /start begins one.', 'dim');
    }
    draw-panel($cv, $m, 2, $foot, $w, $pw) if $pw;

    # --- the input line and the footer
    $cv.put($foot, 0, '─' x $cols, 'rule');
    my ($prompt, $hint) = prompt-and-hint($m, $cols);
    if $m.mode eq 'confirm' && text-width($prompt) > $cols - 2 {
        # a long question begins on the rule above the input line and ends
        # on it, so the end, which asks, is never cut
        my ($first, $rest) = split-at-width($prompt, $cols - 2);
        $cv.put($foot, 0, ' ' x $cols);
        $cv.put($foot, 1, $first, 'bold');
        $prompt = $rest;
    }
    # the arrow before the cursor is where the person is: the focus blue
    my $pc = $prompt.ends-with('❯')
        ?? $cv.put($foot + 1, $cv.put($foot + 1, 1, $prompt.chop, 'bold'), '❯', 'now')
        !! $cv.put($foot + 1, 1, $prompt, 'bold');
    for %area<lines>.kv -> $i, $line { $cv.put($foot + 1 + $i, %area<left>, $line) }
    # an empty prompt says what it is for
    if $m.layout eq 'lines' && $sc.defined && $m.input eq '' && $m.mode eq 'input' | 'nav' && !$strip {
        $cv.put($foot + 1, %area<left>, $m.mode eq 'nav' ?? "↓ to say something to {$sc.display}" !! "say something to {$sc.display}, or / for a word", 'dim');
    }
    # rows scrolled out of the area are counted, never silently hidden
    $cv.put($foot, $cols - 14, " +{%area<above>} above ", 'dim') if %area<above> && $cols > 30;
    # a flash never hides what a question needs to say
    my $flash = (now.Num - $m.flash-at < 6 && $m.mode eq 'input' | 'nav' | 'find') ?? $m.flash !! '';
    if $flash ne '' && text-width($flash) > $cols - 2 {
        # too long for one row: it begins on the rule above the input line
        # and ends below it, so the end, which says what to do, is never cut
        my ($first, $rest) = split-at-width($flash, $cols - 2);
        $cv.put($foot, 0, ' ' x $cols);
        $cv.put($foot, 1, $first, 'wait');
        $flash = $rest;
    }
    $cv.put($foot + 1 + $ih, 1, $flash ne '' ?? $flash !! $hint, $flash ne '' ?? 'wait' !! 'dim');
    $cv;
}

#| A run as a square on its agent's trackline.  Squares, because these
#| are bots: 123 draws a person's steps as dots.  Each state has a mark
#| of its own, so the line reads without colour: ■ done, ▪ no change,
#| ⊟ stopped, ◧ waits on you, ⊠ did not happen, ▣ at work now (it
#| throbs to ▢ and back for as long as it is worked on), ◫ held, □ next.  Returns the mark,
#| its tone and its zone: done, now or next.
sub track-mark(Crew $c, Int $tick, Bool :$answered = False --> List) is export {
    my $zone = track-zone($c, :$answered);
    # the shape says the state; the colour says where on the track it
    # is: green for done, blue for now, orange for next.  One exception:
    # what did not happen is red, so it is never read as done.
    my $tone = %( done => 'ok', now => 'now', next => 'wait' ){$zone};
    my $mark = do given $c.phase {
        when 'queued'   { '□' }
        when 'starting' { '▣' }
        when 'held'     { '◫' }
        when 'stopping' { '▣' }
        # a job being worked on throbs, an even pulse, for as long as
        # its host's heartbeat says it is there; a stale one holds still
        when 'running'  { motion() && $c.heartbeat-age <= HEARTBEAT-STALE && $tick % 2 == 1 ?? '▢' !! '▣' }
        when 'lost'     { $tone = 'bad'; '⊠' }
        default {
            given $c.outcome {
                when 'done'      { '■' }
                when 'no_change' { '▪' }
                when 'stopped'   { '⊟' }
                when 'blocked'   { '◧' }
                default          { $tone = 'bad'; '⊠' }
            }
        }
    };
    ($mark, $tone, $zone);
}

constant TRACK-LEGEND is export = '■ done  ▪ no change  ⊟ stopped  ⊠ did not happen  ◧ waits on you  ▣ working  ◫ held  □ next';

#| The tracklines: a row an agent, time running left to right.  What
#| it has done leads up to NOW; everything it has in hand stands side
#| by side between two blue bars, which line up down the screen as one
#| band, so what is happening now is a column the eye runs down; what
#| waits its turn follows.  Marks only: what a job is, is said for the
#| one under the cursor, in the detail beneath.  The cursor is 321's
#| own mark closed on a job.  Never more than two fifths of the screen;
#| rows past that are counted, above and below.  Returns the next free row.
sub draw-tracks(Canvas $cv, Model $m, @crew, Int $top, Int $rows, Int $cols, Str $empty, Bool :$panel = False --> Int) {
    my $row = $top;
    my $sc = $m.selected;
    my %zone = $m.zones;
    my @names = @crew.map(*.name).unique;
    my %of = @names.map(-> $n { $n => %( done => [], now => [], next => [] ) });
    %of{.name}{%zone{.id}}.push($_) for @crew;
    my $nw = (@names.map(*.chars).max // 4) max 4;
    my $left = 2 + $nw + 2;
    # room between the marks, so each reads as a thing of its own
    my $step = $cols >= 100 ?? 4 !! 3;
    # the band is as wide as the busiest agent needs, the same on every row
    my $most = (@names.map({ %of{$_}<now>.elems }).max // 0) max 1;
    my $cap = ((($cols - $left) div (2 * $step)) max 2) min 12;
    my $slots = $most min $cap;
    my $band-w = $step * $slots + ($step - 2) + ($most > $cap ?? 3 !! 0);
    # a short memory: the last few things done, the rest counted.  The
    # lines sit at the left and leave the rest of the row empty.
    my $done-w = ((($cols - $left - $band-w - 2) div 3) max (3 * $step + 5)) min (8 * $step + 5);
    my $bar = $left + $done-w;                 # the left bar
    my $bar2 = $bar + $band-w + 1;             # the right bar
    $cv.put($row, 2, 'CREW', 'dim');
    $cv.put($row, $bar - 5, 'DONE', 'ok');
    # NOW sits over the middle of the band
    $cv.put($row, $bar + 1 + (($band-w - 3) div 2 max 0), fit('NOW', $band-w), 'now');
    $cv.put($row, $bar2 + $step - 1, 'NEXT', 'wait');
    # the key to the shapes: beside the headings where the screen is wide,
    # else on a row of its own where it is tall
    my $key-at = $cols - 1 - text-width(TRACK-LEGEND);
    my $key-beside = !$panel && $key-at > $bar2 + 6 * $step + 8;
    $cv.put($row, $key-at, TRACK-LEGEND, 'dim') if $key-beside;
    $row++;
    my $at = $sc.defined ?? (@names.first({ $_ eq $sc.name }, :k) // 0) !! 0;
    my $max = ((($rows * 2) div 5) - 4) max 3;
    my $fits = @names <= $max ?? @names.elems !! $max - 1;
    my $first = @names <= $max ?? 0 !! ((($at - $fits + 1) max 0) min (@names - $fits));
    # zoomed in: the cursor's row alone; the conversation has the rest
    my $zoom = $m.zoom && $sc.defined && @names.elems > 0;
    if $zoom { $first = $at; $fits = 1 }
    # the cursor is 321's own mark closing on a job: ❮▣❯.  The square
    # keeps its state's colour; the brackets wear the focus blue.
    my sub square(Int $col, Crew $c) {
        my ($mark, $tone) = track-mark($c, $m.tick, :answered(%zone{$c.id} eq 'done'));
        my $on = $sc.defined && $c.id eq $sc.id;
        $cv.put($row, $col, $mark, $on ?? "bold+$tone" !! $tone);
        # bold while the arrows are on the lines; plain while the person
        # is at the prompt, where it still says who the words go to
        my $br = $m.mode eq 'nav' ?? 'bold+now' !! 'now';
        if $on { $cv.put($row, $col - 1, '❮', $br); $cv.put($row, $col + 1, '❯', $br) }
    }
    # as many as fit, around the cursor's own, which is always on the line
    my sub window(@all, Int $fit, Bool :$newest --> List) {
        return @all.List if @all <= $fit;
        my $k = $sc.defined ?? @all.first({ .id eq $sc.id }, :k) !! Int;
        my $from = $newest ?? @all - $fit !! 0;
        with $k { $from = $k if $k < $from; $from = $k - $fit + 1 if $k >= $from + $fit }
        @all[$from ..^ ($from + $fit)].List;
    }
    for @names[$first ..^ ($first + $fits)] -> $name {
        my %z = %of{$name};
        $cv.put($row, 2, pad($name, $nw), ($sc.defined && $sc.name eq $name ?? 'bold+' !! '') ~ (@crew.first({ .name eq $name }).accent));
        # done: the newest nearest now, the rest counted
        my @shown = window(%z<done>, ($done-w - 5) div $step, :newest);
        my $col = $bar - $step * @shown.elems;
        $cv.put($row, $col - $step - "+{%z<done> - @shown}".chars, "+{%z<done> - @shown}", 'dim') if %z<done> > @shown;
        for @shown -> $d { square($col, $d); $col += $step }
        # now: side by side between the bars; a still point when there is none
        $cv.put($row, $bar, '│', 'now');
        $cv.put($row, $bar2, '│', 'now');
        my @now = window(%z<now>, $slots);
        $col = $bar + $step - 1;
        for @now -> $n { square($col, $n); $col += $step }
        $cv.put($row, $bar + $step - 1, '·', 'dim') unless @now;
        $cv.put($row, $col, "+{%z<now> - @now}", 'dim') if %z<now> > @now;
        # next: what waits its turn, oldest first, the rest counted
        my @q = window(%z<next>, ((($cols - $bar2 - 7) div $step) max 1));
        $col = $bar2 + $step - 1;
        for @q -> $n { square($col, $n); $col += $step }
        $cv.put($row, $col, "+{%z<next> - @q}", 'dim') if %z<next> > @q;
        $row++;
    }
    if @names > $fits && !$zoom {
        my ($above, $below) = $first, @names - $first - $fits;
        $cv.put($row++, 2, ($above ?? "↑ $above above" !! '') ~ ($above && $below ?? '   ' !! '') ~ ($below ?? "↓ $below below" !! ''), 'dim');
    }
    unless @crew { $cv.put($row, 2, $_, 'dim', :max($cols - 3)) for wrap($empty, $cols - 3)[0]; $row++ }
    if !$panel && !$key-beside && !$zoom && $rows >= 30 && $key-at >= 2 { $cv.put($row++, 2, TRACK-LEGEND, 'dim') }
    $cv.put($row, 0, '─' x $cols, 'rule');
    $row++;
    if $sc.defined {
        # the job under the cursor: what it is, then how it stands
        my ($mark, $tone) = track-mark($sc, $m.tick, :answered(%zone{$sc.id} eq 'done'));
        # its mark, without the cursor: the cursor is in one place only
        my $c = $cv.put($row, 1, "$mark ", $tone);
        $c = $cv.put($row, $c, $sc.display, 'bold+' ~ $sc.accent);
        $c = $cv.put($row, $c, " {$sc.short}  ", 'bold');
        # what can be done to it, by its own state: keys while the arrows
        # are on the lines, the same things as words at the prompt
        my %say = $m.mode eq 'nav'
            ?? (hold => 'h hold', resume => 'r resume', go => 'r go now', stop => 's stop', restart => 'a again', force => 'f force stop')
            !! (hold => '/hold', resume => '/resume', go => '/resume', stop => '/stop', restart => '/restart');
        my $do = actions-for($m).map({ %say{.<key>} // Empty }).join('   ');
        $do = '' if $panel || $cols - $c < text-width($do) + 24;
        $cv.put($row, $c, fit($sc.request, $cols - $c - 1 - ($do ne '' ?? text-width($do) + 3 !! 0)), 'bold');
        $cv.put($row, $cols - 1 - text-width($do), $do, $m.mode eq 'nav' ?? 'now' !! 'dim') if $do ne '';
        $row++;
        # what a person wants at a glance: how it stands, the time it has
        # taken, what it has cost, and the harness it is on.  These are
        # kept whole; the status takes the room that is left.
        my ($, $word, $wt) = crew-line($sc, $m.tick, :narrow($cols < 110));
        my $time = met($sc);
        my $rest = ($time ne '' ?? " · $time" !! '')
            ~ ($sc.state.cost-reported ?? " · {$sc.state.cost-text}" !! '')
            ~ ($sc.harness ne '' ?? " · on {harness-name($sc.harness)}" !! '')
            ~ ($sc.state.model ne '' && $cols >= 110 ?? ", {$sc.state.model}" !! '');
        my $from = $sc.origin ne '' ?? " · from {$sc.origin}" !! '';
        $c = $cv.put($row, 3, fit($word, ($cols - 4 - text-width($rest)) max 12), $wt eq 'ok' | 'now' ?? '' !! $wt);
        $c = $cv.put($row, $c, fit($rest, $cols - $c - 1));
        $cv.put($row, $c, fit($from, $cols - $c - 1), 'dim') if $cols - $c > 12;
        $row++;
    }
    $row;
}

constant PANEL-FROM is export = 140;
constant PANEL-WIDTH is export = 26;

#| The panel at the right of a large screen: the key to the shapes, with
#| the cursor's own picked out; what can be done to the job under the
#| cursor, by its state; and how to move.  Keys while the arrows are on
#| the lines, the same things as words at the prompt.
sub draw-panel(Canvas $cv, Model $m, Int $top, Int $bottom, Int $at, Int $width) {
    for $top ..^ $bottom -> $r { $cv.put($r, $at, '│', 'rule') }
    my $left = $at + 2;
    my $max = $width - 2;
    my $row = $top;
    my $sc = $m.selected;
    my $nav = $m.mode eq 'nav';
    my sub head(Str $t) { $cv.put($row++, $left, $t, 'dim') if $row < $bottom }
    # a section's words begin in one column, past its widest key
    my sub lines(@pairs, Str $ks, Str $ts, :&on) {
        my $in = @pairs.map(*[0].chars).max + 2;
        for @pairs -> ($k, $t) {
            last if $row >= $bottom;
            my $lit = &on.defined && on($k);
            $cv.put($row, $left, $k, $lit ?? 'bold' !! $ks);
            $cv.put($row++, $left + $in, fit($t, $max - $in), $lit ?? '' !! $ts);
        }
    }
    my $mine = $sc.defined ?? track-mark($sc, 0, :answered($m.zones{$sc.id} eq 'done'))[0] !! '';
    head('SHAPES');
    lines(TRACK-LEGEND.split('  ').map({ .split(' ', 2).List }).List, 'dim', 'dim', :on({ $_ eq $mine }));
    $row++;
    if $sc.defined {
        my %say = $nav
            ?? (hold => ('h', 'hold'), resume => ('r', 'resume'), go => ('r', 'go now'), stop => ('s', 'stop'), restart => ('a', 'again'), force => ('f', 'force stop'))
            !! (hold => ('/hold', ''), resume => ('/resume', ''), go => ('/resume', 'go now'), stop => ('/stop', ''), restart => ('/restart', ''));
        my @do = actions-for($m).map({ %say{.<key>} // Empty });
        if @do {
            head('THIS JOB');
            lines(@do, 'now', '');
            $row++;
        }
    }
    head('MOVE');
    my @move = $nav
        ?? $m.zoom ?? (('←→', 'its other jobs'), ('↓', 'say something'), ('Esc', 'every line'))
                   !! (('←→', 'another job'), ('↑↓', 'another agent'), ('↓', 'say something'), ('Enter', 'zoom in'), ('e', 'evidence'), ('t', 'table'))
        !! (('↑', 'the lines'), ('←→', 'another job'), ('Enter', 'send'));
    lines(@move, '', 'dim');
}

#| The deck: a table of runs, never more than a third of the screen, then
#| who the selected run is.  Returns the next free row.
sub draw-deck(Canvas $cv, Model $m, @crew, Int $top, Int $rows, Int $cols, Str $empty --> Int) {
    my $row = $top;
    my $deck-max = (($rows div 3) - 1) max 3;
    my $wide = $cols >= 110;
    # run, crew, harness, mission, state, met, last, tools, cost
    my @w = $wide ?? (6, 8, 13, 0, 30, 9, 6, 6, 9) !! (5, 7, 0, 0, 18, 6, 5, 0, 0);
    my $spare = $cols - 2 - @w.sum - 1;
    # the mission gets up to 44 columns; anything more goes to the state
    @w[3] = $spare min 44;
    @w[4] += $spare - @w[3];
    if $wide {
        $cv.put($row, 2, pad('RUN', @w[0]) ~ pad('CREW', @w[1]) ~ pad('HARNESS', @w[2]) ~ pad('MISSION', @w[3]) ~ pad('STATE', @w[4]) ~
            pad('MET', @w[5]) ~ pad('LAST', @w[6]) ~ pad('TOOLS', @w[7]) ~ 'COST', 'dim');
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
        my $c = $cv.put($row, 0, $sel ?? '▸ ' !! '  ', $sel ?? 'bold' !! '');
        $c = $cv.put($row, $c, pad($cr.short, @w[0]), $sel ?? 'bold' !! '');
        # the agent first; the harness it runs on beside it, quieter
        $c = $cv.put($row, $c, pad($cr.name, @w[1] - 1) ~ ' ', ($sel ?? 'bold+' !! '') ~ $cr.accent);
        if $wide {
            $cv.put($row, $c, fit($cr.tag, @w[2] - 1), 'dim');
            $c += @w[2];
        }
        $c = $cv.put($row, $c, pad($cr.request, @w[3] - 1) ~ ' ', $sel ?? 'bold' !! '');
        my $sc = $cv.put($row, $c, $mark ~ ' ', $tone);
        $cv.put($row, $sc, fit($word, @w[4] - 3), $tone eq 'ok' | 'now' ?? '' !! $tone);
        $c += @w[4];
        $c = $cv.put($row, $c, pad(met($cr), @w[5]), 'dim');
        $c = $cv.put($row, $c, pad(ago($cr.state.last-at), @w[6]), 'dim');
        if $wide {
            $c = $cv.put($row, $c, pad($cr.state.tools.Str, @w[7]), 'dim');
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
    $cv.put($row, 0, '─' x $cols, 'rule');
    $row++;
    my $sc = $m.selected;
    if $sc.defined {
        my $c = $cv.put($row, 1, $sc.display, 'bold+' ~ $sc.accent);
        $c = $cv.put($row, $c, ", {$sc.byline}") if $sc.byline ne '';
        my $right = "{$sc.short}{$sc.harness ne '' ?? ' · on ' ~ harness-name($sc.harness) !! ''} · {$sc.state.attempts > 1 ?? "attempt {$sc.state.attempts} · " !! ''}{$sc.origin ne '' ?? "from {$sc.origin} · " !! ''}{($sc.run<workspace> // '') || 'no workspace'}";
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
        my $c = $cv.put($r, 0, $sel ?? '▸ ' !! '  ', $sel ?? 'bold' !! '');
        $c = $cv.put($r, $c, "{$cr.short} ", $sel ?? 'bold' !! '');
        $c = $cv.put($r, $c, pad($cr.name, 7), ($sel ?? 'bold+' !! '') ~ $cr.accent);
        $c = $cv.put($r, $c, $mark ~ ' ', $tone);
        $cv.put($r, $c, fit($word, $w - $c - 1), $tone eq 'ok' | 'now' ?? 'dim' !! $tone);
        $cv.put($r + 1, 6, fit(($cr.tag ne '' ?? "{$cr.tag} · " !! '') ~ ($cr.origin ne '' ?? "from {$cr.origin} · " !! '') ~ $cr.request, $w - 7), 'dim');
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
    @r.push(['ran on', $s.ran-on ~ ($s.profile ne '' ?? " ({$s.profile})" !! ''), '']) if $s.ran-on ne '';
    @r.push(['attempts', $s.attempts.Str, '']);
    @r.push(['tools', many-of($s.tools, 'call'), '']);
    @r.push(['cost', $s.cost-reported ?? "{$s.cost-text}, as the harness reported it" !! 'none reported yet', '']);
    @r.push(['tokens', $s.tokens-text ne '' ?? $s.tokens-text !! 'not reported', $s.tokens-text ne '' ?? '' !! 'dim']);
    # what the run was started knowing, and what has been said of it since
    my %ap = runs-applied($c.rd.dir.parent.parent){$c.id} // {};
    @r.push(['context', %ap<context>, '']) if (%ap<context> // '') ne '';
    @r.push(['lessons', @(%ap<lessons>).join(', ') ~ ', given as advice', '']) if @(%ap<lessons> // []);
    if $c.phase eq 'ended' {
        my %oc = run-outcomes($c.rd.dir.parent.parent){$c.id} // {};
        @r.push(['outcome', (%oc<outcome> // '') ne '' ?? "{%oc<outcome>}, said by {%oc<by> // '?'}" !! 'not yet said: 321 outcome ' ~ $c.short ~ ' accepted', (%oc<outcome> // '') ne '' ?? '' !! 'dim']);
    }
    @r.push(['host', %h<pid> ?? "pid {%h<pid>}" ~ ($hb >= 0 ?? ", heartbeat {$hb}s ago" !! '') !! 'not started yet',
             $hb > HEARTBEAT-STALE && $c.active ?? 'wait' !! '']);
    my $u = $c.status<usage>;
    if $u ~~ Associative && $c.active {
        my $n = ($u<processes> // 0).Int;
        @r.push(['below it', "$n process{$n == 1 ?? '' !! 'es'}", '']);
        @r.push(['cpu, mem', sprintf('%.1fs, %d MB', ($u<cpuSeconds> // 0).Num, (($u<rssBytes> // 0) / 1_048_576).Int), '']);
    }
    @r.push(['workspace', ($c.run<workspace> // '') || 'none', '']);
    # where the work came from: the issuer's own references, or this machine
    @r.push(['from', $c.origin ne '' ?? $c.origin !! 'started here' ~ ((($c.run<launchedBy> // {})<via> // '') eq 'mission-control' ?? ', in Mission Control' !! ''), '']);
    # iz4's last word on that workspace, in its own words, as the status line shows it
    with iz4-last-line(($c.run<workspace> // '') ~~ Str ?? ($c.run<workspace> // '') !! '') -> $iz4 {
        @r.push(['iz4', $iz4.subst(/^ \S+ ' IZ4: '/, ''), $iz4.starts-with('◈') ?? 'ok' !! $iz4.starts-with('✗') ?? 'bad' !! 'wait']) if $iz4 ne '';
    }
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
    $sc.scroll-max = ($total - $rows) max 0;
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

#| The most rows the input area takes: it grows with what is typed, up
#| to eight rows or a third of the screen, then scrolls with the cursor.
sub input-max(Int $rows --> Int) is export { (($rows div 3) min 8) max 1 }

#| What is typed, laid out in rows $w wide: broken where a row is full
#| and where the person broke it (Alt-Enter).  Returns the rows shown
#| (at most $max, the ones around the cursor), and the cursor's row and
#| column among them.
sub input-layout(Str $text, Int $cursor, Int $w, Int $max --> Hash) is export {
    my $width = $w max 1;
    my @lines = '';
    my $col = 0;
    my ($cr, $cc) = (0, 0);
    my $i = 0;
    for $text.comb -> $ch {
        if $i == $cursor { ($cr, $cc) = (@lines.end, $col) }
        $i++;
        if $ch eq "\n" { @lines.push(''); $col = 0; next }
        my $cw = text-width($ch);
        if $col + $cw > $width { @lines.push(''); $col = 0 }
        @lines[*-1] ~= $ch;
        $col += $cw;
    }
    if $cursor >= $i { ($cr, $cc) = (@lines.end, $col) }
    # a cursor past a full row waits at the start of the next
    if $cc >= $width && $cr == @lines.end { @lines.push(''); $cr++; $cc = 0 }
    my $top = @lines > $max ?? (($cr - $max + 1) max 0) min (@lines - $max) !! 0;
    %( lines => @lines[$top ..^ (($top + $max) min @lines.elems)].List, row => $cr - $top, col => $cc, above => $top, total => @lines.elems );
}

#| The input area for this frame: its width, its rows and the cursor.
sub input-area(Model $m, Int $rows, Int $cols --> Hash) is export {
    my ($prompt) = prompt-and-hint($m, $cols);
    my $pc = 1 + text-width($prompt) + 1;
    my $t = $m.mode eq 'input' | 'find' ?? $m.input !! '';
    my %l = input-layout($t, $m.cursor, $cols - $pc - 1, $m.mode eq 'input' ?? input-max($rows) !! 1);
    %( |%l, left => $pc, height => %l<lines>.elems );
}

#| Where the cursor goes: in the typed text, on whichever row it is.
sub cursor-at(Model $m, Int $rows, Int $cols --> List) is export {
    return (-1, 0) unless $m.mode eq 'input' | 'find';
    my %a = input-area($m, $rows, $cols);
    ($rows - 1 - %a<height> + %a<row>, (%a<left> + %a<col>) min ($cols - 1));
}

sub prompt-and-hint(Model $m, Int $cols --> List) {
    my $sc = $m.selected;
    my $narrow = $cols < 100;
    given $m.mode {
        when 'confirm' { return ($m.confirm[0], 'y yes · any other key cancels') }
        when 'find' { return ('find ❯', "words in {$sc.defined ?? $sc.name ~ ' ' ~ $sc.short !! 'this run'}'s conversation   Enter older match · Esc back") }
        when 'nav' {
            if $m.layout eq 'lines' && $sc.defined {
                # the keys for the job itself are beside its title; these move
                my @do;
                my @rest = $m.zoom
                    ?? ('↓ say something', '←→ its other jobs', 'Esc every line')
                    !! $narrow ?? ('↓ say something', 'Enter zoom in', '←→↑ move', 'q leave')
                               !! ('↓ say something', 'Enter zoom in', '←→ time', '↑ agents', 'e evidence', 'n new', '/ word', 't table', 'q leave');
                return ("{$sc.name} {$sc.short} ❯", (|@do, |@rest).join($narrow ?? ' · ' !! '   '));
            }
            return ('', $narrow
                ?? '↑↓ run · s stop · h hold · r resume · n new · / word · q leave · Esc type'
                !! '↑↓ run   s stop   h hold   r resume   a again   n new   / word   v view   t lines   q leave   Esc type');
        }
    }
    my $to = $sc.defined ?? "to {$sc.name} {$sc.short} ❯" !! '❯';
    $to = "{$sc.name} {$sc.short} ❯" if $sc.defined && $m.layout eq 'lines';
    my $slash = slash-hint($m);
    return ($to, $slash) if $slash ne '';
    if $m.layout eq 'lines' && $sc.defined {
        return ($to, $narrow ?? 'Enter send · ↑ the lines · ←→ job · / words'
                             !! 'Enter send   ↑ the lines   ←→ another job   Alt-Enter new line   /edit editor   / words: /start /stop …');
    }
    ($to, $narrow
        ?? 'Enter send · / words · Esc keys · ←→ run'
        !! 'Enter send   Alt-Enter new line   /edit editor   / words: /start /stop …   Esc keys   ←→ run');
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
                    my @row = [' ' ~ pad($i ?? '' !! $t, $time-w - 1), 'dim'], [pad($i ?? '' !! $who, $who-w), $l.who eq 'you' ?? 'bold' !! 'bold+' ~ $c.accent];
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
            when 'queued' {
                @a.push(%( key => 'go', label => 'Go now', what => 'starts it now, ahead of its turn' ));
                @a.push(%( key => 'stop', label => 'Stop', what => 'ends it before it starts; nothing will have run' ));
            }
            when 'stopping' | 'starting' {
                @a.push(%( key => 'stop', label => 'Stop', what => 'ends this run; the others keep running' ));
            }
        }
        if $c.phase eq 'ended' | 'lost' {
            @a.push(%( key => 'restart', label => 'Run again', what => 'a new run of this request, with its own budget; this one stays as it ended' ));
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

#| The same thing said at the shell, for a person learning the words:
#| 'CLI: 321 stop K3F'.  Only for what the shell takes word for word
#| (Do321::RunWords); DO_321_HINTS=0 leaves it out.
sub cli-hint(Str $verb, Crew $c, Str $rest = '' --> Str) is export {
    return '' if (%*ENV<DO_321_HINTS> // '1') eq '0';
    my $w = run-word($verb);
    return '' if !$w.defined || $w.screen-only;
    " · CLI: 321 $verb {$c.short}" ~ ($rest ne '' ?? " $rest" !! '');
}

sub send-control(Model $m, Str $kind) {
    my $c = $m.selected // return;
    my $id = try send-directive($c.rd, $kind, :reason("$kind from Mission Control"), :client('mission-control'));
    if $! { $m.tell("not sent: {$!.message}"); return }
    $c.sent{$id} = [$kind, now.Num, ''];
    $m.tell("{$kind} requested for {$c.name} {$c.short}" ~ cli-hint($kind, $c));
}

sub do-action(Model $m, Str $key) is export {
    my $c = $m.selected;
    given $key {
        when 'hold'   { send-control($m, 'hold') if $c.defined && $c.phase eq 'running' }
        when 'go'     { send-control($m, 'resume') if $c.defined && $c.phase eq 'queued' }
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
        when 'restart-now' {
            my ($rd, $err) = restart-run($c.rd, :harness($m.pick-harness));
            with $err { $m.tell("not started: $_"); return }
            $m.filter = 'all';
            $m.scan;
            $m.sel = $m.visible.first({ .id eq $rd.id }, :k) // 0;
            $m.tell("started {$rd.short}, again of {$c.short}{$m.pick-harness ne '' ?? ' on ' ~ harness-name($m.pick-harness) !! ''}; it has its own budget");
        }
        when 'view' { cycle-filter($m) }
        when 'new'    { $m.mode = 'input'; $m.input = '/start '; $m.cursor = $m.input.chars }
        when 'follow' { .scroll = 0 with $c }
        when 'quit'   { $m.quit = True }
    }
}

#| The same runs as a line an agent, or as a table a run; the cursor
#| stays on the run it was on.
sub set-layout(Model $m, Str $layout) is export {
    my $keep = $m.selected;
    $m.zoom = False;
    $m.layout = $layout;
    $m.sel = $m.visible.first({ $keep.defined && .id eq $keep.id }, :k) // 0;
    $m.tell($layout eq 'lines' ?? 'a line for each agent: done, now, next   ←→ through time   ↑↓ between agents   /view table for a row a run'
                                !! 'a row for each run   /view lines for a line an agent');
}

#| The evidence for the run under the cursor, shown or put away.  It is
#| detail: there for a person who wants to look, out of the way otherwise.
sub show-evidence(Model $m) is export {
    if $m.layout ne 'lines' { $m.tell('the evidence is beside the conversation on a wide screen; /view lines, then e, shows it there'); return }
    $m.evidence = !$m.evidence;
    $m.tell($m.evidence ?? 'the evidence for the job under the cursor, at the right   e puts it away' !! 'evidence put away   e shows it');
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

#| The run a word names: '' is the one you are on; otherwise its id, or
#| the end of it.  A run the filter hides is shown, rather than refused.
sub pick-run(Model $m, Str $ref --> Crew) {
    return $m.selected if $ref eq '';
    my $want = $ref.uc;
    my $c = $m.crew.first({ .id eq $want || .id.ends-with($want) });
    without $c { $m.tell("no run here ends in '$ref'"); return Crew }
    unless $m.visible.first({ .id eq $c.id }) { $m.filter = 'all' }
    $m.sel = $m.visible.first({ .id eq $c.id }, :k) // $m.sel;
    $c;
}

#| A line from the input: a steer, or a run word said as '/word', the same
#| words '321 <word>' takes at the shell (Do321::RunWords).
sub run-line(Model $m, Str $line) is export {
    .note("line: $line") with $m.log;
    # a line that begins by naming an agent here is work for that agent
    my $said = $line;
    if $line.trim ~~ /^ '@' (\S+) \s+ \S / && agents-here().first({ .lc eq $0.Str.lc }) -> $name {
        $said = "/start $name " ~ $line.trim.split(/\s+/, 2)[1];
    }
    my %w = parse-run-line($said);
    with %w<error> { $m.tell($_); return }
    my $clear = { $m.input = ''; $m.cursor = 0 };
    given %w<verb> {
        when 'steer' {
            my $c = $m.selected;
            return $m.tell('no run is selected; /start begins one') unless $c.defined;
            unless $c.phase eq 'running' | 'held' | 'starting' | 'queued' {
                # the run is over, so the words begin the agent's next one:
                # same agent, same workspace, its conversation carried on
                return $m.tell("{$c.name} {$c.short} has been lost; /restart runs its request again") if $c.phase eq 'lost';
                return follow-up($m, $c, %w<words>, $clear);
            }
            my $id = try send-directive($c.rd, 'steer', :text(%w<words>), :client('mission-control'));
            if $! { $m.tell("not sent: {$!.message}"); return }
            $c.sent{$id} = ['steer', now.Num, %w<words>];
            $clear();
            $c.scroll = 0;
            $m.tell(($c.phase eq 'queued' ?? 'kept; it gets your words when its turn comes' !! steer-note($c.harness)) ~ cli-hint('steer', $c, '<words>'));
        }
        when 'start' {
            my $harness = '';
            if %w<harness> ne '' {
                my ($name, $why) = check-harness(%w<harness>);
                with $why { $m.tell($why); return }
                $harness = $name;
            }
            $clear();
            $m.tell("starting {%w<agent>}…");
            my ($rd, $err) = launch-run(%w<agent>, %w<words>, :via('mission-control'), :$harness,
                :workspace(%w<workspace>), :isolate(%w<isolate>));
            with $err { $m.tell("not started: $_"); return }
            $m.filter = 'all'; $m.scan;
            $m.sel = $m.visible.first({ .id eq $rd.id }, :k) // 0;
            $m.tell("started {%w<agent>} {$rd.short}; it keeps going when you leave");
        }
        when 'stop' | 'hold' | 'resume' {
            my $c = pick-run($m, %w<run>) // return;
            $clear();
            my $verb = %w<force> ?? 'force' !! $_;
            if $verb eq 'hold' && $c.phase ne 'running' { return $m.tell("{$c.name} {$c.short} is not running; nothing to hold") }
            if $verb eq 'resume' && $c.phase eq 'queued' { return do-action($m, 'go') }
            if $verb eq 'resume' && $c.phase ne 'held' { return $m.tell("{$c.name} {$c.short} is not held") }
            if $verb eq 'stop' && !$c.active { return $m.tell("{$c.name} {$c.short} has already ended") }
            do-action($m, $verb);
        }
        when 'restart' {
            my $c = pick-run($m, %w<run>) // return;
            $clear();
            with restart-refusal($c.rd) { $m.tell("not now: $_"); return }
            my $harness = '';
            if %w<harness> ne '' {
                my ($name, $why) = check-harness(%w<harness>);
                with $why { $m.tell($why); return }
                $harness = $name;
            }
            $m.pick-harness = $harness;
            $m.confirm = [restart-question($c.rd, :$harness), 'restart-now'];
            $m.mode = 'confirm';
        }
        when 'attach' {
            my $c = pick-run($m, %w<run>) // return;
            $clear();
            $m.tell("on {$c.name} {$c.short}");
        }
        when 'find' {
            return $m.tell('no run is selected') unless $m.selected.defined;
            $m.draft = '';
            $m.mode = 'find'; $m.input = %w<words>; $m.cursor = $m.input.chars;
            find-next($m);
        }
        when 'view' {
            $clear();
            if %w<view> eq '' { cycle-filter($m) }
            elsif %w<view> eq 'lines' | 'table' { set-layout($m, %w<view>) }
            elsif %w<view> eq 'evidence' { show-evidence($m) }
            else {
                my $keep = $m.selected;
                $m.filter = %w<view>;
                $m.sel = $m.visible.first({ $keep.defined && .id eq $keep.id }, :k) // 0;
                $m.tell("showing {filter-word($m.filter)}: {+$m.visible} of {+$m.crew}");
            }
        }
        when 'edit' {
            # the words after it are the draft the editor opens on
            $m.input = %w<words>; $m.cursor = $m.input.chars;
            $m.want-editor = True;
        }
        when 'quit' { $m.quit = True }
    }
}

#| Words to an agent whose run has ended: a new run of the same agent in
#| the same workspace, going on from the ended run's receipt, so the
#| agent answers with what it did in mind.  No question first: the words
#| are the person's own, the run has its own budget, and no approval
#| carries over.
sub follow-up(Model $m, Crew $c, Str $words, &clear) {
    my %run = $c.run;
    my $name = %run<agent><name> // '';
    return $m.tell("{$c.name} {$c.short} has ended; its run names no agent to ask") if $name eq '';
    clear();
    $m.tell("asking {$c.display}…");
    my ($rd, $err) = launch-run($name, $words, :via('mission-control'), :follows($c.rd),
        :workspace((%run<workspace> // '').Str), :harness(((%run<harness> // {})<requested> // '').Str));
    with $err { $m.tell("not asked: $_"); return }
    $m.filter = 'all'; $m.scan;
    $m.sel = $m.visible.first({ .id eq $rd.id }, :k) // $m.sel;
    $m.tell("{$c.display} {$rd.short} goes on from {$c.short}; it answers here");
}

#| What '/' and the start of a word offer, for the line under the input.
#| Text cut at a word boundary to fit a width: (what fits, the rest).
sub split-at-width(Str $t, Int $w --> List) is export {
    my @words = $t.split(' ');
    my $first = '';
    while @words && text-width($first ~ ($first ne '' ?? ' ' !! '') ~ @words[0]) <= $w {
        $first ~= ($first ne '' ?? ' ' !! '') ~ @words.shift;
    }
    # a single word longer than the row is cut, never lost
    if $first eq '' { $first = $t.substr(0, $w); return ($first, $t.substr($w)) }
    ($first, @words.join(' '));
}

#| The agents a person can name here: the short names in their trust
#| file.  Read, never resolved or loaded.
sub agents-here(--> List) is export {
    my $f = %*ENV<DO_321_TRUST> ?? %*ENV<DO_321_TRUST>.IO !! ($*HOME // '/'.IO).add('.321/trust.json');
    return () unless $f.e;
    my $doc = try parse-json($f.slurp);
    return () unless $doc ~~ Associative;
    (($doc<aliases> // {}).keys.sort).List;
}

#| An agent being named at the end of the input line: '@b' anywhere, or
#| the word after /start.  Returns (what is typed of it, the names that
#| begin so, whether it wears an @), or () when no agent is being named.
sub mention(Str $t --> List) is export {
    return () if $t eq '' || $t.ends-with(' ');
    my @w = $t.words;
    my $last = @w.tail;
    my $at = $last.starts-with('@');
    my $start = $t.starts-with('/') && !$t.starts-with('//') && @w > 1
        && (run-word(@w[0].substr(1)) // run-words-starting(@w[0].substr(1)).head // RunWord).?name eq 'start'
        && (@w[1 ..^ @w.end].grep({ !.starts-with('--') }).elems == 0)
        && !$last.starts-with('-') && !(@w > 2 && @w[*-2] eq '--harness' | '--workspace');
    return () unless $at || $start;
    my $typed = $at ?? $last.substr(1) !! $last;
    ($typed, agents-here().grep({ .lc.starts-with($typed.lc) }).List, $at);
}

sub slash-hint(Model $m --> Str) {
    my $t = $m.input;
    # an agent being named: who it could be
    if mention($t) -> ($typed, @names, $at) {
        my $p = $at ?? '@' !! '';
        return "no agent here begins '{$p}{$typed}'; 321 agents lists them" unless @names;
        return "{$p}{@names[0]}   " ~ ($typed eq @names[0] ?? 'then what it should do' !! 'Tab completes') if @names == 1;
        return @names.map({ $p ~ $_ }).join('  ') ~ '   Tab completes';
    }
    return '' unless $t.starts-with('/') && !$t.starts-with('//');
    my $word = $t.substr(1).split(' ', 2)[0];
    my @w = $t.contains(' ') ?? run-words().grep(*.name eq $word) !! run-words-starting($word);
    return "no word starts '/{$word}'; / alone lists them" unless @w;
    return @w.map({ '/' ~ .name }).join('  ') ~ '   Tab completes' if @w > 1;
    # on the screen a run left out is the one you are on, and a steer has no run word
    my $usage = @w[0].name eq 'steer' ?? '<words...>' !! @w[0].usage.subst('<run>', '[run]');
    "/{@w[0].name} $usage   {@w[0].what}" ~ ($t.contains(' ') ?? '   Enter does it' !! '   Tab completes');
}

#| One key, applied to the model.  Keys are for moving and for the few
#| things done often; everything else is a word on the input line.
sub handle-key(Model $m, Key $k, Int :$page = 10) is export {
    my $c = $m.selected;
    # the arrows stop at the ends of the crew, as a list does; Tab cycles,
    # which is what Tab is for
    my sub move(Int $d, Bool :$cycle = False) {
        my $n = $m.visible.elems;
        return unless $n;
        $m.sel = $cycle ?? ($m.sel + $d) % $n !! (($m.sel + $d) max 0) min ($n - 1);
    }
    # on tracklines the arrows go where the eye does: left and right
    # along one agent's line, through done, now and next, stopping at
    # its ends; up and down to the next agent, landing on what it has
    # in hand, else on the newest thing it did.
    my sub go($to) { with $to { $m.sel = $m.visible.first({ .id eq $to.id }, :k) // $m.sel } }
    my sub along(Int $d) {
        return move($d) unless $m.layout eq 'lines' && $c.defined;
        my @on = $m.visible.grep({ .name eq $c.name });
        my $k = @on.first({ .id eq $c.id }, :k) + $d;
        go(@on[$k]) if 0 <= $k < @on.elems;
    }
    my sub line(Int $d) {
        return move($d) unless $m.layout eq 'lines' && $c.defined;
        my @v = $m.visible;
        my %z = $m.zones;
        my @names = @v.map(*.name).unique;
        my $i = (@names.first({ $_ eq $c.name }, :k) // 0) + $d;
        return if $i < 0 || $i >= @names.elems;
        my @on = @v.grep({ .name eq @names[$i] });
        go(@on.first({ %z{.id} eq 'now' }) // @on.grep({ %z{.id} eq 'done' }).tail // @on.head);
    }
    # the arrows live in two places, one above the other: the lines and
    # the prompt.  Down from the last line goes to the prompt; up from
    # an empty prompt goes back to the lines.
    my sub down() {
        return line(1) unless $m.layout eq 'lines' && $c.defined;
        if $m.zoom || $c.name eq $m.visible.map(*.name).unique.tail { $m.mode = 'input' } else { line(1) }
    }
    my sub type(Str $text) { $m.mode = 'input'; $m.input = $text; $m.cursor = $text.chars }
    my sub edit() {
        given $k.name {
            when 'char' | 'paste' {
                $m.input = $m.input.substr(0, $m.cursor) ~ $k.text ~ $m.input.substr($m.cursor);
                $m.cursor += $k.text.chars;
            }
            when 'alt-enter' { $m.input = $m.input.substr(0, $m.cursor) ~ "\n" ~ $m.input.substr($m.cursor); $m.cursor++ }
            when 'backspace' { if $m.cursor > 0 { $m.input = $m.input.substr(0, $m.cursor - 1) ~ $m.input.substr($m.cursor); $m.cursor-- } }
            when 'delete'    { $m.input = $m.input.substr(0, $m.cursor) ~ $m.input.substr($m.cursor + 1) if $m.cursor < $m.input.chars }
            when 'home' { $m.cursor = 0 }
            when 'end'  { $m.cursor = $m.input.chars }
            when 'left'  { $m.cursor-- if $m.cursor > 0 }
            when 'right' { $m.cursor++ if $m.cursor < $m.input.chars }
        }
    }
    # the terminal's own interrupt still leaves; the runs keep going
    if $k.name eq 'ctrl-c' { $m.quit = True; return }
    # a long thought is written in the person's own editor
    if $k.name eq 'ctrl-g' && $m.mode eq 'input' { $m.want-editor = True; return }
    given $k.name {
        when 'pgup' { if $c.defined { $c.scroll += $page }; return }
        when 'pgdn' { if $c.defined { $c.scroll = ($c.scroll - $page) max 0 }; return }
    }
    given $m.mode {
        when 'confirm' {
            my $action = $m.confirm[1];
            $m.mode = 'nav';
            $m.confirm = Nil;
            if $k.name eq 'char' && $k.text eq 'y' | 'Y' { do-action($m, $action) } else { $m.tell('cancelled; nothing was sent') }
        }
        when 'find' {
            given $k.name {
                when 'esc'   { $m.mode = 'input'; $m.input = $m.draft; $m.cursor = $m.input.chars; $m.draft = ''; .hit = Int with $c }
                when 'enter' { find-next($m) }
                default      { edit(); .hit = Int with $c }
            }
        }
        when 'nav' {
            given $k.name {
                when 'left'  { along(-1) }
                when 'right' { along(1) }
                when 'up'    { line(-1) }
                when 'down'  { down() }
                when 'tab'            { move(1, :cycle) }
                # Enter goes in: the job alone, ready to be spoken to.  Esc
                # comes back out, a level at a time.
                when 'enter' {
                    if $m.layout eq 'lines' && $c.defined && !$m.zoom {
                        $m.zoom = True;
                        $m.tell("{$c.name} {$c.short} alone: type to it   Esc for its keys   Esc again for every line");
                    }
                    $m.mode = 'input';
                }
                when 'esc' { if $m.zoom { $m.zoom = False } else { $m.mode = 'input' } }
                when 'char' {
                    given $k.text {
                        when 'h' { run-line($m, '/hold') }
                        when 'r' { run-line($m, '/resume') }
                        when 's' { run-line($m, '/stop') }
                        when 'f' { do-action($m, 'force') if actions-for($m).first(*<key> eq 'force') }
                        when 'a' { run-line($m, '/restart') }
                        when 'n' { type('/start ') }
                        when '/' { type('/') }
                        when 'v' { cycle-filter($m) }
                        when 'e' { show-evidence($m) }
                        when 't' { set-layout($m, $m.layout eq 'lines' ?? 'table' !! 'lines') }
                        when 'q' { $m.quit = True }
                        when 'i' { $m.mode = 'input' }
                        when 'k' { line(-1) }
                        when 'j' { down() }
                    }
                }
            }
        }
        default {   # input
            given $k.name {
                when 'esc' { $m.mode = 'nav' }
                when 'tab' {
                    # a word being typed after '/' is finished; otherwise the next run
                    my $t = $m.input;
                    my sub agree(@n) { @n.reduce(-> $a, $b { my $i = 0; $i++ while $i < $a.chars && $i < $b.chars && $a.substr($i, 1) eq $b.substr($i, 1); $a.substr(0, $i) }) }
                    if $m.cursor == $t.chars && mention($t) -> ($typed, @names, $at) {
                        # an agent being named is finished, or taken as far as the names agree
                        my $head = $t.substr(0, $t.chars - $typed.chars);
                        if @names == 1 { type($head ~ @names[0] ~ ' ') }
                        elsif @names > 1 && agree(@names).chars > $typed.chars { type($head ~ agree(@names)) }
                    }
                    elsif $t.starts-with('/') && !$t.starts-with('//') && !$t.contains(' ') {
                        my @w = run-words-starting($t.substr(1));
                        if @w == 1 { type("/{@w[0].name} ") }
                        elsif @w > 1 {
                            # as far as they agree
                            my $common = @w.map(*.name).reduce(-> $a, $b { my $i = 0; $i++ while $i < $a.chars && $i < $b.chars && $a.substr($i, 1) eq $b.substr($i, 1); $a.substr(0, $i) });
                            type("/$common");
                        }
                    }
                    else { move(1, :cycle) }
                }
                when 'shift-tab' { move(-1, :cycle) }
                # up from an empty prompt is back on the lines above it; with
                # words typed, the arrows read the conversation
                when 'up'   { if $m.layout eq 'lines' && $m.input eq '' && $c.defined { $m.mode = 'nav' } elsif $c.defined { $c.scroll += 1 } }
                when 'down' { if $c.defined { $c.scroll = ($c.scroll - 1) max 0 } }
                when 'left' | 'right' {
                    if $m.input eq '' { along($k.name eq 'left' ?? -1 !! 1) } else { edit() }
                }
                when 'enter' {
                    return if $m.input.trim eq '';
                    run-line($m, $m.input);
                }
                default { edit() }
            }
        }
    }
}

# ------------------------------------------------------------ the editor

#| The editor a person named: $VISUAL, else $EDITOR, else vi.
sub editor-command(--> Str) is export { (%*ENV<VISUAL> // '').trim || (%*ENV<EDITOR> // '').trim || 'vi' }

#| The draft, written in an editor: the input goes into a private file,
#| &open is handed its path and returns when the editor closes, and what
#| the file then holds is the input.  Nothing is sent: the person reads
#| it back on the input line and presses Enter themselves.  Returns what
#| went wrong, or Str.
sub edit-draft(Model $m, &open --> Str) is export {
    my $f = $m.draft-file;
    my $err = Str;
    {
        $f.spurt($m.input);
        $f.chmod(0o600);
        open($f);
        $m.input = $f.slurp.subst(/\n+ $/, '');
        $m.cursor = $m.input.chars;
        $m.mode = 'input';
        CATCH { default { $err = .message } }
    }
    try $f.unlink;
    $err;
}

# ------------------------------------------------------------ the loop

#| Open Mission Control.  Returns the exit code when the person leaves.
sub run-deck(Str :$focus = '' --> Int) is export {
    my $m = Model.new;
    $m.scan;
    # a trackline an agent: who is doing what, at a glance.
    # DO_321_VIEW=table opens on a row a run instead.
    my $want = (%*ENV<DO_321_VIEW> // '').lc;
    $m.layout = $want eq 'table' ?? 'table' !! 'lines';
    # the cursor opens on work in hand, else on the newest thing
    $m.sel = $m.visible.first(*.active, :k) // ($m.layout eq 'lines' ?? ($m.visible.end max 0) !! 0);
    if $focus ne '' { $m.sel = $m.visible.first({ .id eq $focus }, :k) // 0 }
    my $t = Terminal.new;
    my $log = TuiLog.new.open;
    $m.log = $log;
    # a warning from anything the screen calls goes to the log, never
    # across the screen
    my $*ERR = (try open(tui-log-path(), :a)) // $*ERR;
    LEAVE { try $*ERR.close if $*ERR !=== $PROCESS::ERR }
    $t.size;                                   # the real size, not the defaults, in the log
    $log.note("open {$t.cols}x{$t.rows}, {+$m.crew} runs{$focus ne '' ?? ', on ' ~ $focus !! ''}");
    # what the person sees change after a key: the mode, the run, the view, a question
    my sub seen(--> Str) {
        my $c = $m.selected;
        "mode={$m.mode} run={$c.defined ?? $c.short !! '-'} view={$m.filter}" ~ ($m.confirm ?? " asking: {$m.confirm[0]}" !! '');
    }
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
            my $name = $k.name eq 'char' ?? 'typed' !! $k.name eq 'paste' ?? "paste of {$k.text.chars} characters" !! $k.name;
            my $before = seen();
            try {
                handle-key($m, $k, :page(($rows - 12) max 5));
                CATCH { default {
                    $log.note("error after key $name: {.message}\n{.backtrace.Str}");
                    $m.tell("that went wrong: {.message.lines.head}; {$log.path} has the detail");
                } }
            }
            my $after = seen();
            # a letter typed is logged only when it changed what is shown
            $log.note("key $name" ~ ($after ne $before ?? " → $after" !! '')) if $name ne 'typed' || $after ne $before;
            $dirty = True;
            last if $m.quit;
        }
        last if $m.quit;
        if $m.want-editor {
            $m.want-editor = False;
            my $ed = editor-command();
            $log.note("editor: $ed");
            # the screen and the keys go to the editor, and come back after
            $t.leave;
            sleep 0.2;
            my $why = edit-draft($m, -> $f { my $p = shell("$ed '{$f.Str.subst("'", "'\\''", :g)}'"); die "$ed ended {$p.exitcode}" if $p.exitcode != 0 });
            $t.enter;
            while $keys.poll { }
            $t.key-reader($keys);
            $t.invalidate;
            $m.tell($why.defined ?? "the editor did not finish: $why" !! $m.input eq '' ?? 'nothing was written' !! 'written; Enter sends it');
            $dirty = True;
        }
        if $resized { $resized = False; $t.size; $t.invalidate; $dirty = True; $log.note("resize {$t.cols}x{$t.rows}") }
        for $m.crew -> $c { $dirty = True if $c.refresh }
        # a run started elsewhere shows within two seconds; a run started
        # here is scanned for at once
        if now.Num - $m.scanned > 2 { my $n = $m.crew.elems; $m.scan; $dirty = True if $m.crew.elems != $n }
        if now.Num - $last-tick >= 0.4 {
            $m.tick++;
            $last-tick = now.Num;
            # the beat moves while a run works; otherwise only the clock,
            # the flash and the 'ago' words change, once a second at most.
            # An idle screen is not redrawn more often than that
            $dirty = True if $m.crew.first(*.active) || $last-tick.Int != $last-draw.Int;
        }
        if $dirty && now.Num - $last-draw >= 1/30 {
            my ($rows, $cols) = ($t.rows, $t.cols);
            try {
                my $cv = render($m, $rows, $cols);
                my ($cr, $cc) = cursor-at($m, $rows, $cols);
                $t.draw($cv, :cursor-row($cr), :cursor-col($cc));
                CATCH { default {
                    # said once per message, not thirty times a second
                    my $msg = .message.lines.head;
                    unless $m.flash.contains($msg) {
                        $log.note("error drawing {$cols}x{$rows}: {.message}\n{.backtrace.Str}");
                        $m.tell("the screen could not be drawn: $msg; {$log.path} has the detail");
                    }
                } }
            }
            $last-draw = now.Num;
            $dirty = False;
        }
        sleep 0.03;
    }
    $t.leave;
    my $live = $m.crew.grep(*.active).elems;
    $log.note("leave, {$live} still going");
    $log.close;
    say "{icon()} 321 tui: left Mission Control; " ~ ($live ?? "{many-of($live, 'run')} still going" !! 'nothing is running');
    say next-text('come back to them', '321 tui') if $live;
    0;
}
