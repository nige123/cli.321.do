unit module Do321::Fold;

#| A run's state, folded from its events.  The same fold serves the host's
#| status file and every screen, so two readers of one log never disagree.
#| It reads what the runtime and the host recorded; it never infers more
#| than an event says: a steer is "taken" when the
#| runtime applied it, never "obeyed", and a plan bar exists only when an
#| event gives a denominator.

use Do321::RunDir;

#| One line of a run's conversation.
class Line is export {
    has Str $.at = '';
    has Str $.who = 'note';      # you | agent | tool | note | end
    has Str $.text = '';
    has Str $.mark is rw = '';      # a short state shown at the right: "✓ taken 09:38"
    has Str $.tone is rw = '';      # ok | wait | bad | dim
    has Str $.directive = '';    # the directive id a "you" line belongs to
}

class RunState is export {
    has Str $.phase is rw = 'starting';
    has Str $.outcome is rw = '';
    has Str $.activity is rw = 'starting';
    has Str $.summary is rw = '';
    has Int $.tools is rw = 0;
    has Int $.attempts is rw = 0;
    has Str $.harness is rw = '';
    has Rat $.usd is rw = 0.0;
    has Bool $.cost-reported is rw = False;
    has Str $.last-at is rw = '';
    has Str $.started-at is rw = '';
    has Str $.ended-at is rw = '';
    has Int $.seq is rw = 0;
    has @.lines;
    #| Lines dropped from the front to keep memory bounded; they are still
    #| in the run's events.jsonl.
    has Int $.dropped is rw = 0;
    #| directive id -> { kind, text, state, at, reason }
    has %.controls;
    has @.swept;

    method cost-text(--> Str) {
        return 'none yet' unless $!cost-reported;
        sprintf('$%.2f', $!usd);
    }

    #| A control's lifecycle in words for the deck: the newest one that is
    #| not settled, else ''.
    method open-control(--> Str) {
        for %!controls.values.sort({ $^b<at> cmp $^a<at> }) -> %c {
            next if %c<state> eq 'applied' | 'refused' | 'rejected' | 'duplicate' | 'confirmed';
            next if %c<kind> eq 'steer' | 'clarify';
            return "{%c<kind>} {%c<state>}";
        }
        '';
    }
}

sub hhmm(Str $iso --> Str) is export {
    return '' if $iso.chars < 16;
    my $t = try DateTime.new($iso).local;
    return $iso.substr(11, 5) without $t;
    sprintf('%02d:%02d', $t.hour, $t.minute);
}

#| How many conversation lines a state keeps in memory.
constant KEEP-LINES is export = 2000;

#| Fold one event into the state.
sub fold-event(RunState $s, %e) is export {
    my %p = (%e<payload> // {}).Hash;
    my $at = %e<at> // '';
    my $kind = %e<kind> // '';
    $s.seq = %e<seq> if (%e<seq> // 0) > $s.seq;
    $s.started-at = $at if $s.started-at eq '';
    $s.last-at = $at unless $kind eq 'heartbeat';
    my sub say-line(*%f) {
        $s.lines.push(Line.new(:$at, |%f));
        if $s.lines.elems > KEEP-LINES { $s.lines.shift; $s.dropped++ }
    }
    my sub control(Str $id, *%f) {
        return if $id eq '';
        my %c = ($s.controls{$id} // { kind => %f<kind> // '', text => '', state => 'requested', at => $at }).Hash;
        %c{.key} = .value for %f.pairs;
        %c<at> = $at;
        $s.controls{$id} = %c;
    }
    given $kind {
        # --- what the host records
        when 'host_started' {
            $s.phase = 'running';
            $s.activity = 'starting';
            say-line(:who<note>, :text("a new run of the request {%p<continues>} ran; that run's receipt is unchanged"), :tone<dim>)
                if (%p<continues> // '') ne '';
            say-line(:who<you>, :text(%p<request> // '')) if (%p<request> // '') ne '';
        }
        when 'directive_delivered' {
            control(%p<directiveId> // '', :kind(%p<kind> // ''), :text(%p<text> // ''), :state<acknowledged>);
            if %p<kind> eq 'steer' | 'clarify' {
                say-line(:who<you>, :text(%p<text> // ''), :mark('· delivered'), :tone<dim>, :directive(%p<directiveId> // ''));
            }
        }
        when 'directive_refused' {
            control(%p<directiveId> // '', :state<refused>, :reason(%p<reason> // ''));
            say-line(:who<note>, :text("not delivered: {%p<reason> // ''}"), :tone<bad>);
        }
        when 'swept' {
            $s.swept.append(@(%p<processes> // []));
            my $n = @(%p<processes> // []).elems;
            say-line(:who<note>, :text("stopped {$n} process{$n == 1 ?? '' !! 'es'} the agent left running"), :tone<wait>) if $n;
        }
        when 'log_truncated' {
            say-line(:who<note>, :text("the log reached {(%p<bytes> // 0) div 1_048_576} MB: the agent's words from here are not kept, everything else is"), :tone<wait>);
        }
        when 'runtime_exited' {
            say-line(:who<note>, :text("the runtime exited {%p<exitCode> // '?'} without a receipt"), :tone<bad>) unless %p<receipt>;
        }
        when 'receipt' {
            $s.phase = 'ended';
            $s.outcome = outcome-word(%p<status> // '');
            $s.summary = %p<summary> // '';
            $s.ended-at = $at;
            $s.activity = $s.outcome;
            my $tone = $s.outcome eq 'done' | 'no_change' ?? 'ok' !! $s.outcome eq 'blocked' ?? 'wait' !! 'bad';
            say-line(:who<end>, :text("{$s.outcome}: {$s.summary}"), :$tone);
            for $s.controls.kv -> $id, %c { control($id, :state<confirmed>) if %c<kind> eq 'stop' }
        }
        # --- what the runtime records
        when 'started'          { $s.activity = 'starting' }
        when 'adapter_selected' { $s.harness = %p<adapter> // ''; say-line(:who<note>, :text("running in {%p<adapter> // '?'}"), :tone<dim>) }
        when 'attempt_started'  {
            $s.attempts = (%p<attempt> // ($s.attempts + 1)).Int;
            $s.activity = 'thinking';
            say-line(:who<note>, :text("attempt {$s.attempts}"), :tone<dim>) if $s.attempts > 1;
        }
        when 'attempt_ended'    { $s.activity = 'between steps' }
        when 'tool_call' {
            $s.tools++;
            my $t = %p<target> // (%p<op> // '');
            $s.activity = "running a tool · {(%p<tool> // '').lc}";
            say-line(:who<tool>, :text("{(%p<tool> // '?').lc}  $t".trim), :tone<dim>);
        }
        when 'tool_result' {
            if %p<ok>.defined && !%p<ok> {
                say-line(:who<tool>, :text("{(%p<tool> // '?').lc} {%p<op> // ''}".trim), :mark("✗ exit {%p<exitCode> // '?'}"), :tone<bad>);
            }
        }
        when 'progress' {
            if (%p<text> // '') ne '' { $s.activity = 'writing'; say-line(:who<agent>, :text(%p<text>)) }
            elsif (%p<notice> // '') ne '' { say-line(:who<note>, :text(%p<notice>), :tone<wait>) }
            elsif (%p<instruction> // '') ne '' { control(%p<directiveId> // '', :state<applied>) }
        }
        when 'cost' {
            if %p<usd>.defined { $s.usd += %p<usd>.Rat; $s.cost-reported = True }
        }
        when 'directive_received' { control(%p<directiveId> // '', :kind(%p<kind> // ''), :state<received>) }
        when 'directive_applied'  { control(%p<directiveId> // '', :state<applied>) }
        when 'directive_rejected' {
            control(%p<directiveId> // '', :state<rejected>, :reason(%p<reason> // ''));
            say-line(:who<note>, :text("could not apply: {%p<reason> // ''}"), :tone<bad>);
        }
        when 'directive_duplicate' { control(%p<directiveId> // '', :state<duplicate>) }
        when 'paused' {
            $s.phase = 'held';
            $s.activity = 'held';
            for $s.controls.kv -> $id, %c { control($id, :state<confirmed>) if %c<kind> eq 'hold' && %c<state> ne 'confirmed' }
            say-line(:who<note>, :text('held: the current step ended; nothing runs until you resume'), :tone<wait>);
        }
        when 'resumed' {
            $s.phase = 'running';
            for $s.controls.kv -> $id, %c { control($id, :state<confirmed>) if %c<kind> eq 'resume' && %c<state> ne 'confirmed' }
            say-line(:who<note>, :text('resumed: the conversation continues'), :tone<dim>);
        }
        when 'stopping' {
            $s.phase = 'stopping';
            $s.activity = 'stopping';
            control(%p<directiveId> // '', :state('in progress'));
            say-line(:who<note>, :text("stopping{(%p<reason> // '') ne '' ?? ': ' ~ %p<reason> !! ''}"), :tone<wait>);
        }
        when 'denied' { say-line(:who<note>, :text("denied: {%p<reason> // %p<summary> // ''}"), :tone<bad>) }
    }
    # a steer the runtime applied is taken: the agent has the words
    return unless $kind eq 'directive_delivered' | 'directive_received' | 'directive_applied' | 'directive_rejected'
        | 'directive_refused' | 'directive_duplicate' | 'progress';
    for $s.lines.grep({ .who eq 'you' && .directive ne '' }) -> $l {
        my %c = $s.controls{$l.directive} // next;
        given %c<state> {
            when 'applied'   { $l.mark = "✓ taken {hhmm(%c<at>)}"; $l.tone = 'ok' }
            when 'received'  { $l.mark = '· received'; $l.tone = 'dim' }
            when 'rejected' | 'refused' { $l.mark = '✗ not delivered'; $l.tone = 'bad' }
            when 'duplicate' { $l.mark = '· already sent'; $l.tone = 'dim' }
        }
    }
}

#| The whole fold of a list of events.
sub fold(@events, RunState $s = RunState.new --> RunState) is export {
    fold-event($s, $_) for @events;
    $s;
}

#| What a status file says: the fold, small, for readers that want the
#| state without the log.  A cache: the log and the kernel win.
sub status-doc(RunState $s, Str $run-id --> Hash) is export {
    %( schema => SCHEMA-STATUS, runId => $run-id, seq => $s.seq, phase => $s.phase, outcome => $s.outcome,
       activity => $s.activity, tools => $s.tools, attempts => $s.attempts,
       cost => ($s.cost-reported ?? { usd => $s.usd, basis => 'harness' } !! { basis => 'unreported so far' }),
       lastEventAt => $s.last-at, heartbeatAt => now-iso(),
       controls => %( $s.controls.map({ .key => .value<state> }) ) );
}

sub now-iso(--> Str) is export { DateTime.now.utc.Str.subst(/\.\d+/, '') }
