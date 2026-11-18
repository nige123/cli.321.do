unit module Do321::CLI;

#| The front door: `321 <agent> <request>` for people and `321 run` for
#| machines, plus the small inspection commands.
#|
#| Reserved first words are RESERVED in Do321::Trust (run, agents, status,
#| help and the rest).  Anything else is an agent alias or a canonical id.  A request
#| is the remaining words joined by single spaces; it becomes the objective
#| of a WorkPackage and is never handed to a shell.

use Data::Native;
use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Digest;
use Do321::Keys;
use Do321::Trust;
use Do321::Tool;
use Do321::Adapter;
use Do321::Codex;
use Do321::Exercised;
use Do321::Interactions;
use Do321::RunWords :parse;     # the parser alone: this module has a run-word of its own
use Do321::Run;
use Do321::Wire;
use Do321::Hooks;
use Do321::Controller;
use Do321::Enforcement;
use Do321::Help;
use Do321::Look;
# Only the names these commands call: Do321::Screen's value types (Row,
# State, Table, Note and the rest) are deliberately generic and belong to
# the screen builders in Do321::Screens, not to a namespace shared with
# Run, Adapter and Controller.  Do321::History keeps a when-text of its
# own, and this module's is a different thing.
use Do321::Screens;
use Do321::History :read;
use Do321::Learn;
use Do321::Registry;
use Do321::Record;
use Do321::Complete;
use Do321::Models;
use Do321::Plan;
use Do321::Curate;
use Do321::Choose;
use Do321::Versions;

#| Stamped at build time in the release workflow.
constant VERSION is export = '0.7.1';

#| Everything a command touches, so tests can substitute all of it.
class Env is export {
    has $.stdin;                 # a LineSource
    has $.stdout;                # IO::Handle
    has $.stderr;                # IO::Handle
    has @.args;
    has Str $.trust-path = '';   # '' means the default
    has Str $.home = '';         # ~/.321; '' means the default
    has Registry $.adapters;
    has Bool $.interactive = False;
    has Bool $.signals = False;
}

#| The installed adapter set: the procedure executor and the fake (hidden,
#| selectable only by name), Claude Code and Codex.  DO_321_CLAUDE_BINARY
#| and DO_321_CODEX_BINARY name the harness executables for an isolated
#| test environment without touching PATH.
sub default-registry($stderr --> Registry) is export {
    # DO_321_FAKE_SCRIPT is a test seam: a JSON list of procedure steps the
    # hidden fake adapter runs instead of its default script (the JSON
    # itself, or @<file> holding it), so the suite can drive every
    # directive path through the real entry point.
    my $seam = %*ENV<DO_321_FAKE_SCRIPT> // '';
    $seam = (try $seam.substr(1).IO.slurp) // '' if $seam.starts-with('@');
    my $script = $seam ne '' ?? (try parse-json($seam)) !! Any;
    $script = [ @$script.map({ load('ProcedureStep', $_) }) ] if $script ~~ Positional;
    Registry.new
        .register-hidden(new-procedure(:tools(default-tools())))
        .register-hidden(new-fake($script, :controls(fake-controls-seam())))
        # No transcript handle: a run is shown from its own events, which the
        # CLI renders in the house style, so teeing the adapter's readable copy
        # of the same stream to standard error would say every line twice on a
        # terminal.  :stderr carries the harness's error output, which nothing
        # else shows.
        # A promoted version still on disk is the one run, whatever PATH has
        # moved to (321 harness pin); the test seam comes first.
        .register(ClaudeCode.new(:binary(%*ENV<DO_321_CLAUDE_BINARY> // pinned-binary(versions-home(), 'claude_code')), :stderr($stderr)))
        # Codex is chosen only where its claims cover the package: it has
        # a sandbox, not a tool allowlist, so a package with tool grants is
        # never placed on it.
        .register(Codex.new(:binary(%*ENV<DO_321_CODEX_BINARY> // ''), :stderr($stderr)));
}

my sub versions-home(--> IO::Path) { (%*ENV<DO_321_HOME> // $*HOME.add('.321').Str).IO }

#| DO_321_FAKE_CONTROLS is a test seam: a JSON object of control =>
#| strength that makes the hidden fake adapter stand in for a harness with
#| exactly those controls, so a weaker environment can be shown through
#| the real entry point.
sub fake-controls-seam(--> Hash) {
    my $seam = %*ENV<DO_321_FAKE_CONTROLS> // '';
    return %() if $seam eq '';
    my $c = try parse-json($seam);
    $c ~~ Associative ?? %$c !! %();
}

#| The externally configured tools a procedure may reach, each an explicit
#| path from the environment; nothing is looked up by name on PATH.
#|   DP_BIN      the deployment engine's entry point (deploy.321.do/bin/dp)
#|   DP_EXECUTE  a comma-separated list of targets on which an APPROVED
#|               deployment may be executed through the engine's `go`.
#|               Unset means execute is unavailable, the state of every
#|               production binding.
sub default-tools(--> Hash) is export {
    my $bin = %*ENV<DP_BIN> // '';
    my $exec;
    my $allow = (%*ENV<DP_EXECUTE> // '').trim;
    if $allow ne '' && $bin ne '' {
        my @targets = $allow.split(',').map(*.trim).grep(* ne '');
        $exec = EngineExecutor.new(:$bin, :allowed-targets(@targets));
    }
    %( dp => DP.new(:$bin, :$exec) );
}

class X::Do321::Usage is Exception is export {
    has Str $.message;
}

#| Options that precede the command word.  Options after the agent name
#| belong to the request text.
class Global {
    has Str $.trust-path is rw = '';
    has Str $.workspace is rw = '';
    has Str $.package-dir is rw = '';
    has Str $.placement is rw = '';
    has Str $.adapter is rw = '';
    has Str $.network is rw = '';
    #| --context: the work context a run belongs to (Do321::Learn).
    has Str $.context is rw = '';
    #| --skill: installed skills selected for a run (Do321::Registry).
    has @.skill is rw;
    has @.attach is rw;
    has @.done is rw;
    has @.grant is rw;
    has Bool $.non-interactive is rw = False;
    has Bool $.json-out is rw = False;
    #| --brief: one record per line for a tool, no title, no next step.
    has Bool $.brief is rw = False;
    #| --verbose: the whole transcript of a run (trust, grants, every
    #| event, every tool call); the default screen is the short one.
    has Bool $.verbose is rw = False;
    #| --task, --profile, --model, --effort: what a person sets by hand
    #| in place of the agent's own choice (Do321::Choose).
    has Str $.task is rw = '';
    has Str $.profile is rw = '';
    has Str $.model is rw = '';
    has Str $.effort is rw = '';
    method asked(--> Asked) { Asked.new(task => $!task, profile => $!profile, model => $!model, effort => $!effort) }
}

#| The two switches a pipeline reaches for, taken from wherever they
#| stand around a reserved command (321 --brief status, 321 status
#| --brief): --plain is the pipe form on a terminal, --brief one record
#| per line.  After an agent's name every word is the request, so they
#| are never taken from there.
sub take-pipe-flags(Global $g, @args --> List) {
    my @rest;
    for @args -> $a {
        if $a eq '--brief'    { $g.brief = True }
        elsif $a eq '--plain' { %*ENV<DO_321_COLOR> = '0' }
        else { @rest.push($a) }
    }
    @rest;
}

sub parse-global(@args --> List) {
    my $g = Global.new;
    my $i = 0;
    while $i < @args {
        my $a = @args[$i];
        return ($g, [ |@args[$i + 1 .. *] ]) if $a eq '--';
        return ($g, ['help', |@args[$i + 1 .. *]]) if $a eq '-h' || $a eq '--help';   # help is never an unknown option
        return ($g, ['version']) if $a eq '--version';                                  # nor is version, out of habit
        last unless $a.starts-with('-');
        my ($name, $value, $has-value) = $a.contains('=') ?? (|$a.split('=', 2), True) !! ($a, '', False);
        my sub need() {
            return $value if $has-value;
            X::Do321::Usage.new(message => "$name needs a value").throw if $i + 1 >= @args;
            $i++;
            @args[$i];
        }
        given $name {
            when '--trust'           { $g.trust-path = need() }
            when '--workspace'       { $g.workspace = need() }
            when '--package-dir'     { $g.package-dir = need() }
            when '--placement'       { $g.placement = need() }
            when '--adapter'         { $g.adapter = need() }
            when '--network'         { $g.network = need() }
            when '--context'         { $g.context = need() }
            when '--task'            { $g.task = need() }
            when '--profile'         { $g.profile = need() }
            when '--model'           { $g.model = need() }
            when '--effort'          { $g.effort = need() }
            when '--skill'           { $g.skill.push(need()) }
            when '--attach'          { $g.attach.push(need()) }
            when '--done'            { $g.done.push(need()) }
            when '--grant'           { $g.grant.push(need()) }
            when '--non-interactive' { $g.non-interactive = True }
            when '--json'            { $g.json-out = True }
            when '--brief'           { $g.brief = True }
            when '--verbose'         { $g.verbose = True }
            when '--plain'           { %*ENV<DO_321_COLOR> = '0' }
            default { X::Do321::Usage.new(message => "unknown option $name").throw }
        }
        $i++;
    }
    ($g, [ |@args[$i .. *] ]);
}

sub trust-of(Env $env --> Config) {
    my $p = $env.trust-path ne '' ?? $env.trust-path.IO !! default-trust-path();
    load-trust($p);
}

sub home-of(Env $env --> IO::Path) {
    return $env.home.IO if $env.home ne '';
    return %*ENV<DO_321_HOME>.IO if %*ENV<DO_321_HOME>;
    $*HOME.add('.321');
}

sub runner-of(Env $env --> Runner) { Runner.new(:adapters($env.adapters)) }

#| Run the CLI and return the exit code.
#| Mission Control's words go to Mission Control.  The entry that carries
#| it (bin/321) hands it in: it drives this runtime, so the runtime cannot
#| name it.  A build without it says so.
my &MISSION;
sub hand-runs-to(&mission) is export { &MISSION = &mission }

#| Whether a person at a terminal is asking for a screen: both ends are a
#| terminal, nothing asked for a record or the plain form, and Mission
#| Control is in this build.
sub screen-wanted(Env $env, Global $g --> Bool) {
    return False without &MISSION;
    return False unless $*KERNEL.name eq 'linux';   # no screen there yet: the help instead
    return False if $g.json-out || $g.brief || brief-on() || is-in('--plain', $env.args);
    my $term = %*ENV<TERM> // '';
    return False if $term eq '' || $term eq 'dumb';
    so $*IN.t && (try $env.stdout.t);
}

sub cmd-mission(Env $env, Global $g, @words --> Int) {
    without &MISSION {
        $env.stderr.say("321: '{@words[0]}' needs Mission Control, and this build has none");
        return EXIT-USAGE;
    }
    # what was said before the word still holds after it
    %*ENV<DO_321_CONTEXT> = $g.context if $g.context ne '';
    my @argv = |($g.trust-path ne '' ?? ('--trust', $g.trust-path) !! ()),
               |($g.workspace ne '' ?? ('--workspace', $g.workspace) !! ()),
               |($g.brief ?? ('--brief',) !! ()), |($g.json-out ?? ('--json',) !! ()), |@words;
    MISSION(@argv);
}

#| Every command a person types goes through here: answered, then one
#| line about it kept for the people who shape 321 (Do321::Interactions).
#| The record never changes the answer.
sub cli-main(Env $env --> Int) is export {
    my $t0 = now;
    my $code = cli-run($env);
    try { my %i = interaction-of($env, $code, now - $t0); record-interaction(interactions-home($env), %i) if %i }
    $code;
}

sub interactions-home(Env $env --> IO::Path) {
    $env.home ne '' ?? $env.home.IO !! (%*ENV<DO_321_HOME> ?? %*ENV<DO_321_HOME>.IO !! $*HOME.add('.321'));
}

#| What one invocation looked like, for the record: the command word and
#| the options and arguments around it, with the person's own prose
#| counted rather than kept.  Nothing for the hooks a harness calls or
#| the processes 321 runs for itself: those are not a person typing.
sub interaction-of(Env $env, Int $code, Duration $took --> Hash) {
    my ($g, $rest) = try parse-global($env.args);
    my @rest = $g.defined ?? @$rest !! @($env.args);
    my $word = @rest ?? @rest[0] !! '';
    return %() if $word eq 'hook' | 'host' | 'run';
    my @args = @rest[1 .. *];
    my $free = 0;
    my $agent = '';
    if $word eq '' { $word = '(nothing)' }
    elsif $word eq 'start' | 'steer' {
        my %r = parse-run-words($word, @args);
        if !%r<error> && %r<words> ne '' {
            $free = %r<words>.words.elems;
            @args = @args.head(* - $free);
        }
        # the agent is named on its own; what remains is the options
        if $word eq 'start' && (%r<agent> // '') ne '' { $agent = %r<agent>; @args = @args.head(* - 1) }
    }
    elsif !is-in($word, RESERVED) && $word !~~ /^ '-'/ {
        $agent = $word; $word = 'agent';
        $free = @args.elems; @args = ();
    }
    my @opts = $env.args.grep(*.starts-with('--')).grep({ !is-in($_, @args) }).unique;
    my $tty = so (try $env.stdout.t);
    my $form = ($g.defined && $g.json-out) || is-in('--json', $env.args) ?? 'json'
            !! ($g.defined && $g.brief) || brief-on() ?? 'brief'
            !! !$tty || (%*ENV<DO_321_COLOR> // '') eq '0' || is-in('--plain', $env.args) ?? 'plain'
            !! 'screen';
    my %rec = command => $word, options => @opts, args => @args.map(*.Str).List, free => $free,
              form => $form, tty => $tty, exit => $code, ms => ($took * 1000).Int, note => take-interaction-note();
    %rec<agent> = $agent if $agent ne '';
    %rec<cols> = screen-width() if $tty;
    %rec;
}

sub cli-run(Env $env is copy --> Int) {
    adopt-old-names();
    $env = Env.new(:stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :args($env.args), :trust-path($env.trust-path),
        :home($env.home), :adapters(default-registry($env.stderr)), :interactive($env.interactive), :signals($env.signals))
        without $env.adapters;
    # Names a person cites are shown in bold on a terminal; a document
    # for a machine is never dressed.
    emphasise-harnesses($env.adapters.all.grep({ .controls.elems > 0 }).map(*.name).List);
    dress(False) if is-in('--json', $env.args);
    my ($g, $rest) = try parse-global($env.args);
    if $! {
        $env.stderr.say("321: {$!.message}");
        $env.stderr.say(next-text('see the options that go before the agent name', '321 help options'));
        return EXIT-USAGE;
    }
    my @rest = @$rest;
    $env = Env.new(:stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :args($env.args), :trust-path($g.trust-path),
        :home($env.home), :adapters($env.adapters), :interactive($env.interactive), :signals($env.signals)) if $g.trust-path ne '';
    # 321 alone at a terminal is Mission Control; anywhere else, the help it always was
    return cmd-mission($env, $g, ['tui']) if !@rest && screen-wanted($env, $g);
    unless @rest { $env.stdout.print(help-index(help-ctx($env))); return EXIT-USAGE }
    $g.brief = True if brief-on();
    # a request after 'start', or a steer, is the person's own, word for word
    @rest = (@rest[0], |take-pipe-flags($g, @rest[1 .. *])) if is-in(@rest[0], RESERVED) && @rest[0] ne 'start' | 'steer';
    dress(False) if $g.brief;
    # the two machine forms are exclusive: a document, or a record per line
    if $g.brief && ($g.json-out || is-in('--json', @rest)) {
        $env.stderr.say('321: --json and --brief are two forms; ask for one');
        $env.stderr.say(next-text('one record per line, or the document', '321 help brief'));
        return EXIT-USAGE;
    }
    # '321 status --help' is '321 help status'
    return cmd-help($env, [@rest[0]]) if is-in(@rest[0], RESERVED) && @rest.grep('--help' | '-h');
    given @rest[0] {
        when 'help' | '-h' | '--help' { return cmd-help($env, @rest[1 .. *]) }
        when 'version' | '--version' { $env.stdout.say("321 {VERSION}"); return 0 }
        when 'run'      { return cmd-run($env, $g, @rest[1 .. *]) }
        when 'agents'   { return cmd-agents($env, $g, @rest[1 .. *]) }
        when 'whois'    { return cmd-whois($env, $g, @rest[1 .. *]) }
        when 'packages' { return cmd-packages($env, $g, @rest[1 .. *]) }
        when 'trust'    { return cmd-trust($env, $g, @rest[1 .. *]) }
        when 'doctor'   { return cmd-doctor($env, $g, @rest[1 .. *]) }
        when 'status'   { return cmd-status($env, $g, @rest[1 .. *]) }
        when 'log'      { return cmd-log($env, $g, @rest[1 .. *]) }
        when 'value'    { return cmd-value($env, $g, @rest[1 .. *]) }
        when 'outcome'  { return cmd-outcome($env, $g, @rest[1 .. *]) }
        when 'context'  { return cmd-context($env, $g, @rest[1 .. *]) }
        when 'lessons'  { return cmd-lessons($env, $g, @rest[1 .. *]) }
        when 'skills'   { return cmd-skills($env, $g, @rest[1 .. *]) }
        when 'registry' { return cmd-registry($env, $g, @rest[1 .. *]) }
        when 'record'   { return cmd-record($env, $g, @rest[1 .. *]) }
        when 'models'   { return cmd-models($env, $g, @rest[1 .. *]) }
        when 'choose'   { return cmd-choose($env, $g, @rest[1 .. *]) }
        when 'completion' { return cmd-completion($env, $g, @rest[1 .. *]) }
        when 'key'      { return cmd-key($env, $g, @rest[1 .. *]) }
        when 'receipt'  { return cmd-receipt($env, $g, @rest[1 .. *]) }
        when 'hooks'    { return cmd-hooks($env, $g, @rest[1 .. *]) }
        when 'harness'  { return cmd-harness($env, $g, @rest[1 .. *]) }
        when 'hook'     { return cmd-hook($env, @rest[1 .. *]) }
        # Runs that outlive the terminal, and the screen that watches them
        when 'tui'      { return cmd-mission($env, $g, @rest) }
        when 'start'    { return cmd-mission($env, $g, @rest) }
        when 'stop'     { return cmd-mission($env, $g, @rest) }
        when 'attach'   { return cmd-mission($env, $g, @rest) }
        when 'restart'  { return cmd-mission($env, $g, @rest) }
        when 'steer'    { return cmd-mission($env, $g, @rest) }
        when 'hold'     { return cmd-mission($env, $g, @rest) }
        when 'resume'   { return cmd-mission($env, $g, @rest) }
        when 'host'     { return cmd-mission($env, $g, @rest) }
        # A controller by name.  Another controller is one more line here.
        when 'iz4'      { return cmd-controller($env, $g, 'iz4', @rest[1 .. *]) }
    }
    cmd-agent($env, $g, @rest[0], @rest[1 .. *]);
}

# ----------------------------------------------------------------- help

#| What the help screens need to make their examples the person's own:
#| the configured aliases, whether a trust file exists, the dp binding.
sub help-ctx(Env $env --> Hash) {
    my $cfg = try trust-of($env);
    my @agents = $cfg.defined ?? $cfg.configured.map({ .alias ne '' ?? .alias !! .id.Str }) !! ();
    %( agents => @agents, trust-exists => ($cfg.defined && $cfg.path.IO.e),
       dp-bound => ((%*ENV<DP_BIN> // '') ne ''), dp-bin => (%*ENV<DP_BIN> // '').Str, dp-execute => (%*ENV<DP_EXECUTE> // '').Str );
}

#| A command called wrongly: one line saying what was wrong, then that
#| command's own help, to standard error, and the usage exit.
sub usage-error(Env $env, Str $topic, Str $line = '' --> Int) {
    interaction-note("usage $topic" ~ ($line ne '' ?? ": $line" !! ''));
    $env.stderr.say("{glyph('no')} 321 $topic: $line") if $line ne '';
    with topic($topic) { $env.stderr.print(help-topic($_, help-ctx($env))) }
    else { $env.stderr.print(help-for([$topic], help-ctx($env))[0]) }
    EXIT-USAGE;
}

# ------------------------------------------------------------------ key

#| The runtime's signing key: show it, or make one.  With a key under the
#| home every receipt this 321 writes is signed over its digest; the
#| public half is what an issuer pins to check them.
sub cmd-key(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my $sub = @args ?? @args[0] !! 'show';
    given $sub {
        when 'new' {
            my %pub = (try new-key($home)) // %();
            if $! { $env.stderr.say("321 key: {$!.message}"); return EXIT-FAILED }
            if $g.json-out { $env.stdout.say(encode-json(%pub)); return 0 }
            if $g.brief { $env.stdout.say(brief-line(%pub<keyId>, %pub<publicKey>, key-path($home))); return 0 }
            my $w = $env.stdout;
            $w.say(header('key new', "{%pub<keyId>} made"));
            $w.say('');
            $w.say($_) for flat row-lines('key:', key-path($home).Str), row-lines('public key:', %pub<publicKey>.Str);
            $w.say('');
            $w.say('Receipts from this 321 are signed with it from now on. A signature says a receipt is as it was issued; it never says the work is right.');
            $w.say('');
            $w.say(next-text('pin the public key where receipts are checked; this shows it again', '321 key'));
            0;
        }
        when 'show' {
            my $k = try load-key($home);
            if $! { $env.stderr.say("321 key: {$!.message}"); return EXIT-FAILED }
            my $w = $env.stdout;
            without $k {
                if $g.json-out { $w.say(encode-json(%())); return 0 }
                return 0 if $g.brief;
                $w.say(header('key', 'none yet'));
                $w.say('');
                $w.say($_) for flat row-lines('key:', "none at {key-path($home)}"), row-lines('receipts:', 'unsigned until there is one');
                $w.say('');
                $w.say(next-text('make one', '321 key new'));
                return 0;
            }
            my %pub = public-part(%$k);
            if $g.json-out { $w.say(encode-json(%pub)); return 0 }
            if $g.brief { $w.say(brief-line(%pub<keyId>, %pub<publicKey>, key-path($home))); return 0 }
            $w.say(header('key', %pub<keyId>.Str));
            $w.say('');
            $w.say($_) for flat row-lines('key:', key-path($home).Str), row-lines('public key:', %pub<publicKey>.Str), row-lines('receipts:', 'signed with it');
            $w.say('');
            $w.say('A signature says a receipt is as it was issued; it never says the work is right.');
            0;
        }
        default { usage-error($env, 'key', "there is no 'key $sub'") }
    }
}

# -------------------------------------------------------------- receipt

#| Check a receipt file: its digest against its content, and its signature
#| against a public key (--key <base64>, else this home's own).
sub cmd-receipt(Env $env, Global $g, @args --> Int) {
    my $sub = @args ?? @args[0] !! '';
    return usage-error($env, 'receipt', $sub eq '' ?? 'say what to do' !! "there is no 'receipt $sub'") unless $sub eq 'verify';
    my ($file, $key) = (Str, Str);
    my @rest = @args[1 .. *];
    my $i = 0;
    while $i < @rest {
        given @rest[$i] {
            when '--key' { $i++; $key = @rest[$i] // Str }
            when /^ '--key=' (.*) $/ { $key = ~$0 }
            default { $file = $_ }
        }
        $i++;
    }
    without $file { return usage-error($env, 'receipt', 'which file?') }
    my $r = try parse-json($file.IO.slurp);
    if $! || $r !~~ Associative {
        $env.stderr.say("321 receipt verify: {$file} is not a receipt: {$!.message // 'not a JSON object'}");
        $env.stderr.say(next-text('the last runs are listed, each with its receipt, under', '321 status'));
        return EXIT-FAILED;
    }
    without $key {
        my $k = try load-key(home-of($env));
        $key = $k<publicKey> with $k;
    }
    without $key {
        $env.stderr.say("321 receipt verify: no key to check against: give --key <base64>, or make this 321's own");
        $env.stderr.say(next-text('make one', '321 key new'));
        return EXIT-USAGE;
    }
    my $id = try verify-receipt(%$r, $key);
    if $! {
        $env.stderr.say("321 receipt verify: {$file}: {$!.message}");
        $env.stderr.say(next-text('check it against the key it was signed with', "321 receipt verify $file --key B64"));
        return EXIT-FAILED;
    }
    if $g.brief { $env.stdout.say(brief-line('verified', $r<receiptId>, $r<packageId>, $id)); return 0 }
    my $w = $env.stdout;
    $w.say(header('receipt verify', $file));
    $w.say('');
    $w.say("{glyph('yes')} verified: the digest matches the content and the signature holds under key $id");
    $w.say('');
    $w.say($_) for flat row-lines('receipt:', $r<receiptId>.Str), row-lines('package:', $r<packageId>.Str), row-lines('key:', $id.Str);
    $w.say('');
    $w.say('That says the receipt is as it was issued; it never says the work is right.');
    0;
}

#| `321 help [<command>]`: one screen at a time.
sub cmd-help(Env $env, @args --> Int) {
    my ($text, $known) = help-for(@args.grep({ !.starts-with('-') }), help-ctx($env));
    unless $known { $env.stderr.print($text); return EXIT-USAGE }
    $env.stdout.print($text);
    0;
}

# --------------------------------------------------------------- status

#| One run's line on the status screen, from its directory under
#| ~/.321/runs: when it started, which agent, what was asked, how it
#| ended, and the question it is waiting on if it ended blocked.  A
#| directory with a package but no receipt is a run that has not ended.
sub run-summary(IO::Path $dir, %alias-of --> Hash) {
    my %wp = (try parse-json($dir.add('work-package.json').slurp)) // %();
    my %r  = $dir.add('receipt.json').f ?? (try parse-json($dir.add('receipt.json').slurp)) // %() !! %();
    my $id = (%wp<agent><id> // %r<agent><id> // '').Str;
    my $agent = %alias-of{$id} // $id;
    %(
        packageId => $dir.basename,
        startedAt => (%r<startedAt> // %wp<issuedAt> // '').Str,
        agent     => $agent,
        objective => (%wp<objective> // '').Str,
        status    => (%r ?? %r<status>.Str !! 'running'),
        blockedOn => (%r<blockedOn> // '').Str,
        summary   => (%r<summary> // '').Str,
        receipt   => $dir.add('receipt.json').Str,
    );
}

#| How long ago, as a person says it: "just now", "5 mins ago", "3 hours
#| ago", "yesterday", "4 days ago"; beyond a week the date, with the year
#| once it differs.  A run is placed by how far back it is, not by a clock.
sub when-text(Str $iso, DateTime :$now = DateTime.now --> Str) is export {
    return '' if $iso eq '';
    my $d = try DateTime.new($iso);
    return '' without $d;
    my $s = ($now - $d).Int;
    return 'just now'           if $s < 60;
    my $m = $s div 60;
    return "$m min{$m == 1 ?? '' !! 's'} ago" if $m < 60;
    my $h = $s div 3600;
    return "$h hour{$h == 1 ?? '' !! 's'} ago" if $h < 24;
    my $days = $now.local.Date - $d.local.Date;
    return 'yesterday'          if $days <= 1;
    return "$days days ago"     if $days < 7;
    my $l = $d.local;
    my $md = sprintf('%d %s', $l.day, <Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec>[$l.month - 1]);
    $l.year == $now.local.year ?? $md !! "$md {$l.year}";
}

sub trim-to(Str $s, Int $n --> Str) { $s.chars <= $n ?? $s !! $s.substr(0, $n - 1) ~ '…' }

#| Who a person is addressing, in a few words after the agent's name: the
#| package's own byline (identity.byline, written to be remembered), or
#| failing that the first clause of its role.
sub agent-byline(%m --> Str) {
    my $b = (%m<identity><byline> // '').trim;
    return $b if $b ne '';
    trim-to((%m<identity><role> // '').split(/ <[:;,.]> /, 2)[0].trim, 40);
}

#| `321 status`: what is going on with this 321, on one screen: the
#| runtime, the workspace and its IZ4, the agents, the deploy binding,
#| receipt signing, the last runs, and the next step the newest run that
#| needs a person is waiting for.  This is the runtime's own state; an
#| agent's `status` request (321 <agent> status) is the engine's view of
#| services, a different thing.
sub cmd-status(Env $env, Global $g, @args --> Int) {
    my $want = 5;
    if @args && @args[0] eq '--runs' { $want = (@args[1] // '5').Int max 1 }
    elsif @args && @args[0] ne '--json' { return usage-error($env, 'status', "it takes --runs N, --json and --brief, not '{@args[0]}'") }
    my %ctx = help-ctx($env);
    my $home = home-of($env);
    my ($workspace, $kind) = resolve-workspace($g.workspace);
    my $cfg = try trust-of($env);
    my %alias-of = $cfg.defined ?? $cfg.aliases.kv.map(-> $a, $id { $id.Str => $a }).Hash !! %();

    # the workspace and whether its IZ4 is enforced in a harness that is here
    my $iz4 = $workspace ne '' ?? find-iz4-file($workspace) !! IO::Path;
    # In the controller's own words: the headline iz4 status gives for each
    # harness that is here (aware, enforced, ...), never a reading of ours.
    my @harnesses;
    if $iz4.defined && $iz4.f {
        my $controller = controller-named('iz4');
        for harness-adapters($env).grep({ .detect.available }) -> $a {
            my %s = (try enforcement-status($a, $controller, $workspace.IO)) // %();
            next unless %s;
            @harnesses.push(%( harness => $a.name, headline => (%s<headline> // '').Str ));
        }
    }
    my $here = $workspace eq '' ?? 'no workspace (not inside a git repository)'
        !! "$workspace ($kind)" ~ (($iz4.defined && $iz4.f)
            ?? (@harnesses ?? ', IZ4 ' ~ @harnesses.map({ "{.<headline>.lc} in {.<harness>}" }).join('; ') !! ', IZ4 present')
            !! ', no IZ4');

    # receipt signing
    my $k = try load-key($home);
    my $signing = $k.defined ?? "signed with key {public-part(%$k)<keyId>}" !! 'unsigned (no key; 321 key new makes one)';

    # the last runs, newest first
    my $runs = $home.add('runs');
    my @dirs = $runs.d ?? $runs.dir.grep(*.d).sort(*.basename).reverse !! ();
    my @runs = @dirs.head($want).map({ run-summary($_, %alias-of) });
    my $total = @dirs.elems;

    if $g.json-out || is-in('--json', @args) {
        $env.stdout.say(encode-json-pretty(%(
            schema => 'status.v1', version => VERSION, host => $*KERNEL.hostname.Str,
            workspace => %( path => $workspace, kind => $kind, iz4 => ($iz4.defined && $iz4.f ?? $iz4.Str !! ''), harnesses => @harnesses ),
            trust => %( path => ($cfg.defined ?? $cfg.path.Str !! ''), exists => %ctx<trust-exists>, agents => %ctx<agents> ),
            deploy => %( bound => %ctx<dp-bound>, bin => %ctx<dp-bin>, execute => %ctx<dp-execute> ),
            receipts => %( signed => $k.defined, keyId => ($k.defined ?? public-part(%$k)<keyId> !! '') ),
            runs => %( total => $total, recent => @runs ),
        )));
        return 0;
    }
    # one run per line, newest first, for a tool: when (ISO 8601), agent,
    # status, what was asked, what it waits on
    if $g.brief {
        $env.stdout.say(brief-line(.<startedAt>, .<agent>, run-word(.<status>), .<objective>, .<blockedOn>)) for @runs;
        return 0;
    }

    my $w = $env.stdout;
    $w.say(header('status'));
    $w.say(subtitle(VERSION, $*KERNEL.hostname.Str));
    $w.say('');
    my sub row(Str $k, Str $v) { $w.say(sprintf('%-13s %s', $k, $v)) }
    row('here:', $here);
    my @agents = @(%ctx<agents>);
    row('agents:', @agents
        ?? "{@agents.elems} configured ({trim-to(@agents.join(', '), 40)}); trust: {$cfg.path}"
        !! (%ctx<trust-exists> ?? "none configured in {$cfg.path}" !! 'none; no trust file yet'));
    row('deploy:', (%ctx<dp-bound> ?? "dp bound ({%ctx<dp-bin>})" !! 'dp not bound (DP_BIN unset)')
        ~ '; execute ' ~ (%ctx<dp-execute> ne '' ?? "enabled for {%ctx<dp-execute>}" !! 'not enabled here (DP_EXECUTE unset)'));
    row('receipts:', $signing);
    $w.say('');
    # three columns: how long ago, what was asked as it was typed, and
    # how it ended; a question it waits on follows its line
    my $done = @runs.grep({ .<status> eq 'completed' | 'no_change' }).elems;
    if @runs {
        row('last runs:', ($total > @runs ?? "{@runs.elems} of $total, " !! "{@runs.elems} of $total, ")
            ~ "$done completed" ~ ($total > @runs ?? ' (321 status --runs N for more)' !! ''));
        for @runs -> %r {
            my $line = sprintf('  %-13s %-44s %s', when-text(%r<startedAt>), trim-to("{%r<agent>} {%r<objective>}", 44), last-word(%r<status>));
            $line ~= '   ' ~ trim-to(%r<blockedOn>, 40) if %r<blockedOn> ne '';
            $w.say($line);
        }
        $w.say('  a receipt says what ran and what changed, never that the work is right');
    }
    else { row('last runs:', 'none yet') }
    $w.say('');

    # the next step: the newest run waiting on a person wins
    my $first = @agents ?? @agents[0] !! 'helper';
    my $blocked = @runs.first({ .<status> eq 'blocked' && .<blockedOn> ne '' });
    my $failed  = @runs && @runs[0]<status> eq 'failed' ?? @runs[0] !! Nil;   # an older failure that later runs moved past is not news
    my $running = @runs.first({ .<status> eq 'running' });
    $w.say(do
        with $blocked { next-text("a run is waiting on an answer: {.<blockedOn>}", "321 {.<agent>} {.<objective>} <answer>") }
        orwith $running { next-text('a run has not ended; its directory has the package but no receipt yet', "ls {$runs.add(.<packageId>)}") }
        orwith $failed { next-text('the last run failed; its receipt names the cause. Fix that, then ask again', "321 {.<agent>} {.<objective>}") }
        elsif !@agents { next-text('no agent is configured yet; set one up', '321 help trust') }
        elsif !@runs { next-text('make a first run', "321 $first status") }
        else { next-text('ask the next thing', "321 $first <request...>") });
    # a clean state is said last, plainly, and only when it is so: every
    # run shown ended completed and nothing waits on the person
    if @runs && $done == @runs && !$blocked && !$running && !$failed {
        $w.say('');
        $w.say(all-well('clear', "the last {many-of(@runs.elems, 'run')} completed and nothing is waiting on you."));
    }
    0;
}

# ------------------------------------------------------------------ run

sub cmd-run(Env $env, Global $g, @args --> Int) {
    my %o = package-source => '-', package-dir => $g.package-dir, workspace => $g.workspace, adapter => $g.adapter;
    my %asked = task => $g.task, profile => $g.profile, model => $g.model, effort => $g.effort;
    my $i = 0;
    while $i < @args {
        my $a = @args[$i];
        my ($name, $value, $has-value) = $a.contains('=') ?? (|$a.split('=', 2), True) !! ($a, '', False);
        my sub need() {
            return $value if $has-value;
            X::Do321::Usage.new(message => "$name needs a value").throw if $i + 1 >= @args;
            $i++;
            @args[$i];
        }
        my $err = try {
            given $name {
                when '--package'     { %o<package-source> = need() }
                when '--workspace'   { %o<workspace> = need() }
                when '--package-dir' { %o<package-dir> = need() }
                when '--receipt'     { %o<receipt-path> = need() }
                when '--events'      { %o<events-path> = need() }
                when '--run-id'      { %o<run-id> = need() }
                when '--history-dir' { %o<history-dir> = need() }
                when '--adapter'     { %o<adapter> = need() }
                when '--task'        { %asked<task> = need() }
                when '--profile'     { %asked<profile> = need() }
                when '--model'       { %asked<model> = need() }
                when '--effort'      { %asked<effort> = need() }
                when '--continue'    { %o<continue-from> = need() }
                when '--follows'     { %o<follows-from> = need() }
                when '--stop-first'  { %o<stop-first> = True }
                default { X::Do321::Usage.new(message => "unknown option $name for run").throw }
            }
            Str;
        };
        if $! { return usage-error($env, 'run', $!.message) }
        $i++;
    }
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321 run: {$!.message}"); return EXIT-INTERNAL }
    my $opts = WireOptions.new(|%o, :asked(Asked.new(|%asked)), :stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :runner(runner-of($env)),
        :signals($env.signals), :trust($cfg), :home(home-of($env).Str));
    serve(Cancel.new, $opts);
}

# ------------------------------------------------------------- inspection

#| The agent a name stands for: the local package by path when one was
#| named, else the one trust configuration resolves.  Returns (package,
#| error) so a caller can say what it was looking for.
sub load-agent-named($cfg, Global $g, Str $name --> List) is export {
    if $g.package-dir ne '' {
        my $a = try load-path($g.package-dir.IO);
        return (Nil, $!.message) if $!;
        return (Nil, "the package at {$g.package-dir} is {$a.id}, not $name")
            if $a.id ne $name && $a.manifest<name> ne $name;
        return ($a, Str);
    }
    my $a = try load-resolved($cfg.resolve($name));
    return (Nil, $!.message) if $!;
    ($a, Str);
}

#| One agent, for a person deciding which one to ask: what it is for, what
#| each skill it carries says it does, and what the package asks to be
#| allowed and refuses outright.  Every description is the package's own
#| words, shown as the claim it is - a profile is not evidence of
#| anything, and what a run may actually do is this intersected with the
#| caller's grants and local policy (authority-is-intersection.cli.321.do).
#| `321 whois <agent>`: an introduction to one agent, for a person about
#| to address it.  The same screen answers `321 agents <agent>`.
sub cmd-whois(Env $env, Global $g, @args --> Int) {
    return usage-error($env, 'whois', @args ?? "it takes one agent's name, not '{@args.join(' ')}'" !! 'say which agent; 321 agents lists them')
        unless @args == 1 && !@args[0].starts-with('-');
    cmd-agent-profile($env, $g, @args[0]);
}

sub cmd-agent-profile(Env $env, Global $g, Str $name --> Int) {
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my ($agent, $err) = load-agent-named($cfg, $g, $name);
    with $err {
        $env.stderr.say("321: $err");
        $env.stderr.say($cfg.configured.elems
            ?? next-text('see who is configured here', '321 agents')
            !! next-text('configure an agent first', '321 help trust'));
        return EXIT-DENIED;
    }
    my %m = $agent.manifest;
    my $w = $env.stdout;
    if $g.brief {
        $w.say(brief-line(%m<id>, %m<version>, $agent.level, agent-byline(%m), %m<identity><role>));
        return 0;
    }
    my sub row(Str $k, Str $v) { $w.say($_) for flat row-lines($k, $v) }
    # a skill and what it is for, in a column of its own so a long name
    # never pushes the words it explains out of line
    my sub note(Str $n, Str $t) {
        my @l = wrap-at($t, 54);
        $w.say(sprintf('  %-14s %s', $n, @l[0] // ''));
        $w.say((' ' x 17) ~ $_) for @l[1 .. *];
    }
    $w.say(header('whois', "{%m<displayName>}, {agent-byline(%m)}"));
    $w.say(subtitle("{%m<id>} {%m<version>}", $agent.level));
    $w.say('');
    # The introduction: its reason for being, its personality, and its ways
    # of working (how it speaks, how it decides), then its skills and what
    # it may do.  Each line is the package's own field under its own label:
    # joining two of them into a sentence would be writing words the
    # publisher did not.
    row('is for:', %m<identity><role>);
    for ('personality:', 'personality'), ('speaks:', 'tone'), ('decides:', 'decisionStyle') -> ($label, $field) {
        my $v = (%m<identity>{$field} // '').trim;
        row($label, $v) if $v ne '';
    }
    my @skills = (try $agent.skill-notes) // ();
    if @skills {
        $w.say('');
        row('skills:', "{many-of(@skills.elems, 'skill')}, as the package describes them");
        note(.<name>, .<what>) for @skills;
    }
    my @req = @(%m<capabilities><required> // []);
    my @opt = @(%m<capabilities><optional> // []);
    my @no  = @(%m<capabilities><denied> // []);
    $w.say('');
    row('may:', 'what it asks to be allowed, and what it refuses even if offered');
    $w.say("  {glyph('yes')} {capability-plain($_)}") for @req;
    $w.say("  {glyph('unknown')} {capability-plain($_)}, if you grant it") for @opt;
    $w.say("  {glyph('no')} {capability-plain($_)}") for @no;
    $w.say("  a run gets that, your grants and this machine's policy, intersected");
    $w.say('');
    row('trust:', $agent.label);
    row('note:', $_) for $agent.warnings;
    $w.say('');
    $w.say(next-text('ask it; nothing is committed, so you read the change and commit it', "321 $name <request...>"));
    0;
}

sub cmd-agents(Env $env, Global $g, @args --> Int) {
    return cmd-agent-profile($env, $g, @args[0]) if @args == 1 && !@args[0].starts-with('-');
    return usage-error($env, 'agents', "it takes one agent's name or none, not '{@args.join(' ')}'") if @args;
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my @list = $cfg.configured;
    if $g.brief {
        $env.stdout.say(brief-line(.id.Str, .level, ($_.pin.defined ?? .pin<version> !! ''), .alias)) for @list;
        return 0;
    }
    unless @list {
        $env.stdout.print(calm("No agents are configured in {$cfg.path}",
            'Add a pinned publisher package or a local package there, or run an unsigned local package by path with --package-dir DIR.',
            :next(['help trust' => 'how a package is pinned or a local one named'])));
        return 0;
    }
    $env.stdout.say(header('agents'));
    $env.stdout.say(subtitle("{many-of(@list.elems, 'agent')} configured", $cfg.path.Str));
    $env.stdout.say('');
    for @list -> $r {
        my $alias = $r.alias ne '' ?? '  alias ' ~ $r.alias !! '';
        my $version = $r.pin.defined ?? '  ' ~ $r.pin<version> !! '';
        $env.stdout.say(sprintf('%-32s %-12s%s%s', $r.id.Str, $r.level, $version, $alias));
    }
    my $first = @list[0].alias ne '' ?? @list[0].alias !! @list[0].id.Str;
    $env.stdout.say('');
    $env.stdout.say(next-text('read what one of them is for', "321 agents $first"));
    $env.stdout.say("then:  ask one of them");
    $env.stdout.say("       321 $first <request...>");
    0;
}

#| The packages built into the runtime, written out on request so a
#| caller with only the binary can use them by path.  `prompt` is the
#| prompt-only package (packages/prompt in the repository).
sub builtin-packages(--> Hash) {
    %( prompt => %(
        'agent.json' => q:to/JSON/,
            {
              "schema": "agent-package.v1",
              "id": "local/prompt",
              "name": "prompt",
              "displayName": "Prompt",
              "version": "0.1.0",
              "publisher": { "domain": "" },
              "licence": { "spdx": "Apache-2.0" },
              "identity": {
                "role": "a reader that answers one question about the files it can see, in text, and changes nothing",
                "byline": "the plain-spoken page reader",
                "tone": "direct"
              },
              "prompts": ["prompts/identity.md"],
              "capabilities": {
                "required": ["repo.read", "model.text"],
                "optional": [],
                "denied": ["repo.write", "files.write", "shell.run", "net.fetch", "deploy.invoke"]
              },
              "harness": { "requires": ["tool_allowlist", "structured_output"] },
              "placement": { "allowed": ["client", "server"] },
              "outputSchemas": { "default": "schemas/outcome.json" }
            }
            JSON
        'prompts/identity.md' => q:to/MD/,
            You answer the question in the work below by reading the repository you are given, and you reply in text only.

            You change nothing: no file is created, edited or deleted, and no command is run. If the question cannot be answered from what you can see, say what is missing instead of guessing.

            Put the whole answer in `summary`. When the work asks for a file's content, `summary` is that content and nothing else.
            MD
        'schemas/outcome.json' => q:to/JSON/,
            {
              "type": "object",
              "additionalProperties": false,
              "required": ["status", "summary"],
              "properties": {
                "status": {"type": "string", "enum": ["changed", "no_change", "blocked"]},
                "summary": {"type": "string", "description": "The whole answer, as text."},
                "blocked_on": {"type": "string", "description": "When status is blocked, the single thing that is missing."},
                "conditions": {"type": "array",
                  "description": "One element per done condition, in the order they were given.",
                  "items": {"type": "object", "required": ["met"],
                    "properties": {"met": {"type": "boolean"}, "proof": {"type": "string"}}}}
              }
            }
            JSON
    ) );
}

#| Write a built-in package under $home/packages/<name> if it is not
#| already there, word for word, with its DIGEST; returns the directory.
sub materialise-builtin(Str $name, IO::Path $home --> IO::Path) is export {
    my %files = builtin-packages(){$name} // die "no built-in package named $name";
    my $dir = $home.add('packages').add($name);
    my $same = $dir.d && %files.kv.map(-> $rel, $text { $dir.add($rel).f && $dir.add($rel).slurp eq $text }).all.so;
    unless $same {
        mkdir-private($home);
        mkdir-p($dir);
        for %files.kv -> $rel, $text {
            my $f = $dir.add($rel);
            mkdir-p($f.parent);
            $f.spurt($text);
        }
        write-digest-file($dir, compute($dir)[0]);
    }
    $dir;
}

# ------------------------------------------------------------------- log

#| `321 log`: what the crew has done, read back from the receipts.  The
#| command gathers facts and hands them to one screen builder; the
#| renderer is told the width, the colour and the character set
#| separately (Do321::Screens, Do321::Screen).  Every count here is a
#| receipt that exists: a run that reported no cost is said to have
#| reported none, never averaged into one that did
#| (cost-carries-its-basis.cli.321.do).
sub cmd-log(Env $env, Global $g, @args --> Int) {
    my $days  = 7;
    my $agent = '';
    # A command never shows a person's screen where a document was asked
    # for, wherever the ask stands on the line.
    my $json  = $g.json-out;
    my @rest  = @args;
    while @rest {
        my $word = @rest.shift;
        given $word {
            when '--json'  { $json = True }
            when '--brief' { $g.brief = True }
            when '--plain' { }   # taken around the command
            when '--days' {
                my $v = (@rest.shift // '').Str;
                return usage-error($env, 'log', "--days takes a number of days, not '$v'")
                    unless $v ~~ / ^ \d+ $ / && $v.Int > 0;
                $days = $v.Int;
            }
            when '--agent' {
                $agent = (@rest.shift // '').Str;
                return usage-error($env, 'log', 'say which crew member: 321 agents lists them')
                    if $agent eq '' || $agent.starts-with('-');
            }
            default { return usage-error($env, 'log', "it takes --days N, --agent NAME, --json and --brief, not '$word'") }
        }
    }

    my $dir   = home-of($env).add('runs');
    # One reading opens at most this many receipts; the screen says so
    # when it stopped there, rather than letting a count look complete.
    constant CAP = 500;
    my @runs  = read-runs($dir, :$days, :$agent, :cap(CAP));
    my %tally = tally(@runs);
    my $capped = @runs.elems >= CAP;

    # A tool gets one record per run, newest first, and nothing else.
    if $g.brief {
        for @runs -> $r {
            $env.stdout.say(brief-line($r.started.Str, $r.agent, outcome-of($r.status),
                ($r.objective ne '' ?? $r.objective !! $r.summary), $r.waiting));
        }
        return 0;
    }
    if $json {
        $env.stdout.say(log-json(@runs, %tally, :$days, :$agent, dir => $dir.Str));
        return 0;
    }
    my $home = ($*HOME // ''.IO).Str;
    my $shown = $home ne '' && $dir.Str.starts-with($home) ?? '~' ~ $dir.Str.substr($home.chars) !! $dir.Str;
    $env.stdout.say($_) for screen-text(
        log-screen(@runs, %tally, :$days, :$agent, :$capped, dir => $shown),
        :colour(pretty-on()), :utf8(utf8-terminal()));
    0;
}

# ------------------------------------------------- value, outcomes, contexts, lessons

my sub learn-say(Env $env, @lines) { $env.stdout.say($_) for @lines }

my sub who-am-i(--> Str) { (%*ENV<USER> // 'someone') }

my sub since-text(Int $days --> Str) { $days == 1 ?? 'the last day' !! "the last $days days" }

#| What a set of runs came to, as rows a person reads.
my sub sum-rows(%s --> List) {
    my @r;
    my $spend = %s<priced-runs> ?? money(%s<usd>) ~ ", reported by the harness for {many-of(%s<priced-runs>, 'run')}" !! 'nothing reported';
    $spend ~= "; {many-of(%s<unpriced-runs>, 'run')} reported no cost: unknown, not free" if %s<unpriced-runs>;
    $spend ~= "; {many-of(%s<modelless-runs>, 'run')} used no model" if %s<modelless-runs>;
    @r.append: row-lines('spent:', $spend);
    @r.append: row-lines('tokens:', %s<token-runs> ?? count-text(%s<tokens>) ~ " over {many-of(%s<token-runs>, 'run')} that reported them" !! 'not reported');
    @r.append: row-lines('time:', duration(%s<seconds>) ~ " of agent time over {many-of(%s<runs>, 'run')}" ~ (%s<retries> ?? ", {many-of(%s<retries>, 'retry').subst('retrys', 'retries')}" !! ''));
    my @said;
    @said.push("{%s<accepted>} accepted") if %s<accepted>;
    @said.push("{%s<corrected>} corrected") if %s<corrected>;
    @said.push("{%s<rejected>} rejected") if %s<rejected>;
    @said.push("{%s<unknown>} not yet said") if %s<unknown>;
    @r.append: row-lines('outcomes:', "{%s<finished>} of {%s<runs>} finished; " ~ (@said ?? @said.join(', ') !! 'none'));
    @r.List;
}

my sub sums-doc(%s --> Hash) {
    %( runs => %s<runs>, finished => %s<finished>,
       spend => %( usd => %s<usd>, runsReporting => %s<priced-runs>, runsNotReporting => %s<unpriced-runs>, runsWithoutAModel => %s<modelless-runs> ),
       tokens => (%s<token-runs> ?? %( total => %s<tokens>, runsReporting => %s<token-runs> ) !! Nil),
       seconds => %s<seconds>.Int, retries => %s<retries>,
       outcomes => %( accepted => %s<accepted>, corrected => %s<corrected>, rejected => %s<rejected>, unknown => %s<unknown> ) );
}

#| `321 value`: what the work cost and, where it can be shown, what it
#| saved.  Spend is what a harness reported; a run that reported nothing
#| is unknown.  Savings are an estimate against a stated baseline, and
#| are withheld until there is enough accepted work to rest them on.
sub cmd-value(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my ($days, $agent, $ctx, $minutes, $rate) = 30, '', $g.context, Any, Any;
    my $json = $g.json-out;
    my @rest = @args;
    my $sub = @rest && @rest[0] eq 'baseline' ?? @rest.shift !! '';
    while @rest {
        my $word = @rest.shift;
        my sub num(Str $what) {
            my $v = (@rest.shift // '').Str;
            $v ~~ / ^ \d+ [ '.' \d+ ]? $ / && $v > 0 ?? $v.Numeric !! Nil;
        }
        given $word {
            when '--json'    { $json = True }
            when '--brief'   { $g.brief = True }
            when '--plain'   { }
            when '--days'    { $days = (num('days') // return usage-error($env, 'value', '--days takes a number of days')).Int }
            when '--minutes' { $minutes = num('minutes') // return usage-error($env, 'value', '--minutes takes a number') }
            when '--rate'    { $rate = num('rate') // return usage-error($env, 'value', '--rate takes dollars an hour, as a number') }
            when '--agent'   { $agent = (@rest.shift // '').Str; return usage-error($env, 'value', 'say which agent') if $agent eq '' }
            when '--context' { $ctx = (@rest.shift // '').Str; return usage-error($env, 'value', 'say which work context') if $ctx eq '' }
            default { return usage-error($env, 'value', "it takes --days N, --agent NAME, --context NAME, --json and --brief, not '$word'") }
        }
    }
    my $w = $env.stdout;
    if $sub eq 'baseline' {
        return usage-error($env, 'value', 'a baseline is --minutes N (a person\'s time for one accepted run) and --rate DOLLARS (an hour of it)')
            unless $minutes.defined && $rate.defined;
        my %b = set-baseline($home, $minutes, $rate);
        if $json { $w.say(encode-json(%( schema => SCHEMA-VALUE, baseline => %b ))); return 0 }
        if $g.brief { $w.say(brief-line('baseline', $minutes, $rate)); return 0 }
        learn-say($env, [header('value baseline', 'set'), '',
            |row-lines('baseline:', "$minutes minutes of a person's time for each accepted run, at \$$rate an hour"),
            |row-lines('it is:', 'your own estimate; every savings figure says it rests on it'), '',
            next-text('see what the work has cost and saved', '321 value')]);
        return 0;
    }
    my @work = read-work($home, :$days);
    @work = @work.grep({ .who eq $agent || .agent eq $agent }) if $agent ne '';
    @work = @work.grep({ .context eq $ctx }) if $ctx ne '';
    my %s = sums(@work);
    my $base = baseline($home);
    my %sv = savings(%s, $base);
    my %by-agent = @work.classify(*.who).map({ .key => sums(.value) });
    my %by-harness = @work.grep({ .harness ne '' && .harness ne 'none' }).classify(*.harness).map({ .key => sums(.value) });
    my %by-context = @work.grep({ .context ne '' }).classify(*.context).map({ .key => sums(.value) });
    if $g.brief {
        # one record a group: kind, name, runs, finished, usd or '?', runs reporting cost, tokens or '?', seconds, accepted, rejected, corrected, unknown
        my sub rec(Str $kind, Str $name, %x) {
            $w.say(brief-line($kind, $name, %x<runs>, %x<finished>, (%x<priced-runs> ?? sprintf('%.4f', %x<usd>) !! %x<unpriced-runs> ?? '?' !! '0'), %x<priced-runs>,
                (%x<token-runs> ?? %x<tokens> !! '?'), %x<seconds>.Int, %x<accepted>, %x<rejected>, %x<corrected>, %x<unknown>));
        }
        rec('all', '-', %s);
        rec('agent', .key, .value) for %by-agent.sort(*.key);
        rec('harness', .key, .value) for %by-harness.sort(*.key);
        rec('context', .key, .value) for %by-context.sort(*.key);
        $w.say(brief-line('savings', (%sv<known> ?? sprintf('%.2f', %sv<net>) !! '?'), (%sv<known> ?? %sv<assumption> !! %sv<why>)));
        return 0;
    }
    if $json {
        $w.say(encode-json(%( schema => SCHEMA-VALUE, days => $days, agent => ($agent || Nil), context => ($ctx || Nil),
            total => sums-doc(%s),
            byAgent => %( %by-agent.map({ .key => sums-doc(.value) }) ),
            byHarness => %( %by-harness.map({ .key => sums-doc(.value) }) ),
            byContext => %( %by-context.map({ .key => sums-doc(.value) }) ),
            baseline => ($base ~~ Associative ?? $base !! Nil),
            savings => (%sv<known>
                ?? %( estimate => True, acceptedRuns => %sv<accepted>, minutesOfAPersonsTime => %sv<minutes>, worthUsd => %sv<worth>,
                      spendUsd => %sv<spend>, spendIsAFloor => %sv<spend-is-floor>, netUsd => %sv<net>, assumption => %sv<assumption>, minimumSample => MIN-SAMPLE )
                !! %( estimate => False, why => %sv<why>, minimumSample => MIN-SAMPLE )) )));
        return 0;
    }
    my $what = since-text($days) ~ ($agent ne '' ?? ", $agent" !! '') ~ ($ctx ne '' ?? ", context $ctx" !! '');
    my @l = header('value', $what), '';
    unless @work {
        @l.append: 'No runs with a receipt in that time.', '', next-text('ask an agent for something', '321 agents');
        learn-say($env, @l);
        return 0;
    }
    @l.append: sum-rows(%s);
    if %sv<known> {
        @l.append: row-lines('saved:', "about {money(%sv<net>)}, an estimate: {%sv<accepted>} accepted runs at your baseline is {duration(%sv<minutes> * 60)} of a person's time, worth {money(%sv<worth>)}, less the {money(%sv<spend>)} spent"
            ~ (%sv<spend-is-floor> ?? ' (at least: some runs reported no cost)' !! ''));
        @l.append: row-lines('rests on:', %sv<assumption> ~ '; only accepted work is counted, and everything spent is set against it');
    }
    else {
        @l.append: row-lines('savings:', "none estimated: {%sv<why>}");
    }
    my sub group(Str $title, %g) {
        return unless %g.elems > 1 || ($title eq 'by context' && %g);
        @l.append: '', $title;
        for %g.sort({ -.value<runs> }) -> $p {
            my %x = $p.value;
            @l.push: sprintf('  %-14s %-10s %-13s %-9s %s', $p.key.substr(0, 14), many-of(%x<runs>, 'run'),
                (%x<priced-runs> ?? money(%x<usd>) !! %x<unpriced-runs> ?? 'cost unknown' !! 'no model') ~ (%x<priced-runs> && %x<unpriced-runs> ?? '+' !! ''),
                duration(%x<seconds>), (%x<accepted> + %x<rejected> + %x<corrected> ?? "{%x<accepted>} accepted of {%x<accepted> + %x<rejected> + %x<corrected>} said" !! 'outcomes not said'));
        }
    }
    group('by agent', %by-agent);
    group('by harness', %by-harness);
    group('by context', %by-context);
    @l.push: '';
    @l.push: !$base.defined ?? next-text('say what accepted work would have taken you, and savings can be estimated', '321 value baseline --minutes 30 --rate 60')
        !! %s<unknown> ?? next-text('say what came of a run, so it can be counted', '321 outcome <run> accepted')
        !! next-text('the whole calculation, for a program', '321 value --json');
    learn-say($env, @l);
    0;
}

#| `321 outcome <run> accepted|rejected|corrected [why...]`: what a person
#| or the calling work system says came of a run.  Kept beside the
#| receipt, which is never changed.
sub cmd-outcome(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    return usage-error($env, 'outcome', 'say which run and what came of it: accepted, rejected or corrected') if @a < 2;
    my ($ref, $word) = @a[0], @a[1];
    return usage-error($env, 'outcome', "an outcome is accepted, rejected or corrected, not '$word'") unless is-in($word, OUTCOMES);
    my $n = $ref.uc;
    my @m = $home.add('runs').d ?? $home.add('runs').dir.grep(*.d).map(*.basename).grep({ $_ eq $n || (.ends-with($n) && $n.chars >= 3) }) !! ();
    if @m != 1 {
        $env.stderr.say(@m ?? "321: {@m.elems} runs end in $ref; give more of the id" !! "321: no run here is called $ref");
        $env.stderr.say(next-text('see your runs and their ids', '321 status'));
        return EXIT-USAGE;
    }
    my %o = (try record-outcome($home, @m[0], $word, note => @a[2 .. *].join(' '), by => who-am-i())) // %();
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
    if $json { $env.stdout.say(encode-json(%o)); return 0 }
    if $g.brief { $env.stdout.say(brief-line(@m[0], $word)); return 0 }
    my $had = $home.add('runs').add(@m[0]).add('receipt.json').e;
    learn-say($env, [header('outcome', "{@m[0].substr(*-3)} $word"), '',
        |row-lines('run:', @m[0]), |row-lines('said:', "$word, by {who-am-i()}" ~ (%o<note> ne '' ?? ": {%o<note>}" !! '')),
        |row-lines('receipt:', $had ?? 'unchanged; the outcome is kept beside it' !! 'none yet; the outcome is kept for when there is'), '',
        next-text('see what the work has come to', '321 value')]);
    0;
}

#| `321 context`: regions of related work, each with a purpose and a history.
sub cmd-context(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    my $w = $env.stdout;
    my $sub = @a ?? @a[0] !! 'list';
    my sub need-context(Str $name) {
        my $c = context($home, $name);
        without $c {
            $env.stderr.say("321: no work context is called '$name'");
            $env.stderr.say(next-text('see the ones there are', '321 context'));
        }
        $c;
    }
    given $sub {
        when 'list' {
            my @c = contexts($home);
            my @work = read-work($home, :days(3650));
            if $json { $w.say(encode-json(%( contexts => [ @c.map({ %( name => .<name>, purpose => .<purpose>, runs => @work.grep(-> $r { $r.context eq .<name> }).elems ) }) ] ))); return 0 }
            if $g.brief { $w.say(brief-line(.<name>, @work.grep(-> $r { $r.context eq .<name> }).elems, .<purpose>)) for @c; return 0 }
            my @l = header('context', @c ?? many-of(@c.elems, 'work context') !! 'none yet'), '';
            for @c -> %c {
                @l.push: sprintf('  %-28s %-9s %s', %c<name>, many-of(@work.grep({ .context eq %c<name> }).elems, 'run'), %c<purpose>);
            }
            # those an organisation holds at the registry and this machine has no copy of
            my @there = registry-contexts($home).grep(-> %r { !@c.first({ .<name> eq %r<name> }).defined });
            if @there {
                @l.append: '', 'at the registry, not here:';
                @l.push: sprintf('  %-28s %-9s %s', .<name>, (.<sharing> // ''), (.<purpose> // '')) for @there;
            }
            @l.push: '' if @c || @there;
            @l.push: @c ?? next-text('run something in one', "321 --context {@c[0]<name>} <agent> <request...>")
                        !! next-text('begin one: a name, and what the work is for', '321 context new checkout make checkout work on a phone');
            learn-say($env, @l);
            return 0;
        }
        when 'new' {
            return usage-error($env, 'context', 'a context is a name and what it is for: 321 context new NAME <words...>') if @a < 3;
            return usage-error($env, 'context', "a name is lower-case letters, digits, dots and dashes, not '{@a[1]}'") unless learn-name-ok(@a[1]);
            if context($home, @a[1]).defined { $env.stderr.say("321: there is already a work context called '{@a[1]}'"); $env.stderr.say(next-text('see it', "321 context show {@a[1]}")); return EXIT-USAGE }
            my %c = new-context($home, @a[1], @a[2 .. *].join(' '));
            if $json { $w.say(encode-json(%c)); return 0 }
            if $g.brief { $w.say(brief-line(%c<name>, 'new')); return 0 }
            learn-say($env, [header('context new', %c<name>), '', |row-lines('for:', %c<purpose>),
                |row-lines('owned by:', %c<owner> ne '' ?? "{%c<owner>}, by its name; the name says whose it is and grants nothing" !! 'you: a plain name is a personal context'),
                |row-lines('kept in:', '~/.321/contexts on this machine; private' ~ (%c<owner> ne '' ?? ". {%c<owner>} shares it, if it chooses, at the registry" !! '')), '',
                next-text('run something in it', "321 --context {%c<name>} <agent> <request...>")]);
            return 0;
        }
        when 'pull' {
            return usage-error($env, 'context', 'say which context: 321 context pull NAME') if @a < 2;
            my $doc = try registry-get($home, "/api/contexts/{@a[1]}");
            if $! {
                $env.stderr.say("321: {$!.message}");
                $env.stderr.say(next-text('a private context needs its organisation\'s token', '321 registry token'));
                return EXIT-FAILED;
            }
            my %c = (try pull-context($home, $doc.Hash, registry-url($home))) // %();
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            # the lessons kept there for it: a registry that has none to
            # give, or will not give them, leaves the ones here as they were
            my $why = '';
            my $got = try registry-get($home, "/api/lessons?context={%c<name>}");
            if $! { $why = $!.message }
            elsif $got<lessons> ~~ Positional { %c = pull-context-lessons($home, %c<name>, @($got<lessons>)) }
            else { $why = 'the registry\'s answer held no list of lessons' }
            my $held = context-lessons(%c).elems;
            if $json { $w.say(encode-json(%( |%c, |($why ne '' ?? (lessonsNote => $why) !! ()) ))); return 0 }
            if $g.brief { $w.say(brief-line(%c<name>, 'pulled', %c<sharing>, %c<notes>.elems, $held, ($why ne '' ?? 'lessons not refreshed' !! 'lessons refreshed'))); return 0 }
            learn-say($env, [header('context pull', %c<name>), '', |row-lines('for:', %c<purpose>),
                |row-lines('owned by:', %c<owner>), |row-lines('sharing:', %c<sharing> eq 'public' ?? 'public: its organisation shares it with everyone' !! 'private to its organisation'),
                |row-lines('history:', many-of(@(%c<notes>).grep({ (.<from> // '') eq 'registry' }).elems, 'entry').subst('entrys', 'entries') ~ ' from the registry; notes made here stay here'),
                |row-lines('lessons:', $why eq '' ?? "{$held} from the registry; runs in it are told them as advice"
                    !! "not refreshed: $why. " ~ ($held ?? "The {$held} kept from before " ~ ($held == 1 ?? 'is' !! 'are') ~ ' still in use' !! 'None are kept here')),
                |row-lines('copy:', "from {%c<source>}; pull again to refresh it"), '',
                next-text('run something in it', "321 --context {%c<name>} <agent> <request...>")]);
            return 0;
        }
        when 'decided' | 'rejected' | 'note' {
            return usage-error($env, 'context', "say which context and what: 321 context $sub NAME <words...>") if @a < 3;
            need-context(@a[1]) // return EXIT-USAGE;
            my %c = context-note($home, @a[1], ($sub eq 'decided' ?? 'decision' !! $sub), @a[2 .. *].join(' '));
            if $json { $w.say(encode-json(%c)); return 0 }
            if $g.brief { $w.say(brief-line(%c<name>, $sub, %c<notes>.elems)); return 0 }
            learn-say($env, [header("context $sub", %c<name>), '', |row-lines('kept:', @a[2 .. *].join(' ')),
                |row-lines('told to:', "runs started in this context from now on, as what is already known"), '',
                next-text('see the whole context', "321 context show {%c<name>}")]);
            return 0;
        }
        when 'show' {
            return usage-error($env, 'context', 'say which context: 321 context show NAME') if @a < 2;
            my %c = (need-context(@a[1]) // return EXIT-USAGE).Hash;
            my @work = read-work($home, :days(3650)).grep({ .context eq %c<name> });
            my %s = sums(@work);
            my @ls = lessons($home).grep({ ((.<scope> // {})<context> // '') eq %c<name> });
            my @kept = context-lessons(%c);
            if $json { $w.say(encode-json(%( |%c, runs => sums-doc(%s), lessons => [ @ls.map(*<id>) ], registryLessons => [ |@kept ] ))); return 0 }
            if $g.brief { $w.say(brief-line(%c<name>, %s<runs>, (%s<priced-runs> ?? %s<usd> !! '?'), %c<purpose>)); return 0 }
            my @l = header('context', %c<name>), '', |row-lines('for:', %c<purpose> // '');
            my $owner = (%c<owner> // '') || context-owner(%c<name>);
            @l.append: row-lines('owned by:', $owner ne '' ?? $owner !! 'you');
            @l.append: row-lines('copy of:', "{%c<source>}, pulled {age-text(%c<pulledAt> // '')}; {(%c<sharing> // 'private') eq 'public' ?? 'shared with everyone' !! 'private to its organisation'}") if (%c<source> // '') ne '';
            for @(%c<notes> // []) -> %n { @l.append: row-lines((%n<kind> eq 'decision' ?? 'decided:' !! %n<kind> eq 'rejected' ?? 'rejected:' !! 'noted:'), %n<text>) }
            @l.append: row-lines('lessons:', @ls ?? @ls.map({ "{.<id>} ({.<state>})" }).join(', ') !! 'none scoped to it');
            @l.append: row-lines('registry:', "{many-of(@kept.elems, 'lesson')} kept there, pulled {age-text(%c<lessonsPulledAt> // '')}") if %c<lessonsPulledAt>:exists;
            @l.push: '';
            if @work { @l.append: sum-rows(%s) } else { @l.push: 'No runs in it yet.' }
            @l.append: '', next-text('run something in it', "321 --context {%c<name>} <agent> <request...>");
            learn-say($env, @l);
            return 0;
        }
        default { return usage-error($env, 'context', "it is new, show, pull, decided, rejected or note, not '$sub'") }
    }
}

#| `321 lessons`: what agents have learnt here.  Add one, see whether it
#| helps, keep it or revert it; share one with the project on purpose.
sub cmd-lessons(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    my $w = $env.stdout;
    my ($ws) = resolve-workspace($g.workspace);
    my $project = project-root($ws);
    my $sub = @a ?? @a.shift !! 'list';
    my sub need-lesson(Str $id) {
        my $l = lesson($home, $id, :$project);
        without $l {
            $env.stderr.say("321: no lesson here is called '$id'");
            $env.stderr.say(next-text('see the ones there are', '321 lessons'));
        }
        $l;
    }
    my sub verdict(%c --> Str) {
        return "applied to {many-of(%c<with><runs>, 'run')}; {MIN-SAMPLE} with it and {MIN-SAMPLE} comparable without are needed before anything can be said" unless %c<enough>;
        my sub rate(%x) { %x<runs> ?? (100 * %x<finished> / %x<runs>).round ~ '% finished' !! '' }
        my sub cost(%x) { %x<median-usd>.defined ?? 'median ' ~ money(%x<median-usd>) !! 'cost unknown' }
        "with it: {%c<with><runs>} runs, {rate(%c<with>)}, {cost(%c<with>)}, median {duration(%c<with><median-seconds> // 0)}. "
            ~ "Without: {%c<without><runs>} runs, {rate(%c<without>)}, {cost(%c<without>)}, median {duration(%c<without><median-seconds> // 0)}."
    }
    given $sub {
        when 'list' {
            my @ls = lessons($home, :$project);
            my @work = read-work($home, :days(365));
            # those a registry keeps, held in the contexts pulled from it: read only here
            my @there = registry-lessons($home);
            if $json { $w.say(encode-json(%( lessons => [ @ls.map({ %( |$_, comparison => compare-lesson($_, @work) ) }) ], registry => [ |@there ] ))); return 0 }
            if $g.brief {
                $w.say(brief-line(.<id>, .<state>, .<kept-in>, scope-text($_), .<text>)) for @ls;
                $w.say(brief-line(.<id>, .<state>, 'registry', (.<at> ne '' ?? "context {.<at>}" !! 'this organisation'), .<text>)) for @there;
                return 0;
            }
            my @l = header('lessons', (@ls ?? many-of(@ls.elems, 'lesson') !! @there ?? 'none of yours yet' !! 'none yet') ~ (@there ?? ", {@there.elems} from the registry" !! '')), '';
            for @ls -> %x {
                my $n = @work.grep({ %x<id> (elem) .lessons }).elems;
                @l.push: sprintf('  %-7s %-9s %-10s %s', %x<id>, %x<state>, (%x<kept-in> eq 'project' ?? 'project' !! 'yours'), "{scope-text(%x)}; applied to {many-of($n, 'run')}");
                @l.append: wrap-at(%x<text>, 66).map({ (' ' x 10) ~ $_ });
            }
            if @there {
                @l.append: '' if @ls;
                @l.push: 'from the registry, read only here:';
                for @there -> %x {
                    @l.push: sprintf('  %-28s %-9s %s', (%x<name> ne '' ?? %x<name> !! %x<id>), %x<state>, 'in ' ~ (%x<at> ne '' ?? %x<at> !! 'this organisation'));
                    @l.append: wrap-at(%x<text>, 66).map({ (' ' x 10) ~ $_ });
                }
            }
            @l.push: '' if @ls || @there;
            @l.push: @ls ?? next-text('see whether one helps: the runs with it against the runs without', "321 lessons show {@ls[0]<id>}")
                         !! next-text('add one; it is tried from the next run it applies to', '321 lessons add --agent <agent> <what was learnt...>');
            learn-say($env, @l);
            return 0;
        }
        when 'add' {
            my (%scope, $from);
            my ($when, $because) = '', '';
            while @a && @a[0].starts-with('--') {
                my $f = @a.shift;
                my $v = (@a.shift // '').Str;
                return usage-error($env, 'lessons', "$f needs a value") if $v eq '';
                given $f {
                    when '--agent'   { %scope<agent> = $v }
                    when '--context' { return usage-error($env, 'lessons', "no work context is called '$v'") unless context-for($home, $v).defined; %scope<context> = $v }
                    when '--skill'   { %scope<skill> = $v }
                    when '--harness' { %scope<harness> = $v }
                    when '--from'    { $from = $v }
                    when '--when'    { $when = $v }
                    when '--because' { $because = $v }
                    default { return usage-error($env, 'lessons', "add takes --agent, --context, --skill, --harness, --from, --when and --because, not '$f'") }
                }
            }
            %scope<context> = $g.context if $g.context ne '' && !(%scope<context>:exists);
            return usage-error($env, 'lessons', 'say what was learnt: 321 lessons add [--agent NAME] <words...>') unless @a;
            my %l = add-lesson($home, @a.join(' '), %scope, %( from => ($from.defined ?? 'run' !! 'person'), |($from.defined ?? (runId => $from) !! ()), by => who-am-i() ), :$when, :$because);
            if $json { $w.say(encode-json(%l)); return 0 }
            if $g.brief { $w.say(brief-line(%l<id>, 'trial')); return 0 }
            learn-say($env, [header('lessons add', %l<id>), '', |row-lines('lesson:', %l<text>), |row-lines('applies to:', scope-text(%l)),
                |row-lines('state:', 'on trial: runs it applies to are given it as advice, and record that they were'),
                |row-lines('kept in:', '~/.321/lessons, yours alone until you share it'), '',
                next-text('after a few runs, see whether it helps', "321 lessons show {%l<id>}")]);
            return 0;
        }
        when 'teach' {
            # the one way a lesson leaves this machine for a registry: a
            # person types it, for one lesson, and is told where it went
            my ($when, $because) = '', '';
            my @ids;
            while @a {
                my $f = @a.shift;
                if $f eq '--when' | '--because' {
                    my $v = (@a.shift // '').Str;
                    return usage-error($env, 'lessons', "$f needs a value") if $v eq '';
                    if $f eq '--when' { $when = $v } else { $because = $v }
                }
                elsif $f.starts-with('--') { return usage-error($env, 'lessons', "teach takes --when and --because, not '$f'") }
                else { @ids.push($f) }
            }
            return usage-error($env, 'lessons', 'say which lesson: 321 lessons teach ID [--when <words>] [--because <words>]') unless @ids.elems == 1;
            my %l = (need-lesson(@ids[0]) // return EXIT-USAGE).Hash;
            my %t = %l<taught> ~~ Associative ?? %l<taught>.Hash !! {};
            if (%t<id> // '') ne '' {
                if $json { $w.say(encode-json(%( |%l, alreadyTaught => True ))); return 0 }
                if $g.brief { $w.say(brief-line(%l<id>, 'already taught', %t<id>, %t<at> // '')); return 0 }
                learn-say($env, [header('lessons teach', "{%l<id>} was already taught"), '', |row-lines('lesson:', %l<text>),
                    |row-lines('taught to:', "{%t<at> // '?'}, {%t<when> // '?'}"), |row-lines('known as:', %t<id>),
                    |row-lines('sent:', 'nothing this time'), '', next-text('see them all', '321 lessons')]);
                return 0;
            }
            my %s = %l<scope> ~~ Associative ?? %l<scope>.Hash !! {};
            my $to = (%s<context> // '').Str;
            return usage-error($env, 'lessons', "a lesson is taught to a work context, and {%l<id>} is scoped to none: add it again with --context NAME") if $to eq '';
            $when = (%l<when> // '').Str if $when eq '';
            $because = (%l<because> // '').Str if $because eq '';
            return usage-error($env, 'lessons', "say when it applies: 321 lessons teach {%l<id>} --when <words>") if $when eq '';
            return usage-error($env, 'lessons', "say why it holds: 321 lessons teach {%l<id>} --because <words>") if $because eq '';
            my %body = context => $to, when => $when, do => (%l<text> // '').Str, because => $because;
            %body<agent> = %s<agent>.split('/').tail if (%s<agent> // '') ne '';
            my $card = try registry-get($home, '/api/lessons', send => encode-json(%body));
            if $! {
                $env.stderr.say("321: {$!.message}");
                $env.stderr.say(next-text('nothing was taught, and the lesson here is as it was; see which registry this is and who you are to it', '321 registry'));
                return EXIT-FAILED;
            }
            if ($card<id> // '') eq '' {
                $env.stderr.say('321: the registry answered, but not with a lesson: it is not recorded here as taught');
                return EXIT-FAILED;
            }
            my $at = ($card<at> // '').Str || $to;
            my %n = mark-taught(%l, $card<id>.Str, $at, :$when, :$because);
            if $json { $w.say(encode-json(%( |%n, card => $card ))); return 0 }
            if $g.brief { $w.say(brief-line(%n<id>, 'taught', %n<taught><id>, $at)); return 0 }
            learn-say($env, [header('lessons teach', "{%n<id>} taught to $at"), '', |row-lines('lesson:', %n<text>),
                |row-lines('when:', $when), |row-lines('because:', $because),
                |row-lines('known as:', "{%n<taught><id>} at {registry-url($home)}, " ~ (($card<state> // '') eq 'trial' ?? 'on trial there' !! ($card<state> // '') ne '' ?? "{$card<state>} there" !! 'as the registry keeps it')),
                |row-lines('told to:', "runs in $at and the names under it, once their copy is pulled again"), '',
                next-text('refresh your own copy', "321 context pull $at")]);
            return 0;
        }
        when 'show' | 'keep' | 'revert' | 'remove' | 'share' {
            return usage-error($env, 'lessons', "say which lesson: 321 lessons $sub ID") unless @a;
            my %l = (need-lesson(@a[0]) // return EXIT-USAGE).Hash;
            my %c = compare-lesson(%l, read-work($home, :days(365)));
            given $sub {
                when 'show' {
                    if $json { $w.say(encode-json(%( |%l, comparison => %( enough => %c<enough>, minimumSample => MIN-SAMPLE, with => sums-doc(%c<with>), without => sums-doc(%c<without>) ) ))); return 0 }
                    if $g.brief { $w.say(brief-line(%l<id>, %l<state>, %c<with><runs>, %c<without><runs>, (%c<enough> ?? 'comparable' !! 'too few'))); return 0 }
                    my %p = %l<provenance> // {};
                    learn-say($env, [header('lessons show', %l<id>), '', |row-lines('lesson:', %l<text>), |row-lines('applies to:', scope-text(%l)),
                        |row-lines('state:', %l<state>), |row-lines('kept in:', %l<kept-in> eq 'project' ?? "this project ({%l<file>})" !! '~/.321/lessons, yours alone'),
                        |row-lines('came from:', (%p<from> eq 'run' ?? "run {%p<runId>}" !! 'a person') ~ ", {%p<by> // '?'}, {%p<at> // '?'}" ~ ((%p<sharedBy> // '') ne '' ?? "; shared by {%p<sharedBy>}" !! '')),
                        |((%l<taught> // {})<id> ?? row-lines('taught:', "to {%l<taught><at>}, as {%l<taught><id>}") !! ()),
                        |row-lines('evidence:', verdict(%c)),
                        |row-lines('mind:', 'the runs are not a controlled trial: other things may differ between them'), '',
                        next-text('yours to say', "321 lessons keep {%l<id>}    or    321 lessons revert {%l<id>}")]);
                    return 0;
                }
                when 'keep' | 'revert' {
                    my %n = set-lesson-state(%l, ($sub eq 'keep' ?? 'kept' !! 'reverted'), @a[1 .. *].join(' '));
                    if $json { $w.say(encode-json(%n)); return 0 }
                    if $g.brief { $w.say(brief-line(%n<id>, %n<state>)); return 0 }
                    learn-say($env, [header("lessons $sub", %n<id>), '', |row-lines('lesson:', %n<text>),
                        |row-lines('now:', $sub eq 'keep' ?? 'kept: it goes on being given to the runs it applies to' !! 'reverted: no run is given it; it stays on record, and keep puts it back'), '',
                        next-text('see them all', '321 lessons')]);
                    return 0;
                }
                when 'remove' {
                    remove-lesson(%l);
                    if $json { $w.say(encode-json(%( id => %l<id>, removed => True ))); return 0 }
                    if $g.brief { $w.say(brief-line(%l<id>, 'removed')); return 0 }
                    learn-say($env, [header('lessons remove', %l<id>), '', |row-lines('removed:', %l<text>),
                        |row-lines('runs:', 'the runs that were given it still say so'), '', next-text('see what is left', '321 lessons')]);
                    return 0;
                }
                when 'share' {
                    if $project eq '' {
                        $env.stderr.say('321: this directory is in no repository, so there is no project to share it with');
                        $env.stderr.say(next-text('share from inside the project', '321 --workspace <repo> lessons share ' ~ %l<id>));
                        return EXIT-USAGE;
                    }
                    my %n = share-lesson(%l, $project, who-am-i());
                    my $file = project-lessons-dir($project).add("{%n<id>}.json").Str;
                    if $json { $w.say(encode-json(%( |%n, file => $file ))); return 0 }
                    if $g.brief { $w.say(brief-line(%n<id>, 'shared', $file)); return 0 }
                    learn-say($env, [header('lessons share', %n<id>), '', |row-lines('lesson:', %n<text>), |row-lines('written:', $file),
                        |row-lines('the team:', 'gets it when this file is committed and merged, as any other change is; 321 commits nothing'), '',
                        next-text('review it and commit it yourself', "git add {$file.subst($project ~ '/', '')}")]);
                    return 0;
                }
            }
        }
        default { return usage-error($env, 'lessons', "it is add, show, keep, revert, remove, share or teach, not '$sub'") }
    }
}

# ------------------------------------------------------- the registry, and skills

my sub age-text(Str $iso --> Str) {
    my $t = try DateTime.new($iso);
    return 'never' without $t;
    my $s = (now - $t.Instant).Int max 0;
    $s < 120 ?? 'just now' !! $s < 7200 ?? "{$s div 60} minutes ago" !! $s < 172800 ?? "{$s div 3600} hours ago" !! "{$s div 86400} days ago";
}

#| `321 registry`: where agents and skills are described, the copy kept
#| here, and the token this person holds.
sub cmd-registry(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    my $w = $env.stdout;
    my $sub = @a ?? @a[0] !! 'status';
    given $sub {
        when 'use' {
            return usage-error($env, 'registry', 'say which registry: 321 registry use URL') if @a < 2 || !(@a[1] ~~ / ^ [ 'https://' | 'http://' | 'file://' ] /);
            set-registry-url($home, @a[1]);
            if $json { $w.say(encode-json(%( url => registry-url($home) ))); return 0 }
            if $g.brief { $w.say(brief-line('registry', registry-url($home))); return 0 }
            learn-say($env, [header('registry use', registry-url($home)), '', |row-lines('registry:', registry-url($home)),
                |row-lines('copy:', 'the copy kept here is of the registry it was read from; sync reads this one'), '', next-text('read it', '321 registry sync')]);
            return 0;
        }
        when 'token' {
            my $t = ($env.stdin.next // '').trim;
            set-registry-token($home, $t);
            if $json { $w.say(encode-json(%( token => ($t ne '' ?? 'set' !! 'removed') ))); return 0 }
            if $g.brief { $w.say(brief-line('token', $t ne '' ?? 'set' !! 'removed')); return 0 }
            learn-say($env, [header('registry token', $t ne '' ?? 'set' !! 'removed'), '',
                |row-lines('token:', $t ne '' ?? 'kept in ~/.321/registry-token, readable by you alone; it is never shown' !! 'none: the registry is read as anyone may read it'), '',
                next-text('read what it lets you see', '321 registry sync')]);
            return 0;
        }
        when 'sync' | 'status' {
            my %s = try { $sub eq 'sync' ?? registry-sync($home) !! registry-state($home) } // %();
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            my $failed = $sub eq 'sync' && (%s<error> // '') ne '';
            my $told = '';
            if $sub eq 'sync' && !$failed && sharing-on($home) {
                my %r = try { send-reports($home) } // %();
                $told = $! ?? "not sent: {$!.message}" !! %r<sent> ?? "{many-of(%r<sent>, 'outcome')} sent to the record" ~ (%r<signed> ?? ", {%r<signed>} signed" !! '') ~ (%r<duplicateReceipt> ?? "; {%r<duplicateReceipt>} already counted from another account" !! '') ~ (%r<unknownAgent> ?? "; {%r<unknownAgent>} for agents the registry does not hold" !! '') !! 'nothing new to send';
                %s<reports> = $told;
            }
            if $json { $w.say(encode-json(%( url => registry-url($home), |%s ))); return $failed ?? EXIT-FAILED !! 0 }
            if $g.brief {
                $w.say(brief-line('registry', registry-url($home), ($failed ?? 'unreachable' !! (%s<syncedAt> // '') ne '' ?? 'synced' !! 'never'), (%s<syncedAt> // ''), (%s<agents> // ''), (%s<skills> // '')));
                return $failed ?? EXIT-FAILED !! 0;
            }
            my $have = (%s<syncedAt> // '') ne '';
            my @l = header("registry" ~ ($sub eq 'sync' ?? ' sync' !! ''), $failed ?? 'not read' !! $have ?? "read {age-text(%s<syncedAt>)}" !! 'never read'), '';
            @l.append: row-lines('registry:', registry-url($home));
            @l.append: row-lines('you are:', registry-token($home) ne '' ?? 'known to it by your token' !! 'anyone: no token, so public descriptions only');
            @l.append: row-lines('problem:', %s<error>) if (%s<error> // '') ne '' && ($failed || $sub eq 'status');
            if $have {
                @l.append: row-lines('copy here:', "{many-of((%s<agents> // 0).Int, 'agent')}" ~ ((%s<skills>:exists) ?? ", {many-of(%s<skills>.Int, 'skill')}" !! '') ~ ((%s<contexts>:exists) ?? ", {many-of(%s<contexts>.Int, 'work context')}" !! '') ~ ", read {age-text(%s<syncedAt>)}" ~ ($failed ?? '; still in use' !! ''));
                @l.append: row-lines('skills:', "not listed by this registry ({%s<skillsNote>})") if (%s<skillsNote> // '') ne '';
            }
            else { @l.append: row-lines('copy here:', 'none yet') }
            @l.append: row-lines('your reports:', $told) if $told ne '';
            @l.append: row-lines('packages:', 'never served by the registry: an agent runs from a package pinned in your trust file');
            @l.push: '';
            @l.push: $failed ?? next-text('321 goes on working from what is here; try again when it can be reached', '321 registry sync')
                !! $have && (%s<skillsNote> // '') ne '' ?? next-text('see who you can ask on this machine', '321 agents')
                !! $have ?? next-text('see the skills it offers you', '321 skills available')
                !! next-text('read what you may see, and keep a copy', '321 registry sync');
            learn-say($env, @l);
            return $failed ?? EXIT-FAILED !! 0;
        }
        default { return usage-error($env, 'registry', "it is sync, token or use, not '$sub'") }
    }
}

#| `321 record`: how an agent's versions have done, as the people who ran
#| them reported; and whether this machine adds what its person said.
sub cmd-record(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    my $w = $env.stdout;
    return usage-error($env, 'record', 'name an agent, or say share: 321 record 1da') unless @a;
    if @a[0] eq 'share' {
        my $word = (@a[1] // '').Str;
        return usage-error($env, 'record', "it is on or off, not '$word'") unless $word eq '' | 'on' | 'off';
        my $done = try { set-sharing($home, $word eq 'on') if $word ne ''; True };
        if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
        my $on = sharing-on($home);
        my @p = try { reports-pending($home) } // ();
        my $token = registry-token($home) ne '';
        if $json { $w.say(encode-json(%( sharing => $on, since => sharing-since($home), registry => registry-url($home), token => $token, key => report-key($home), pending => [ |@p ] ))); return 0 }
        if $g.brief { $w.say(brief-line('share', $on ?? 'on' !! 'off', @p.elems)); $w.say(brief-line('report', .<agent>, .<version>, .<outcome>, (.<tokens> // ''), ((.<signature>:exists) ?? 'signed' !! 'unsigned'))) for @p; return 0 }
        my @l = header('record share', $on ?? 'on' !! 'off'), '';
        @l.append: row-lines('sharing:', $on ?? "on: 321 registry sync sends what you said of your runs to {registry-url($home)}" !! 'off: nothing about your runs leaves this machine');
        @l.append: row-lines('goes:', 'for a run you gave an outcome: the agent and its version, the harness, how it ended, your outcome, tokens, cost, time, attempts');
        @l.append: row-lines('stays:', 'the request, files, paths, contexts, lessons, your notes and the run id');
        @l.append: row-lines('to send:', @p ?? many-of(@p.elems, 'run') !! 'nothing: no run with an outcome is waiting');
        my $sg = @p.grep({ .<signature>:exists }).elems;
        @l.append: row-lines('signed:', $sg ?? "$sg of them carry the signature this 321 gave their receipt; its public key goes too"
            !! report-key($home) ?? 'none of them: their receipts were not signed by the key here now' !! 'none: this 321 has no key (321 key new makes one, for receipts from then on)') if @p;
        @l.append: row-lines('token:', 'none: the registry takes reports only from someone it knows') if $on && !$token;
        if @p {
            @l.push: '';
            @l.push: sprintf('  %-22s %-10s %-10s %s', .<agent>, (.<version> || '-'), .<outcome>, (.<tokens>.defined ?? count-text(.<tokens>) ~ ' tokens' !! 'tokens not reported')) for @p.head(8);
            @l.push: "  and {@p.elems - 8} more" if @p.elems > 8;
        }
        @l.push: '';
        @l.push: !$on ?? next-text('add what you said of your runs to the record', '321 record share on')
            !! !$token ?? next-text('say who you are to the registry', '321 registry token')
            !! @p ?? next-text('send them', '321 registry sync')
            !! next-text('say what came of a run, and it can be sent', '321 outcome accepted');
        learn-say($env, @l);
        return 0;
    }
    my %r = try { agent-record($home, @a[0]) } // %();
    if $! {
        $env.stderr.say("321: {$!.message}");
        $env.stderr.say(next-text('see the agents the registry holds', '321 registry sync'));
        return EXIT-FAILED;
    }
    if $json { $w.say(encode-json(%r)); return 0 }
    my @v = @(%r<versions> // []).grep(Associative);
    if $g.brief {
        $w.say(brief-line('record', (%r<agent> // ''), (.<version> // ''), (.<enough> ?? 'enough' !! 'few'), (.<reports> // ''), (.<accounts> // ''),
            ((.<outcomes> // {})<accepted> // ''), ((.<tokens> // {})<median> // ''))) for @v;
        return 0;
    }
    my $name = (%r<agent> // record-name(@a[0])).Str;
    my @l = header("record $name", @v ?? many-of(@v.elems, 'version') ~ ' reported' !! 'no reports yet'), '';
    for @v -> %v {
        my @t = version-lines(%v);
        @l.append: row-lines(@t[0] ~ ':', @t[1 .. *].join('; '));
    }
    my %min = (%r<minimum> // {}).Hash;
    @l.append: row-lines('basis:', (%r<basis> // 'reported by people who ran it').Str ~ (%min ?? "; a version shows its figures at {%min<reports> // '?'} reports from {%min<accounts> // '?'} accounts" !! ''));
    @l.append: row-lines('signed:', 'a signed report carries the signature of a key its reporter registered: a receipt was written, which does not make its figures true') if @v.first({ .<signed> ~~ Associative });
    @l.push: '';
    @l.push: sharing-on($home) ?? next-text('say what came of a run of yours, and it joins the record', '321 outcome accepted')
        !! next-text('add what you said of your runs to the record', '321 record share on');
    learn-say($env, @l);
    0;
}

#| `321 skills`: the skills on this machine and the ones the registry
#| offers.  Installing checks the text against its digest and keeps the
#| version it replaces.  A skill grants nothing.
sub cmd-skills(Env $env, Global $g, @args --> Int) {
    my $home = home-of($env);
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    my $version = '';
    with @a.first('--version', :k) -> $i { $version = (@a[$i + 1] // '').Str; @a.splice($i, 2) }
    my $w = $env.stdout;
    my $sub = @a ?? @a.shift !! 'list';
    my sub fail-line(Str $m, Str $advice, Str $cmd --> Int) {
        $env.stderr.say("321: $m");
        $env.stderr.say(next-text($advice, $cmd));
        EXIT-FAILED;
    }
    my sub asks(%m --> Str) { @(%m<requires> // []) ?? @(%m<requires>).join(', ') ~ ' (it works only where the run is granted these; it grants none)' !! 'nothing beyond the run\'s own grants' }
    given $sub {
        when 'list' {
            my @s = installed-skills($home);
            if $json { $w.say(encode-json(%( skills => [ @s.map({ %( |$_, news => skill-news($home, $_) ) }) ] ))); return 0 }
            if $g.brief { $w.say(brief-line(.<id>, .<version>, .<digest>, .<source>, skill-news($home, $_))) for @s; return 0 }
            my @l = header('skills', @s ?? "{many-of(@s.elems, 'skill')} here" !! 'none here yet'), '';
            for @s -> %m {
                my $news = skill-news($home, %m);
                @l.push: sprintf('  %-28s v%-5s %s', %m<id>, %m<version>, %m<description>.substr(0, 40)) ~ ($news ne '' ?? "   ({$news})" !! '');
            }
            @l.push: '' if @s;
            @l.push: @s ?? next-text('give one to a run; it adds no permission', "321 --skill {@s[0]<id>} <agent> <request...>")
                        !! next-text('see what the registry offers you', '321 skills available');
            learn-say($env, @l);
            return 0;
        }
        when 'available' {
            my %st = registry-state($home);
            my @s = registry-skills($home);
            my %here = installed-skills($home).map({ .<id> => .<version> });
            if $json { $w.say(encode-json(%( syncedAt => (%st<syncedAt> // Nil), url => registry-url($home), skills => [ @s.map({ %( $_.grep({ .key ne 'instructions' }) ) }) ] ))); return 0 }
            if $g.brief { $w.say(brief-line(.<id>, .<version>, (.<sharing> // ''), (%here{.<id>} // ''), (.<description> // ''))) for @s; return 0 }
            if (%st<syncedAt> // '') eq '' {
                learn-say($env, [header('skills available', 'the registry has not been read yet'), '', next-text('read what you may see', '321 registry sync')]);
                return 0;
            }
            my @l = header('skills available', "{many-of(@s.elems, 'skill')}, as the registry was {age-text(%st<syncedAt>)}"), '';
            for @s -> %r {
                my $mark = (%here{%r<id>}:exists) ?? (%here{%r<id>} eq (%r<version> // '').Str ?? 'here' !! "here: v{%here{%r<id>}}") !! '';
                @l.push: sprintf('  %-28s v%-5s %-8s %s', %r<id>, (%r<version> // ''), (%r<sharing> // ''), (%r<description> // '').substr(0, 36)) ~ ($mark ne '' ?? "   ($mark)" !! '');
            }
            @l.push: '' if @s;
            @l.push: @s ?? next-text('install one by name', "321 skills install {@s[0]<id>}") !! next-text('read the registry again', '321 registry sync');
            learn-say($env, @l);
            return 0;
        }
        when 'install' {
            return usage-error($env, 'skills', 'say which skill: 321 skills install PUBLISHER/NAME') unless @a;
            my ($m, $what) = try install-skill($home, @a[0], :$version);
            return fail-line($!.message, 'see what the registry offers you', '321 skills available') if $!;
            my %m = $m.Hash;
            if $json { $w.say(encode-json(%( |%m, result => $what ))); return 0 }
            if $g.brief { $w.say(brief-line(%m<id>, %m<version>, $what, %m<digest>)); return 0 }
            learn-say($env, [header('skills install', "{%m<id>} $what"), '', |row-lines('skill:', "{%m<id>} version {%m<version>}"),
                |row-lines('from:', %m<source>), |row-lines('checked:', "its text matches the digest the registry gave ({%m<digest>.substr(0, 19)}…)"),
                |(@(%m<previous>) && $what eq 'updated' ?? row-lines('kept:', "version {@(%m<previous>).tail}, which it replaced; 321 skills rollback {%m<id>} puts it back") !! ()),
                |row-lines('it asks for:', asks(%m)), '',
                next-text('give it to a run; it adds no permission', "321 --skill {%m<id>} <agent> <request...>")]);
            return 0;
        }
        when 'show' | 'rollback' | 'remove' {
            return usage-error($env, 'skills', "say which skill: 321 skills $sub PUBLISHER/NAME") unless @a;
            my $have = installed-skill($home, @a[0]);
            return fail-line("{@a[0]} is not installed here", 'see what is', '321 skills') without $have;
            my %m = $have.Hash;
            given $sub {
                when 'show' {
                    my $news = skill-news($home, %m);
                    if $json { $w.say(encode-json(%( |%m, news => $news ))); return 0 }
                    if $g.brief { $w.say(brief-line(%m<id>, %m<version>, %m<digest>, %m<source>, %m<installedAt>)); return 0 }
                    my %p = %m<provenance> ~~ Associative ?? %m<provenance>.Hash !! {};
                    learn-say($env, [header('skills show', %m<id>), '', |row-lines('skill:', "{%m<id>} version {%m<version>}" ~ ($news ne '' ?? "; $news" !! '')),
                        |row-lines('what:', %m<description> ~ (%m<purpose> ne '' ?? " {%m<purpose>}" !! '')),
                        |row-lines('from:', "{%m<source>}, installed {age-text(%m<installedAt>)}" ~ ((%p<createdBy> // '') ne '' ?? "; made by {%p<createdBy>}" !! '')
                            ~ (%p<adoptedFrom> ~~ Associative ?? "; adopted from {%p<adoptedFrom><id>} v{%p<adoptedFrom><version>}" !! '')),
                        |row-lines('digest:', %m<digest>),
                        |row-lines('harnesses:', @(%m<harnesses>) ?? @(%m<harnesses>).join(', ') ~ ', by its publisher\'s word' !! 'not stated'),
                        |row-lines('it asks for:', asks(%m)),
                        |row-lines('kept:', @(%m<previous>) ?? "earlier versions {@(%m<previous>).join(', ')}" !! 'no earlier version'), '',
                        next-text('read its words', skill-dir($home, %m<id>).add('SKILL.md').Str.subst(($*HOME // '').Str, '~'))]);
                    return 0;
                }
                when 'rollback' {
                    my $n = try rollback-skill($home, %m<id>);
                    return fail-line($!.message, 'see what is kept', "321 skills show {%m<id>}") if $!;
                    if $json { $w.say(encode-json($n)); return 0 }
                    if $g.brief { $w.say(brief-line($n<id>, $n<version>, 'rolled back', $n<digest>)); return 0 }
                    learn-say($env, [header('skills rollback', $n<id>), '', |row-lines('now:', "version {$n<version>}, the copy this machine kept"),
                        |row-lines('was:', "version {$n<rolledBackFrom>}, kept too: installing it again brings it back"), '', next-text('see it', "321 skills show {$n<id>}")]);
                    return 0;
                }
                when 'remove' {
                    remove-skill($home, %m<id>);
                    if $json { $w.say(encode-json(%( id => %m<id>, removed => True ))); return 0 }
                    if $g.brief { $w.say(brief-line(%m<id>, 'removed')); return 0 }
                    learn-say($env, [header('skills remove', %m<id>), '', |row-lines('removed:', "{%m<id>} and the earlier versions kept with it"), '', next-text('see what is left', '321 skills')]);
                    return 0;
                }
            }
        }
        default { return usage-error($env, 'skills', "it is available, install, show, rollback or remove, not '$sub'") }
    }
}

# ------------------------------------------------------------ completion

#| `321 completion bash|zsh|fish` writes the script a shell sources;
#| `321 completion words -- <typed...>` is the seam that script calls on
#| every TAB.  Both read the one registry that dispatch and help read, so
#| no shell holds a list of its own and none can drift.  Completing
#| nothing runs, loads no package and asks for no authority
#| (loading-executes-nothing.cli.321.do): it reads trust.json and each
#| package's agent.json, and writes nothing anywhere.
sub cmd-completion(Env $env, Global $g, @args --> Int) {
    return usage-error($env, 'completion', 'say which shell: bash, zsh or fish') unless @args;
    my $what = @args[0];
    if $what eq 'words' {
        my @typed = @args[1 .. *];
        @typed.shift if @typed && @typed[0] eq '--';
        my $trust = $env.trust-path ne ''
            ?? $env.trust-path.IO
            !! home-of($env).add('trust.json');
        $env.stdout.say($_) for candidates(@typed, :$trust);
        return 0;
    }
    return usage-error($env, 'completion', "there is no completion for '$what'; it is bash, zsh or fish")
        unless so($what eq 'bash' | 'zsh' | 'fish');
    $env.stdout.print(script($what));
    0;
}

sub cmd-packages(Env $env, Global $g, @args --> Int) {
    return usage-error($env, 'packages', @args ?? "'packages {@args.join(' ')}' needs more" !! 'say what to do') if @args < 2;
    my $w = $env.stdout;
    given @args[0] {
        when 'builtin' {
            my $dir = try materialise-builtin(@args[1], home-of($env));
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }
            my ($m, $d) = try validate-package($dir);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            # The path is the result, and a tool (iz4's launcher among them)
            # reads this command's standard output as nothing but the path.
            # Into a pipe that is all it gets; the screen is for a terminal.
            if $g.brief || !pretty-on() { $w.say($dir.Str); return 0 }
            $w.say(header('packages builtin', @args[1]));
            $w.say('');
            $w.say($_) for flat row-lines('path:', $dir.Str), row-lines('package:', "{$m<id>} {$m<version>}");
            $w.say('');
            $w.say(next-text('run it by path, no trust file needed', "321 --package-dir $dir {@args[1]} <request...>"));
            return 0;
        }
        when 'validate' {
            my ($m, $d) = try validate-package(@args[1].IO);
            if $! {
                # in pipeline mode a failure is one line on standard error and the exit code
                if $g.brief { $env.stderr.say("321 packages validate: {@args[1]}: {$!.message}"); return EXIT-FAILED }
                $w.say(header('packages validate', @args[1]));
                $w.say('');
                $w.say("{glyph('no')} invalid: {$!.message}");
                $w.say('');
                $w.say(next-text('fix what it names, then validate again', "321 packages validate {@args[1]}"));
                return EXIT-FAILED;
            }
            if $g.brief { $w.say(brief-line('valid', $m<id>, $m<version>, $d)); return 0 }
            $w.say(header('packages validate', @args[1]));
            $w.say('');
            $w.say("{glyph('yes')} valid: {$m<id>} {$m<version>}");
            $w.say('');
            $w.say($_) for flat row-lines('digest:', $d.Str);
            $w.say('');
            $w.say(next-text('pin it in the trust file so it can be asked by name', '321 help trust'));
            return 0;
        }
        when 'digest' {
            my ($d, $entries) = try compute(@args[1].IO);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            my $write = @args > 2 && @args[2] eq '--write';
            if $write {
                try write-digest-file(@args[1].IO, $d);
                if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            }
            if $g.brief { $w.say(brief-line($d, @$entries.elems, @args[1])); return 0 }
            $w.say(header('packages digest', @args[1]));
            $w.say('');
            $w.say($_) for flat row-lines('digest:', $d.Str), row-lines('files:', many-of(@$entries.elems, 'file') ~ ($write ?? '; written to DIGEST' !! ''));
            $w.say('');
            $w.say($write
                ?? next-text('validate the package', "321 packages validate {@args[1]}")
                !! next-text('write it into the package as its DIGEST file', "321 packages digest {@args[1]} --write"));
            return 0;
        }
        when 'show' {
            my $cfg = try trust-of($env);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
            my $l = try load-resolved($cfg.resolve(@args[1]));
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-DENIED }
            my %m = $l.manifest;
            $env.stdout.say(header('packages show', "{%m<id>} {%m<version>}"));
            $env.stdout.say('');
            $env.stdout.say("digest:     {$l.digest}");
            $env.stdout.say("trust:      {$l.label}");
            $env.stdout.say("publisher:  {%m<publisher><domain>}   owner: {%m<owner><legalName>}   licence: {(%m<licence><spdx> ~ ' ' ~ %m<licence><url>).trim}");
            $env.stdout.say("role:       {%m<identity><role>}");
            $env.stdout.say("requires:   {@(%m<capabilities><required> // []).join(', ')}");
            $env.stdout.say("optional:   {@(%m<capabilities><optional> // []).join(', ')}");
            $env.stdout.say("denied:     {@(%m<capabilities><denied> // []).join(', ')}");
            $env.stdout.say("enforce:    {@(%m<harness><requires> // []).join(', ')}");
            $env.stdout.say("placement:  {@(%m<placement><allowed> // []).join(', ')}");
            my @procs = @(%m<procedures> // []);
            $env.stdout.say("procedures: {@procs.map({ $_<name> }).join(', ')}") if @procs;
            $env.stdout.say('');
            $env.stdout.say(next-text('ask it', "321 {@args[1]} <request...>"));
            return 0;
        }
    }
    usage-error($env, 'packages', "there is no 'packages {@args[0]}'");
}

sub cmd-trust(Env $env, Global $g, @args --> Int) {
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
    my $sub = @args ?? @args[0] !! 'show';
    given $sub {
        when 'show' {
            if $g.brief {
                for $cfg.publishers.keys.sort -> $d {
                    my %p = $cfg.publishers{$d};
                    for (%p<packages> // {}).keys.sort -> $n {
                        my %pin = %p<packages>{$n};
                        $env.stdout.say(brief-line("$d/$n", %pin<version>, (%pin<trust> eq '' ?? LEVEL-VERIFIED !! %pin<trust>), %pin<path>));
                    }
                }
                $env.stdout.say(brief-line("local/$_", '', 'local', $cfg.local{$_}<path>)) for $cfg.local.keys.sort;
                return 0;
            }
            $env.stdout.say(header('trust show', $cfg.path.Str));
            $env.stdout.say('');
            for $cfg.publishers.keys.sort -> $d {
                my %p = $cfg.publishers{$d};
                $env.stdout.say("publisher $d: {@(%p<keys> // []).elems} key(s)");
                $env.stdout.say("  key {$_<keyId>} {$_<note>}") for @(%p<keys> // []);
                for (%p<packages> // {}).keys.sort -> $n {
                    my %pin = %p<packages>{$n};
                    my $level = %pin<trust> eq '' ?? LEVEL-VERIFIED !! %pin<trust>;
                    $env.stdout.say("  $d/$n {%pin<version>} $level {%pin<path>}");
                }
            }
            $env.stdout.say("local/$_ {$cfg.local{$_}<path>}") for $cfg.local.keys.sort;
            $env.stdout.say("alias $_ -> {$cfg.aliases{$_}}") for $cfg.aliases.keys.sort;
            $env.stdout.say('');
            $env.stdout.say(next-text('check that every agent named here loads', '321 trust check'));
            return 0;
        }
        when 'project' {
            # what this project pins (.321/pins.json), beside what is here
            my ($root, $kind) = resolve-workspace($g.workspace);
            if $root eq '' { $env.stderr.say('321: this is not inside a project: there is no directory to keep pins in'); return EXIT-USAGE }
            my $home = home-of($env);
            my @rest = @args[1 .. *].grep({ $_ ne '--plain' && $_ ne '--json' && $_ ne '--brief' });
            if @rest && @rest[0] eq 'pin' {
                return usage-error($env, 'trust', 'name the agent to pin: 321 trust project pin b1ll') unless @rest[1].defined;
                my ($agent, $err) = load-agent-named($cfg, $g, @rest[1]);
                with $err { $env.stderr.say("321: $err"); return EXIT-USAGE }
                my $done = try { write-project-pins($root, $home, $agent, @($g.skill)); True };
                if $! { $env.stderr.say("321: {$!.message.trim}"); return EXIT-FAILED }
            }
            elsif @rest { return usage-error($env, 'trust', "it is project, or project pin AGENT, not 'project {@rest[0]}'") }
            my %p = read-project-pins($root);
            my @rows;
            for (%p<agents> // {}).sort(*.key) -> $kv {
                my ($a, $e) = load-agent-named($cfg, $g, $kv.key);
                my $here = $a.defined ?? $a.digest !! '';
                @rows.push(%( kind => 'agent', id => $kv.key, version => ($kv.value<version> // ''), digest => ($kv.value<digest> // ''),
                    here => ($a.defined ?? ($a.manifest<version> // '') !! ''), same => $here eq ($kv.value<digest> // '') ));
            }
            for (%p<skills> // {}).sort(*.key) -> $kv {
                my $d = (try installed-skill($home, $kv.key)) // Any;
                @rows.push(%( kind => 'skill', id => $kv.key, version => ($kv.value<version> // ''), digest => ($kv.value<digest> // ''),
                    here => (($d // {})<version> // ''), same => (($d // {})<digest> // '') eq ($kv.value<digest> // '') ));
            }
            if $g.json-out || so @args.first('--json') { $env.stdout.say(encode-json-pretty(%( schema => 'project-pins-status.v1', project => $root, file => project-pins-file($root).Str, pins => [ |@rows ] ))); return 0 }
            if $g.brief || so @args.first('--brief') { $env.stdout.say(brief-line('pin', .<kind>, .<id>, .<version>, (.<same> ?? 'same' !! 'differs'), .<here>)) for @rows; return 0 }
            my @l = header('trust project', $root), '';
            @l.push: '  nothing is pinned for this project yet' unless @rows;
            for @rows -> %r {
                @l.push: sprintf('  %s %-6s %-26s %-8s %s', (%r<same> ?? glyph('yes') !! glyph('no')), %r<kind>, %r<id>, %r<version>,
                    %r<same> ?? 'the same here' !! %r<here> eq '' ?? 'not here' !! "here it is {%r<here>}, with other content");
            }
            @l.push: '';
            my $off = @rows.first({ !.<same> });
            @l.push: !@rows ?? next-text('pin the agent this project is worked on with', '321 trust project pin <agent>')
                !! $off.defined ?? next-text('get the pinned version here, or change the pin with the team: runs with it are refused until they agree', '321 trust show')
                !! all-well('pinned', "{many-of(@rows.elems, 'pin')} in .321/pins.json match what is here; commit the file to share them.");
            learn-say($env, @l);
            return 0;
        }
        when 'check' {
            my $w = $env.stdout;
            my @rows; my @failed;
            for $cfg.configured -> $r {
                my $l = try load-resolved($r);
                if $! { @rows.push([ 'failed', $r.id.Str, $r.level, $!.message ]); @failed.push($r.id.Str); next }
                @rows.push([ 'loads', $r.id.Str, $r.level, 'as pinned' ]);
            }
            if $g.brief { $w.say(brief-line(|$_)) for @rows; return @failed ?? EXIT-FAILED !! 0 }
            $w.say(header('trust check', $cfg.path.Str));
            $w.say('');
            # each row says in words what its mark means, so no legend is needed
            my $wide = @rows.map({ .[1].chars }).max // 10;
            for @rows -> @r {
                $w.say(sprintf('%s %-*s  %-12s %s', (@r[0] eq 'loads' ?? glyph('yes') !! glyph('no')), $wide, @r[1], @r[2], @r[0] eq 'loads' ?? 'loads as pinned' !! "did not load: {@r[3]}"));
            }
            $w.say('');
            if @failed {
                $w.print(say-next(@failed.map({ "fix the pin for $_ in {$cfg.path}; the digest or path is what usually moved" }), :then('321 trust check')));
                return EXIT-FAILED;
            }
            $w.say(next-text('see them as a list', '321 agents'));
            $w.say('');
            $w.say(all-well('loaded', "{@rows.elems} of {many-of(@rows.elems, 'agent')} named here load as pinned.")) if @rows;
            return 0;
        }
        when 'network' { my $rc = trust-network($env, $g, $cfg, @args[1] // ''); return $rc }
        when 'now' { my $rc = trust-now($env, $g, $cfg, @args[1] // ''); return $rc }
    }
    usage-error($env, 'trust', "there is no 'trust $sub'");
}

#| `321 trust network [none|provider_only|open]`: the network every run
#| started here gets unless --network says otherwise.  Said, or set: the
#| one standing grant a person changes often enough to deserve a word.
#| A wider network is said as what it widens, in words, before the file
#| is named.
sub trust-network(Env $env, Global $g, Config $cfg, Str $want --> Int) {
    my $w = $env.stdout;
    my $was = ((($cfg.policy // {})<limits> // {})<network> // '').Str;
    my sub standing(Str $n --> Str) { $n eq '' ?? NETWORK-PROVIDER-ONLY ~ ' (the default)' !! $n }
    my sub meaning(Str $n --> Str) {
        given $n eq '' ?? NETWORK-PROVIDER-ONLY !! $n {
            when NETWORK-OPEN { 'an agent may use the network as it works' }
            when NETWORK-NONE { 'an agent reaches nothing, its model provider included' }
            default { 'an agent reaches only its model provider; a shell it is granted cannot be kept off the network, so a run with shell.run needs a harness that can, or --network open' }
        }
    }
    if $want eq '' {
        if $g.brief { $w.say(brief-line('network', $was eq '' ?? NETWORK-PROVIDER-ONLY !! $was, $was eq '' ?? 'default' !! 'set', $cfg.display-path)); return 0 }
        $w.say(header('trust network', standing($was)));
        $w.say('');
        $w.say($_) for flat row-lines('standing:', standing($was)), row-lines('means:', meaning($was)), row-lines('file:', $cfg.display-path);
        $w.say('');
        $w.say(next-text('widen it for every run started here, or narrow it', '321 trust network open'));
        return 0;
    }
    return usage-error($env, 'trust', "network is none, provider_only or open, not '$want'")
        unless is-in($want, [NETWORK-NONE, NETWORK-PROVIDER-ONLY, NETWORK-OPEN]);
    if $want eq $was {
        if $g.brief { $w.say(brief-line('network', $want, 'unchanged', $cfg.display-path)); return 0 }
        $w.say(header('trust network', "$want already"));
        $w.say('');
        $w.say($_) for flat row-lines('standing:', $want), row-lines('means:', meaning($want)), row-lines('file:', $cfg.display-path);
        return 0;
    }
    my %doc = $cfg.doc;
    %doc<schema> = SCHEMA-TRUST-CONFIG if (%doc<schema> // '') eq '';
    %doc<policy> = {} unless %doc<policy> ~~ Associative;
    %doc<policy><limits> = {} unless %doc<policy><limits> ~~ Associative;
    %doc<policy><limits><network> = $want;
    my $path = ($cfg.path ne '' ?? $cfg.path !! default-trust-path().Str).IO;
    my $err = try {
        $path.parent.mkdir unless $path.parent.d;
        $path.parent.chmod(0o700);
        my $tmp = $path.parent.add($path.basename ~ ".$*PID.tmp");
        $tmp.spurt(to-pretty('TrustConfig', %doc) ~ "\n");
        $tmp.chmod(0o600);
        $tmp.rename($path);
        load-trust($path);      # what was written reads back
        Str;
    };
    if $! { $env.stderr.say("321 trust: {$!.message}"); return EXIT-FAILED }
    if $g.brief { $w.say(brief-line('network', $want, 'set', $path.Str)); return 0 }
    my $agent = $cfg.aliases.keys.sort.head // '<agent>';
    $w.say(header('trust network', "$want, was {standing($was)}"));
    $w.say('');
    $w.say($_) for flat row-lines('standing:', $want), row-lines('means:', meaning($want)), row-lines('file:', $path.Str);
    $w.say('');
    $w.say('Every run started here takes it: at the shell, with 321 start, and from Mission Control. One run is still narrowed with --network before the agent\'s name. A package another system issues carries its own.');
    $w.say('');
    $w.say(next-text('ask an agent, and it has the network', "321 $agent <request...>"));
    0;
}

#| `321 trust now [N|none]`: how many runs of one agent work at once
#| here.  A run started past it waits its turn, oldest first; nothing is
#| refused and nothing chooses between pieces of work.
sub trust-now(Env $env, Global $g, Config $cfg, Str $want --> Int) {
    my $w = $env.stdout;
    my $was = ((($cfg.policy // {})<now>) // 0).Int;
    my sub standing(Int $n --> Str) { $n > 0 ?? "$n at once" !! 'no limit (the default)' }
    my sub meaning(Int $n --> Str) {
        $n > 0 ?? "an agent works on $n thing{$n == 1 ?? '' !! 's'} at once here; a run started past that waits its turn, oldest first"
               !! 'an agent starts every run it is given at once; only two runs writing in one workspace wait for each other'
    }
    if $want eq '' {
        if $g.brief { $w.say(brief-line('now', $was > 0 ?? $was.Str !! 'none', $was > 0 ?? 'set' !! 'default', $cfg.display-path)); return 0 }
        $w.say(header('trust now', standing($was)));
        $w.say('');
        $w.say($_) for flat row-lines('standing:', standing($was)), row-lines('means:', meaning($was)), row-lines('file:', $cfg.display-path);
        $w.say('');
        $w.say(next-text('have each agent finish one thing before the next', '321 trust now 1'));
        return 0;
    }
    return usage-error($env, 'trust', "now is a number of runs, 1 or more, or none; not '$want'")
        unless $want eq 'none' || ($want ~~ /^ \d+ $/ && $want.Int >= 1);
    my $n = $want eq 'none' ?? 0 !! $want.Int;
    if $n == $was {
        if $g.brief { $w.say(brief-line('now', $n > 0 ?? $n.Str !! 'none', 'unchanged', $cfg.display-path)); return 0 }
        $w.say(header('trust now', "{standing($n)} already"));
        $w.say('');
        $w.say($_) for flat row-lines('standing:', standing($n)), row-lines('means:', meaning($n)), row-lines('file:', $cfg.display-path);
        return 0;
    }
    my %doc = $cfg.doc;
    %doc<schema> = SCHEMA-TRUST-CONFIG if (%doc<schema> // '') eq '';
    %doc<policy> = {} unless %doc<policy> ~~ Associative;
    if $n > 0 { %doc<policy><now> = $n } else { %doc<policy><now>:delete }
    my $path = ($cfg.path ne '' ?? $cfg.path !! default-trust-path().Str).IO;
    my $err = try {
        $path.parent.mkdir unless $path.parent.d;
        $path.parent.chmod(0o700);
        my $tmp = $path.parent.add($path.basename ~ ".$*PID.tmp");
        $tmp.spurt(to-pretty('TrustConfig', %doc) ~ "\n");
        $tmp.chmod(0o600);
        $tmp.rename($path);
        load-trust($path);      # what was written reads back
        Str;
    };
    if $! { $env.stderr.say("321 trust: {$!.message}"); return EXIT-FAILED }
    if $g.brief { $w.say(brief-line('now', $n > 0 ?? $n.Str !! 'none', 'set', $path.Str)); return 0 }
    $w.say(header('trust now', "{standing($n)}, was {standing($was)}"));
    $w.say('');
    $w.say($_) for flat row-lines('standing:', standing($n)), row-lines('means:', meaning($n)), row-lines('file:', $path.Str);
    $w.say('');
    $w.say('It holds for runs started here from now on: with 321 start and from Mission Control. A run already going is not touched, and a package another system issues is hosted as it stands.');
    $w.say('');
    $w.say(next-text('see who is working and who waits', '321 tui'));
    0;
}

#| The standing policy in words, never as a document: what stands
#| approved, by whom, and whether any limit is set.
sub policy-text(%policy --> Str) {
    my @parts;
    for @(%policy<standingApprovals> // []) -> %sa {
        @parts.push("{%sa<action>} to {@(%sa<targets> // []).join(', ')} stands approved by {%sa<approvedBy>}");
    }
    @parts.push('no standing approvals') unless @parts;
    # a zero or an empty value is no limit, as the Limits shape reads it
    my @limits = (%policy<limits> // {}).pairs.grep({ .value.defined && .value ne '' && .value ne '0' }).sort(*.key);
    @parts.push(@limits ?? "limits: {@limits.map({ "{.key} {.value}" }).join(', ')}" !! 'no limits set');
    my @adapters = (%policy<adapters> // {}).keys.sort;
    @parts.push("adapter settings for {@adapters.join(', ')}") if @adapters;
    @parts.join('; ');
}

#| What an adapter is, in a few words, beside what it can do.
sub adapter-note(Str $name --> Str) {
    given $name {
        when 'procedure' { 'runs a package procedure; no model' }
        when 'fake'      { 'a stand-in for tests' }
        when 'codex'     { 'OpenAI Codex; a sandbox, not a tool allowlist' }
        default          { '' }
    }
}

sub cmd-doctor(Env $env, Global $g, @args --> Int) {
    my $json = is-in('--json', @args);
    my $verbose = is-in('--verbose', @args);
    for @args.grep({ $_ ne '--json' | '--verbose' }) -> $a { return usage-error($env, 'doctor', "it takes --verbose, --json and --brief, not '$a'") }
    if $json {
        my $cfg = try trust-of($env);
        my %trust = $! ?? %( error => $!.message ) !! %( path => $cfg.path, exists => $cfg.path.IO.e, packages => $cfg.configured.elems, policy => $cfg.policy );
        my @bindings;
        with $env.adapters.get('procedure') -> $p { @bindings = $p.bindings if $p ~~ ProcedureAdapter }
        my %d = doctor-document($env.adapters, @bindings, %trust);
        # What each harness can do at each control, in the one vocabulary:
        # enforces (an answer can stop the thing), advises (text reaches the
        # model and nothing more) or none.
        for @(%d<adapters>) -> %rec {
            my $a = $env.adapters.get(%rec<name>);
            next unless $a.defined && $a.controls.elems > 0;
            %rec<controls> = %( controls().map({ $_ => control-strength($a.controls, $_) }) );
            %rec<headlessControls> = %( controls().map({ $_ => control-strength($a.headless-controls, $_) }) );
        }
        # Whether iz4 can really be driven is asked of iz4, not inferred from
        # a file being on PATH.
        my %probe = IZ4.new.probe;
        %d<iz4> = %( binary => %probe<binary>, drivable => %probe<drivable>, applied => %probe<drivable>, reason => %probe<reason>, tool => %probe<tool> );
        $env.stdout.say(encode-json-pretty(%d));
        return $! ?? EXIT-FAILED !! 0;
    }
    # The screen: one row per adapter, one per tool, then trust and
    # policy in words.  What each adapter enforces, feature by feature and
    # control by control, is --verbose.
    my @adapters;
    for $env.adapters.all -> $a {
        my $det = $a.detect;
        my %enf = $a.enforcement;
        my @yes = features().grep({ enforces(%enf, $_) });
        my @no  = features().grep({ !enforces(%enf, $_) });
        my %c = $a.controls;
        my @ce = controls().grep({ control-strength(%c, $_) eq STRENGTH-ENFORCES });
        my @ca = controls().grep({ control-strength(%c, $_) eq STRENGTH-ADVISES });
        my @cn = controls().grep({ control-strength(%c, $_) eq STRENGTH-NONE });
        my $what = "enforces {@yes.elems} of {features().elems} features"
                 ~ ($a.controls.elems > 0 ?? ", {@ce.elems} of {controls().elems} controls" !! '')
                 ~ (adapter-note($a.name) ne '' ?? "; {adapter-note($a.name)}" !! '');
        @adapters.push(%( name => $a.name, available => $det.available,
            where => ($det.available ?? ($det.version eq 'built-in' ?? 'built in' !! $det.version) !! "not here: {$det.reason}"),
            what => $what, yes => @yes, no => @no, ce => @ce, ca => @ca, cn => @cn, harness => ($a.controls.elems > 0) ));
    }
    my @tools;
    with $env.adapters.get('procedure') -> $p {
        if $p ~~ ProcedureAdapter {
            for registry-names($p.tools) -> $name {
                my $t = $p.tools{$name};
                my ($where, $what) = 'bound', '';
                if $t ~~ DP {
                    $where = $t.bound ?? $t.bin !! 'not bound';
                    $what = !$t.bound ?? 'set DP_BIN to the engine\'s explicit entry point'
                        !! $t.exec ~~ EngineExecutor ?? "execute enabled on {$t.exec.allowed-targets.join(', ')} (DP_EXECUTE)"
                        !! 'execute not enabled here (DP_EXECUTE unset)';
                }
                @tools.push(%( name => $name, where => $where, what => $what, ops => $t.ops.map({ "{.name} ({.capability})" }).List ));
            }
        }
    }
    my %probe = IZ4.new.probe;
    @tools.push(%( name => 'iz4',
        where => (%probe<binary> ne '' ?? %probe<binary> !! 'not on PATH'),
        what  => (%probe<drivable> ?? "{%probe<tool>.subst(/^ 'iz4/' /, '')}, drivable: applied to model-driven runs in a workspace that keeps an IZ4"
               !! %probe<binary> ne '' ?? "cannot be driven: {%probe<reason>}; an IZ4 here is reported, not applied"
               !! 'an IZ4 in a workspace is reported on the receipt, not applied'),
        ops => () ));
    my $cfg = try trust-of($env);
    my $trust-err = $! ?? $!.message !! '';

    if $g.brief {
        my $w = $env.stdout;
        $w.say(brief-line('adapter', .<name>, (.<available> ?? 'available' !! 'unavailable'), .<where>, .<what>)) for @adapters;
        $w.say(brief-line('tool', .<name>, .<where>, .<what>)) for @tools;
        $w.say($trust-err ne '' ?? brief-line('trust', '', $trust-err) !! brief-line('trust', $cfg.path.Str, $cfg.configured.elems));
        return $trust-err ne '' ?? EXIT-FAILED !! 0;
    }

    my $w = $env.stdout;
    $w.say(header('doctor'));
    $w.say(subtitle(VERSION, $*KERNEL.hostname.Str));
    $w.say('');
    my $here = @adapters.grep(*<available>).elems;
    my $wide = (@adapters.map(*<name>.chars), @tools.map(*<name>.chars)).flat.max // 10;
    $w.say($_) for flat row-lines('adapters:', "$here of {@adapters.elems} here; a harness runs a model, the rest run without one");
    # the version column is as wide as its longest entry, so a reason never runs into what follows
    my $where-wide = (@adapters.map(*<where>.chars).max // 0) max 22;
    for @adapters -> %a {
        $w.say(sprintf('  %-*s  %-*s %s', $wide, %a<name>, $where-wide, %a<where>, %a<what>));
        if $verbose {
            $w.say(sprintf('  %-*s    %-13s %s', $wide, '', 'enforces:', %a<yes>.join(', ') || 'nothing'));
            $w.say(sprintf('  %-*s    %-13s %s', $wide, '', 'not enforced:', %a<no>.join(', '))) if %a<no>;
            if %a<harness> {
                $w.say(sprintf('  %-*s    %-13s %s', $wide, '', 'controls:', %a<ce>.join(', ') || 'nothing'));
                $w.say(sprintf('  %-*s    %-13s %s', $wide, '', 'advises:', %a<ca>.join(', '))) if %a<ca>;
                $w.say(sprintf('  %-*s    %-13s %s', $wide, '', 'cannot:', %a<cn>.join(', '))) if %a<cn>;
            }
        }
    }
    $w.say('');
    $w.say($_) for flat row-lines('tools:', 'bound by explicit path, never found by guessing');
    my $path-wide = @tools.map(*<where>.chars).max // 10;
    for @tools -> %t {
        $w.say(sprintf('  %-*s  %-*s   %s', $wide, %t<name>, $path-wide, %t<where>, %t<what>).trim-trailing);
        $w.say(sprintf('  %-*s    %-13s %s', $wide, '', 'operations:', %t<ops>.join(', '))) if $verbose && %t<ops>;
    }
    $w.say('');
    if $trust-err ne '' {
        $w.say($_) for flat row-lines('trust:', $trust-err);
        $w.say('');
        $w.say(next-text('mend the trust file, then look again', '321 doctor'));
        return EXIT-FAILED;
    }
    $w.say($_) for flat row-lines('trust:', $cfg.path.IO.e
        ?? "{$cfg.path}, {many-of($cfg.configured.elems, 'agent')} configured"
        !! "no file at {$cfg.path}; only --package-dir packages can run");
    $w.say($_) for flat row-lines('policy:', policy-text($cfg.policy // {}));
    $w.say('');
    $w.say($cfg.configured.elems ?? next-text('see who you can ask', '321 agents') !! next-text('configure an agent', '321 help trust'));
    $w.say(next-text('what each adapter enforces, feature by feature', '321 doctor --verbose').subst(/^ 'next:'/, 'then:')) unless $verbose;
    my @harness-here = @adapters.grep({ .<harness> && .<available> });
    if @harness-here && %probe<drivable> && $cfg.configured.elems {
        $w.say('');
        $w.say(all-well('here', "{@harness-here.map(*<name>).join(', ')} to run a model, iz4 to hold it to an IZ4, and {many-of($cfg.configured.elems, 'agent')} to ask."));
    }
    0;
}

# -------------------------------------------------- harnesses, controllers

#| The harness adapters: the ones that say they have controls at all.
sub harness-adapters(Env $env --> List) {
    $env.adapters.all.grep({ .controls.elems > 0 }).List;
}

#| The harnesses here that a controller is not wired into, so a status can
#| say the gap rather than leave it out: a harness 321 runs but cannot
#| hook (Codex), and one it does not know (Gemini).  Each with why.
sub unwired-harnesses(Env $env --> List) {
    # a harness that is installed counts, logged in or not: the gap is there either way
    my @out = $env.adapters.all.grep({ .controls.elems == 0 })
        .map({ $_ => .detect }).grep({ .value.version ne 'built-in' && !.value.reason.contains('not on PATH') })
        .map({ %( harness => .key.name, why => 'runs under 321, but nothing checks the turn end: 321 cannot wire hooks into it yet' ) });
    @out.push(%( harness => 'gemini', why => 'not known to 321: nothing is checked there' )) if on-path('gemini').defined;
    @out.List;
}

#| The 321 command a harness should call back.  A project's settings are
#| shared between machines, so the default is the name on PATH;
#| DO_321_HOOK_SELF overrides it.
sub hook-self(--> Str) { %*ENV<DO_321_HOOK_SELF> // '321' }

sub parse-harness-options(Env $env, Global $g, @args, Str $what --> List) {
    my ($workspace, $harness, $json, $advisory, $verbose) = $g.workspace, $g.adapter, $g.json-out, False, False;
    my $i = 0;
    while $i < @args {
        my $a = @args[$i];
        my ($name, $value, $has-value) = $a.contains('=') ?? (|$a.split('=', 2), True) !! ($a, '', False);
        my sub need() {
            return $value if $has-value;
            X::Do321::Usage.new(message => "$name needs a value").throw if $i + 1 >= @args;
            $i++;
            @args[$i];
        }
        given $name {
            when '--workspace' { $workspace = need() }
            when '--harness'   { $harness = need() }
            when '--json'      { $json = True }
            when '--advisory'  { $advisory = True }
            when '--verbose'   { $verbose = True }
            default { X::Do321::Usage.new(message => "unknown option $name for $what").throw }
        }
        $i++;
    }
    $workspace = $*CWD.Str if $workspace eq '';
    X::Do321::Usage.new(message => "no such directory $workspace").throw unless $workspace.IO.d;
    ($workspace, $harness, $json, $advisory, $verbose);
}

sub cmd-harness(Env $env, Global $g, @args --> Int) {
    return cmd-mission($env, $g, ['harnesses', |@args[1 .. *]]) if @args && @args[0] eq 'can';
    return cmd-harness-versions($env, $g, @args) if @args && @args[0] eq 'check' | 'pin' | 'rollback';
    return usage-error($env, 'harness detect', @args ?? "there is no 'harness {@args[0]}'" !! 'say what to do: detect, can, check, pin or rollback') if !@args || @args[0] ne 'detect';
    my ($workspace, $, $json, $, $verbose) = try parse-harness-options($env, $g, @args[1 .. *], 'harness detect');
    if $! { return usage-error($env, 'harness detect', $!.message) }
    my @records;
    for harness-adapters($env) -> $a {
        my $det = $a.detect;
        my %c = $a.controls;
        my $path = $a.wiring-path;
        @records.push(%(
            harness => $a.name, detected => $det.available, version => $det.version, reason => $det.reason,
            wiring => $path, configured => ($path ne '' && $workspace.IO.add($path).e),
            controls => %( controls().map({ $_ => control-strength(%c, $_) }) ),
            headless => %( controls().map({ $_ => control-strength($a.headless-controls, $_) }) ),
        ));
    }
    if $json {
        $env.stdout.say(encode-json-pretty(%( schema => 'harness-detect.v1', workspace => $workspace.IO.absolute, harnesses => @records )));
        return 0;
    }
    my $w = $env.stdout;
    if $g.brief {
        $w.say(brief-line(.<harness>, (.<detected> ?? 'detected' !! 'not detected'), .<version>, .<wiring>, (.<configured> ?? 'wired' !! 'not wired'))) for @records;
        return 0;
    }
    $w.say(header('harness detect', $workspace.IO.absolute.Str));
    $w.say('');
    # one row per harness: whether it is here, and whether this project
    # is wired into it; the controls it offers are --verbose
    my $wide = @records.map({ .<harness>.chars }).max // 10;
    for @records -> %r {
        my $wiring = %r<wiring> eq '' ?? '' !! %r<configured> ?? "wired at {%r<wiring>}" !! "{%r<wiring>} (none yet)";
        $w.say(sprintf('  %-*s  %-22s %s', $wide, %r<harness>, (%r<detected> ?? "detected {%r<version>}" !! 'not detected'), $wiring).trim-trailing);
        $w.say(sprintf('  %-*s  %s', $wide, '', %r<reason>)) if !%r<detected> && %r<reason> ne '';
        if $verbose {
            my @yes = controls().grep({ %r<controls>{$_} eq STRENGTH-ENFORCES });
            my @adv = controls().grep({ %r<controls>{$_} eq STRENGTH-ADVISES });
            my @no  = controls().grep({ %r<controls>{$_} eq STRENGTH-NONE });
            $w.say(sprintf('  %-*s    %-10s %s', $wide, '', 'enforces:', @yes.join(', ') || 'nothing'));
            $w.say(sprintf('  %-*s    %-10s %s', $wide, '', 'advises:', @adv.join(', '))) if @adv;
            $w.say(sprintf('  %-*s    %-10s %s', $wide, '', 'cannot:', @no.join(', '))) if @no;
        }
    }
    $w.say('  no harness with controls is known to this 321') unless @records;
    $w.say('');
    my @here = @records.grep(*<detected>);
    $w.say(@here
        ?? next-text('see what the IZ4 here is held by, harness by harness', '321 iz4 status')
        !! next-text('install a harness 321 knows, then look again', '321 harness detect'));
    $w.say(next-text('the controls each harness offers a controller', '321 harness detect --verbose').subst(/^ 'next:'/, 'then:')) unless $verbose;
    0;
}


# ------------------------------------------------- models and the choice

#| `321 models`: what a harness here can be asked for.  The harness is
#| the one that signs in and pays; 321 names a model to it and holds no
#| key.  A price is the provider's list rate on the day stated.
sub cmd-models(Env $env, Global $g, @args --> Int) {
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    return usage-error($env, 'models', "there is no 'models {@a[0]}'") if @a;
    my $home = home-of($env);
    my ($models, $skipped) = catalogue($home);
    my @rows;
    for $env.adapters.all.grep({ @(.manifest<providers> // []) }) -> $a {
        my %m = $a.manifest;
        my $d = $a.detect;
        my @reach = models-for(@$models, @(%m<providers>)).grep({ .access eq %m<access> });
        @rows.push(%( harness => $a.name, available => $d.available, version => $d.version, reason => $d.reason,
            access => %m<access>, efforts => [ |@(%m<efforts> // []) ], reportsUsd => so %m<reports><usd>, reportsTokens => so %m<reports><tokens>,
            spendCap => so %m<spend-cap>,
            models => [ @reach.map({ %( provider => .provider, id => .id, name => .label, tier => .tier, contextTokens => .context-tokens,
                efforts => [ |.efforts ], priceIn => .price-in, priceOut => .price-out, priceAsOf => .price-as-of, source => .source ) }) ] ));
    }
    my $w = $env.stdout;
    if $json { $w.say(encode-json-pretty(%( schema => 'models.v1', harnesses => [ |@rows ], skipped => [ |@$skipped ] ))); return 0 }
    if $g.brief {
        for @rows -> %r {
            $w.say(brief-line('harness', %r<harness>, (%r<available> ?? 'ready' !! 'not here'), %r<version>, %r<reason>));
            $w.say(brief-line('model', %r<harness>, .<name>, .<tier>, (.<priceIn> // '?'), (.<priceOut> // '?'), .<id>)) for @(%r<models>);
        }
        return 0;
    }
    my @l = header('models', 'what a harness here can be asked for'), '';
    for @rows -> %r {
        @l.push: "  {harness-label(%r<harness>)}" ~ (%r<version> ne '' ?? " {bare-version(%r<version>)}" !! '') ~ (%r<available> ?? '' !! "   not here: {%r<reason>}");
        for @(%r<models>) -> %m {
            my $price = %m<priceIn>.defined ?? sprintf('$%.2f in, $%.2f out per million tokens', %m<priceIn>, %m<priceOut>) !! 'price not recorded';
            @l.push: sprintf('    %-9s %-7s %s', %m<name>, %m<tier>, $price);
        }
        @l.push: '    reports: ' ~ (%r<reportsUsd> ?? 'what a run cost' !! 'tokens, and no cost: a run there is priced as unknown');
        @l.push: '';
    }
    @l.push: '  no harness that runs a model is known to this 321', '' unless @rows;
    @l.append: row-lines('prices:', 'list rates, for estimates only. What a run cost is on its receipt, as its harness reported it.');
    @l.append: row-lines('left out:', $_) for @$skipped;
    @l.push: '';
    my $first = (try trust-of($env).aliases.keys.sort.head) // 'helper';
    @l.push: next-text('see what an agent would run a request on', "321 choose $first <request...>");
    learn-say($env, @l);
    0;
}

#| `321 choose AGENT <request...>`: the plan a run would be pinned to,
#| and why.  Nothing is run and nothing is recorded.
sub cmd-choose(Env $env, Global $g, @args --> Int) {
    my @a = @args.grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    @a = @a.grep({ $_ ne '--json' });
    return usage-error($env, 'choose', 'name an agent and say the request: 321 choose b1ll fix the failing test') if @a < 2;
    my $name = @a[0];
    my $request = @a[1 .. *].join(' ').trim;
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my ($agent, $err) = load-agent-named($cfg, $g, $name);
    with $err { $env.stderr.say("321: $err"); return EXIT-USAGE }
    my ($workspace, $kind) = resolve-workspace($g.workspace);
    ($workspace, $kind) = ('', 'none') unless touches-workspace($agent.manifest);
    my $home = home-of($env);
    my %wp = (try build-package($cfg, $agent, $g, $request, $workspace, $kind, :$home, :!learn)) // %();
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }
    my $want = try want-for($home, $agent, %wp, $g.asked);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }
    my @reqs = requirements($agent.manifest, %wp, @(%wp<capabilities><granted>));
    my ($chosen, $plan, $rejections) = pin-plan($env.adapters, @reqs, $cfg.policy<adapters> // {}, $g.adapter, $want, models-here($home));
    my $w = $env.stdout;
    without $chosen {
        if $json { $w.say(encode-json-pretty(%( schema => 'choice.v1', agent => $agent.id, plan => Any, rejected => [ @$rejections.map(*.Str) ] ))); return EXIT-FAILED }
        my @l = header("choose $name", $request.subst(/\s+/, ' ', :g)), '';
        @l.push: "{glyph('no')} nothing here can run this as asked";
        @l.push: "  $_" for @$rejections.map(*.Str);
        @l.push: '';
        @l.push: next-text('see what each harness here can be asked for', '321 models');
        learn-say($env, @l);
        return EXIT-FAILED;
    }
    if $json { $w.say(encode-json-pretty(%( schema => 'choice.v1', agent => $agent.id, plan => parse-json(to-wire('ExecutionPlan', load('ExecutionPlan', $plan))) ))); return 0 }
    my %p = %$plan;
    my @l = header("choose $name", $request.subst(/\s+/, ' ', :g)), subtitle('nothing was run', $agent.id), '';
    @l.append: row-lines('would run on:', plan-words(%p) ~ profile-note(%p));
    @l.append: row-lines('harness:', harness-label(%p<harness>) ~ ((%p<harnessVersion> // '') ne '' ?? " {bare-version(%p<harnessVersion>)}" !! ''));
    @l.append: row-lines('why:', $_) for @(%p<reasons> // []);
    @l.append: row-lines('set by you:', @(%p<overrides>).join(', ')) if @(%p<overrides> // []);
    with %p<evidence> -> %e {
        if %e<usdRuns> > 0 {
            @l.append: row-lines('earlier:', sprintf('about %s and %s a run, over %s that reported a cost', usd-words(%e<medianUsd>), duration-words(%e<medianSeconds>), many-of(%e<usdRuns>, 'comparable run')));
        }
    }
    my @ladder = @(%p<ladder> // []);
    my $max = %p<maxEscalations> // 0;
    @l.append: row-lines('if harder:', @ladder && $max > 0
        ?? "one step up to {@ladder[0]<profile>}, when " ~ (@(%p<escalateOn> // []).first('unmet_conditions') ?? 'the harness fails or a done condition is unmet' !! 'the harness fails') ~ '; ' ~ ($max == 1 ?? 'then it stops' !! "$max steps at most") ~ ', and never past the budget'
        !! 'it does not climb: the choice was made by hand');
    @l.append: row-lines('not used:', "{harness-label(.<harness>)}: {.<why>}") for @(%p<considered> // []);
    @l.push: '';
    @l.push: next-text('run it', ('321', |$g.asked.argv, $name, $request).join(' '));
    @l.push: 'then:  set it yourself with --profile, --model or --effort before the agent name' unless $g.asked.any;
    learn-say($env, @l);
    0;
}

my sub duration-words($seconds --> Str) {
    my $s = ($seconds // 0).Int;
    $s >= 3600 ?? sprintf('%dh %02dm', $s div 3600, ($s mod 3600) div 60) !! $s >= 60 ?? sprintf('%dm %02ds', $s div 60, $s mod 60) !! "{$s}s";
}


#| `321 harness check | pin | rollback`: which version of a harness is
#| trusted here.  check reads the installed harness against what its
#| adapter depends on, and calls no model.
sub cmd-harness-versions(Env $env, Global $g, @args --> Int) {
    my $sub = @args[0];
    my @a = @args[1 .. *].grep({ $_ ne '--plain' });
    my $json = $g.json-out || so @a.first('--json');
    $g.brief = True if @a.first('--brief');
    @a = @a.grep({ $_ ne '--json' && $_ ne '--brief' });
    my $home = home-of($env);
    my $w = $env.stdout;
    my @adapters = $env.adapters.all.grep({ .executable ne '' || @(.manifest<providers> // []) });
    my sub named(Str $n) { @adapters.first({ .name eq $n || harness-label(.name).lc eq $n.lc }) }
    if $sub eq 'check' {
        return usage-error($env, 'harness check', "there is no harness '{@a[0]}' here") if @a && !named(@a[0]).defined;
        my @rows = (@a ?? (named(@a[0]),) !! @adapters).map(-> $ad {
            my %c = contract-check($ad);
            my %k = known-good($home, $ad.name);
            %c<promoted> = (%k<version> // '').Str;
            %c<previous> = ((%k<previous> // {})<version> // '').Str;
            %c<held> = (%k<binary> // '') ne '' && (%k<binary> // '').IO.f;
            # only what its help has stopped naming since the promotion is news
            my %known = @(%k<undocumented> // []).map({ $_ => True });
            %c<changed> = [ @(%c<undocumented>).grep({ %c<promoted> eq '' || !%known{$_} }) ];
            %c<verdict> = !%c<available> ?? 'not ready' !! @(%c<changed>) ?? 'look' !! %c<promoted> eq '' ?? 'fits, not promoted'
                !! %c<promoted> eq %c<installed> ?? 'fits, promoted' !! 'fits, newer than promoted';
            %c;
        });
        if $json { $w.say(encode-json-pretty(%( schema => 'harness-check.v1', harnesses => [ |@rows ] ))); return 0 }
        if $g.brief { $w.say(brief-line('harness', .<harness>, .<verdict>, .<installed>, .<promoted>, @(.<changed>).join(','))) for @rows; return 0 }
        my @l = header('harness check', 'the harnesses here against what 321 asks of them'), '';
        for @rows -> %r {
            my $mark = %r<verdict>.starts-with('fits') ?? glyph('yes') !! %r<verdict> eq 'look' ?? glyph('unknown') !! glyph('no');
            @l.push: "  $mark {harness-label(%r<harness>)} {%r<installed>}".trim-trailing ~ (%r<available> ?? '' !! "   {%r<reason>}");
            @l.push: '      ' ~ (@(%r<flags>) ?? "{@(%r<flags>).grep(*<documented>).elems} of {@(%r<flags>).elems} flags 321 passes are in its help" !! 'its help could not be read') if %r<available> || @(%r<flags>);
            @l.push: "      not in its help: {@(%r<changed>).join(', ')} (a run may still take it; try one before promoting)" if @(%r<changed>);
            @l.push: '      promoted: ' ~ (%r<promoted> eq '' ?? 'none yet' !! %r<promoted> ~ (%r<held> ?? ', and 321 runs that one' !! %r<promoted> eq %r<installed> ?? '' !! ', which is not what is installed now')
                ~ (%r<previous> ne '' ?? "; before it {%r<previous>}" !! ''));
            @l.push: "      kept on disk: {%r<beside>.keys.sort.join(', ')}" if %r<beside>.elems > 1;
            @l.push: '';
        }
        my $new = @rows.first({ .<verdict> eq 'fits, not promoted' | 'fits, newer than promoted' | 'look' });
        @l.push: $new.defined
            ?? next-text('after a run on it that you accepted, promote it', "321 harness pin {$new<harness>}")
            !! next-text('see what each can be asked for', '321 models');
        learn-say($env, @l);
        return 0;
    }
    return usage-error($env, "harness $sub", 'name the harness: 321 harness ' ~ $sub ~ ' claude_code') unless @a;
    my $ad = named(@a[0]);
    return usage-error($env, "harness $sub", "there is no harness '{@a[0]}' here") without $ad;
    my %now;
    if $sub eq 'pin' {
        my %c = contract-check($ad);
        my $version = (@a[1] // %c<installed>).Str;
        if $version eq '' { $env.stderr.say("321: {$ad.name} is not here, so there is no version to promote"); return EXIT-FAILED }
        my $binary = (%c<beside>{$version} // '').Str;
        if @a[1].defined && $version ne %c<installed> && $binary eq '' {
            $env.stderr.say("321: {$ad.name} $version is not on this machine; installed is {%c<installed>}" ~ (%c<beside> ?? ", kept: {%c<beside>.keys.sort.join(', ')}" !! ''));
            return EXIT-FAILED;
        }
        %now = promote($home, $ad.name, $version, $binary, undocumented => @(%c<undocumented>));
    }
    else {
        %now = (try roll-back($home, $ad.name)) // %();
        if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
    }
    my $held = (%now<binary> // '') ne '' && %now<binary>.IO.f;
    if $json { $w.say(encode-json-pretty(%( schema => 'harness-pin.v1', harness => $ad.name, |%now, held => $held ))); return 0 }
    if $g.brief { $w.say(brief-line('promoted', $ad.name, %now<version>, ($held ?? 'held' !! 'recorded'), ((%now<previous> // {})<version> // ''))); return 0 }
    my @l = header("harness $sub", "{harness-label($ad.name)} {%now<version>}"), '';
    @l.append: row-lines('promoted:', %now<version> ~ ($sub eq 'rollback' ?? ', the one promoted before' !! ''));
    @l.append: row-lines('runs on:', $held ?? "that version, from {%now<binary>}, whatever the command on PATH moves to"
        !! "whatever version is installed: this harness keeps one version at a time, so 321 records {%now<version>} and cannot hold it. To have it, install that version");
    @l.append: row-lines('before it:', (%now<previous> // {})<version>) if ((%now<previous> // {})<version> // '') ne '';
    @l.push: '';
    @l.push: ((%now<previous> // {})<version> // '') ne '' && $sub eq 'pin'
        ?? next-text('go back to the one before, if this one disappoints', "321 harness rollback {$ad.name}")
        !! next-text('see it against what 321 asks of it', '321 harness check');
    learn-say($env, @l);
    0;
}

#| install | status | remove for one controller, in one harness or every
#| harness detected here.
sub cmd-controller(Env $env, Global $g, Str $name, @args --> Int) {
    return usage-error($env, $name, @args ?? "there is no '$name {@args[0]}'" !! 'say what to do') if !@args || !is-in(@args[0], <install status remove>);
    my $sub = @args[0];
    my ($workspace, $harness, $json, $advisory, $verbose) = try parse-harness-options($env, $g, @args[1 .. *], "$name $sub");
    if $! { return usage-error($env, "$name $sub", $!.message) }
    my $controller = controller-named($name);
    without $controller { $env.stderr.say("321: no controller \"$name\""); return EXIT-USAGE }
    my @adapters = harness-adapters($env);
    if $harness ne '' {
        @adapters = @adapters.grep(*.name eq $harness);
        unless @adapters { $env.stderr.say("321 $name: no harness \"$harness\" (321 harness detect lists them)"); return EXIT-USAGE }
    }
    else {
        # With no harness named, act on the ones that are here; if none is,
        # still report on every harness 321 knows.
        my @here = @adapters.grep({ .detect.available });
        @adapters = @here if @here;
    }
    unless @adapters { $env.stderr.say("321 $name: this 321 knows no harness it can wire a controller into"); return EXIT-FAILED }
    my $ws = $workspace.IO;
    my %found = $controller.discover($workspace);
    my @statuses = do given $sub {
        when 'install' {
            %found ?? @adapters.map({ install-enforcement($_, $controller, $ws, hook-self(), :$advisory) })
                   !! @adapters.map({ enforcement-status($_, $controller, $ws) })
        }
        when 'remove'  { @adapters.map({ remove-enforcement($_, $controller, $ws) }) }
        default        { @adapters.map({ enforcement-status($_, $controller, $ws) }) }
    };
    # what the hooks really did here, beside what is wired
    with-exercised($_, exercised-summary(home-of($env), exercised-key(%found, $ws.absolute.Str), .<harness>)) for @statuses;
    if $json {
        $env.stdout.say(encode-json-pretty(%( schema => 'enforcement-report.v1', workspace => $ws.absolute, controller => $name, harnesses => [ |@statuses ],
                                              unwired => [ |(%found ?? unwired-harnesses($env) !! ()) ] )));
    }
    elsif $g.brief {
        $env.stdout.say(brief-line(.<harness>, (.<action> // $sub), (.<headline> // '').lc, verdict($_))) for @statuses;
        $env.stdout.say(brief-line(.<harness>, 'unwired', '', .<why>)) for (%found ?? unwired-harnesses($env) !! ());
    }
    else {
        # One verdict per harness.  The detail, control by control, is
        # --verbose; what the levels mean is 321 help enforcement.
        my $w = $env.stdout;
        $w.say(header("$name $sub", $ws.absolute.Str));
        $w.say('');
        my $wide = @statuses.map({ .<harness>.chars }).max // 10;
        # a row is marked ? when calls could not reach the controller: the
        # one thing on this screen a person acts on
        my sub unreached(%s --> Bool) { ((%s<exercised> // %())<unansweredSince> // 0) > 0 }
        for @statuses -> %s {
            my $did = $sub eq 'status' || !%s<applies> ?? ''
                !! %s<action> ~ (%s<action> eq 'unchanged' | 'removed' | 'failed' ?? '' !! (%s<wiring> ne '' ?? " ({%s<wiring>})" !! '')) ~ '; ';
            $w.say(sprintf('  %-2s%-*s  %s%s', (unreached(%s) ?? '?' !! ''), $wide, %s<harness>, $did, verdict(%s)));
            $w.say(sprintf('  %-2s%-*s  adopted the wiring an earlier %s wrote (%s): its commands are replaced by 321\'s', '', $wide, '', $name, @(%s<adopted>).map({ control-label($_) }).join(', ')))
                if (%s<action> // '') eq 'adopted';
            $w.say(sprintf('  %-2s%-*s  ! %s', '', $wide, '', %s<error>)) if (%s<error> // '') ne '';
            if $verbose { $w.say(''); $w.say($_) for status-lines(%s) }
        }
        # what is not wired is said, not left out
        $w.say(sprintf('  %-2s%-*s  %s', '', $wide, .<harness>, .<why>)) for (%found ?? unwired-harnesses($env) !! ());
        $w.say('');
        my @live = @statuses.grep({ .<applies> });
        my @weak = @live.grep({ !.<available> || .<headline> ne 'GUARDED' });
        my @legacy = @live.grep({ @(.<legacy> // []).elems });
        if !@live { $w.say(next-text('an IZ4 here would say what the software is for; iz4 init starts one', 'iz4 init')) }
        elsif @live.grep({ !.<available> }) { $w.say(next-text("{$name} cannot be driven here; make it so, then install again", "321 $name install")) }
        elsif @legacy { $w.say(next-text("adopt the wiring an earlier {$name} wrote, so 321 drives it", "321 $name install")) }
        elsif @live.grep({ unreached($_) }) { $w.say(next-text("some checks could not reach {$name}; doctor says whether it can be driven here", '321 doctor')) }
        elsif @weak && $sub ne 'remove' { $w.say(next-text('wire it as strongly as the harness allows', "321 $name install")) }
        elsif $sub eq 'remove' { $w.say(next-text('wire it again when wanted', "321 $name install")) }
        else {
            # when it last checked work, from the hooks' own records; nothing
            # is claimed where there are none (timestamps sort as text)
            my @when = @live.map({ (.<exercised> // %())<lastAnswered> // '' }).grep(* ne '').sort;
            my $when = @when ?? @when.tail.Str !! '';
            $w.say(all-well('wired', "{$name.uc} is guarded in {@live.map(*<harness>).join(', ')}"
                ~ ($when ne '' ?? ", and it last checked work {ago-words($when)}" !! '') ~ '.'));
        }
    }
    @statuses.grep({ (.<action> // '') eq 'failed' }) ?? EXIT-FAILED !! 0;
}

#| The glue a harness calls at one of its own events.  It reads the
#| native event on stdin, translates it, asks the controller, and answers
#| in the harness's terms.  Each call is appended to DO_321_HOOK_LOG when
#| that is set, which is how a run proves its hooks really fired.
sub cmd-hook(Env $env, @args --> Int) {
    return usage-error($env, 'hook', 'it takes a harness, a controller and a control, and is called by a harness') if @args != 3;
    my ($harness, $name, $control) = @args;
    return status-line($env) if $control eq STATUS-LINE && $name eq 'iz4';
    my $adapter = $env.adapters.get($harness);
    my $controller = controller-named($name);
    without $adapter { $env.stderr.say("321 hook: no harness \"$harness\""); return EXIT-USAGE }
    without $controller { $env.stderr.say("321 hook: no controller \"$name\""); return EXIT-USAGE }
    unless is-in($control, controls()) { $env.stderr.say("321 hook: no control \"$control\""); return EXIT-USAGE }

    my @lines;
    loop { my $l = $env.stdin.next; last without $l; @lines.push($l) }
    my $parsed = try parse-json(@lines.join("\n"));
    my %native = $parsed ~~ Associative ?? %$parsed !! %();
    my $workspace = ((%native<cwd> // '') ~~ Str && (%native<cwd> // '') ne '') ?? %native<cwd> !! $*CWD.Str;
    my $headless = (%*ENV<DO_321_HEADLESS> // '') eq '1';

    my %found = $controller.discover($workspace);
    return 0 unless %found;                       # nothing governs here: stay out of the way
    # What this harness can do at this control, here: it decides what a
    # controller that cannot be asked leads to.  Enforcing stops; advisory
    # warns.  Nothing is let through quietly.
    my $strength = control-strength($headless ?? $adapter.headless-controls !! $adapter.controls, $control);
    my Verdict $v;
    my Verdict $said;          # what the controller itself said, where that differs from the answer given
    my ($code, $out, $err) = 0, '', '';
    my sub answer() { ($code, $out, $err) = $adapter.answer($control, $v, :$headless, :$strength, :controller($name)) }
    if $control eq CTRL-POST-RUN && %native<stop_hook_active> {
        # The harness's own loop guard: this turn was already refused once,
        # so it ends whatever is said now and an agent is never trapped.
        # iz4 is still asked, because the agent may have put it right: its
        # last word must not go on showing the refusal, and a pass moves
        # the baseline as any allowed turn end does.
        my $session = $adapter.session-key(%native);
        my $again = $controller.verify($workspace, %( summary => $adapter.final-words(%native), base => read-baseline($env, $harness, $session, $workspace) ));
        store-baseline($env, $harness, $session, $workspace, tree-of($again)) if $again.ran && !$again.stops;
        $said = $again;
        $v = $again.ran && !$again.stops ?? $again
          !! unavailable(POINT-VERIFY, 'let through: this turn end was already refused once (the harness\'s loop guard)');
    }
    elsif !%found<available> {
        $v = unavailable('', "{$name} cannot be driven here: {%found<reason>}");
        answer();
    }
    elsif $control eq CTRL-AUTHORITATIVE-CONTEXT {
        my ($text, $why) = $controller.context($workspace);
        if $why.defined {
            # The context is told, never enforced: say, where the person will
            # see it, that it was not delivered.
            $v = unavailable(POINT-CONTEXT, "the context could not be read: $why");
            ($code, $out, $err) = $adapter.answer($control, $v, :$headless, :strength(STRENGTH-ADVISES), :controller($name));
        }
        else { $v = Verdict.new(:point(POINT-CONTEXT), :result(RESULT-PASS), :reason('the context was delivered')); $out = $text }
        # The session starts here: the tree as it stands is the baseline
        # the first turn is measured from.  Dirt already in the tree is
        # not that turn's doing.
        store-baseline($env, $harness, $adapter.session-key(%native), $workspace, $controller.baseline($workspace));
    }
    elsif $control eq CTRL-POST-RUN {
        my $session = $adapter.session-key(%native);
        if !$adapter.turn-wrote(%native) {
            # Nothing this turn could have changed a file: there is nothing
            # to verify and no report owed.  Said so in the log, not asked.
            $v = Verdict.new(:point(POINT-VERIFY), :result(RESULT-PASS), :!asked, :reason('not asked: this turn used no tool that can change files'));
        }
        else {
            my $base = read-baseline($env, $harness, $session, $workspace);
            $v = $controller.verify($workspace, %( summary => $adapter.final-words(%native), base => $base ));
            # A turn allowed to end moves the baseline to where it left the
            # tree; a refused one keeps it, so the same changes are measured
            # when the agent tries again.
            store-baseline($env, $harness, $session, $workspace, tree-of($v)) if $v.ran && !$v.stops;
        }
        answer();
    }
    else {
        my $action = $adapter.translate-event($control, %native);
        if $action.defined { $v = $controller.check-action($workspace, $action) }
        else               { $v = unavailable(POINT-ACTION, "{$harness} gave no action for $control") }
        answer();
    }
    # The rule holds whatever an adapter's translation does or forgets: a
    # control that can stop the thing never lets it through unchecked, and
    # an unchecked pass-through is never silent.
    my $asked = !($control eq CTRL-POST-RUN && %native<stop_hook_active>);
    if $asked && !$v.ran {
        my $stops = $strength eq STRENGTH-ENFORCES
            && is-in($control, [CTRL-FILESYSTEM-GUARD, CTRL-SHELL-GUARD, CTRL-PRE-TOOL, CTRL-PRE-ACTION, CTRL-POST-RUN]);
        if $stops && $code == 0 {
            $code = 2;
            $out = '';
            $err = "321: {$name.uc} enforcement could not be performed: {$v.reason}\n";
        }
        elsif !$stops && $out eq '' && $err eq '' {
            $err = "321: {$name.uc} did NOT check this: {$v.reason}. The work was let through unchecked.\n";
        }
    }
    hook-log($name, $harness, $control, $v);
    # What really happened here, for `321 iz4 status`: never in the way
    # of the answer, and nothing when the controller was asked nothing.
    record-exercised(home-of($env), exercised-key(%found, $workspace), $harness, $adapter.session-key(%native), $control,
        exercised-outcome($control, $said // $v));
    $env.stdout.print($out) if $out ne '';
    $env.stderr.print($err) if $err ne '';
    $code;
}

#| What a project's exercised records are filed under: its IZ4, so the
#| hooks and a status run from any directory of the project agree; the
#| workspace itself when the controller names no subject.
sub exercised-key(%found, Str $workspace --> Str) {
    (%found<subject> // '') ne '' ?? %found<subject>.Str !! $workspace;
}

#| Where a session's baseline lives: the tree the current turn began
#| from, under ~/.321/sessions/<harness>/<session>.json with the workspace
#| it belongs to.  No session name, no baseline: verify measures from HEAD
#| as it always did.
sub baseline-file(Env $env, Str $harness, Str $session --> IO::Path) {
    return IO::Path if $session eq '';
    home-of($env).add('sessions').add($harness).add("$session.json");
}
sub read-baseline(Env $env, Str $harness, Str $session, Str $workspace --> Str) {
    my $f = baseline-file($env, $harness, $session);
    return '' without $f;
    return '' unless $f.f;
    my $doc = try parse-json($f.slurp);
    return '' unless $doc ~~ Associative && ($doc<workspace> // '') eq $workspace.IO.absolute;
    my $tree = ($doc<tree> // '').Str;
    $tree ~~ / ^ <[0..9a..f]> ** 40 $ / ?? $tree !! '';
}
sub store-baseline(Env $env, Str $harness, Str $session, Str $workspace, Str $tree) {
    return if $tree eq '';
    my $f = baseline-file($env, $harness, $session);
    return without $f;
    try {
        mkdir-private(home-of($env));
        mkdir-p($f.parent);
        $f.spurt(encode-json(%( workspace => $workspace.IO.absolute.Str, tree => $tree, at => now-stamp() )) ~ "\n");
    }
}

sub hook-log(Str $controller, Str $harness, Str $control, Verdict $v) {
    my $path = %*ENV<DO_321_HOOK_LOG> // '';
    return if $path eq '';
    my %line = controller => $controller, harness => $harness, control => $control, point => $v.point,
        result => $v.result, reason => $v.reason, invariants => [ |$v.invariants.map(*.Str) ];
    # A turn that owed nothing was never put to the controller: the line
    # says so, and a receipt counts it as no hook answered.
    %line<asked> = False unless $v.asked;
    try {
        my $fh = $path.IO.open(:a);
        $fh.say(encode-json(%line));
        $fh.close;
    }
}

# ----------------------------------------------------------------- hooks

#| The status line: iz4's last word on the workspace Claude Code is in,
#| as iz4 wrote it, or nothing.  It runs every few seconds and its output
#| is the line itself, so it never fails loudly.
sub status-line(Env $env --> Int) {
    my @lines;
    loop { my $l = $env.stdin.next; last without $l; @lines.push($l) }
    my $parsed = try parse-json(@lines.join("\n"));
    my %in = $parsed ~~ Associative ?? %$parsed !! %();
    my $ws = (%in<workspace> ~~ Associative ?? %in<workspace><current_dir> !! Nil) // %in<cwd> // $*CWD.Str;
    my $line = iz4-last-line($ws ~~ Str ?? $ws !! $*CWD.Str);
    $env.stdout.say($line) if $line ne '';
    0;
}

sub cmd-hooks(Env $env, Global $g, @args --> Int) {
    return usage-error($env, 'hooks', 'say what to do') unless @args;
    my $sub = @args[0];
    my ($workspace, $command, $strict, $json) = $g.workspace, '', False, $g.json-out;
    my $i = 1;
    while $i < @args {
        my $a = @args[$i];
        my ($name, $value, $has-value) = $a.contains('=') ?? (|$a.split('=', 2), True) !! ($a, '', False);
        my sub need() {
            return $value if $has-value;
            X::Do321::Usage.new(message => "$name needs a value").throw if $i + 1 >= @args;
            $i++;
            @args[$i];
        }
        my $err = try {
            given $name {
                when '--workspace' { $workspace = need() }
                when '--command'   { $command = need() }
                when '--strict'    { $strict = True }
                when '--json'      { $json = True }
                default { X::Do321::Usage.new(message => "unknown option $name for hooks").throw }
            }
            Str;
        };
        if $! { return usage-error($env, 'hooks', $!.message) }
        $i++;
    }
    $workspace = $*CWD.Str if $workspace eq '';
    if $command eq '' { return usage-error($env, 'hooks', '--command names the hook command, such as "iz4 hook"') }
    unless $workspace.IO.d { return usage-error($env, 'hooks', "no such directory {$workspace}") }
    my @records = do given $sub {
        when 'install' {
            # A hook 321 writes calls 321, which asks the controller.  This
            # older command wrote the controller's own command straight into
            # a harness, and no longer does: what is there is reported and
            # left exactly as it is, and nothing new is written.
            status-all($workspace.IO, $command).map({
                %( |$_, action => 'refused',
                   error => "321 no longer writes a controller's own command into a harness: hooks 321 installs call 321. "
                          ~ "Nothing was written and nothing here was changed. Use: 321 <controller> install (for iz4: 321 iz4 install, with iz4 0.15.0 or later)" )
            }).List
        }
        when 'status'  { status-all($workspace.IO, $command) }
        when 'remove'  { remove-all($workspace.IO, $command) }
        default { return usage-error($env, 'hooks', "there is no 'hooks $sub'") }
    };
    if $json { $env.stdout.say(encode-json-pretty(%( schema => 'hooks.v1', workspace => $workspace.IO.absolute, command => $command, harnesses => [ |@records ] ))) }
    else {
        $env.stdout.say(header("hooks $sub", $workspace.IO.absolute.Str));
        $env.stdout.say('');
        for @records -> %r {
            my $head = %r<harness> ~ (%r<available> ?? '' !! ' (not on PATH here)') ~ (%r<action>:exists ?? ": {%r<action>}" !! '');
            $env.stdout.say($head);
            $env.stdout.say("  {%r<settings>}");
            for EVENTS -> $e { $env.stdout.say("  {$e}: {%r<events>{$e}}") }
            $env.stdout.say("  enforced: {@(%r<enforced>).join(', ') || 'nothing'}; advisory: {@(%r<advisory>).join(', ') || 'nothing'}");
            $env.stdout.say("  ! {%r<error>}") with %r<error>;
        }
    }
    @records.grep({ .<error>.defined }) ?? EXIT-FAILED !! 0;
}

# -------------------------------------------------------------- operator

# Operator approval: the CLI invocation IS the human approval.
#
# A deployment's execution boundary requires an approval bound to the
# exact plan being executed.  In the delegated flow that approval is a
# person's reaction in the app, minted long after the plan was seen, so
# the boundary re-plans and compares.  At a terminal there is no gap: a
# person typing `321 1da go <svc> <target>` IS exercising the authority.
# So the standalone runner, for an interactive operator, plans first
# (read-only), mints an approval bound to that exact proposal, attaches
# it, and runs the go.  Nothing here widens the boundary: execution
# remains gated by DP_EXECUTE, and a plan that does not come back
# `planned` mints no approval at all.  A server-issued package never
# enters here.
#
# Unattended (no terminal, or --non-interactive) there is no person to
# exercise the authority, so a go is approved only by a standing approval
# the administrator wrote into local policy (policy.standingApprovals),
# matching the planned service@target.  The administrator is the
# approver: the approval names them, carries a standing/ ref, and is
# bound to the exact plan like any other.  No standing approval, no
# approval: an agent's own text never grants one.

sub is-operator-deploy-go(Env $env, Global $g, Loaded $agent, Str $request --> Str) {
    return Str unless is-in(CAP-DEPLOY-INVOKE, @($agent.manifest<capabilities><optional> // []));
    my @fields = $request.words;
    return Str unless @fields && @fields[0] eq 'go';
    @fields[0] = 'plan';
    @fields.join(' ');
}

sub mint-operator-approval(%p, Str $by, Str :$kind = 'operator' --> Hash) {
    my %params = approval-params(%p);
    doc('Approval', proposalRef => 'operator/' ~ %p<proposalId>, approvalRef => $kind ~ '/' ~ new-ulid(), approvedBy => $by,
        action => 'deploy', target => %p<service> ~ '@' ~ %p<target>, params => %params, paramsHash => params-hash(%params), proposal => %p);
}

sub operator-plan(Env $env, Global $g, Config $cfg, Loaded $agent, Str $plan-request --> Hash) {
    my %plan-wp = (try build-package($cfg, $agent, $g, $plan-request, '', 'none', :!learn)) // %();
    return Hash if $!;
    my $raw = to-wire('WorkPackage', %plan-wp).encode('utf-8');
    my %receipt = runner-of($env).run(Cancel.new, %plan-wp, $agent, Options.new(:sink(SinkFunc.new(:f(-> % {}))), :policy($cfg.policy), :adapter($g.adapter), :package-raw($raw)));
    %receipt<evidence><proposal> // Hash;
}

#| When this is an interactive operator `go`, plan read-only and, if a
#| concrete plan comes back, mint an operator approval bound to it and
#| attach it (granting deploy.invoke within local policy).  Returns the
#| approval: row of the run header, or Str when nothing was assumed; it
#| never prints, so the title stays the first line a person reads.
sub assume-operator-approval(Env $env, Global $g, Config $cfg, Loaded $agent, %wp, Str $request --> Str) {
    my $plan-request = is-operator-deploy-go($env, $g, $agent, $request);
    return Str without $plan-request;
    with $cfg.policy<capabilityCeiling> -> $ceiling { return Str unless is-in(CAP-DEPLOY-INVOKE, @$ceiling) }
    my $attended = $env.interactive && !$g.non-interactive;
    return Str unless $attended || @(($cfg.policy // {})<standingApprovals> // []);
    my $proposal = operator-plan($env, $g, $cfg, $agent, $plan-request);
    return Str unless $proposal.defined && $proposal<status> eq 'planned';
    my ($by, $kind, $how);
    if $attended {
        $by = %*ENV<USER> // '';
        my $host = (try qx{hostname}.trim) // '';
        $by ~= "@$host" if $host ne '';
        ($kind, $how) = 'operator', 'assumed, you typed the command';
    }
    else {
        my $sa = standing-approval-for($cfg, $proposal<service> // '', $proposal<target> // '');
        return Str without $sa;
        $by = "{$sa<approvedBy>} (standing approval in local policy)";
        ($kind, $how) = 'standing', "standing, in local policy (approved by {$sa<approvedBy>})";
    }
    %wp<approval> = mint-operator-approval($proposal, $by, :$kind);
    %wp<capabilities><granted>.push(CAP-DEPLOY-INVOKE) unless is-in(CAP-DEPLOY-INVOKE, %wp<capabilities><granted>);
    if validate-work-package(%wp) {
        %wp<approval>:delete;
        return Str;
    }
    my $sha = ($proposal<revision> // {})<sha>; $sha = '' unless $sha ~~ Str;
    "$how: deploy {$proposal<service>} to {$proposal<target>} at {short-sha($sha)}; executes only where DP_EXECUTE enables it";
}

#| The first standing approval in local policy that covers service@target
#| (either side of a pattern may be *), or Hash when none does.
sub standing-approval-for(Config $cfg, Str $service, Str $target --> Hash) {
    return Hash if $service eq '' || $target eq '';
    for @(($cfg.policy // {})<standingApprovals> // []) -> %sa {
        next unless %sa<action> eq 'deploy';
        for @(%sa<targets> // []) -> $t {
            my ($s, $tg) = $t.split('@', 2);
            return %sa if ($s eq '*' || $s eq $service) && ($tg eq '*' || $tg eq $target);
        }
    }
    Hash;
}

# -------------------------------------------------------------- standalone

#| Whether a package could read or write files at all: only then does
#| the enclosing repository become its workspace.
sub touches-workspace(%m --> Bool) {
    for |@(%m<capabilities><required> // []), |@(%m<capabilities><optional> // []) -> $c {
        return True if is-in($c, [CAP-REPO-READ, CAP-REPO-WRITE, CAP-FILES-READ, CAP-FILES-WRITE, CAP-SHELL-RUN]);
    }
    False;
}

#| The git repository enclosing dir, or none.  Returns (path, kind).
sub resolve-workspace(Str $flag --> List) is export {
    my $dir = $flag ne '' ?? $flag.IO !! $*CWD;
    my $abs = try $dir.absolute.IO;
    return ('', 'none') without $abs;
    my $p = $abs;
    loop {
        my $git = $p.add('.git');
        return ($p.Str, 'git') if $git.d || $git.f;
        last if $p.parent.Str eq $p.Str;
        $p = $p.parent;
    }
    $flag ne '' ?? ($abs.Str, 'none') !! ('', 'none');
}

#| A standalone WorkPackage.  Grants are the package's required set plus
#| explicitly requested optional ones, all inside the policy ceiling;
#| anything outside is refused up front with the reason.
sub build-package(Config $cfg, Loaded $agent, Global $g, Str $request, Str $workspace, Str $kind,
                  IO::Path :$home = (%*ENV<DO_321_HOME> ?? %*ENV<DO_321_HOME>.IO !! $*HOME.add('.321')), Bool :$learn = True, Str :$harness = $g.adapter --> Hash) is export {
    my %m = $agent.manifest;
    my @optional = @(%m<capabilities><optional> // []);
    my @grants = @(%m<capabilities><required> // []);
    for $g.grant -> $c {
        X::Do321::Usage.new(message => "--grant $c: the package does not list it as optional (required: {@grants.join(', ')}; optional: {@optional.join(', ')})").throw
            unless is-in($c, @optional);
        @grants.push($c);
    }
    with $cfg.policy<capabilityCeiling> -> $ceiling {
        for @grants -> $c {
            X::Do321::Usage.new(message => "local policy does not allow $c (policy.capabilityCeiling in {$cfg.path})").throw unless is-in($c, @$ceiling);
        }
    }
    my $placement = $g.placement ne '' ?? $g.placement !! PLACEMENT-CLIENT;
    my %limits = load('Limits', $cfg.policy<limits>);
    # Network authority is separate and explicit: shell.run does not imply
    # it.  The person states it with --network, or local policy does;
    # otherwise the default provider_only stands.
    if $g.network ne '' {
        X::Do321::Usage.new(message => '--network must be none, provider_only or open').throw
            unless is-in($g.network, [NETWORK-NONE, NETWORK-PROVIDER-ONLY, NETWORK-OPEN]);
        %limits<network> = $g.network;
    }
    my $user = %*ENV<USER> // '';
    my $host = (try qx{hostname}.trim) // '';
    my %wp = doc('WorkPackage', schema => SCHEMA-WORK-PACKAGE, packageId => new-ulid(), issuer => { kind => 'local', id => "$user@$host" },
        issuedAt => now-stamp(), agent => { id => $agent.id, version => %m<version>, digest => $agent.digest }, placement => $placement,
        workspace => { kind => $kind, path => $workspace, ownership => 'caller' }, objective => $request,
        completion => { conditions => [ |$g.done ] }, capabilities => { granted => [ |@grants ], limits => %limits });
    my @attachments;
    for $g.attach -> $a {
        my $abs = $a.IO.absolute.IO;
        my $b = try $abs.slurp(:bin);
        X::Do321::Usage.new(message => "--attach $a: {$!.message}").throw if $!;
        @attachments.push(doc('Attachment', name => $abs.basename, sha256 => sha256-hex($b), uri => 'file://' ~ $abs.Str));
    }
    %wp<context><attachments> = @attachments if @attachments;
    # What is already known: the work context this run belongs to, and the
    # lessons whose scope matches it.  They go in as known things, beside
    # the task and under it; nothing here adds a grant or moves a limit.
    my $ctx = $g.context ne '' ?? $g.context !! (%*ENV<DO_321_CONTEXT> // '').Str;
    my @lesson-ids;
    # A skill selected for this job is words in its package: checked
    # against the digest it was installed with, and no grant.
    if $learn && $g.skill {
        my $text = try skills-instructions($home, $g.skill);
        X::Do321::Usage.new(message => $!.message).throw if $!;
        %wp<instructions> = $text;
    }
    if $learn {
        X::Do321::Usage.new(message => "no work context is called '$ctx'; make it with: 321 context new $ctx <what it is for>").throw
            if $ctx ne '' && !context-for($home, $ctx).defined;
        my ($lines, $ids) = known-lines($home, agent => $agent.id, context => $ctx, :$harness, :$workspace,
            skills => (|@(%m<skills> // []).grep(Str).map({ my @p = .split('/'); @p > 1 ?? @p[*-2] !! @p[0] }), |$g.skill, |$g.skill.map(*.split('/').tail)).List);
        %wp<context><lines> = [ |@$lines ] if @$lines;
        @lesson-ids = @$ids;
    }
    my $ps = validate-work-package(%wp);
    X::Do321::Usage.new(message => $ps.Str).throw if $ps;
    record-applied($home, %wp<packageId>, agent => $agent.id, context => $ctx, :$harness, lessons => @lesson-ids, skills => $g.skill) if $learn;
    %wp;
}

sub local-directive(Str $package-id, Int $seq, Str $kind, Str $text, Str $reason, Str $issuer --> Hash) {
    my $user = %*ENV<USER> // '';
    my %d = doc('WorkDirective', schema => SCHEMA-WORK-DIRECTIVE, directiveId => 'local-' ~ new-ulid(), packageId => $package-id,
        seq => $seq, issuer => { kind => 'local', id => "$user/$issuer" }, issuedAt => now-stamp(), kind => $kind,
        payload => { text => $text, reason => $reason });
    %d<digest> = directive-digest(%d);
    %d;
}

#| Terminal lines as local directives.
sub read-steering(Cancel $ctx, LineSource $in, Mailbox $ch, Str $package-id) {
    my $seq = 0;
    loop {
        last if $ctx.done;
        my $l = $in.next;
        last without $l;
        my $line = $l.trim;
        next if $line eq '';
        $seq++;
        my %d = do given $line {
            when '/pause'  { local-directive($package-id, $seq, DIRECTIVE-PAUSE, '', '', 'terminal') }
            when '/resume' { local-directive($package-id, $seq, DIRECTIVE-RESUME, '', '', 'terminal') }
            when '/stop'   { local-directive($package-id, $seq, DIRECTIVE-STOP, '', 'stopped at the terminal', 'terminal') }
            default        { local-directive($package-id, $seq, DIRECTIVE-STEER, $line, '', 'terminal') }
        };
        $ch.send(%d, :cancel($ctx));
    }
}

#| The run as it happens: one dotted line per thing the runtime did, so
#| a person can follow along without reading a log.  The verdict and its
#| details come once, in the receipt block, not here.
sub render-event($w, %e --> Bool) {
    my %p = %e<payload> // {};
    my $d = glyph('dot');
    my $wrote = True;
    given %e<kind> {
        when EVENT-PROGRESS {
            if %p<text> ~~ Str && %p<text> ne '' { $w.say(%p<text>) }
            elsif %p<notice> ~~ Str && %p<notice> ne '' { $w.say("  $d {%p<notice>}") }
            elsif %p<instruction> ~~ Str { $w.say("  {glyph('note')} instruction applied: " ~ %p<instruction>) }
            else { $wrote = False }
        }
        when EVENT-TOOL-CALL {
            if %p<op>:exists { $w.say("  $d tool {%p<tool>} {%p<op>} {encode-json(%p<params> // {})}") }
            else { $w.say("  $d {%p<tool>} {%p<target>}") }
        }
        when EVENT-TOOL-RESULT { if %p<op>:exists { $w.say("  $d tool {%p<tool>} {%p<op>}: ok={%p<ok>.Str.lc} exit={%p<exitCode>}") } else { $wrote = False } }
        when EVENT-ADAPTER-SELECTED { $w.say("  $d running in {%p<adapter>}") }
        when EVENT-PROCEDURE-SELECTED { $w.say("  $d procedure {%p<procedure>} (no model)") }
        when EVENT-ATTEMPT-STARTED { if (%p<attempt> // 0) > 1 { $w.say("  $d attempt {%p<attempt>}") } else { $wrote = False } }
        when EVENT-DIRECTIVE-APPLIED { $w.say("  $d applied {%p<directiveId>}") }
        when EVENT-DIRECTIVE-REJECTED { $w.say("  $d could not apply {%p<directiveId>}: {%p<reason>}") }
        when EVENT-PAUSED { $w.say("  $d paused") }
        when EVENT-RESUMED { $w.say("  $d resumed") }
        when EVENT-STOPPING { $w.say("  $d stopping") }
        # a denial is the run's last word: it is said once, in the receipt block
        when EVENT-DENIED { $wrote = False }
        default { $wrote = False }
    }
    $wrote;
}

#| An event's words for a pipeline record: what render-event would say,
#| without its mark or indent, on one line; empty for an event it does
#| not say.
my class Collector { has @.lines; method say($s) { @!lines.push($s.Str) } }
sub brief-event-text(%e --> Str) {
    my $c = Collector.new;
    render-event($c, %e);
    $c.lines.join(' ').subst(/ ^ \h* ['·' | '-' | '›' | '»' | '>'] \h+ /, '').trim;
}

#| What the run came to, in chunks a person can take in: the last word
#| with its mark and one line of summary; what it needs or what stopped
#| it, indented beneath; the conditions; then the rows a person comes back
#| for (changed, proposal, cost when a model was used, receipt); then the
#| next step.  The tool calls and a cost of none are --verbose.  The words
#| are the receipt's own; nothing here says the work is right.
my sub harness-label(Str $n --> Str) { $n eq 'claude_code' ?? 'Claude Code' !! $n eq 'codex' ?? 'Codex' !! $n }
#| A harness's version as a bare number: its own name is said beside it.
my sub bare-version(Str $v --> Str) { ($v ~~ / (\d+ [ '.' \d+ ]+ <[\w.-]>*) / ?? ~$0 !! $v).Str }
#| The profile a plan ran on, in brackets; a model named by hand is said so instead.
my sub profile-note(%p --> Str) {
    return ' (the model you named)' if @(%p<overrides> // []).first(*.starts-with('model '));
    my $what = (%p<task> // '') ne '' ?? " for {%p<task>} work" !! '';
    (%p<profile> // '') ne '' ?? " ({%p<profile>}$what)" !! '';
}

sub render-receipt($w, %r, IO::Path $run-dir, Str :$invocation = '', Str :$prefix = '', Str :$workspace = '', Bool :$lead = True, Bool :$verbose = False) {
    my sub row(Str $k, Str $v) { $w.say($_) for flat row-lines($k, $v) }
    my $status = %r<status>;
    my $summary = %r<summary> // '';
    $summary .= subst(/ ^ 'denied: ' /, '') if $status eq STATUS-DENIED;
    # that no --done was given is not news; the receipt keeps the phrase
    $summary .= subst(' (no conditions were declared)', '');
    $w.say('') if $lead;
    $w.say("{status-glyph($status)} {last-word($status)}: $summary");
    my sub detail(Str $line) { my @w = wrap-at($line, 72); $w.say("  {@w[0]}"); $w.say("    $_") for @w[1..*] }
    if $status eq STATUS-FAILED || $status eq STATUS-DENIED {
        detail($_) for @(%r<evidence><errors> // []);
        with %r<denied> { detail($_) for @(.<details> // []) }
    }
    row('blocked on:', %r<blockedOn>) if %r<blockedOn> ne '';
    for @(%r<conditions> // []).kv -> $i, %c {
        $w.say("  {%c<met> ?? glyph('yes') !! glyph('no')} {$i + 1}. {%c<proof>}");
    }
    $w.say('');
    my @files = @(%r<evidence><filesChanged> // []);
    row('changed:', @files.join(', ')) if @files;
    for @(%r<evidence><toolCalls> // []) -> %c {
        last unless $verbose;
        my $state = %c<unavailable> ne '' ?? 'not performed' !! (%c<ok> ?? 'ok' !! "exit {%c<exitCode>}");
        row('tool:', (%c<tool>, %c<op>, |@(%c<argv> // []), "($state)").grep(* ne '').join(' '));
    }
    with %r<evidence><proposal> -> %p {
        row('proposal:', "{%p<proposalId>} {%p<status>} ({%p<operation>}) {%p<proposalDigest>}");
        if %p<status> eq 'planned' {
            my $sha = (%p<revision> // {})<sha>; $sha = '' unless $sha ~~ Str;
            detail("{%p<service>} -> {%p<target>} at $sha; not run: {@(%p<unperformed> // []).join(', ')}");
        }
        my $note = %r<evidence><externalAction>.defined
            ?? "the plan that was approved and executed (see the receipt's externalAction)"
            !! 'it is a plan, not an approval, and nothing was deployed';
        detail("written to {$run-dir.add('proposal.json')}; $note");
    }
    # What the run was pinned to, in a line; the reasons are a step away.
    with %r<plan> -> %p {
        if (%p<modelName> // '') ne '' || (%p<profile> // '') ne '' {
            my @climbed = @(%p<escalated> // []);
            my $first = @climbed ?? @climbed[0]<from> !! plan-words(%p);
            row('ran on:', $first ~ (@climbed ?? '' !! profile-note(%p)));
            row('', "then {.<to>}, from attempt {.<attempt> + 1}: {.<why>}") for @climbed;
            if $verbose {
                row('harness:', harness-label(%p<harness>) ~ ((%p<harnessVersion> // '') ne '' ?? " {bare-version(%p<harnessVersion>)}" !! ''));
                row('why:', $_) for @(%p<reasons> // []);
                row('set by you:', @(%p<overrides>).join(', ')) if @(%p<overrides> // []);
                row('not used:', "{.<harness>}: {.<why>}") for @(%p<considered> // []);
            }
        }
    }
    my $attempts = @(%r<attempts>).elems;
    my $spent = usd-words(%r<cost><usd>) ~ ', ' ~ many-of(%r<cost><turns>.Int, 'turn') ~ ', ' ~ many-of($attempts, 'attempt');
    given %r<cost><basis> {
        when COST-NONE { row('cost:', 'none (no model was used)') if $verbose }
        when COST-HARNESS { row('cost:', "$spent, as the harness reported") }
        when COST-UNREPORTED { row('cost:', "unknown (a harness ran and reported none), {many-of($attempts, 'attempt')}") }
        when '' { row('cost:', "$spent; no basis was recorded, so this is unknown, not free") }
        default { row('cost:', "$spent ({%r<cost><basis>})") }
    }
    row('receipt:', $run-dir.add('receipt.json').Str);
    $w.say('');
    return if $invocation eq '';
    $w.say(next-after-run(%r, :$invocation, :$prefix, :$workspace, :dp-bound((%*ENV<DP_BIN> // '') ne ''), :dp-execute((%*ENV<DP_EXECUTE> // '').Str)));
    # the whole transcript is one step away, and the screen says where
    $w.say("then:  {$invocation.subst(/ ^ '321 ' /, '321 --verbose ')}   (every event and tool call)") unless $verbose;
}

#| `321 <agent> <request…>`: build a WorkPackage under local policy and
#| run it through exactly the path a delegated package takes.  Nothing
#| here is a blanket approval.
sub cmd-agent(Env $env, Global $g, Str $name, @words --> Int) {
    my $request = @words.join(' ').trim;
    # a lone "-" takes the request from standard input, to the end, so a
    # caller can hand over a long prompt without argv or a shell; steering
    # is then off, since stdin has been consumed
    if @words == 1 && @words[0] eq '-' {
        my @lines;
        loop { my $l = $env.stdin.next; last without $l; @lines.push($l) }
        $request = @lines.join("\n").trim;
        $g.non-interactive = True;
    }
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my ($agent, $err) = load-agent-named($cfg, $g, $name);
    with $err {
        $env.stderr.say("321: $err");
        $env.stderr.say($cfg.configured.elems ?? next-text('see who is configured here', '321 agents') !! next-text('configure an agent first', '321 help trust'));
        return EXIT-DENIED;
    }
    # Only a name that resolves is asked what it should do; an unknown
    # name was answered above, so no '321 status status' is ever suggested.
    if $request eq '' {
        $env.stderr.say("321: what should $name do? Give the request after the agent name.");
        $env.stderr.say(next-text('say it in plain words', "321 $name status"));
        return EXIT-USAGE;
    }

    my ($workspace, $kind) = resolve-workspace($g.workspace);
    # A package that can never read or write files gets no workspace:
    # whatever repository the terminal happens to be in is not evidence
    # of anything the run did.
    ($workspace, $kind) = ('', 'none') unless touches-workspace($agent.manifest);
    my %wp = (try build-package($cfg, $agent, $g, $request, $workspace, $kind, home => home-of($env))) // %();
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }

    # What the agent asks the runtime for, for this request: read from its
    # own curation and what was recorded here, and from what was set by hand.
    my $want = try want-for(home-of($env), $agent, %wp, $g.asked);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }
    # What the project pins: a run on another version of the agent or of a
    # skill is refused before anything starts, and told what differs.
    if package-pin-problems(home-of($env), $agent, %wp) -> @differs {
        $env.stderr.say("{glyph('no')} 321 $name: $_") for @differs;
        $env.stderr.say(next-text('see what this project pins beside what is here', '321 trust project'));
        return EXIT-DENIED;
    }

    # The CLI invocation is itself the human approval: for an interactive
    # operator `go`, plan first and attach an approval bound to that plan.
    # What was assumed is a row of the header below, never a line above it.
    my $approval-row = assume-operator-approval($env, $g, $cfg, $agent, %wp, $request);

    my $home = home-of($env);
    my $run-dir = $home.add('runs').add(%wp<packageId>);
    try { mkdir-p($run-dir); $run-dir.chmod(0o700) };
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my $raw-package = to-wire('WorkPackage', %wp);
    try $run-dir.add('work-package.json').spurt($raw-package ~ "\n");

    # The header a person reads before anything happens.  By default it is
    # the title and the byline, and the rows that are theirs to know about:
    # where the agent may edit and what was approved in their name.  The
    # trust label, the warnings, the grants and how to steer are --verbose.
    # It goes to standard error so a pipe on standard output gets the run
    # alone; on a terminal it is dressed like every other 321 screen.
    my @grants = @(%wp<capabilities><granted>);
    # The title, then a byline: a page says who wrote it, a run says who is
    # answering.  The identity is the publisher's domain and the agent's name;
    # the version stands beside it and is never part of it
    # (identity-outlives-the-model.cli.321.do).  One word says whether the
    # package is signed; the rest of the trust story is --verbose.
    my $version = (%wp<agent><version> // '').Str;
    my @header = header($name, $request.subst(/\s+/, ' ', :g).trim),
                 byline("{$agent.manifest<displayName>}, {agent-byline($agent.manifest)}", $agent.id ~ ($version ne '' ?? " $version" !! '') ~ ($agent.verified ?? ', signed' !! ', unsigned'));
    my @rows;
    my sub row(Str $k, Str $v) { @rows.append(row-lines($k, $v)) }
    if $g.verbose {
        row('trust:', $agent.label);
        row('note:', $_) for $agent.warnings;
    }
    row('workspace:', "$workspace (git); you commit, the agent only edits") if $kind eq 'git';
    row('grants:', @grants ?? @grants.join(', ') !! 'none') if $g.verbose;
    row('approval:', $approval-row) if $approval-row.defined;
    my $steering = $env.interactive && !$g.non-interactive;
    row('steer:', 'type to steer; /pause, /resume, /stop; Ctrl-C stops') if $steering && $g.verbose;
    @header.append('', |@rows) if @rows;    # the rows are their own chunk, when there are any
    my $text = @header.join("\n") ~ "\n\n";
    # in pipeline mode there is no screen to open: the records are the run
    $env.stderr.print(pretty-on-err() ?? "\n" ~ pretty($text, :on) !! $text) unless $g.brief;
    air-begun();

    my $ctx = Cancel.new;
    my $directives = Mailbox.new(:capacity(64));
    if $steering {
        my $in = $env.stdin;
        my $pid = %wp<packageId>;
        start { read-steering($ctx, $in, $directives, $pid) }
    }
    my Mailbox $signals;
    if $env.signals {
        my $pid = %wp<packageId>;
        $signals = Mailbox.new(:capacity(8));
        signal(SIGTERM, SIGINT).tap(-> $s { $signals.try-send(local-directive($pid, 1 +< 30, DIRECTIVE-STOP, '', "signal {$s.Str}", 'signal')) });
    }
    my $out = $env.stdout;
    my $shown = 0;
    my $live = False;
    # What a person sees while it runs: on a terminal, one live line under
    # the header, rewritten per event and wiped before the verdict; with
    # --verbose (or DO_321_PROGRESS=1 in a pipe) one line per event, kept;
    # into a pipe otherwise, nothing until the verdict.
    my $sink = $g.json-out
        ?? SinkFunc.new(:f(-> %e { $out.say(to-wire('RunEvent', %e)) }))
        !! $g.brief
            ?? SinkFunc.new(:f(-> %e { $out.say(brief-line(%e<kind>, brief-event-text(%e))) }))
            !! $g.verbose || progress-on()
                ?? SinkFunc.new(:f(-> %e { $shown += render-event($out, %e) ?? 1 !! 0 }))
                !! pretty-on()
                    ?? SinkFunc.new(:f(-> %e { my $t = brief-event-text(%e); if $t ne '' { live-line($out, "  {glyph('dot')} $t"); $live = True } }))
                    !! SinkFunc.new(:f(-> % {}));
    my %receipt = runner-of($env).run($ctx, %wp, $agent, Options.new(:$directives, :$signals, :$sink, :history-dir($run-dir.Str),
        :policy($cfg.policy), :adapter($g.adapter), :package-raw($raw-package.encode('utf-8')),
        :$want, :models(models-here(home-of($env)))));
    $ctx.cancel;
    wipe-live($out) if $live;
    %receipt = sign-receipt-if-keyed(%receipt, home-of($env));
    try $run-dir.add('receipt.json').spurt(to-pretty('RunReceipt', %receipt) ~ "\n");
    with %receipt<evidence><proposal> { try $run-dir.add('proposal.json').spurt(to-pretty('DeploymentProposal', $_) ~ "\n") }
    if $g.json-out { $out.say(to-wire('RunReceipt', %receipt)) }
    # the receipt's record, last: the verdict word first, then what a caller
    # comes back for
    elsif $g.brief {
        $out.say(brief-line(outcome-of(%receipt<status>), %wp<packageId>, %receipt<summary> // '', $run-dir.add('receipt.json').Str, %receipt<blockedOn> // ''));
    }
    else {
        my $prefix = '321 ' ~ ($g.package-dir ne '' ?? "--package-dir {$g.package-dir} " !! '') ~ $name;
        my $invocation = $prefix ~ ' ' ~ ($request.contains("\n") ?? '-' !! $request);
        # the block opens with air only when a run's lines came before it
        render-receipt($out, %receipt, $run-dir, :$invocation, :$prefix, :$workspace, :lead($shown > 0), :verbose($g.verbose));
    }
    exit-for(%receipt<status>);
}
