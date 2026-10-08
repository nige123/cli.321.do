# Copyright Nige Ltd. Author: Nigel Hamilton.
unit module Do321::Enforcement;

#| What is actually protecting a piece of work: for one harness and one
#| controller, which controls the harness has, which the controller
#| wants, which are really wired, and what that adds up to.
#|
#| Four levels, as separate facts rather than a ladder, because one can
#| hold without another:
#|
#|     aware     the agent is given the controller's context
#|     checked   changes are checked against it
#|     guarded   consequential operations are intercepted before they run
#|     verified  the finished result was checked, with evidence
#|
#| A status can show the first three (what is wired).  'verified' is
#| earned by a run and recorded on its receipt.  The headline is the
#| strongest of aware < checked < guarded that holds; a context in a
#| prompt is never reported as interception.

use Do321::Protocol;
use Do321::Controller;
use Do321::Adapter;

constant PROTECT-AWARE    is export = 'aware';
constant PROTECT-CHECKED  is export = 'checked';
constant PROTECT-GUARDED  is export = 'guarded';
constant PROTECT-VERIFIED is export = 'verified';

sub protections(--> List) is export { (PROTECT-AWARE, PROTECT-CHECKED, PROTECT-GUARDED, PROTECT-VERIFIED) }

my @GUARDS = CTRL-FILESYSTEM-GUARD, CTRL-SHELL-GUARD, CTRL-PRE-TOOL, CTRL-PRE-ACTION;

#| The headline for a set of levels: the strongest of aware, checked and
#| guarded, in capitals; NONE when none holds.
sub headline(@levels --> Str) is export {
    for PROTECT-GUARDED, PROTECT-CHECKED, PROTECT-AWARE -> $l { return $l.uc if is-in($l, @levels) }
    'NONE';
}

#| The levels a set of operating controls gives.  %operating is control =>
#| strength for the controls that are really wired (or that the runtime
#| operates itself); @answers is what the controller can answer.
sub levels-from(%operating, @answers --> List) is export {
    my @l;
    @l.push(PROTECT-AWARE) if control-strength(%operating, CTRL-AUTHORITATIVE-CONTEXT) ne STRENGTH-NONE && is-in(POINT-CONTEXT, @answers);
    @l.push(PROTECT-CHECKED) if control-strength(%operating, CTRL-POST-RUN) ne STRENGTH-NONE && is-in(POINT-CHANGE, @answers);
    @l.push(PROTECT-GUARDED) if is-in(POINT-ACTION, @answers) && so @GUARDS.grep({ control-strength(%operating, $_) eq STRENGTH-ENFORCES });
    @l.List;
}

#| What a controller's own old hook command does at a control, in words:
#| the truth about wiring 321 did not write and does not drive.
sub legacy-does(Str $control --> Str) is export {
    given $control {
        when CTRL-AUTHORITATIVE-CONTEXT { 'it delivers the context at session start' }
        when CTRL-FILESYSTEM-GUARD      { 'it refuses one edit made before the context was delivered, and checks no action' }
        when CTRL-POST-RUN              { 'it refuses one turn end that changed files without a report, and checks no change' }
        default                         { 'it is not driven by 321' }
    }
}

#| The status of one controller in one harness for a workspace.
sub enforcement-status(Adapter $adapter, Controller $controller, IO::Path $workspace, Bool :$headless = False --> Hash) is export {
    my %found = $controller.discover($workspace.Str);
    my %caps = $headless ?? $adapter.headless-controls !! $adapter.controls;
    my @wants = $controller.wants;
    my %wired = %found ?? $adapter.verify-controller($workspace, $controller.name, @wants) !! %();
    my $det = $adapter.detect;
    my (@rows, %operating, @warnings);
    for controls() -> $c {
        my $strength = control-strength(%caps, $c);
        my $wanted = is-in($c, @wants);
        my $state = !$wanted ?? 'not used'
            !! $strength eq STRENGTH-NONE ?? 'unavailable'
            !! (%wired{$c} // 'missing');
        # The old direct wiring delivers the context and looks for a report;
        # it does not put actions or the change to the controller, so it
        # counts for context and nothing more.
        %operating{$c} = $strength if $wanted && $strength ne STRENGTH-NONE
            && ($state eq 'installed' || ($state eq 'legacy' && $c eq CTRL-AUTHORITATIVE-CONTEXT));
        @rows.push(%( control => $c, label => control-label($c), harness => $strength, wanted => $wanted, state => $state ));
        @warnings.push("{control-label($c)} is not available in {$adapter.name}: this harness cannot intercept it.")
            if $strength eq STRENGTH-NONE && ($wanted || is-in($c, [CTRL-NETWORK-GUARD, CTRL-PRE-COMMIT]));
        @warnings.push("{control-label($c)} is wired the old way (the controller's own hook command): {legacy-does($c)}. It is still active and is left exactly as it is; install to route it through 321.")
            if $state eq 'legacy';
        # Telling is all a context ever is, in any harness, so that one needs
        # no warning; a guard or an end check that can only advise does.
        @warnings.push("{control-label($c)} only advises in {$adapter.name}: text reaches the model, nothing is refused.")
            if $wanted && $strength eq STRENGTH-ADVISES && $c ne CTRL-AUTHORITATIVE-CONTEXT;
    }
    my @levels = (%found && %found<available>) ?? levels-from(%operating, $controller.answers) !! ();
    # Asking a person is not wired separately: a guard that meets
    # needs_human asks through the harness, where the harness can.
    my $guarding = so @GUARDS.grep({ (%operating{$_} // '') eq STRENGTH-ENFORCES });
    for @rows -> %row {
        next unless %row<control> eq CTRL-HUMAN-APPROVAL && %row<harness> ne STRENGTH-NONE;
        %row<state> = $guarding ?? 'through the guards' !! 'no guard installed to ask through';
    }
    @warnings.unshift("{$controller.name} cannot be driven here: {%found<reason>}") if %found && !%found<available>;
    @warnings.unshift("{$adapter.name} was not detected here ({$det.reason}); the wiring is written for when it is.") if %found && !$det.available;
    %(
        schema     => 'enforcement.v1',
        harness    => $adapter.name,
        detected   => $det.available,
        controller => $controller.name,
        applies    => so %found,
        subject    => (%found<subject> // ''),
        digest     => (%found<digest> // ''),
        available  => so (%found<available> // False),
        wiring     => $adapter.wiring-path,
        managedBy  => (@rows.grep({ $_<state> eq 'installed' }) ?? '321'
                        !! @rows.grep({ $_<state> eq 'legacy' }) ?? "legacy {$controller.name} wiring" !! ''),
        legacy     => [ |@rows.grep({ $_<state> eq 'legacy' }).map(*<control>) ],
        # How strong the old wiring is, said separately from the levels: it
        # refuses things of its own (strict) or only tells (advisory), and
        # either way it puts no action and no change to the controller.
        legacyMode => (@rows.grep({ $_<state> eq 'legacy' && $_<control> ne CTRL-AUTHORITATIVE-CONTEXT }) ?? 'strict'
                        !! @rows.grep({ $_<state> eq 'legacy' }) ?? 'advisory' !! ''),
        controls   => @rows,
        levels     => [ |@levels ],
        headline   => headline(@levels),
        warnings   => @warnings,
        note       => 'what is wired, not what happened: a run\'s receipt records the checks that ran and whether the result was verified',
    );
}

#| Wire a controller into a harness for a workspace and report what is
#| really there afterwards.  Returns the status with an 'action' of
#| installed, updated, unchanged or failed (with 'error').
#| :advisory wires only the context: the agent is told, and nothing is
#| refused.  A project can start there and install fully later.
sub install-enforcement(Adapter $adapter, Controller $controller, IO::Path $workspace, Str $self, Bool :$advisory = False --> Hash) is export {
    my %caps = $adapter.controls;
    # Every hook 321 writes calls 321, which has to be able to ask the
    # controller.  Where it cannot (the controller is missing, or too old
    # to be driven), wiring it in would replace whatever works today with
    # hooks that can only fail.  So nothing is written and nothing already
    # there is touched: an older direct wiring keeps doing what it does.
    my %found = $controller.discover($workspace.Str);
    if %found && !%found<available> {
        my %s = enforcement-status($adapter, $controller, $workspace);
        %s<action> = 'failed';
        %s<mode>   = $advisory ?? 'advisory' !! 'full';
        %s<error>  = "{$controller.name} cannot be driven here ({%found<reason>}), so nothing was wired and nothing was changed."
            ~ (@(%s<legacy>) ?? " The hooks an earlier {$controller.name} wrote are untouched and still active." !! '')
            ~ " Make {$controller.name} drivable, then install again.";
        return %s;
    }
    # What is already wired here is never taken away by an install: an
    # advisory install over fuller wiring, or over a controller's own old
    # hook commands, keeps every moment that was covered.  Removing is
    # `remove`'s job.  Old commands are adopted: each is replaced by
    # 321's command for the same moment, once.
    my %was = $adapter.verify-controller($workspace, $controller.name, $controller.wants);
    my @legacy = $controller.wants.grep({ (%was{$_} // '') eq 'legacy' });
    my @intended = $advisory
        ?? $controller.wants.grep({ $_ eq CTRL-AUTHORITATIVE-CONTEXT || is-in((%was{$_} // ''), ['installed', 'legacy']) })
        !! $controller.wants;
    my @can = @intended.grep({ control-strength(%caps, $_) ne STRENGTH-NONE });
    my $action = try $adapter.install-controller($workspace, $self, $controller.name, @can);
    my $error = $! ?? $!.message.trim !! '';
    my %s = enforcement-status($adapter, $controller, $workspace);
    $action = 'adopted' if $error eq '' && @legacy && is-in(($action // ''), ['installed', 'updated']);
    %s<action> = $error ne '' ?? 'failed' !! $action;
    %s<error> = $error if $error ne '';
    %s<adopted> = [ |@legacy ] if %s<action> eq 'adopted';
    # Verified, not assumed: every control that should be there is.
    my @missing = %s<controls>.grep({ is-in($_<control>, @can) && $_<state> ne 'installed' }).map(*<label>);
    %s<mode> = $advisory ?? 'advisory' !! 'full';
    if $error eq '' && @missing {
        %s<action> = 'failed';
        %s<error> = "after installing, these are still not wired: {@missing.join(', ')}";
    }
    %s;
}

sub remove-enforcement(Adapter $adapter, Controller $controller, IO::Path $workspace --> Hash) is export {
    my $action = try $adapter.remove-controller($workspace, $controller.name);
    my $error = $! ?? $!.message.trim !! '';
    my %s = enforcement-status($adapter, $controller, $workspace);
    %s<action> = $error ne '' ?? 'failed' !! $action;
    %s<error> = $error if $error ne '';
    %s;
}

#| The status as lines for a terminal.
sub status-lines(%s --> List) is export {
    my @l;
    unless %s<applies> {
        @l.push("Project: no {%s<controller>.uc} here");
        @l.push("Harness: {%s<harness>}" ~ (%s<detected> ?? '' !! ' (not detected)'));
        @l.push('Nothing to enforce.');
        return @l.List;
    }
    @l.push("Project: {%s<controller>.uc} " ~ (%s<available> ?? 'enabled' !! 'present, not driven') ~ " ({%s<subject>})");
    @l.push("Harness: {%s<harness>}" ~ (%s<detected> ?? '' !! ' (not detected)'));
    @l.push('');
    for @(%s<controls>) -> %c {
        next unless %c<wanted> || is-in(%c<control>, [CTRL-NETWORK-GUARD, CTRL-PRE-COMMIT, CTRL-HUMAN-APPROVAL]);
        my $say = %c<control> eq CTRL-HUMAN-APPROVAL && %c<harness> ne STRENGTH-NONE
                ?? (%c<state> eq 'through the guards' ?? 'yes (a guard asks the person at the session)' !! 'not installed')
            !! !%c<wanted> ?? (%c<harness> eq STRENGTH-NONE ?? 'no' !! 'available, not used')
            !! %c<state> eq 'installed' ?? (%c<control> eq CTRL-AUTHORITATIVE-CONTEXT ?? 'yes (told to the agent; nothing is refused)'
                                            !! %c<harness> eq STRENGTH-ADVISES ?? 'yes (advises only)' !! 'yes')
            !! %c<state> eq 'unavailable' ?? 'no'
            !! %c<state> eq 'legacy' ?? 'old wiring, still active'
            !! 'not installed';
        @l.push(sprintf('%-24s %s', %c<label>, $say));
    }
    @l.push('');
    @l.push("Effective enforcement: {%s<headline>}" ~ (%s<levels> ?? " ({@(%s<levels>).join(', ')})" !! ''));
    if @(%s<legacy> // []) {
        @l.push("Managed by: legacy {%s<controller>.uc} wiring (its own hook commands in {%s<wiring>}; still active, left as it is)");
        @l.push("Legacy wiring: {%s<legacyMode> // 'advisory'} (" ~ @(%s<legacy>).map({ legacy-does($_) }).join('; ') ~ ')');
        @l.push("Migration: 321 {%s<controller>} install adopts it: each old command is replaced by 321's, once");
    }
    elsif (%s<managedBy> // '') eq '321' { @l.push('Managed by: 321') }
    if %s<warnings> { @l.push(''); @l.push('Warning:'); @l.push("  $_") for @(%s<warnings>) }
    @l.List;
}
