# Copyright Nige Ltd. Author: Nigel Hamilton.
unit module Do321::ClaudeHooks;

#| What 321 knows about Claude Code's hooks, in one place: which native
#| event carries each control, how a controller is wired into a project's
#| settings and taken out again, how a native event becomes a generic
#| action, and how a verdict becomes the answer Claude Code understands.
#| When Claude Code changes its hook mechanism, this file changes; no
#| controller does.
#|
#| The wiring never calls a controller directly.  Every hook runs
#|
#|     321 hook claude_code <controller> <control>
#|
#| which reads the native event, translates it, asks the controller, and
#| answers in Claude Code's terms.  That command line is also how 321
#| recognises its own entries: it replaces and removes those and leaves
#| every other setting and hook alone.

use Do321::JSON;
use Do321::Protocol;
use Do321::Controller;

constant CLAUDE-HARNESS  is export = 'claude_code';
constant CLAUDE-SETTINGS is export = '.claude/settings.json';

#| The native event and matcher for a control; an empty list when Claude
#| Code has no place for it.
sub claude-event(Str $control --> List) is export {
    given $control {
        when CTRL-AUTHORITATIVE-CONTEXT { ('SessionStart', 'startup|resume|compact') }
        when CTRL-FILESYSTEM-GUARD      { ('PreToolUse', 'Edit|Write|MultiEdit|NotebookEdit') }
        when CTRL-SHELL-GUARD           { ('PreToolUse', 'Bash') }
        when CTRL-PRE-TOOL              { ('PreToolUse', '') }
        when CTRL-PRE-ACTION            { ('PreToolUse', '') }
        when CTRL-POST-TOOL             { ('PostToolUse', '') }
        when CTRL-POST-ACTION           { ('PostToolUse', '') }
        when CTRL-POST-RUN              { ('Stop', '') }
        default                         { () }
    }
}

#| The glue command for one control.
sub glue-command(Str $self, Str $controller, Str $control --> Str) is export {
    "$self hook {CLAUDE-HARNESS} $controller $control";
}

#| Whether a settings entry is 321's wiring for a controller.  The legacy
#| form (a controller's own hook command written straight into the
#| settings, as `321 hooks install` and iz4 once did) counts for iz4, so
#| an install replaces it instead of running both.
sub ours($entry, Str $controller --> Bool) {
    return False unless $entry ~~ Associative;
    so @($entry<hooks> // []).grep({
        $_ ~~ Associative && ($_<command> // '') ~~ Str
            && ($_<command>.contains(" hook {CLAUDE-HARNESS} $controller ")
                || ($controller eq 'iz4' && so $_<command> ~~ m:P5/(^|[\/ ])iz4 hook (session-start|pre-edit|stop)$/))
    });
}

#| The hook entries for a set of controls, grouped by native event.
#| Controls Claude Code has no event for are left out.
sub claude-entries(Str $self, Str $controller, @controls --> Hash) is export {
    my %h;
    for @controls -> $control {
        my ($event, $matcher) = claude-event($control);
        next without $event;
        my %e = hooks => [ %( type => 'command', command => glue-command($self, $controller, $control) ), ];
        %e<matcher> = $matcher if $matcher ne '';
        %h{$event} = [ |@(%h{$event} // []), %e ];
    }
    %h;
}

sub read-settings(IO::Path $target --> Hash) {
    return %() unless $target.e;
    my $parsed = try parse-json($target.slurp);
    die "{$target.Str} is not a JSON object; fix it, then install again\n" unless $parsed ~~ Associative;
    %$parsed;
}

sub settings-text($v --> Str) is export { encode-json-pretty($v) ~ "\n" }

#| Wire a controller into a project's settings for the given controls,
#| keeping every other setting and every hook that is not 321's for this
#| controller.  Returns 'installed', 'updated' or 'unchanged'; dies on a
#| settings file it cannot parse, touching nothing.
sub claude-install(IO::Path $workspace, Str $self, Str $controller, @controls --> Str) is export {
    my $target = $workspace.add(CLAUDE-SETTINGS);
    my %settings = read-settings($target);
    my $before = $target.e ?? canonical(%settings) !! '';
    my %hooks = %settings<hooks> ~~ Associative ?? %(%settings<hooks>) !! %();
    my $had = so %hooks.values.grep({ @($_ // []).grep({ ours($_, $controller) }) });
    for %hooks.keys -> $event {
        my @kept = @(%hooks{$event} // []).grep({ !ours($_, $controller) });
        if @kept { %hooks{$event} = [ |@kept ] } else { %hooks{$event}:delete }
    }
    my %add = claude-entries($self, $controller, @controls);
    for %add.keys.sort -> $event { %hooks{$event} = [ |@(%hooks{$event} // []), |@(%add{$event}) ] }
    %settings<hooks> = %hooks;
    return 'unchanged' if $before ne '' && canonical(%settings) eq $before;
    mkdir-p($target.parent);
    $target.spurt(settings-text(%settings));
    $had ?? 'updated' !! 'installed';
}

#| Take only this controller's entries out; 'removed' or 'unchanged'.
sub claude-remove(IO::Path $workspace, Str $controller --> Str) is export {
    my $target = $workspace.add(CLAUDE-SETTINGS);
    return 'unchanged' unless $target.e;
    my %settings = read-settings($target);
    return 'unchanged' unless %settings<hooks> ~~ Associative;
    my %hooks = %(%settings<hooks>);
    my $removed = False;
    for %hooks.keys -> $event {
        my @all = @(%hooks{$event} // []);
        my @kept = @all.grep({ !ours($_, $controller) });
        $removed = True if @kept.elems != @all.elems;
        if @kept { %hooks{$event} = [ |@kept ] } else { %hooks{$event}:delete }
    }
    return 'unchanged' unless $removed;
    if %hooks { %settings<hooks> = %hooks } else { %settings<hooks>:delete }
    $target.spurt(settings-text(%settings));
    'removed';
}

#| What is actually in the settings for a controller: control => 'installed',
#| 'legacy' (an older direct wiring covers that moment) or 'missing'.  A
#| settings file that cannot be parsed has nothing installed.
sub claude-verify(IO::Path $workspace, Str $controller, @controls --> Hash) is export {
    my %state = @controls.map({ $_ => 'missing' });
    my $target = $workspace.add(CLAUDE-SETTINGS);
    return %state unless $target.e;
    my $parsed = try parse-json($target.slurp);
    return %state unless $parsed ~~ Associative && $parsed<hooks> ~~ Associative;
    my %hooks = %($parsed<hooks>);
    my %legacy = CTRL-AUTHORITATIVE-CONTEXT, 'session-start', CTRL-FILESYSTEM-GUARD, 'pre-edit', CTRL-POST-RUN, 'stop';
    for @controls -> $control {
        my ($event, $matcher) = claude-event($control);
        next without $event;
        for @(%hooks{$event} // []) -> $entry {
            next unless $entry ~~ Associative;
            for @($entry<hooks> // []) -> $h {
                next unless $h ~~ Associative && ($h<command> // '') ~~ Str;
                if $h<command>.ends-with(" hook {CLAUDE-HARNESS} $controller $control") { %state{$control} = 'installed' }
                elsif %state{$control} eq 'missing' && $controller eq 'iz4' && (%legacy{$control} // '') ne ''
                      && $h<command>.ends-with("iz4 hook {%legacy{$control}}") { %state{$control} = 'legacy' }
            }
        }
    }
    %state;
}

# ------------------------------------------------------------- translation

#| A native Claude Code hook event as a generic action: what is being done
#| to what.  Tools 321 does not know by name are still described, as a
#| tool call with their input, so nothing passes unseen for want of a
#| mapping.
sub claude-action(%native --> Action) is export {
    my $tool = (%native<tool_name> // '').Str;
    my %in = %native<tool_input> ~~ Associative ?? %(%native<tool_input>) !! %();
    my $repo = (%native<cwd> // '').Str;
    my $context = "claude_code tool $tool";
    given $tool {
        when 'Write' {
            Action.new(:operation<write>, :target((%in<file_path> // '').Str), :parameters(%( content => (%in<content> // '').Str )), :repository($repo), :$context)
        }
        when 'Edit' {
            Action.new(:operation<edit>, :target((%in<file_path> // '').Str),
                :parameters(%( old => (%in<old_string> // '').Str, new => (%in<new_string> // '').Str )), :repository($repo), :$context)
        }
        when 'MultiEdit' {
            Action.new(:operation<edit>, :target((%in<file_path> // '').Str), :parameters(%( edits => (%in<edits> // []) )), :repository($repo), :$context)
        }
        when 'NotebookEdit' {
            Action.new(:operation<edit>, :target((%in<notebook_path> // %in<file_path> // '').Str),
                :parameters(%( new => (%in<new_source> // '').Str )), :repository($repo), :$context)
        }
        when 'Bash' {
            Action.new(:operation<execute>, :target<shell>, :parameters(%( command => (%in<command> // '').Str )), :repository($repo), :$context)
        }
        when 'WebFetch' {
            Action.new(:operation<fetch>, :target((%in<url> // '').Str), :parameters(%( prompt => (%in<prompt> // '').Str )),
                :recipient((%in<url> // '').Str), :repository($repo), :$context)
        }
        default {
            Action.new(:operation<tool>, :target($tool), :parameters(%in), :repository($repo), :$context)
        }
    }
}

#| A verdict in Claude Code's terms: (exit code, stdout, stderr).
#|
#| Before a tool call: a block refuses it (exit 2, the reason to the
#| model).  needs_human asks the person at the session to decide, which is
#| the harness's own approval prompt; in a headless run there is nobody to
#| ask, so it refuses and tells the agent to stop and put the proposal to a
#| person.  A warning lets the call through and says why.  At the end of a
#| turn a block or needs_human refuses the stop, so the agent says what is
#| outstanding instead of ending silently.  An unavailable controller lets
#| the call through and says so on stderr: a gap, visibly, never a pass.
sub claude-answer(Str $control, Verdict $v, Bool :$headless = False --> List) is export {
    my ($event) = claude-event($control);
    my $why = $v.proposal ne '' ?? $v.proposal !! $v.reason;
    return (0, '', "321: {$v.reason}\n") unless $v.ran;
    if ($event // '') eq 'PreToolUse' {
        given $v.result {
            when RESULT-BLOCK { return (2, '', "$why\n") }
            when RESULT-NEEDS-HUMAN {
                return (2, '', "$why\nNobody can be asked from here. Stop this part of the work and put the proposal to a person.\n") if $headless;
                return (0, encode-json(%( hookSpecificOutput => %( hookEventName => 'PreToolUse', permissionDecision => 'ask',
                    permissionDecisionReason => $why ) )) ~ "\n", '');
            }
            when RESULT-WARN {
                return (0, encode-json(%( hookSpecificOutput => %( hookEventName => 'PreToolUse', additionalContext => $why ) )) ~ "\n", '');
            }
            default { return (0, '', '') }
        }
    }
    if ($event // '') eq 'Stop' {
        return (2, '', "$why\n") if $v.stops;
        return (0, '', '');
    }
    return (0, '', '');
}
