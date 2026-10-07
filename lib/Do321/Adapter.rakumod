unit module Do321::Adapter;

#| What a harness adapter is, what it may honestly claim to enforce, and
#| how one is chosen for a package.
#|
#| An adapter is a way of executing an attempt.  It receives the effective
#| grants and limits, a rendered prompt or a procedure, a directive
#| mailbox it may or may not be able to act on live, and an approval gate
#| for any external action.  It returns an outcome.  It never decides
#| authority: the runner computed the grants before the adapter saw them,
#| and an adapter that cannot enforce a required restriction is never
#| selected.

use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Tool;
use Do321::Trust;
use Do321::Controller;
use Do321::ClaudeHooks;

#| Whether an adapter can run here at all.
class Detection is export {
    has Bool $.available = False;
    has Str $.version = '';
    has Str $.reason = '';
}

#| An adapter's own account of which features it enforces: a Hash of
#| feature => Bool.  A feature absent is not enforced.
sub enforces(%e, Str $feature --> Bool) is export { so %e{$feature} }

#| One attempt's input.
class Spec is export {
    has %.package;
    has $.agent;                 # Do321::Trust::Loaded
    has Int $.attempt = 0;
    has Str $.workspace = '';    # absolute path, or '' when the package has none
    has Str $.prompt = '';
    has @.instructions;
    has @.grants;
    has %.limits;                # remaining for this attempt (a Limits document)
    has Str $.session-ref = '';
    has Str $.output-schema = '';
    has $.procedure;             # a Procedure document, or Any
    has %.captures;
    has Str $.overlay;           # adapter-specific tuning, or Str
    has %.hook-controls;         # controller name => the controls to register for this run
    has Str $.hook-self = '';    # the 321 command the harness should call back
    has %.hook-env;              # extra environment for the harness, so its hooks can report back
}

#| What the adapter can say and hear while it runs.
class Control is export {
    has &.emit = -> $, % {};              # emit(kind, payload)
    has Mailbox $.directives;             # live directives, for adapters that enforce live_steer or pause
    has &.applied = -> $ {};
    has &.rejected = -> $, $ {};
    has &.approval;                       # approval(action, target, params) -> (ApprovalCheck, error or Str)
}

#| What one attempt produced.
class Outcome is export {
    has Str $.status is rw = '';
    has Str $.end-reason is rw = '';
    has Str $.summary is rw = '';
    has Str $.blocked-on is rw = '';
    has @.conditions is rw;      # ConditionProof documents
    has Str $.session-ref is rw = '';
    has %.cost is rw;            # a Cost document
    has @.denials is rw;
    has @.errors is rw;
    has $.external-action is rw;
    has $.approval-check is rw;
    has @.tool-calls is rw;
    has $.proposal is rw;
}

role Adapter is export {
    method name(--> Str) { ... }
    method detect(--> Detection) { ... }
    method enforcement(--> Hash) { ... }
    method run(Cancel $cancel, Spec $spec, Control $ctl --> Outcome) { ... }
    #| Which controls this harness lets a controller operate, and how
    #| strongly: a Hash of control => strength.  Absent means none.  Claim
    #| only what the harness really does.
    method controls(--> Hash) { %() }
    #| The same, for a run 321 launches itself with nobody at the harness's
    #| own prompt: usually the controls less asking a person.
    method headless-controls(--> Hash) { self.controls }
    #| Whether hooks handed over in a Spec are registered with the harness
    #| for that run.
    method can-register-hooks(--> Bool) { False }

    # What 321 knows about wiring a controller into this harness.  An
    # adapter whose harness has no hook mechanism leaves these as they
    # are: nothing can be installed, and that is what is reported.

    #| Where this harness keeps the wiring in a project, for a person to
    #| look at; '' when it keeps none.
    method wiring-path(--> Str) { '' }
    #| Wire a controller in for the given controls.  $self is the 321
    #| command the harness should call.  Returns 'installed', 'updated' or
    #| 'unchanged'; dies with a reason when it cannot.
    method install-controller(IO::Path $workspace, Str $self, Str $controller, @controls --> Str) {
        die "{self.name} has no hook mechanism 321 can install into\n";
    }
    #| Take only that controller's wiring out: 'removed' or 'unchanged'.
    method remove-controller(IO::Path $workspace, Str $controller --> Str) { 'unchanged' }
    #| What is really there: control => 'installed' | 'missing' (or a
    #| harness-specific word such as 'legacy').
    method verify-controller(IO::Path $workspace, Str $controller, @controls --> Hash) { %( @controls.map({ $_ => 'missing' }) ) }
    #| A native hook event as a generic action, or Action:U when the event
    #| is not an action.
    method translate-event(Str $control, %native --> Action) { Action }
    #| A verdict in the harness's own terms: (exit code, stdout, stderr).
    method answer(Str $control, Verdict $v, Bool :$headless = False --> List) { (0, '', '') }
    #| The agent's last words, from the harness's own end-of-turn event.
    method final-words(%native --> Str) { '' }
}

#| One feature the package or its grants make mandatory.
class Requirement is export {
    has Str $.feature;
    has Str $.reason;
}

#| The package's network mode with the default applied: unspecified means
#| the agent may reach nothing beyond the harness's own model provider.
sub effective-network(%wp --> Str) is export {
    my $n = %wp<capabilities><limits><network> // '';
    $n eq '' ?? NETWORK-PROVIDER-ONLY !! $n;
}

#| What must be enforced for this package under these effective grants.
#| Package requirements are taken as stated; the rest follow from what the
#| grants make reachable.
sub requirements(%m, %wp, @grants --> List) is export {
    my @reqs;
    my sub add(Str $f, Str $why) {
        return if @reqs.first(*.feature eq $f);
        @reqs.push(Requirement.new(:feature($f), :reason($why)));
    }
    add($_, 'the package requires it') for @(%m<harness><requires> // []);
    my sub holds(Str $c) { is-in($c, @grants) }
    my $toolish = holds(CAP-REPO-READ) || holds(CAP-REPO-WRITE) || holds(CAP-SHELL-RUN) || holds(CAP-NET-FETCH) || holds(CAP-FILES-READ) || holds(CAP-FILES-WRITE);
    add(FEAT-TOOL-ALLOWLIST, 'tools are granted, so the harness must confine them to the grant') if $toolish;
    add(FEAT-STRUCTURED-OUTPUT, 'the package declares an output schema');
    add(FEAT-TURN-LIMIT, 'a turn limit is set') if (%wp<capabilities><limits><maxTurns> // 0) > 0;
    add(FEAT-SPEND-LIMIT, 'a spend limit is set') if (%wp<capabilities><limits><maxUsd> // 0) > 0;
    my $network = effective-network(%wp);
    add(FEAT-NETWORK-DENY, "shell.run is granted but agent network access is $network, so an unrestricted shell would bypass it")
        if $network ne NETWORK-OPEN && holds(CAP-SHELL-RUN);
    @reqs.List;
}

#| Why one adapter was not chosen.
class Rejection is export {
    has Str $.adapter;
    has Str $.unavailable = '';
    has @.missing;
    has Bool $.denied = False;
    method Str {
        return "$!adapter: denied by policy" if $!denied;
        return "$!adapter: unavailable: $!unavailable" if $!unavailable ne '';
        "$!adapter: cannot enforce {@!missing.join(', ')}";
    }
}

#| The installed adapters in registration order.  Hidden adapters (the
#| procedure executor and the fake) are never chosen by selection on
#| their own merits: only by name, through the caller's explicit adapter
#| choice or the policy's preferred list.
class Registry is export {
    has @.adapters;
    has %.hidden;

    method register(Adapter $a) { @!adapters.push($a); self }
    method register-hidden(Adapter $a) { %!hidden{$a.name} = True; @!adapters.push($a); self }
    method get(Str $name) { @!adapters.first(*.name eq $name) }
    method all(--> List) { @!adapters.List }

    #| The first adapter, in policy preference order, that is available
    #| and enforces every requirement, with the rejections so a denial
    #| can say exactly why nothing qualified.  %policy is an AdapterPolicy
    #| document.
    method select(@reqs, %policy, Str $only = '' --> List) {
        my %denied = @(%policy<denied> // []).map({ $_ => True });
        my @preferred = @(%policy<preferred> // []);
        my %preferred = @preferred.map({ $_ => True });
        my @rejections;
        for self!ordered(@preferred) -> $a {
            next if $only ne '' && $a.name ne $only;
            next if %!hidden{$a.name} && $only ne $a.name && !%preferred{$a.name};
            if %denied{$a.name} { @rejections.push(Rejection.new(:adapter($a.name), :denied)); next }
            my $det = $a.detect;
            unless $det.available { @rejections.push(Rejection.new(:adapter($a.name), :unavailable($det.reason))); next }
            my %enf = $a.enforcement;
            my @missing = @reqs.grep({ !enforces(%enf, .feature) }).map({ "{.feature} ({.reason})" });
            if @missing { @rejections.push(Rejection.new(:adapter($a.name), :@missing)); next }
            return ($a, @rejections);
        }
        if $only ne '' && !self.get($only) {
            @rejections.push(Rejection.new(:adapter($only), :unavailable('no such adapter')));
        }
        (Adapter, @rejections);
    }

    method !ordered(@preferred --> List) {
        my %rank = @preferred.kv.map(-> $i, $p { $p => $i });
        my @ranked = @!adapters.grep({ %rank{.name}:exists }).sort({ %rank{.name} });
        my @rest = @!adapters.grep({ !(%rank{.name}:exists) });
        (|@ranked, |@rest);
    }
}

#| The argument vector for a harness: with a replacement environment when
#| one is given (tests), and with extra variables added to the inherited
#| one otherwise, through env so the result does not depend on how the
#| runtime's own process passes an environment on.
sub launch-argv(Str $bin, @argv, %replace, %extra --> List) is export {
    return spawn-argv($bin, @argv, %( |%replace, |%extra )) if %replace.elems;
    return ($bin, |@argv) unless %extra.elems;
    my $env-bin = on-path('env') // '/usr/bin/env'.IO;
    ($env-bin.Str, |%extra.keys.sort.map({ "$_={%extra{$_}}" }), $bin, |@argv);
}

#| Neutral grants mapped onto an adapter's tool vocabulary.  Unknown
#| grants map to nothing, which is the safe direction.
sub tool-names(@grants, %table --> List) is export {
    my %seen;
    my @out;
    for @grants -> $g {
        for @(%table{$g} // []) -> $t {
            next if %seen{$t};
            %seen{$t} = True;
            @out.push($t);
        }
    }
    @out.List;
}

# ------------------------------------------------------------ procedures

class X::Do321::Adapter is Exception is export {
    has Str $.message;
}

sub no-approval-error() is export { X::Do321::Adapter.new(message => 'no approval is attached to this package') }

#| A path inside the workspace, or an error.  Refuses escapes, including
#| through a symlinked parent.
sub inside-workspace(Str $ws, Str $rel --> IO::Path) is export {
    X::Do321::Adapter.new(message => "path \"$rel\" is not a safe relative path").throw unless safe-rel-path($rel);
    my $abs = $ws.IO.absolute.IO;
    my $full = $abs.add($rel);
    X::Do321::Adapter.new(message => "path \"$rel\" escapes the workspace").throw unless within($full, $abs);
    my $parent = $full.parent;
    loop {
        if $parent.e {
            my $resolved = $parent.resolve;
            my $abs-resolved = $abs.resolve;
            X::Do321::Adapter.new(message => "path \"$rel\" resolves outside the workspace").throw
                unless within($resolved, $abs-resolved);
            last;
        }
        last if $parent.Str eq $abs.Str || $parent.parent.Str eq $parent.Str;
        $parent = $parent.parent;
    }
    $full;
}

sub all-met(@conds --> Bool) { so @conds.map({ $_<met> }).all }

#| {{name}} replaced with the capture of that name; an unknown or empty
#| capture yields the empty string, which the caller drops.
sub substitute(Str $s, %captures --> Str) is export {
    return $s unless $s.contains('{{');
    my $out = $s;
    for %captures.kv -> $name, $val { $out = $out.subst('{{' ~ $name ~ '}}', $val // '', :g) }
    $out.contains('{{') ?? '' !! $out;
}

sub cap-tail(Str $s, Int $n --> Str) is export {
    $s.chars <= $n ?? $s !! '[…truncated…]' ~ $s.substr(*-$n);
}

#| The deterministic executor for package procedures, and (with a script)
#| the fake adapter tests and dry runs use.  It enforces everything it
#| claims by construction: the only operations it performs are the ones
#| its steps name, each checked against the grants, the workspace
#| boundary and the approval gate before it happens.
class ProcedureAdapter does Adapter is export {
    has Str $.adapter-name = 'procedure';
    has $.script;               # a list of ProcedureStep documents: fake mode
    has %.tools;                # name => Tool
    has %.fake-controls;        # fake mode: the controls a stand-in harness claims
    has Bool $.fake-install-fails = False;

    method name(--> Str) { $!adapter-name }
    method detect(--> Detection) { Detection.new(:available, :version<built-in>) }
    method enforcement(--> Hash) { %( features().map({ $_ => True }) ) }
    #| Deterministic steps have no model, so there is no tool call, write or
    #| turn end of a model's to intercept: every control is none unless a
    #| fake stands in for a harness and says otherwise.
    method controls(--> Hash) { %!fake-controls }

    # A fake stands in for a harness in tests: it keeps its wiring in a
    # file of its own and supports exactly the controls it was given.
    method wiring-path(--> Str) { %!fake-controls ?? '.fake-harness.json' !! '' }
    method can-register-hooks(--> Bool) { False }
    method install-controller(IO::Path $workspace, Str $self, Str $controller, @controls --> Str) {
        die "{self.name} has no hook mechanism 321 can install into\n" unless %!fake-controls;
        die "the fake harness refused the wiring\n" if $!fake-install-fails;
        my $f = $workspace.add('.fake-harness.json');
        my %w = $f.e ?? %(parse-json($f.slurp)) !! %();
        my @have = @(%w{$controller} // []);
        my @want = @controls.grep({ control-strength(%!fake-controls, $_) ne STRENGTH-NONE }).sort;
        return 'unchanged' if @have.sort.join(',') eq @want.join(',') && $f.e;
        %w{$controller} = [ |@want ];
        $f.spurt(encode-json(%w));
        @have ?? 'updated' !! 'installed';
    }
    method remove-controller(IO::Path $workspace, Str $controller --> Str) {
        my $f = $workspace.add('.fake-harness.json');
        return 'unchanged' unless $f.e;
        my %w = %(parse-json($f.slurp));
        return 'unchanged' unless %w{$controller}:exists;
        %w{$controller}:delete;
        $f.spurt(encode-json(%w));
        'removed';
    }
    method verify-controller(IO::Path $workspace, Str $controller, @controls --> Hash) {
        my $f = $workspace.add('.fake-harness.json');
        my %w = $f.e ?? %(parse-json($f.slurp)) !! %();
        my @have = @(%w{$controller} // []);
        %( @controls.map({ $_ => (is-in($_, @have) ?? 'installed' !! 'missing') }) );
    }

    #| The bound tools, for `321 doctor`.
    method bindings(--> List) {
        my @out;
        for registry-names(%!tools) -> $name {
            my $t = %!tools{$name};
            my $state = 'bound';
            if $t ~~ DP {
                $state = $t.bound ?? $t.bin !! 'not configured (set DP_BIN to the engine\'s explicit entry point)';
                if $t.exec ~~ EngineExecutor { $state ~= "; execute ENABLED on {$t.exec.allowed-targets.join(', ')} (DP_EXECUTE)" }
                elsif !$t.exec.defined { $state ~= '; execute unavailable' }
            }
            my @ops = $t.ops.map({ "{.name} ({.capability})" });
            @out.push("$name: $state; operations: {@ops.join(', ')}");
        }
        @out.List;
    }

    method run(Cancel $cancel, Spec $spec, Control $ctl --> Outcome) {
        my (@steps, $name);
        if $spec.procedure.defined { @steps = @($spec.procedure<steps>); $name = $spec.procedure<name> }
        elsif $!script.defined { @steps = @$!script }
        else { @steps = default-script($spec.package) }
        my $out = Outcome.new(:status(STATUS-COMPLETED.Str), :end-reason<completed>, :summary('procedure completed'));   # .Str: a constant bound into an rw attribute is read-only under Raku++
        $out.summary = "procedure $name completed" if $name;
        my @conds = (^(@($spec.package<completion><conditions> // []).elems)).map({ %( met => False, proof => '' ) });
        my $touched = False;
        my $turns = 0;
        my %grants = $spec.grants.map({ $_ => True });
        my $arrived = 0;

        for @steps -> %step {
            return self!stopped($out, @conds, $touched, $turns) if $cancel.done;
            my ($n, $ok) = self!drain-directives($cancel, $ctl, False);
            return self!stopped($out, @conds, $touched, $turns) unless $ok;
            $arrived += $n;
            $turns++;
            if ($spec.limits<maxTurns> // 0) > 0 && $turns > $spec.limits<maxTurns> {
                $out.status = STATUS-FAILED; $out.end-reason = 'turn_limit';
                $out.errors.push("turn limit {$spec.limits<maxTurns>} reached");
                return finish($out, @conds, $touched, $turns);
            }
            given %step<kind> {
                when 'emit' { $ctl.emit.(EVENT-PROGRESS, %( text => %step<text> )) }
                when 'sleep' {
                    my $d = (try parse-duration(%step<duration>)) // 0;
                    return self!stopped($out, @conds, $touched, $turns) unless $cancel.sleep($d);
                }
                when 'await_directive' {
                    if $arrived > 0 { $arrived-- }
                    else {
                        my ($, $ok2) = self!drain-directives($cancel, $ctl, True);
                        return self!stopped($out, @conds, $touched, $turns) unless $ok2;
                    }
                }
                when 'write' {
                    unless %grants{CAP-REPO-WRITE} || %grants{CAP-FILES-WRITE} {
                        $out.denials.push('write ' ~ %step<path>);
                        $out.status = STATUS-FAILED; $out.end-reason = 'denied';
                        $out.errors.push("write to {%step<path>} is not granted");
                        return finish($out, @conds, $touched, $turns);
                    }
                    if $spec.workspace eq '' {
                        $out.status = STATUS-FAILED; $out.end-reason = 'no_workspace';
                        $out.errors.push('write requires a workspace');
                        return finish($out, @conds, $touched, $turns);
                    }
                    my $full = try inside-workspace($spec.workspace, %step<path>);
                    if $! {
                        $out.status = STATUS-FAILED; $out.end-reason = 'denied';
                        $out.errors.push($!.message);
                        return finish($out, @conds, $touched, $turns);
                    }
                    try { mkdir-p($full.parent); $full.spurt(%step<content>) };
                    return failed($out, @conds, $!.message) if $!;
                    $touched = True;
                    $ctl.emit.(EVENT-TOOL-RESULT, %( tool => 'write', path => %step<path> ));
                }
                when 'assert' {
                    my $i = %step<condition>;
                    @conds[$i - 1] = %( met => so %step<met>, proof => %step<proof> ) if 1 <= $i <= @conds;
                }
                when 'blocked' {
                    $out.status = STATUS-BLOCKED; $out.end-reason = 'blocked';
                    $out.blocked-on = %step<question>;
                    $out.summary = 'stopped to ask: ' ~ %step<question>;
                    return finish($out, @conds, $touched, $turns);
                }
                when 'no_change' {
                    $out.status = STATUS-NO-CHANGE; $out.end-reason = 'no_change';
                    $out.summary = %step<text> if %step<text> ne '';
                    return finish($out, @conds, $touched, $turns);
                }
                when 'fail' {
                    $out.status = STATUS-FAILED; $out.end-reason = 'failed';
                    $out.errors.push(%step<text>);
                    return finish($out, @conds, $touched, $turns);
                }
                when 'tool' {
                    my ($done, $stopped) = self!run-tool($cancel, $spec, $ctl, %step, $out);
                    if $done {
                        return self!stopped($out, @conds, $touched, $turns) if $stopped;
                        return finish($out, @conds, $touched, $turns);
                    }
                }
                when 'external_action' {
                    without $ctl.approval {
                        $out.status = STATUS-FAILED; $out.end-reason = 'denied';
                        $out.errors.push('external action with no approval gate');
                        return finish($out, @conds, $touched, $turns);
                    }
                    my ($check, $err) = $ctl.approval.(%step<action>, %step<target>, %step<params>);
                    $out.approval-check = $check;
                    with $err {
                        $out.status = STATUS-FAILED; $out.end-reason = 'approval_mismatch';
                        $out.denials.push('external_action ' ~ %step<action>);
                        $out.errors.push($err);
                        return finish($out, @conds, $touched, $turns);
                    }
                    $out.external-action = doc('ExternalAction',
                        proposalRef => $spec.package<approval><proposalRef>, approvalRef => $spec.package<approval><approvalRef>,
                        action => %step<action>, target => %step<target>, params => %step<params>,
                        performedAt => now-stamp(), result => 'recorded by the procedure executor');
                    $ctl.emit.(EVENT-TOOL-RESULT, %( tool => 'external_action', action => %step<action>, target => %step<target> ));
                }
                default { return failed($out, @conds, "unknown step kind \"{%step<kind>}\"") }
            }
        }
        finish($out, @conds, $touched, $turns);
    }

    #| Apply live directives and report how many were handled.  With
    #| block set it waits for exactly one.  A pause holds here until
    #| resume or cancellation; instructions received while paused are
    #| applied as they arrive but do not count as arrivals for await.
    #| Returns (count, ok); ok False means cancelled.
    method !drain-directives(Cancel $cancel, Control $ctl, Bool $block --> List) {
        my $box = $ctl.directives;
        without $box {
            return (0, False) if $block && !$cancel.wait-for($cancel.promise) || $block;
            return (0, True);
        }
        my sub handle(%d --> Bool) {
            given %d<kind> {
                when DIRECTIVE-PAUSE {
                    $ctl.emit.(EVENT-PAUSED, %( directiveId => %d<directiveId> ));
                    $ctl.applied.(%d<directiveId>);
                    loop {
                        my $r = $box.receive(:$cancel);
                        return False without $r;          # cancelled or closed
                        given $r<kind> {
                            when DIRECTIVE-RESUME {
                                $ctl.applied.($r<directiveId>);
                                $ctl.emit.(EVENT-RESUMED, %( directiveId => $r<directiveId> ));
                                return True;
                            }
                            when DIRECTIVE-PAUSE { $ctl.rejected.($r<directiveId>, 'already paused') }
                            default {
                                $ctl.emit.(EVENT-PROGRESS, %( instruction => $r<payload><text>, directiveId => $r<directiveId> ));
                                $ctl.applied.($r<directiveId>);
                            }
                        }
                    }
                }
                when DIRECTIVE-RESUME { $ctl.rejected.(%d<directiveId>, 'not paused') }
                when DIRECTIVE-CLARIFY | DIRECTIVE-STEER {
                    $ctl.emit.(EVENT-PROGRESS, %( instruction => %d<payload><text>, directiveId => %d<directiveId> ));
                    $ctl.applied.(%d<directiveId>);
                }
                default { $ctl.rejected.(%d<directiveId>, 'unsupported live directive ' ~ %d<kind>) }
            }
            True;
        }
        if $block {
            my $d = $box.receive(:$cancel);
            return (0, False) without $d;
            return (1, handle($d));
        }
        my $n = 0;
        loop {
            return ($n, False) if $cancel.done;
            my $d = $box.poll;
            return ($n, True) without $d;
            $n++;
            return ($n, False) unless handle($d);
        }
    }

    method !stopped(Outcome $out, @conds, Bool $touched, Int $turns --> Outcome) {
        $out.cost<basis> = COST-NONE;
        $out.status = STATUS-STOPPED;
        $out.end-reason = 'cancelled';
        $out.summary = 'stopped before the procedure finished';
        finish($out, @conds, $touched, $turns);
    }

    # A `tool` step reaches an externally bound program through the
    # bounded tool interface.  The runtime checks the grant the OPERATION
    # needs (never the tool as a whole), substitutes the procedure's
    # captures into the declared parameters, and lets the tool validate
    # them and build its own argument vector.  Returns (done, stopped).
    method !run-tool(Cancel $cancel, Spec $spec, Control $ctl, %step, Outcome $out --> List) {
        my sub fail(Str $reason, Str $msg) {
            $out.status = STATUS-FAILED; $out.end-reason = $reason; $out.summary = $msg;
            $out.errors.push($msg);
            (True, False);
        }
        my $t = %!tools{%step<tool>};
        return fail('tool_unavailable', "tool \"{%step<tool>}\" is not bound in this runtime") without $t;
        my $op = $t.op-of(%step<op>);
        return fail('unsupported_operation', "tool \"{%step<tool>}\" has no operation \"{%step<op>}\"") without $op;

        my $granted = is-in($op.capability, $spec.grants);
        # An operation this build never performs ends the procedure here,
        # whatever the grants: nothing runs, the call is recorded as not
        # performed, and the answer says both facts.
        if $op.unavailable ne '' {
            $out.tool-calls.push(doc('ToolCall', tool => %step<tool>, op => %step<op>, capability => $op.capability,
                ok => False, exitCode => -1, unavailable => $op.unavailable));
            $ctl.emit.(EVENT-TOOL-RESULT, %( tool => %step<tool>, op => %step<op>, ok => False, exitCode => -1, unavailable => $op.unavailable ));
            $out.status = STATUS-BLOCKED; $out.end-reason = 'execution_unavailable';
            $out.blocked-on = $op.unavailable;
            $out.blocked-on ~= "; {$op.capability} is not granted either" unless $granted;
            $out.blocked-on ~= " (proposal {$out.proposal<proposalId>}, digest {$out.proposal<proposalDigest>})" with $out.proposal;
            $out.summary = 'prepared, not executed: ' ~ $op.unavailable;
            return (True, False);
        }
        unless $granted {
            $out.denials.push(%step<tool> ~ '.' ~ %step<op>);
            return fail('denied', "{%step<tool>} {%step<op>} needs {$op.capability}, which is not granted");
        }

        # THE EXECUTION BOUNDARY.  A mutating operation with an executor
        # bound is performed only under an approval that names exactly
        # this plan, checked against a fresh observation taken by the
        # preceding plan step.
        if $op.mutates && $t.can('executor') && $t.executor.defined {
            return self!run-boundary($spec, $ctl, %step, $op, $t.executor, $out);
        }

        my %params;
        for (%step<params> // {}).kv -> $k, $v {
            my $val = substitute($v ~~ Str ?? $v !! '', $spec.captures);
            %params{$k} = $val if $val ne '';
        }
        $ctl.emit.(EVENT-TOOL-CALL, %( tool => %step<tool>, op => %step<op>, params => %params, capability => $op.capability ));

        my $res = try $t.run($cancel, %step<op>, %params);
        my %call = doc('ToolCall', tool => %step<tool>, op => %step<op>, capability => $op.capability, params => %params);
        if $! {
            # A refused call: nothing ran.  The refusal is the whole answer.
            my $msg = $!.message;
            %call<ok> = False; %call<exitCode> = -1;
            $out.tool-calls.push(%call);
            return (True, True) if $cancel.done && !$cancel.deadline-exceeded;
            return fail('tool_unavailable', $msg) if $msg.contains('not configured') || $msg.contains('not bound');
            return fail('invalid_parameters', $msg);
        }
        %call<argv> = [ |$res.argv ];
        %call<ok> = $res.ok; %call<exitCode> = $res.exit-code;
        %call<durationMs> = ($res.duration * 1000).Int;
        %call<unavailable> = $res.unavailable;
        %call<outputSha256> = $res.output-digest;
        %call<summary> = summarise(%step<op>, $res.data);
        $out.tool-calls.push(%call);
        $ctl.emit.(EVENT-TOOL-RESULT, %( tool => %step<tool>, op => %step<op>, ok => $res.ok, exitCode => $res.exit-code,
            argv => [ |$res.argv ], output => cap-tail($res.output, 4000), truncated => $res.truncated ));

        return (True, True) if $cancel.done;

        if $res.unavailable ne '' {
            $out.status = STATUS-BLOCKED; $out.end-reason = 'execution_unavailable';
            $out.blocked-on = $res.unavailable;
            $out.blocked-on ~= " (proposal {$out.proposal<proposalId>}, digest {$out.proposal<proposalDigest>})" with $out.proposal;
            $out.summary = 'prepared, not executed: ' ~ $res.unavailable;
            return (True, False);
        }

        given %step<op> {
            when 'plan' {
                return fail('engine_error', 'the engine returned no plan document: ' ~ cap-tail($res.output, 1000)) without $res.data;
                my %prop = build-proposal($spec, $res.data);
                $out.proposal = %prop;
                $ctl.emit.(EVENT-PROGRESS, %( text => "proposal {%prop<proposalId>} ({%prop<status>}): {%call<summary>}",
                    proposalId => %prop<proposalId>, proposalDigest => %prop<proposalDigest> ));
                if %prop<status> ne 'planned' {
                    $out.status = STATUS-BLOCKED; $out.end-reason = 'blocked';
                    $out.blocked-on = %prop<question>;
                    $out.summary = 'no plan: ' ~ %prop<question>;
                    return (True, False);
                }
                $out.summary = %call<summary>;
            }
            when 'status' {
                return fail('engine_error', 'status failed: ' ~ cap-tail($res.output, 1000)) unless $res.ok;
                return fail('engine_error', 'the engine returned no status document: ' ~ cap-tail($res.output, 1000)) without $res.data;
                $out.summary = %call<summary>;
            }
            default {
                return fail('engine_error', %step<op> ~ ' failed: ' ~ cap-tail($res.output, 1000)) unless $res.ok;
                $out.summary = %call<summary>;
            }
        }
        (False, False);
    }

    method !run-boundary(Spec $spec, Control $ctl, %step, Op $op, $ex, Outcome $out --> List) {
        my %call = doc('ToolCall', tool => %step<tool>, op => %step<op>, capability => $op.capability, ok => False, exitCode => -1);
        my $approval = $spec.package<approval>;
        if !$approval.defined || !$approval<proposal>.defined {
            %call<unavailable> = 'no approval bound to a proposal is attached to this package';
            $out.tool-calls.push(%call);
            $out.status = STATUS-BLOCKED; $out.end-reason = 'approval_required';
            $out.blocked-on = "executing needs a person's approval bound to a deployment proposal; none is attached to this package";
            $out.blocked-on ~= " (a fresh plan was prepared: proposal {$out.proposal<proposalId>}, digest {$out.proposal<proposalDigest>})" with $out.proposal;
            $out.summary = 'prepared, not executed: no approval';
            return (True, False);
        }
        my $approved = $approval<proposal>;
        my $fresh = $out.proposal;
        without $fresh {
            %call<unavailable> = 'no fresh plan preceded the execution';
            $out.tool-calls.push(%call);
            $out.status = STATUS-FAILED; $out.end-reason = 'no_fresh_plan';
            $out.errors.push('execution needs a fresh plan of the same target immediately before it');
            return (True, False);
        }
        my %check = doc('ApprovalCheck', paramsHashMatched => params-hash($approval<params>) eq $approval<paramsHash>);
        my $err;
        if $fresh<service> ne $approved<service> || $fresh<target> ne $approved<target> {
            $err = "the fresh plan is for {$fresh<service> ~ '@' ~ $fresh<target>}, the approval for {$approved<service> ~ '@' ~ $approved<target>}";
        }
        my $result = '';
        without $err {
            $result = try gate($approved, $approval, state-from($fresh, $approved), $ex);
            $err = $!.message if $!;
        }
        with $err {
            %check<operationMatched> = False; %check<detail> = $err;
            $out.approval-check = %check;
            $out.denials.push('execute ' ~ $approved<service> ~ '@' ~ $approved<target>);
            %call<unavailable> = 'refused: ' ~ $err;
            $out.tool-calls.push(%call);
            $out.status = STATUS-FAILED; $out.end-reason = 'approval_mismatch';
            $out.errors.push('approval: ' ~ $err);
            $out.summary = 'not executed: ' ~ $err;
            return (True, False);
        }
        %check<operationMatched> = True;
        %check<detail> = "the fresh plan matches the approved proposal {$approved<proposalId>} and the approval {$approval<approvalRef>}";
        $out.approval-check = %check;
        %call<ok> = True; %call<exitCode> = 0; %call<summary> = $result;
        $out.tool-calls.push(%call);
        $out.external-action = doc('ExternalAction', proposalRef => $approval<proposalRef>, approvalRef => $approval<approvalRef>,
            action => 'deploy', target => $approved<service> ~ '@' ~ $approved<target>, params => $approval<params>,
            performedAt => now-stamp(), result => "$result (executor: {$ex.name})");
        $ctl.emit.(EVENT-TOOL-RESULT, %( tool => %step<tool>, op => %step<op>, ok => True, executor => $ex.name, result => $result ));
        $out.summary = "executed under approval {$approval<approvalRef>}: $result";
        (False, False);
    }
}

#| What the fake adapter does with no script: it asserts every condition
#| met with a labelled proof and completes.
sub default-script(%wp --> List) {
    my @steps = %( kind => 'emit', text => 'fake adapter: starting' ),;
    for @(%wp<completion><conditions> // []).kv -> $i, $ {
        @steps.push(%( kind => 'assert', condition => $i + 1, met => True, proof => 'fake adapter: asserted without evidence' ));
    }
    @steps.List;
}

sub finish(Outcome $out, @conds, Bool $touched, Int $turns --> Outcome) {
    $out.conditions = @conds;
    $out.cost<turns> = $turns;
    $out.cost<basis> = COST-NONE;      # deterministic: no model was used
    if !$touched && $out.status eq STATUS-COMPLETED && !$out.external-action.defined && all-met(@conds) && @conds == 0 {
        $out.summary = ($out.summary ~ ' (no conditions were declared)').trim;
    }
    $out;
}

sub failed(Outcome $out, @conds, Str $err --> Outcome) {
    $out.status = STATUS-FAILED; $out.end-reason = 'failed';
    $out.errors.push($err);
    $out.conditions = @conds;
    $out;
}

#| The engine's plan document wrapped as a deployment-proposal.v1, the
#| engine-owned sections carried verbatim.
sub build-proposal(Spec $spec, %data --> Hash) is export {
    my sub str($m, Str $k) { my $v = $m ~~ Associative ?? $m{$k} !! Any; $v ~~ Str ?? $v !! '' }
    my sub obj(Str $k) { my $v = %data{$k}; $v ~~ Associative ?? %($v) !! Any }
    my sub arr(Str $k) { my $v = %data{$k}; $v ~~ Positional ?? [ |@$v ] !! Any }
    my sub strs(Str $k) { [ |(@(%data{$k} ~~ Positional ?? %data{$k} !! []).grep(Str)) ] }
    my $svc = obj('service');
    my %p = doc('DeploymentProposal', schema => SCHEMA-DEPLOYMENT-PROPOSAL, proposalId => new-ulid(),
        packageId => $spec.package<packageId>, supersedesPackageId => $spec.package<supersedesPackageId>,
        operation => 'deploy', status => str(%data, 'status'), question => str(%data, 'question'),
        service => str($svc, 'name'), target => str($svc, 'target'),
        targetHost => obj('targetHost'), repository => obj('repository'), revision => obj('revision'),
        manifest => obj('manifest'), engine => obj('engine'), observed => obj('observed'),
        operations => arr('operations'), checks => arr('checks'), unperformed => strs('unperformed'),
        blockers => strs('blockers'), health => obj('health'), rollback => obj('rollback'),
        engineCommands => arr('commands'), observedAt => str(%data, 'observedAt'));
    with $spec.agent {
        %p<agent> = doc('AgentRef', id => .id, version => .manifest<version>, digest => .digest);
    }
    %p<status> = 'blocked' if %p<status> eq '';
    %p<question> = 'the engine could not plan and gave no reason' if %p<status> eq 'blocked' && %p<question> eq '';
    %p<observedAt> = now-stamp() if %p<observedAt> eq '';
    %p<proposalDigest> = proposal-digest(%p);
    %p;
}

#| The built-in procedure executor.
sub new-procedure(:%tools --> ProcedureAdapter) is export { ProcedureAdapter.new(:adapter-name<procedure>, :%tools) }

#| The deterministic fake adapter with an optional script.
sub new-fake($script = Any, :%controls, Bool :$install-fails = False, Str :$name = 'fake' --> ProcedureAdapter) is export {
    ProcedureAdapter.new(:adapter-name($name), :$script, :fake-controls(%controls), :fake-install-fails($install-fails));
}

# ------------------------------------------------------------ claude code

#| Neutral grants onto Claude Code tool names.  It is the whole policy:
#| under dontAsk anything not listed is denied.
constant CLAUDE-CODE-TOOLS is export = %(
    CAP-REPO-READ,   ['Read', 'Glob', 'Grep'],
    CAP-FILES-READ,  ['Read', 'Glob', 'Grep'],
    CAP-REPO-WRITE,  ['Edit', 'Write'],
    CAP-FILES-WRITE, ['Edit', 'Write'],
    CAP-SHELL-RUN,   ['Bash'],
    CAP-NET-FETCH,   ['WebFetch', 'WebSearch'],
);

#| The harness's own account of a run, read off its result object.
class Summary is export {
    has Str $.summary = '';
    has Str $.stop-reason = '';
    has Str $.terminal-reason = '';
    has Bool $.is-error = False;
    has Str $.session-ref = '';
    has Numeric $.cost-usd = 0;
    has Int $.turns = 0;
    has @.denials;
    has Bool $.blocked = False;
    has Str $.blocked-on = '';
    has @.errors;
    has Bool $.no-change = False;
    has @.conditions;
}

sub str-of($v --> Str) { $v ~~ Str ?? $v !! '' }

#| A result object read out of one line; Summary:U for anything that is
#| not one.
sub parse-envelope(Str $line --> Summary) is export {
    my $env = try parse-json($line);
    return Summary if $! || $env !~~ Associative || $env<type> ne 'result';
    my @denials;
    for @($env<permission_denials> // []) -> $d {
        if $d ~~ Str { @denials.push($d) }
        elsif $d ~~ Associative && $d<tool_name> ~~ Str && $d<tool_name> ne '' { @denials.push($d<tool_name>) }
        else { @denials.push(encode-json($d)) }
    }
    my %args = summary => str-of($env<result>), stop-reason => str-of($env<stop_reason>), terminal-reason => str-of($env<terminal_reason>),
        is-error => so $env<is_error>, session-ref => str-of($env<session_id>),
        cost-usd => ($env<total_cost_usd> ~~ Numeric ?? $env<total_cost_usd> !! 0),
        turns => ($env<num_turns> ~~ Numeric ?? $env<num_turns>.Int !! 0),
        denials => @denials, errors => [ |@($env<errors> // []).grep(Str) ];
    if $env<structured_output> ~~ Associative {
        my $o = $env<structured_output>;
        %args<summary> = $o<summary> if $o<summary> ~~ Str && $o<summary> ne '';
        %args<blocked> = str-of($o<status>) eq 'blocked';
        %args<blocked-on> = str-of($o<blocked_on>);
        %args<no-change> = str-of($o<status>) eq 'no_change';
        %args<conditions> = [ @($o<conditions> // []).grep(Associative).map({ %( met => so $_<met>, proof => str-of($_<proof>) ) }) ];
    }
    # The list attributes are passed from @ variables, not through %args: a
    # hash value is an item, and an item bound to an @ attribute is one
    # element (Rakudo and Raku++ 5.1 agree; 4.0.1 flattened it).
    my @d = @(%args<denials>:delete);
    my @e = @(%args<errors>:delete);
    my @c = @(%args<conditions>:delete // []);
    Summary.new(|%args, :denials(@d), :errors(@e), :conditions(@c));
}

sub first-line(Str $s, Int $max --> Str) {
    my $l = $s.contains("\n") ?? $s.substr(0, $s.index("\n")) !! $s;
    $l.chars > $max ?? $l.substr(0, $max) ~ '…' !! $l;
}

sub tool-target($input --> Str) {
    return '' unless $input ~~ Associative;
    return $input<file_path>.IO.basename if $input<file_path> ~~ Str && $input<file_path> ne '';
    return first-line($input<command>, 60) if $input<command> ~~ Str && $input<command> ne '';
    return first-line($input<pattern>, 40) if $input<pattern> ~~ Str && $input<pattern> ne '';
    '';
}

#| Read the harness's event stream, one line at a time: writes a readable
#| transcript, emits tool events, and returns (envelope or Summary:U,
#| session id from the init event).
class StreamConsumer is export {
    has $.transcript;          # an IO::Handle or Any
    has Control $.ctl;
    has Summary $.envelope;
    has Str $.session = '';

    method line(Str $line) {
        return if $line.trim eq '';
        with parse-envelope($line) { $!envelope = $_; return }
        my $ev = try parse-json($line);
        return if $! || $ev !~~ Associative;
        given str-of($ev<type>) {
            when 'system' {
                $!session = $ev<session_id> if str-of($ev<subtype>) eq 'init' && str-of($ev<session_id>) ne '';
            }
            when 'rate_limit_event' { self!say("  · rate limited, waiting") }
            when 'assistant' {
                my $msg = $ev<message>;
                for @(($msg ~~ Associative ?? $msg<content> !! []) // []) -> $c {
                    next unless $c ~~ Associative;
                    given str-of($c<type>) {
                        when 'tool_use' {
                            next if str-of($c<name>) eq 'StructuredOutput';
                            my $target = tool-target($c<input>);
                            self!say('  · ' ~ (str-of($c<name>) ~ ' ' ~ $target).trim);
                            $!ctl.emit.(EVENT-TOOL-CALL, %( tool => str-of($c<name>), target => $target )) with $!ctl;
                        }
                        when 'text' {
                            my $t = str-of($c<text>).trim;
                            if $t ne '' {
                                self!say($t);
                                $!ctl.emit.(EVENT-PROGRESS, %( text => cap-tail($t, 500) )) with $!ctl;
                            }
                        }
                    }
                }
            }
        }
    }

    method !say(Str $s) { with $!transcript { .say($s) } }
}

sub consume-stream(@lines, $transcript, Control $ctl --> List) is export {
    my $c = StreamConsumer.new(:$transcript, :$ctl);
    $c.line($_) for @lines;
    ($c.envelope, $c.session);
}

#| Drives the `claude` CLI in non-interactive print mode.
#|
#| What it enforces and how:
#|   tool_allowlist     --permission-mode dontAsk --allowedTools <mapped grants>
#|   structured_output  --json-schema; the result carries structured_output
#|   turn_limit         --max-turns
#|   spend_limit        --max-budget-usd
#|   timeout            the runner's cancellation plus SIGTERM
#|   event_stream       --output-format stream-json is read line by line
#|   session_continue   --resume <session id> on a later attempt
#|   graceful_stop      SIGTERM, then SIGKILL after a wait
#| What it does not enforce, and says so: repo_scope, network_deny,
#| live_steer, pause.
class ClaudeCode does Adapter is export {
    has Str $.binary = '';           # '' means "claude"; the CLI sets it from DO321_CLAUDE_BINARY
    has Numeric $.kill-wait = 15;
    has $.stderr;                    # where the harness's stderr is teed; Any discards
    has $.transcript;                # readable transcript of the stream; Any discards
    has %.env;                       # replaces the environment when given (tests)

    method name(--> Str) { 'claude_code' }

    method !binary(--> Str) { $!binary ne '' ?? $!binary !! 'claude' }

    method detect(--> Detection) {
        my $bin = self!binary;
        my $path = ($bin.contains('/') || $bin.contains('\\')) ?? ($bin.IO.f ?? $bin.IO !! IO::Path) !! on-path($bin);
        return Detection.new(:reason("$bin is not on PATH")) without $path;
        my $p = try run $path.Str, '--version', :out, :err;
        return Detection.new(:available, :version<unknown>) if $! || !$p.defined;
        my $out = $p.out.slurp(:close); $p.err.slurp(:close);
        return Detection.new(:available, :version<unknown>) unless $p.exitcode == 0;
        Detection.new(:available, :version($out.trim));
    }

    method enforcement(--> Hash) {
        %( FEAT-TOOL-ALLOWLIST, True, FEAT-STRUCTURED-OUTPUT, True, FEAT-TURN-LIMIT, True, FEAT-SPEND-LIMIT, True,
           FEAT-TIMEOUT, True, FEAT-EVENT-STREAM, True, FEAT-SESSION-CONTINUE, True, FEAT-GRACEFUL-STOP, True,
           FEAT-REPO-SCOPE, False, FEAT-NETWORK-DENY, False, FEAT-LIVE-STEER, False, FEAT-PAUSE, False );
    }

    #| Claude Code runs hooks at a session's start, around every tool call
    #| and at a turn's end.  A hook before a tool call can refuse it, so
    #| writes, shell commands and any other action that is a tool call can
    #| be intercepted; a hook after one can only comment.  A commit is a
    #| shell command there, so it is caught as one and not at a commit hook
    #| of the harness's own.  Network use from inside a shell command is
    #| invisible to it.  A hook can ask the person at an interactive
    #| session to decide; a headless run has nobody to ask, which is what
    #| headless-controls reports.
    method controls(--> Hash) {
        %( CTRL-AUTHORITATIVE-CONTEXT, STRENGTH-ENFORCES, CTRL-PRE-ACTION, STRENGTH-ENFORCES,
           CTRL-PRE-TOOL, STRENGTH-ENFORCES, CTRL-FILESYSTEM-GUARD, STRENGTH-ENFORCES,
           CTRL-SHELL-GUARD, STRENGTH-ENFORCES, CTRL-POST-RUN, STRENGTH-ENFORCES,
           CTRL-HUMAN-APPROVAL, STRENGTH-ENFORCES,
           CTRL-POST-TOOL, STRENGTH-ADVISES, CTRL-POST-ACTION, STRENGTH-ADVISES,
           CTRL-NETWORK-GUARD, STRENGTH-NONE, CTRL-PRE-COMMIT, STRENGTH-NONE, CTRL-POST-COMMIT, STRENGTH-NONE );
    }
    method headless-controls(--> Hash) {
        my %c = self.controls;
        %c{CTRL-HUMAN-APPROVAL} = STRENGTH-NONE;
        %c;
    }
    method can-register-hooks(--> Bool) { True }

    method wiring-path(--> Str) { CLAUDE-SETTINGS }
    method install-controller(IO::Path $workspace, Str $self, Str $controller, @controls --> Str) {
        claude-install($workspace, $self, $controller, @controls);
    }
    method remove-controller(IO::Path $workspace, Str $controller --> Str) { claude-remove($workspace, $controller) }
    method verify-controller(IO::Path $workspace, Str $controller, @controls --> Hash) { claude-verify($workspace, $controller, @controls) }
    method translate-event(Str $control, %native --> Action) {
        my ($event) = claude-event($control);
        ($event // '') eq 'PreToolUse' || ($event // '') eq 'PostToolUse' ?? claude-action(%native) !! Action;
    }
    method answer(Str $control, Verdict $v, Bool :$headless = False --> List) { claude-answer($control, $v, :$headless) }
    method final-words(%native --> Str) { claude-last-words((%native<transcript_path> // '').Str) }

    #| The whole invocation, exported so the surface is testable without a
    #| process.
    method args(Spec $spec --> List) {
        my @tools = tool-names($spec.grants, CLAUDE-CODE-TOOLS);
        @tools.push('TodoWrite');
        my @args = '-p', $spec.prompt, '--output-format', 'stream-json', '--verbose',
            '--permission-mode', 'dontAsk', '--allowedTools', @tools.join(',');
        @args.push('--json-schema', $spec.output-schema) if $spec.output-schema ne '';
        @args.push('--max-turns', ($spec.limits<maxTurns> // 0).Str) if ($spec.limits<maxTurns> // 0) > 0;
        @args.push('--max-budget-usd', sprintf('%.2f', $spec.limits<maxUsd>)) if ($spec.limits<maxUsd> // 0) > 0;
        @args.push('--resume', $spec.session-ref) if $spec.session-ref ne '';
        # Hooks for this run only: handed to the harness on its command
        # line, so the caller's settings file is not written.
        if $spec.hook-controls && $spec.hook-self ne '' {
            my $settings = claude-run-settings($spec.hook-self, $spec.hook-controls);
            @args.push('--settings', $settings) if $settings ne '';
        }
        with $spec.overlay {
            my $o = try parse-json($_);
            @args.push('--model', $o<model>) if !$! && $o ~~ Associative && $o<model> ~~ Str && $o<model> ne '';
        }
        @args.List;
    }

    method run(Cancel $cancel, Spec $spec, Control $ctl --> Outcome) {
        my $start = now;
        my $proc = Proc::Async.new(|launch-argv(self!binary, self.args($spec), %!env, $spec.hook-env));
        my $consumer = StreamConsumer.new(:transcript($!transcript), :$ctl);
        my $err = '';
        my $lock = Lock.new;
        $proc.stdout.lines.tap(-> $l { $lock.protect({ $consumer.line($l) }) });
        $proc.stderr.tap(-> $s { $err ~= $s; with $!stderr { .print($s) } });
        my $started = try $proc.start(|($spec.workspace ne '' ?? (:cwd($spec.workspace)) !! ()));
        if $! {
            my $out = Outcome.new;
            $out.status = STATUS-FAILED; $out.end-reason = 'process_failed';
            $out.errors.push("claude_code: process did not start: {$!.message}");
            return $out;
        }
        my $done = Promise.new;
        start { my $r = try await $started; $done.keep($r // Any) }
        await Promise.anyof($done, $cancel.promise);
        unless $done.status ~~ Kept {
            try $proc.kill(SIGTERM);
            await Promise.anyof($done, Promise.in($!kill-wait));
            try $proc.kill(SIGKILL) unless $done.status ~~ Kept;
            await $done;
        }
        my $result = await $done;
        my $exit = $result.defined ?? $result.exitcode !! -1;
        my ($env, $session) = $lock.protect({ ($consumer.envelope, $consumer.session) });
        my $out = Outcome.new(:cost(doc('Cost', basis => COST-UNREPORTED)), :session-ref($session));
        with $env {
            $out.summary = .summary;
            $out.session-ref = .session-ref if .session-ref ne '';
            $out.cost = doc('Cost', usd => .cost-usd, turns => .turns, basis => COST-HARNESS);
            $out.denials = [ |.denials ];
            $out.errors = [ |.errors ];
            $out.conditions = [ |.conditions ];
            $out.blocked-on = .blocked-on;
        }
        if $cancel.done {
            $out.status = STATUS-STOPPED; $out.end-reason = 'cancelled';
            $out.summary = 'stopped before the harness finished' if $out.summary eq '';
        }
        elsif !$env.defined && $exit != 0 {
            $out.status = STATUS-FAILED; $out.end-reason = 'process_failed';
            $out.errors.push("exit $exit: " ~ cap-tail($err, 2048));
        }
        elsif $env.defined && $env.blocked { $out.status = STATUS-BLOCKED; $out.end-reason = 'blocked' }
        elsif $env.defined && $env.is-error {
            $out.status = STATUS-FAILED; $out.end-reason = 'harness_error';
            $out.errors.push('the harness stopped: ' ~ $env.terminal-reason) if !$out.errors && $env.terminal-reason ne '';
        }
        elsif $env.defined && $env.no-change { $out.status = STATUS-NO-CHANGE; $out.end-reason = 'no_change' }
        elsif !$env.defined {
            $out.status = STATUS-FAILED; $out.end-reason = 'no_result';
            $out.errors.push('the harness exited without a result object');
        }
        else { $out.status = STATUS-COMPLETED; $out.end-reason = 'completed' }
        $ctl.emit.(EVENT-COST, %( usd => $out.cost<usd>, turns => $out.cost<turns>, durationMs => ((now - $start) * 1000).Int ));
        $out;
    }
}
