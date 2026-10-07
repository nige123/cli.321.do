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
        %operating{$c} = $strength if $wanted && $strength ne STRENGTH-NONE && ($state eq 'installed' || $state eq 'legacy');
        @rows.push(%( control => $c, label => control-label($c), harness => $strength, wanted => $wanted, state => $state ));
        @warnings.push("{control-label($c)} is not available in {$adapter.name}: this harness cannot intercept it.")
            if $strength eq STRENGTH-NONE && ($wanted || is-in($c, [CTRL-NETWORK-GUARD, CTRL-PRE-COMMIT]));
        @warnings.push("{control-label($c)} is wired the old way (the controller's own hook command); install again to route it through 321.")
            if $state eq 'legacy';
        @warnings.push("{control-label($c)} only advises in {$adapter.name}: text reaches the model, nothing is refused.")
            if $wanted && $strength eq STRENGTH-ADVISES;
    }
    my @levels = (%found && %found<available>) ?? levels-from(%operating, $controller.answers) !! ();
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
sub install-enforcement(Adapter $adapter, Controller $controller, IO::Path $workspace, Str $self --> Hash) is export {
    my %caps = $adapter.controls;
    my @can = $controller.wants.grep({ control-strength(%caps, $_) ne STRENGTH-NONE });
    my $action = try $adapter.install-controller($workspace, $self, $controller.name, @can);
    my $error = $! ?? $!.message.trim !! '';
    my %s = enforcement-status($adapter, $controller, $workspace);
    %s<action> = $error ne '' ?? 'failed' !! $action;
    %s<error> = $error if $error ne '';
    # Verified, not assumed: every control that should be there is.
    my @missing = %s<controls>.grep({ $_<wanted> && $_<harness> ne STRENGTH-NONE && $_<state> ne 'installed' }).map(*<label>);
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
        my $say = !%c<wanted> ?? (%c<harness> eq STRENGTH-NONE ?? 'no' !! 'available, not used')
            !! %c<state> eq 'installed' ?? (%c<harness> eq STRENGTH-ADVISES ?? 'yes (advises only)' !! 'yes')
            !! %c<state> eq 'unavailable' ?? 'no'
            !! %c<state> eq 'legacy' ?? 'yes (old wiring)'
            !! 'not installed';
        @l.push(sprintf('%-24s %s', %c<label>, $say));
    }
    @l.push('');
    @l.push("Effective enforcement: {%s<headline>}" ~ (%s<levels> ?? " ({@(%s<levels>).join(', ')})" !! ''));
    if %s<warnings> { @l.push(''); @l.push('Warning:'); @l.push("  $_") for @(%s<warnings>) }
    @l.List;
}
