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
use Do321::Run;
use Do321::Wire;
use Do321::Hooks;
use Do321::Controller;
use Do321::Enforcement;
use Do321::Help;
use Do321::Look;

#| Stamped at build time in the release workflow.
constant VERSION is export = '0.4.2';

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
#| selectable only by name) and Claude Code.  DO_321_CLAUDE_BINARY names the
#| harness executable for an isolated test environment without touching
#| PATH.
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
        .register(ClaudeCode.new(:binary(%*ENV<DO_321_CLAUDE_BINARY> // ''), :stderr($stderr), :transcript($stderr)));
}

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
    has @.attach is rw;
    has @.done is rw;
    has @.grant is rw;
    has Bool $.non-interactive is rw = False;
    has Bool $.json-out is rw = False;
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
            when '--attach'          { $g.attach.push(need()) }
            when '--done'            { $g.done.push(need()) }
            when '--grant'           { $g.grant.push(need()) }
            when '--non-interactive' { $g.non-interactive = True }
            when '--json'            { $g.json-out = True }
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
sub cli-main(Env $env is copy --> Int) is export {
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
    unless @rest { $env.stdout.print(help-index(help-ctx($env))); return EXIT-USAGE }
    # '321 status --help' is '321 help status'
    return cmd-help($env, [@rest[0]]) if is-in(@rest[0], RESERVED) && @rest.grep('--help' | '-h');
    given @rest[0] {
        when 'help' | '-h' | '--help' { return cmd-help($env, @rest[1 .. *]) }
        when 'version' | '--version' { $env.stdout.say("321 {VERSION}"); return 0 }
        when 'run'      { return cmd-run($env, $g, @rest[1 .. *]) }
        when 'agents'   { return cmd-agents($env) }
        when 'packages' { return cmd-packages($env, @rest[1 .. *]) }
        when 'trust'    { return cmd-trust($env, @rest[1 .. *]) }
        when 'doctor'   { return cmd-doctor($env, @rest[1 .. *]) }
        when 'status'   { return cmd-status($env, $g, @rest[1 .. *]) }
        when 'key'      { return cmd-key($env, $g, @rest[1 .. *]) }
        when 'receipt'  { return cmd-receipt($env, $g, @rest[1 .. *]) }
        when 'hooks'    { return cmd-hooks($env, $g, @rest[1 .. *]) }
        when 'harness'  { return cmd-harness($env, $g, @rest[1 .. *]) }
        when 'hook'     { return cmd-hook($env, @rest[1 .. *]) }
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
    $env.stderr.say("321 $topic: $line") if $line ne '';
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
            my %pub = try new-key($home);
            if $! { $env.stderr.say("321 key: {$!.message}"); return EXIT-FAILED }
            if $g.json-out { $env.stdout.say(encode-json(%pub)); return 0 }
            $env.stdout.say("key {%pub<keyId>} made at {key-path($home)}; receipts from this 321 are signed with it from now on.");
            $env.stdout.say("public key: {%pub<publicKey>}");
            $env.stdout.say(next-text('pin the public key where receipts are checked', '321 key'));
            0;
        }
        when 'show' {
            my $k = try load-key($home);
            if $! { $env.stderr.say("321 key: {$!.message}"); return EXIT-FAILED }
            without $k {
                if $g.json-out { $env.stdout.say(encode-json(%())); return 0 }
                $env.stdout.say("No signing key at {key-path($home)}: receipts from this 321 are unsigned.");
                $env.stdout.say(next-text('make one', '321 key new'));
                return 0;
            }
            my %pub = public-part(%$k);
            if $g.json-out { $env.stdout.say(encode-json(%pub)); return 0 }
            $env.stdout.say(header('key', "{%pub<keyId>} at {key-path($home)}"));
            $env.stdout.say('');
            $env.stdout.say("public key: {%pub<publicKey>}");
            $env.stdout.say('');
            $env.stdout.say('Receipts from this 321 are signed with it. A signature says a receipt is as it was issued; it never says the work is right.');
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
    if $! || $r !~~ Associative { $env.stderr.say("321 receipt verify: {$file} is not a receipt: {$!.message // 'not a JSON object'}"); return EXIT-FAILED }
    without $key {
        my $k = try load-key(home-of($env));
        $key = $k<publicKey> with $k;
    }
    without $key { $env.stderr.say("321 receipt verify: no key to check against: give --key <base64>, or make this 321's own with '321 key new'"); return EXIT-USAGE }
    my $id = try verify-receipt(%$r, $key);
    if $! { $env.stderr.say("321 receipt verify: {$file}: {$!.message}"); return EXIT-FAILED }
    $env.stdout.say("receipt {$r<receiptId>} for package {$r<packageId>}: digest matches its content and the signature verifies under key $id.");
    $env.stdout.say('That says the receipt is as it was issued and what it records happened; it does not say the work is right.');
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
    my %wp = try parse-json($dir.add('work-package.json').slurp);
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

#| "HH:MM" for today, "MM-DD HH:MM" for an earlier day, local time.
sub when-text(Str $iso --> Str) {
    return '     ' if $iso eq '';
    my $d = try DateTime.new($iso).local;
    return '     ' without $d;
    my $hm = sprintf('%02d:%02d', $d.hour, $d.minute);
    $d.Date eq Date.today ?? $hm !! sprintf('%02d-%02d %s', $d.month, $d.day, $hm);
}

sub trim-to(Str $s, Int $n --> Str) { $s.chars <= $n ?? $s !! $s.substr(0, $n - 1) ~ '…' }

#| `321 status`: what is going on with this 321, on one screen: the
#| runtime, the workspace and its IZ4, the agents, the deploy binding,
#| receipt signing, the last runs, and the next step the newest run that
#| needs a person is waiting for.  This is the runtime's own state; an
#| agent's `status` request (321 <agent> status) is the engine's view of
#| services, a different thing.
sub cmd-status(Env $env, Global $g, @args --> Int) {
    my $want = 5;
    if @args && @args[0] eq '--runs' { $want = (@args[1] // '5').Int max 1 }
    elsif @args && @args[0] ne '--json' { return usage-error($env, 'status', "it takes --runs N and --json, not '{@args[0]}'") }
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
            my %s = try enforcement-status($a, $controller, $workspace.IO);
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

    my $w = $env.stdout;
    $w.say(header('status', "{VERSION} on {$*KERNEL.hostname}"));
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
    if @runs {
        row('last runs:', $total > @runs ?? "{@runs.elems} of $total (321 status --runs N for more)" !! "{@runs.elems} of $total");
        for @runs -> %r {
            my $line = sprintf('  %-11s %-14s %-30s %s', when-text(%r<startedAt>), trim-to(%r<agent>, 14), trim-to(%r<objective>, 30), %r<status>.uc);
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
    0;
}

# ------------------------------------------------------------------ run

sub cmd-run(Env $env, Global $g, @args --> Int) {
    my %o = package-source => '-', package-dir => $g.package-dir, workspace => $g.workspace, adapter => $g.adapter;
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
                when '--continue'    { %o<continue-from> = need() }
                default { X::Do321::Usage.new(message => "unknown option $name for run").throw }
            }
            Str;
        };
        if $! { return usage-error($env, 'run', $!.message) }
        $i++;
    }
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321 run: {$!.message}"); return EXIT-INTERNAL }
    my $opts = WireOptions.new(|%o, :stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :runner(runner-of($env)),
        :signals($env.signals), :trust($cfg), :home(home-of($env).Str));
    serve(Cancel.new, $opts);
}

# ------------------------------------------------------------- inspection

sub cmd-agents(Env $env --> Int) {
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my @list = $cfg.configured;
    unless @list {
        $env.stdout.print(calm("No agents are configured in {$cfg.path}",
            'Add a pinned publisher package or a local package there, or run an unsigned local package by path with --package-dir DIR.',
            :next(['help trust' => 'how a package is pinned or a local one named'])));
        return 0;
    }
    $env.stdout.say(header('agents', "{@list.elems} configured in {$cfg.path}"));
    $env.stdout.say('');
    for @list -> $r {
        my $alias = $r.alias ne '' ?? '  alias ' ~ $r.alias !! '';
        my $version = $r.pin.defined ?? '  ' ~ $r.pin<version> !! '';
        $env.stdout.say(sprintf('%-32s %-12s%s%s', $r.id.Str, $r.level, $version, $alias));
    }
    my $first = @list[0].alias ne '' ?? @list[0].alias !! @list[0].id.Str;
    $env.stdout.say('');
    $env.stdout.say(next-text('ask one of them', "321 $first <request...>"));
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

sub cmd-packages(Env $env, @args --> Int) {
    return usage-error($env, 'packages', @args ?? "'packages {@args.join(' ')}' needs more" !! 'say what to do') if @args < 2;
    given @args[0] {
        when 'builtin' {
            my $dir = try materialise-builtin(@args[1], home-of($env));
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }
            my ($m, $d) = try validate-package($dir);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            $env.stdout.say($dir.Str);
            $env.stdout.say(next-text('run it by path, no trust file needed', "321 --package-dir $dir {@args[1]} <request...>"));
            return 0;
        }
        when 'validate' {
            my ($m, $d) = try validate-package(@args[1].IO);
            if $! { $env.stdout.say("INVALID: {$!.message}"); $env.stdout.say(next-text('fix what it names, then validate again', "321 packages validate {@args[1]}")); return EXIT-FAILED }
            $env.stdout.say("OK {$m<id>} {$m<version>} $d");
            $env.stdout.say(next-text('pin it in the trust file so it can be asked by name', '321 help trust'));
            return 0;
        }
        when 'digest' {
            my ($d, $entries) = try compute(@args[1].IO);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            if @args > 2 && @args[2] eq '--write' {
                try write-digest-file(@args[1].IO, $d);
                if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            }
            $env.stdout.say("$d ({@$entries.elems} files)");
            $env.stdout.say(@args > 2 && @args[2] eq '--write'
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

sub cmd-trust(Env $env, @args --> Int) {
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
    my $sub = @args ?? @args[0] !! 'show';
    given $sub {
        when 'show' {
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
        when 'check' {
            $env.stdout.say(header('trust check', $cfg.path.Str));
            $env.stdout.say('');
            my @failed;
            for $cfg.configured -> $r {
                my $l = try load-resolved($r);
                if $! { $env.stdout.say("{glyph('no')} {$r.id}: {$!.message}"); @failed.push($r.id.Str); next }
                $env.stdout.say("{glyph('yes')} {$r.id} ({$r.level})");
            }
            $env.stdout.say('');
            $env.stdout.print(@failed
                ?? say-next(@failed.map({ "fix the pin for $_ in {$cfg.path}; the digest or path is what usually moved" }), :then('321 trust check'))
                !! next-text('see them as a list', '321 agents') ~ "\n");
            return @failed ?? EXIT-FAILED !! 0;
        }
    }
    usage-error($env, 'trust', "there is no 'trust $sub'");
}

sub cmd-doctor(Env $env, @args --> Int) {
    my $json = is-in('--json', @args);
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
    $env.stdout.say(header('doctor', 'what this machine can run and enforce'));
    $env.stdout.say('');
    $env.stdout.say('adapters and what each actually enforces:');
    for $env.adapters.all -> $a {
        my $det = $a.detect;
        my $state = $det.available ?? 'available ' ~ $det.version !! 'unavailable: ' ~ $det.reason;
        $env.stdout.say(sprintf('  %-12s %s', $a.name, $state));
        my %enf = $a.enforcement;
        my @yes = features().grep({ enforces(%enf, $_) });
        my @no = features().grep({ !enforces(%enf, $_) });
        $env.stdout.say("      enforces:     {@yes.join(', ')}");
        $env.stdout.say("      not enforced: {@no.join(', ')}") if @no;
        if $a.controls.elems > 0 {
            my %c = $a.controls;
            my @ce = controls().grep({ control-strength(%c, $_) eq STRENGTH-ENFORCES });
            my @ca = controls().grep({ control-strength(%c, $_) eq STRENGTH-ADVISES });
            my @cn = controls().grep({ control-strength(%c, $_) eq STRENGTH-NONE });
            $env.stdout.say('      controls a controller can be driven from:');
            $env.stdout.say("        enforces: {@ce.join(', ') || 'nothing'}");
            $env.stdout.say("        advises:  {@ca.join(', ')}") if @ca;
            $env.stdout.say("        cannot:   {@cn.join(', ')}") if @cn;
        }
    }
    with $env.adapters.get('procedure') -> $p {
        if $p ~~ ProcedureAdapter {
            $env.stdout.say('tools bound to procedures (by explicit path):');
            my @b = $p.bindings;
            $env.stdout.say('  none') unless @b;
            $env.stdout.say('  ' ~ $_) for @b;
        }
    }
    my %probe = IZ4.new.probe;
    $env.stdout.say(%probe<drivable>
        ?? "iz4: {%probe<binary>} ({%probe<tool>}; drivable: it is applied to model-driven runs in a workspace that keeps an IZ4)"
        !! %probe<binary> ne ''
            ?? "iz4: {%probe<binary>} is installed but cannot be driven: {%probe<reason>}. An IZ4 in a workspace is reported, not applied."
            !! 'iz4: not on PATH (an IZ4 in a workspace is reported on the receipt, not applied)');
    my $cfg = try trust-of($env);
    if $! { $env.stdout.say("trust: {$!.message}"); return EXIT-FAILED }
    if $cfg.path.IO.e { $env.stdout.say("trust: {$cfg.path}, {$cfg.configured.elems} configured package(s)") }
    else { $env.stdout.say("trust: no file at {$cfg.path} (only --package-dir packages can run)") }
    $env.stdout.say("policy: {to-wire('Policy', $cfg.policy)}");
    $env.stdout.say('');
    $env.stdout.say($cfg.configured.elems ?? next-text('see who you can ask', '321 agents') !! next-text('configure an agent', '321 help trust'));
    0;
}

# -------------------------------------------------- harnesses, controllers

#| The harness adapters: the ones that say they have controls at all.
sub harness-adapters(Env $env --> List) {
    $env.adapters.all.grep({ .controls.elems > 0 }).List;
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
    return usage-error($env, 'harness detect', @args ?? "there is no 'harness {@args[0]}'" !! 'say what to do') if !@args || @args[0] ne 'detect';
    my ($workspace, $, $json) = try parse-harness-options($env, $g, @args[1 .. *], 'harness detect');
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
    $env.stdout.say(header('harness detect', $workspace.IO.absolute.Str));
    $env.stdout.say('');
    for @records -> %r {
        $env.stdout.say(sprintf('%-14s %s', %r<harness>, %r<detected> ?? "detected {%r<version>}" !! "not detected ({%r<reason>})"));
        $env.stdout.say("    project wiring: {%r<wiring>}" ~ (%r<configured> ?? '' !! ' (none yet)')) if %r<wiring> ne '';
        my @yes = controls().grep({ %r<controls>{$_} eq STRENGTH-ENFORCES });
        my @adv = controls().grep({ %r<controls>{$_} eq STRENGTH-ADVISES });
        my @no  = controls().grep({ %r<controls>{$_} eq STRENGTH-NONE });
        $env.stdout.say("    enforces: {@yes.join(', ') || 'nothing'}");
        $env.stdout.say("    advises:  {@adv.join(', ')}") if @adv;
        $env.stdout.say("    cannot:   {@no.join(', ')}") if @no;
    }
    $env.stdout.say('no harness with controls is known to this 321') unless @records;
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
    if $json {
        $env.stdout.say(encode-json-pretty(%( schema => 'enforcement-report.v1', workspace => $ws.absolute, controller => $name, harnesses => [ |@statuses ] )));
    }
    else {
        # One verdict per harness.  The detail, control by control, is
        # --verbose; what the levels mean is 321 help enforcement.
        my $w = $env.stdout;
        $w.say(header("$name $sub", $ws.absolute.Str));
        $w.say('');
        my $wide = @statuses.map({ .<harness>.chars }).max // 10;
        for @statuses -> %s {
            my $did = $sub eq 'status' || !%s<applies> ?? ''
                !! %s<action> ~ (%s<action> eq 'unchanged' | 'removed' | 'failed' ?? '' !! (%s<wiring> ne '' ?? " ({%s<wiring>})" !! '')) ~ '; ';
            $w.say(sprintf('  %-*s  %s%s', $wide, %s<harness>, $did, verdict(%s)));
            $w.say(sprintf('  %-*s  adopted the wiring an earlier %s wrote (%s): its commands are replaced by 321\'s', $wide, '', $name, @(%s<adopted>).map({ control-label($_) }).join(', ')))
                if (%s<action> // '') eq 'adopted';
            $w.say(sprintf('  %-*s  ! %s', $wide, '', %s<error>)) if (%s<error> // '') ne '';
            if $verbose { $w.say(''); $w.say($_) for status-lines(%s) }
        }
        $w.say('');
        my @live = @statuses.grep({ .<applies> });
        my @weak = @live.grep({ !.<available> || .<headline> ne 'GUARDED' });
        my @legacy = @live.grep({ @(.<legacy> // []).elems });
        if !@live { $w.say(next-text('an IZ4 here would say what the software is for; iz4 init starts one', 'iz4 init')) }
        elsif @live.grep({ !.<available> }) { $w.say(next-text("{$name} cannot be driven here; make it so, then install again", "321 $name install")) }
        elsif @legacy { $w.say(next-text("adopt the wiring an earlier {$name} wrote, so 321 drives it", "321 $name install")) }
        elsif @weak && $sub ne 'remove' { $w.say(next-text('wire it as strongly as the harness allows', "321 $name install")) }
        elsif $sub eq 'remove' { $w.say(next-text('wire it again when wanted', "321 $name install")) }
        else {
            $w.say("All wired: {$name.uc} is guarded in {@live.map(*<harness>).join(', ')}. That is what is wired, not what happened: a run's receipt records the checks that ran.");
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
    my ($code, $out, $err) = 0, '', '';
    my sub answer() { ($code, $out, $err) = $adapter.answer($control, $v, :$headless, :$strength, :controller($name)) }
    if $control eq CTRL-POST-RUN && %native<stop_hook_active> {
        # The harness's own loop guard: this turn was already refused once.
        # Nothing is asked again, and nothing is recorded as having passed.
        $v = unavailable(POINT-VERIFY, 'not asked again: this turn end was already refused once (the harness\'s loop guard)');
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
    }
    elsif $control eq CTRL-POST-RUN {
        $v = $controller.verify($workspace, %( summary => $adapter.final-words(%native) ));
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
    $env.stdout.print($out) if $out ne '';
    $env.stderr.print($err) if $err ne '';
    $code;
}

sub hook-log(Str $controller, Str $harness, Str $control, Verdict $v) {
    my $path = %*ENV<DO_321_HOOK_LOG> // '';
    return if $path eq '';
    my %line = controller => $controller, harness => $harness, control => $control, point => $v.point,
        result => $v.result, reason => $v.reason, invariants => [ |$v.invariants.map(*.Str) ];
    try {
        my $fh = $path.IO.open(:a);
        $fh.say(encode-json(%line));
        $fh.close;
    }
}

# ----------------------------------------------------------------- hooks

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
    my %plan-wp = try build-package($cfg, $agent, $g, $plan-request, '', 'none');
    return Hash if $!;
    my $raw = to-wire('WorkPackage', %plan-wp).encode('utf-8');
    my %receipt = runner-of($env).run(Cancel.new, %plan-wp, $agent, Options.new(:sink(SinkFunc.new(:f(-> % {}))), :policy($cfg.policy), :adapter($g.adapter), :package-raw($raw)));
    %receipt<evidence><proposal> // Hash;
}

#| When this is an interactive operator `go`, plan read-only and, if a
#| concrete plan comes back, mint an operator approval bound to it and
#| attach it (granting deploy.invoke within local policy).  Returns a
#| one-line note to show the person, or Str when nothing was assumed.
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
        ($kind, $how) = 'operator', 'operator approval assumed (you typed the command)';
    }
    else {
        my $sa = standing-approval-for($cfg, $proposal<service> // '', $proposal<target> // '');
        return Str without $sa;
        $by = "{$sa<approvedBy>} (standing approval in local policy)";
        ($kind, $how) = 'standing', "standing approval in local policy (approved by {$sa<approvedBy>})";
    }
    %wp<approval> = mint-operator-approval($proposal, $by, :$kind);
    %wp<capabilities><granted>.push(CAP-DEPLOY-INVOKE) unless is-in(CAP-DEPLOY-INVOKE, %wp<capabilities><granted>);
    if validate-work-package(%wp) {
        %wp<approval>:delete;
        return Str;
    }
    my $sha = ($proposal<revision> // {})<sha>; $sha = '' unless $sha ~~ Str;
    "$how: deploy {$proposal<service>} to {$proposal<target>} at {short-sha($sha)} — execution proceeds only where DP_EXECUTE enables it";
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
sub build-package(Config $cfg, Loaded $agent, Global $g, Str $request, Str $workspace, Str $kind --> Hash) is export {
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
    my $ps = validate-work-package(%wp);
    X::Do321::Usage.new(message => $ps.Str).throw if $ps;
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

sub render-event($w, %e) {
    my %p = %e<payload> // {};
    given %e<kind> {
        when EVENT-PROGRESS {
            if %p<text> ~~ Str && %p<text> ne '' { $w.say(%p<text>) }
            elsif %p<instruction> ~~ Str { $w.say('  » instruction applied: ' ~ %p<instruction>) }
        }
        when EVENT-TOOL-CALL {
            if %p<op>:exists { $w.say("  · tool {%p<tool>} {%p<op>} {encode-json(%p<params> // {})}") }
            else { $w.say("  · {%p<tool>} {%p<target>}") }
        }
        when EVENT-TOOL-RESULT { $w.say("  · tool {%p<tool>} {%p<op>}: ok={%p<ok>.Str.lc} exit={%p<exitCode>}") if %p<op>:exists }
        when EVENT-ADAPTER-SELECTED { $w.say("  · adapter {%p<adapter>}") }
        when EVENT-PROCEDURE-SELECTED { $w.say("  · procedure {%p<procedure>} (no model)") }
        when EVENT-ATTEMPT-STARTED { $w.say("  · attempt {%p<attempt>}") if (%p<attempt> // 0) > 1 }
        when EVENT-DIRECTIVE-APPLIED { $w.say("  · applied {%p<directiveId>}") }
        when EVENT-DIRECTIVE-REJECTED { $w.say("  · could not apply {%p<directiveId>}: {%p<reason>}") }
        when EVENT-PAUSED { $w.say('  · paused') }
        when EVENT-RESUMED { $w.say('  · resumed') }
        when EVENT-STOPPING { $w.say('  · stopping') }
        when EVENT-DENIED {
            $w.say("  · denied: {%p<reason>}");
            $w.say("    - $_") for @(%p<details> // []);
        }
    }
}

sub render-receipt($w, %r, IO::Path $run-dir, Str :$invocation = '', Str :$prefix = '', Str :$workspace = '') {
    $w.say('');
    $w.say("{%r<status>.uc}: {%r<summary>}");
    if %r<status> eq STATUS-FAILED || %r<status> eq STATUS-DENIED {
        $w.say("  ! $_") for @(%r<evidence><errors> // []);
        with %r<denied> {
            $w.say("  ! {.<reason>}");
            $w.say("    $_") for @(.<details> // []);
        }
    }
    $w.say("Needs an answer: {%r<blockedOn>}") if %r<blockedOn> ne '';
    for @(%r<conditions> // []).kv -> $i, %c {
        $w.say("  {%c<met> ?? '✓' !! '✗'} {$i + 1}. {%c<proof>}");
    }
    my @files = @(%r<evidence><filesChanged> // []);
    $w.say("Changed: {@files.join(', ')}") if @files;
    for @(%r<evidence><toolCalls> // []) -> %c {
        my $state = %c<unavailable> ne '' ?? 'not performed' !! (%c<ok> ?? 'ok' !! "exit {%c<exitCode>}");
        $w.say("Tool: {%c<tool>} {%c<op>} {@(%c<argv> // []).join(' ')} ($state)");
    }
    with %r<evidence><proposal> -> %p {
        $w.say("Proposal: {%p<proposalId>} {%p<status>} ({%p<operation>}) {%p<proposalDigest>}");
        if %p<status> eq 'planned' {
            my $sha = (%p<revision> // {})<sha>; $sha = '' unless $sha ~~ Str;
            $w.say("  {%p<service>} -> {%p<target>} at $sha; not run: {@(%p<unperformed> // []).join(', ')}");
        }
        my $note = %r<evidence><externalAction>.defined
            ?? "the plan that was approved and executed (see the receipt's externalAction)"
            !! 'it is a plan, not an approval, and nothing was deployed';
        $w.say("  written to {$run-dir.add('proposal.json')}; $note");
    }
    given %r<cost><basis> {
        when COST-NONE { $w.say('Cost: none (no model was used)') }
        when COST-HARNESS { $w.say(sprintf('Cost: $%.2f, %d turns, %d attempt(s), as the harness reported', %r<cost><usd>, %r<cost><turns>, @(%r<attempts>).elems)) }
        when COST-UNREPORTED { $w.say("Cost: unknown (a harness ran and reported none), {@(%r<attempts>).elems} attempt(s)") }
        default { $w.say(sprintf('Cost: $%.2f, %d turns, %d attempt(s) (%s)', %r<cost><usd>, %r<cost><turns>, @(%r<attempts>).elems, %r<cost><basis>)) }
    }
    $w.say("Receipt: {$run-dir.add('receipt.json')}");
    $w.say('');
    $w.say(next-after-run(%r, :$invocation, :$prefix, :$workspace, :dp-bound((%*ENV<DP_BIN> // '') ne ''), :dp-execute((%*ENV<DP_EXECUTE> // '').Str)))
        if $invocation ne '';
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
    my $agent;
    my $err;
    if $g.package-dir ne '' {
        $agent = try load-path($g.package-dir.IO);
        $err = $!.message if $!;
        if !$err.defined && $agent.id ne $name && $agent.manifest<name> ne $name {
            $err = "the package at {$g.package-dir} is {$agent.id}, not $name";
        }
    }
    else {
        $agent = try load-resolved($cfg.resolve($name));
        $err = $!.message if $!;
    }
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
    my %wp = try build-package($cfg, $agent, $g, $request, $workspace, $kind);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }

    # The CLI invocation is itself the human approval: for an interactive
    # operator `go`, plan first and attach an approval bound to that plan.
    with assume-operator-approval($env, $g, $cfg, $agent, %wp, $request) -> $note { $env.stderr.say("321: $note") }

    my $home = home-of($env);
    my $run-dir = $home.add('runs').add(%wp<packageId>);
    try { mkdir-p($run-dir); $run-dir.chmod(0o700) };
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my $raw-package = to-wire('WorkPackage', %wp);
    try $run-dir.add('work-package.json').spurt($raw-package ~ "\n");

    $env.stderr.say("321: {$agent.manifest<displayName>} ({$agent.label})");
    $env.stderr.say("321: note: $_") for $agent.warnings;
    $env.stderr.say("321: workspace $workspace (you commit; the agent only edits)") if $kind eq 'git';
    $env.stderr.say("321: grants {@(%wp<capabilities><granted>).join(', ')}");

    my $ctx = Cancel.new;
    my $directives = Mailbox.new(:capacity(64));
    if $env.interactive && !$g.non-interactive {
        $env.stderr.say('321: type to steer, /pause, /resume, /stop; Ctrl-C stops');
        my $in = $env.stdin;
        my $pid = %wp<packageId>;
        start { read-steering($ctx, $in, $directives, $pid) }
    }
    if $env.signals {
        my $pid = %wp<packageId>;
        signal(SIGTERM, SIGINT).tap(-> $s { $directives.try-send(local-directive($pid, 1 +< 30, DIRECTIVE-STOP, '', "signal {$s.Str}", 'signal')) });
    }
    my $out = $env.stdout;
    my $sink = $g.json-out
        ?? SinkFunc.new(:f(-> %e { $out.say(to-wire('RunEvent', %e)) }))
        !! SinkFunc.new(:f(-> %e { render-event($out, %e) }));
    my %receipt = runner-of($env).run($ctx, %wp, $agent, Options.new(:$directives, :$sink, :history-dir($run-dir.Str),
        :policy($cfg.policy), :adapter($g.adapter), :package-raw($raw-package.encode('utf-8'))));
    $ctx.cancel;
    %receipt = sign-receipt-if-keyed(%receipt, home-of($env));
    try $run-dir.add('receipt.json').spurt(to-pretty('RunReceipt', %receipt) ~ "\n");
    with %receipt<evidence><proposal> { try $run-dir.add('proposal.json').spurt(to-pretty('DeploymentProposal', $_) ~ "\n") }
    if $g.json-out { $out.say(to-wire('RunReceipt', %receipt)) }
    else {
        my $prefix = '321 ' ~ ($g.package-dir ne '' ?? "--package-dir {$g.package-dir} " !! '') ~ $name;
        my $invocation = $prefix ~ ' ' ~ ($request.contains("\n") ?? '-' !! $request);
        render-receipt($out, %receipt, $run-dir, :$invocation, :$prefix, :$workspace);
    }
    exit-for(%receipt<status>);
}
