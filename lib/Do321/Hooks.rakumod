unit module Do321::Hooks;

#| Harness hooks: wiring a harness-neutral hook command into whatever
#| harnesses 321 knows, and saying honestly what each of them enforces.
#|
#| The command is somebody else's (iz4's `iz4 hook`, say): it reads the
#| harness's JSON on standard input, prints for the model on standard
#| output, and refuses with exit code 2.  321 knows the harnesses'
#| configuration files, event names and quirks, so it writes the wiring
#| and keeps up with them; the command's owner keeps the protocol.
#|
#| Three events are wired: session-start, pre-edit and stop.  A harness
#| that can refuse an edit or a turn end at a hook enforces those; one
#| that only injects text at a session start advises.  Everything here
#| merges: entries that are not ours are kept, ours are replaced, and
#| remove takes only ours away.

use Do321::JSON;
use Do321::Protocol;
use Do321::Adapter;

constant EVENTS is export = <session-start pre-edit stop>;

#| A harness 321 can wire hooks into: its name, where its settings live in
#| a workspace, and which events it can enforce (refuse) as opposed to
#| advise (inject).  Only Claude Code is known in this release.
class Harness is export {
    has Str $.name;
    has Str $.settings-path;           # relative to the workspace
    has %.enforces;                    # event => Bool
    has Str $.detect-binary;
}

constant CLAUDE-SETTINGS is export = '.claude/settings.json';

sub known-harnesses(--> List) is export {
    (Harness.new(:name<claude_code>, :settings-path(CLAUDE-SETTINGS), :detect-binary<claude>,
        :enforces(%( 'session-start', False, 'pre-edit', True, 'stop', True ))),).List;
}

sub harness-named(Str $name --> Harness) is export { known-harnesses().first(*.name eq $name) }

#| Whether a harness's binary is on PATH (its settings can be written
#| either way; this only says whether a person could run it here).
sub harness-available(Harness $h --> Bool) is export {
    on-path($h.detect-binary).defined;
}

# ----------------------------------------------------------- Claude Code

#| The hook entries for Claude Code's settings.json, calling $command
#| with the event name.  Session start is always wired; pre-edit and stop
#| only when :strict, because they refuse.  Matches the shape iz4 writes
#| for itself, so the two installers agree.
sub claude-hooks(Str $command, Bool :$strict = False --> Hash) is export {
    my sub entry(Str $event, Str :$matcher --> Hash) {
        my %e = hooks => [ %( type => 'command', command => "$command $event" ), ];
        %e<matcher> = $matcher with $matcher;
        %e;
    }
    my %h = SessionStart => [ entry('session-start', :matcher<startup|resume|compact>), ];
    if $strict {
        %h<PreToolUse> = [ entry('pre-edit', :matcher<Edit|Write|MultiEdit|NotebookEdit>), ];
        %h<Stop>       = [ entry('stop'), ];
    }
    %h;
}

sub ours($entry, Str $command --> Bool) {
    $entry ~~ Associative && so @($entry<hooks> // []).grep({ $_ ~~ Associative && ($_<command> // '') ~~ Str && $_<command>.starts-with($command ~ ' ') });
}

#| Readable JSON for a settings file: two-space indent, keys sorted.
sub settings-json($v --> Str) is export { encode-json-pretty($v) ~ "\n" }

#| Install or refresh the hooks in a workspace's .claude/settings.json,
#| keeping every other setting and every hook that is not ours.  Returns
#| 'installed', 'updated' or 'unchanged'; refuses to touch a file it
#| cannot parse.
sub install-claude-hooks(IO::Path $workspace, Str $command, Bool :$strict = False --> Str) is export {
    my $target = $workspace.add(CLAUDE-SETTINGS);
    my %settings;
    if $target.e {
        my $parsed = try parse-json($target.slurp);
        die "{CLAUDE-SETTINGS} is not valid JSON; fix it by hand, nothing was changed" unless $parsed ~~ Associative;
        %settings = %$parsed;
    }
    my $before = canonical(%settings);
    my %hooks = %(%settings<hooks> // %());
    for %hooks.keys -> $event {
        %hooks{$event} = [ |@(%hooks{$event} // []).grep({ !ours($_, $command) }) ];
        %hooks{$event}:delete unless %hooks{$event}.elems;
    }
    for claude-hooks($command, :$strict).kv -> $event, $entries {
        %hooks{$event} = [ |@(%hooks{$event} // []), |@$entries ];
    }
    %settings<hooks> = %hooks;
    my $after = canonical(%settings);
    return 'unchanged' if $after eq $before;
    $target.parent.mkdir;
    $target.spurt(settings-json(%settings));
    $before eq '{}' ?? 'installed' !! 'updated';
}

#| Take only our entries out; 'removed' or 'unchanged'.
sub remove-claude-hooks(IO::Path $workspace, Str $command --> Str) is export {
    my $target = $workspace.add(CLAUDE-SETTINGS);
    return 'unchanged' unless $target.e;
    my $parsed = try parse-json($target.slurp);
    die "{CLAUDE-SETTINGS} is not valid JSON; fix it by hand, nothing was changed" unless $parsed ~~ Associative;
    my %settings = %$parsed;
    my $before = canonical(%settings);
    my %hooks = %(%settings<hooks> // %());
    for %hooks.keys -> $event {
        %hooks{$event} = [ |@(%hooks{$event} // []).grep({ !ours($_, $command) }) ];
        %hooks{$event}:delete unless %hooks{$event}.elems;
    }
    if %hooks { %settings<hooks> = %hooks } else { %settings<hooks>:delete }
    my $after = canonical(%settings);
    return 'unchanged' if $after eq $before;
    $target.spurt(settings-json(%settings));
    'removed';
}

#| Which of our events a settings file carries: event => Bool.
sub claude-hooks-status(IO::Path $workspace, Str $command --> Hash) is export {
    my %wired = EVENTS.map({ $_ => False });
    my $target = $workspace.add(CLAUDE-SETTINGS);
    return %wired unless $target.e;
    my $parsed = try parse-json($target.slurp);
    return %wired unless $parsed ~~ Associative && $parsed<hooks> ~~ Associative;
    my %hooks = %($parsed<hooks>);
    %wired<session-start> = so @(%hooks<SessionStart> // []).grep({ ours($_, $command) });
    %wired<pre-edit>      = so @(%hooks<PreToolUse> // []).grep({ ours($_, $command) });
    %wired<stop>          = so @(%hooks<Stop> // []).grep({ ours($_, $command) });
    %wired;
}

# --------------------------------------------------------------- records

#| One record per harness, for --json: what is wired, what that enforces,
#| and what it only advises.
sub harness-record(Harness $h, IO::Path $workspace, Str $command, Str :$action = '' --> Hash) is export {
    my %wired = claude-hooks-status($workspace, $command);
    my @enforced = EVENTS.grep({ %wired{$_} && $h.enforces{$_} });
    my @advisory = EVENTS.grep({ %wired{$_} && !$h.enforces{$_} });
    my %r = harness => $h.name, available => harness-available($h), settings => $h.settings-path,
        events => %( EVENTS.map({ $_ => (%wired{$_} ?? 'wired' !! 'not wired') }) ),
        enforced => [ |@enforced ], advisory => [ |@advisory ],
        note => 'a wired hook is only as strong as the harness: pre-edit and stop can refuse, session-start can only inject';
    %r<action> = $action if $action ne '';
    %r;
}

#| Wire the command into every known harness; returns the records.
sub install-all(IO::Path $workspace, Str $command, Bool :$strict = False --> List) is export {
    known-harnesses().map(-> $h {
        my $action = try install-claude-hooks($workspace, $command, :$strict);
        my %r = harness-record($h, $workspace, $command, :action($action // 'failed'));
        %r<error> = $!.message if $!;
        %r;
    }).List;
}

sub remove-all(IO::Path $workspace, Str $command --> List) is export {
    known-harnesses().map(-> $h {
        my $action = try remove-claude-hooks($workspace, $command);
        my %r = harness-record($h, $workspace, $command, :action($action // 'failed'));
        %r<error> = $!.message if $!;
        %r;
    }).List;
}

sub status-all(IO::Path $workspace, Str $command --> List) is export {
    known-harnesses().map(-> $h { harness-record($h, $workspace, $command) }).List;
}

# ----------------------------------------------------------- doctor json

#| The doctor's findings as one document: adapters with what each
#| enforces and which hook events its harness can carry, the bound tools,
#| and the trust configuration.
sub doctor-document(Registry $adapters, @tool-bindings, %trust --> Hash) is export {
    my @a;
    for $adapters.all -> $ad {
        my $det = $ad.detect;
        my %enf = $ad.enforcement;
        my $h = harness-named($ad.name);
        @a.push(%(
            name => $ad.name, available => $det.available, version => $det.version, reason => $det.reason,
            enforces => %( features().map({ $_ => enforces(%enf, $_) }) ),
            hooks => ($h.defined ?? %( EVENTS.map({ $_ => ($h.enforces{$_} ?? 'refuses' !! 'advises') }) ) !! %()),
        ));
    }
    %( schema => 'doctor.v1', adapters => @a, tools => [ |@tool-bindings ], trust => %trust );
}
