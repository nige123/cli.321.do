unit module Do321::CLI;

#| The front door: `321 <agent> <request>` for people and `321 run` for
#| machines, plus the small inspection commands.
#|
#| Reserved first words: run, agents, packages, trust, doctor, help,
#| version.  Anything else is an agent alias or a canonical id.  A request
#| is the remaining words joined by single spaces; it becomes the objective
#| of a WorkPackage and is never handed to a shell.

use Data::Native;
use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Digest;
use Do321::Trust;
use Do321::Tool;
use Do321::Adapter;
use Do321::Run;
use Do321::Wire;
use Do321::Hooks;

#| Stamped at build time in the release workflow.
constant VERSION is export = '0.3.1';

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

constant USAGE = q:to/END/;
    321 - run an agent

      321 <agent> <request...>            ask a configured agent to do something here
      321 <publisher>/<agent> <request>   the same, by canonical id
      321 <agent> -                       the request from standard input, to its end

    Options before the agent:
      --workspace <dir>       where the work happens (default: the enclosing git repo, else none)
      --package-dir <dir>     load an unsigned local package from a directory (identity local/<name>)
      --attach <file>         make a file available to the agent (repeatable)
      --done <condition>      a completion condition, in order (repeatable)
      --grant <capability>    grant an optional capability within local policy (repeatable)
      --placement client|server|either
      --network none|provider_only|open
                              the agent's own network access (default: local policy, else provider_only).
                              shell.run does not imply network: with a shell granted and no open
                              network, no adapter that cannot deny the network will be selected
      --adapter <name>        insist on one adapter
      --non-interactive       never read steering from the terminal
      --json                  print events as JSON lines instead of a transcript
      --trust <file>          trust configuration (default ~/.321/trust.json)

    Machine invocation:
      321 run --package <file|-> [--workspace <dir>] [--receipt <file>] [--events <file>]
              [--run-id <id>] [--history-dir <dir>] [--adapter <name>] [--package-dir <dir>]
              [--continue <receipt.json>]   continue a blocked run of the SAME package: cost and
                                            attempts carry forward, the old receipt is linked
          stdin:  the work package (when --package -), then work directives, one JSON object per line
          stdout: run events, then exactly one run receipt; a protocol error when no package can be identified

    Inspection:
      321 agents                    configured packages, their trust and aliases
      321 packages validate <dir>   check a package directory against agent-package.v1
      321 packages digest <dir> [--write]
      321 packages builtin prompt   write the built-in prompt-only package under ~/.321/packages and print its path
      321 trust show | check
      321 doctor [--json]           installed adapters and what each actually enforces, and bound tools

    Harness hooks (for a hook command such as 'iz4 hook'):
      321 hooks install --workspace <dir> --command <cmd> [--strict] [--json]
                                    wire <cmd> session-start|pre-edit|stop into every harness
                                    321 knows, in that workspace; --strict wires the two that refuse
      321 hooks status  --workspace <dir> --command <cmd> [--json]
      321 hooks remove  --workspace <dir> --command <cmd> [--json]

    Tool bindings (procedures only, by explicit path, never by PATH lookup):
      DP_BIN             the deployment engine entry point a package's dp
                                    tool steps may call: status (deploy.read) and plan (deploy.plan);
                                    execute (deploy.invoke) is not performed in this build
      321 version | help

    Exit codes: 0 completed or no change, 2 blocked, 3 stopped, 4 failed, 5 denied,
    64 usage, 65 malformed input, 70 internal error.
    END

#| The installed adapter set: the procedure executor and the fake (hidden,
#| selectable only by name) and Claude Code.  X321_CLAUDE_BINARY names the
#| harness executable for an isolated test environment without touching
#| PATH.
sub default-registry($stderr --> Registry) is export {
    # DO321_FAKE_SCRIPT is a test seam: a JSON list of procedure steps the
    # hidden fake adapter runs instead of its default script (the JSON
    # itself, or @<file> holding it), so the suite can drive every
    # directive path through the real entry point.
    my $seam = %*ENV<DO321_FAKE_SCRIPT> // '';
    $seam = (try $seam.substr(1).IO.slurp) // '' if $seam.starts-with('@');
    my $script = $seam ne '' ?? (try parse-json($seam)) !! Any;
    $script = [ @$script.map({ load('ProcedureStep', $_) }) ] if $script ~~ Positional;
    Registry.new
        .register-hidden(new-procedure(:tools(default-tools())))
        .register-hidden(new-fake($script))
        .register(ClaudeCode.new(:binary(%*ENV<X321_CLAUDE_BINARY> // ''), :stderr($stderr), :transcript($stderr)));
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
    return %*ENV<X321_HOME>.IO if %*ENV<X321_HOME>;
    $*HOME.add('.321');
}

sub runner-of(Env $env --> Runner) { Runner.new(:adapters($env.adapters)) }

#| Run the CLI and return the exit code.
sub cli-main(Env $env is copy --> Int) is export {
    $env = Env.new(:stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :args($env.args), :trust-path($env.trust-path),
        :home($env.home), :adapters(default-registry($env.stderr)), :interactive($env.interactive), :signals($env.signals))
        without $env.adapters;
    my ($g, $rest) = try parse-global($env.args);
    if $! {
        $env.stderr.say("321: {$!.message}");
        $env.stderr.print(USAGE);
        return EXIT-USAGE;
    }
    my @rest = @$rest;
    $env = Env.new(:stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :args($env.args), :trust-path($g.trust-path),
        :home($env.home), :adapters($env.adapters), :interactive($env.interactive), :signals($env.signals)) if $g.trust-path ne '';
    unless @rest { $env.stdout.print(USAGE); return EXIT-USAGE }
    given @rest[0] {
        when 'help' | '-h' | '--help' { $env.stdout.print(USAGE); return 0 }
        when 'version' | '--version' { $env.stdout.say("321 {VERSION}"); return 0 }
        when 'run'      { return cmd-run($env, $g, @rest[1 .. *]) }
        when 'agents'   { return cmd-agents($env) }
        when 'packages' { return cmd-packages($env, @rest[1 .. *]) }
        when 'trust'    { return cmd-trust($env, @rest[1 .. *]) }
        when 'doctor'   { return cmd-doctor($env, @rest[1 .. *]) }
        when 'hooks'    { return cmd-hooks($env, $g, @rest[1 .. *]) }
    }
    cmd-agent($env, $g, @rest[0], @rest[1 .. *]);
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
        if $! { $env.stderr.say("321 run: {$!.message}"); return EXIT-USAGE }
        $i++;
    }
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321 run: {$!.message}"); return EXIT-INTERNAL }
    my $opts = WireOptions.new(|%o, :stdin($env.stdin), :stdout($env.stdout), :stderr($env.stderr), :runner(runner-of($env)),
        :signals($env.signals), :trust($cfg));
    serve(Cancel.new, $opts);
}

# ------------------------------------------------------------- inspection

sub cmd-agents(Env $env --> Int) {
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
    my @list = $cfg.configured;
    unless @list {
        $env.stdout.say("No agents are configured in {$cfg.path}.");
        $env.stdout.say('Add a pinned publisher package or a local package there, or use --package-dir <dir> for an unsigned local package.');
        return 0;
    }
    for @list -> $r {
        my $alias = $r.alias ne '' ?? '  alias ' ~ $r.alias !! '';
        my $version = $r.pin.defined ?? '  ' ~ $r.pin<version> !! '';
        $env.stdout.say(sprintf('%-32s %-12s%s%s', $r.id.Str, $r.level, $version, $alias));
    }
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
        $dir.mkdir;
        for %files.kv -> $rel, $text {
            my $f = $dir.add($rel);
            $f.parent.mkdir;
            $f.spurt($text);
        }
        write-digest-file($dir, compute($dir)[0]);
    }
    $dir;
}

sub cmd-packages(Env $env, @args --> Int) {
    my $usage = 'usage: 321 packages validate <dir> | digest <dir> [--write] | show <id> | builtin <name>';
    if @args < 2 { $env.stderr.say($usage); return EXIT-USAGE }
    given @args[0] {
        when 'builtin' {
            my $dir = try materialise-builtin(@args[1], home-of($env));
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-USAGE }
            my ($m, $d) = try validate-package($dir);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
            $env.stdout.say($dir.Str);
            return 0;
        }
        when 'validate' {
            my ($m, $d) = try validate-package(@args[1].IO);
            if $! { $env.stdout.say("INVALID: {$!.message}"); return EXIT-FAILED }
            $env.stdout.say("OK {$m<id>} {$m<version>} $d");
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
            return 0;
        }
        when 'show' {
            my $cfg = try trust-of($env);
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-INTERNAL }
            my $l = try load-resolved($cfg.resolve(@args[1]));
            if $! { $env.stderr.say("321: {$!.message}"); return EXIT-DENIED }
            my %m = $l.manifest;
            $env.stdout.say("{%m<id>}  {%m<version>}  {$l.digest}");
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
            return 0;
        }
    }
    $env.stderr.say($usage);
    EXIT-USAGE;
}

sub cmd-trust(Env $env, @args --> Int) {
    my $cfg = try trust-of($env);
    if $! { $env.stderr.say("321: {$!.message}"); return EXIT-FAILED }
    my $sub = @args ?? @args[0] !! 'show';
    given $sub {
        when 'show' {
            $env.stdout.say("trust file: {$cfg.path}");
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
            return 0;
        }
        when 'check' {
            my $problems = 0;
            for $cfg.configured -> $r {
                my $l = try load-resolved($r);
                if $! { $env.stdout.say("FAIL {$r.id}: {$!.message}"); $problems++; next }
                $env.stdout.say("ok   {$r.id} ({$r.level})");
            }
            return $problems ?? EXIT-FAILED !! 0;
        }
    }
    $env.stderr.say('usage: 321 trust show | check');
    EXIT-USAGE;
}

sub cmd-doctor(Env $env, @args --> Int) {
    my $json = is-in('--json', @args);
    if $json {
        my $cfg = try trust-of($env);
        my %trust = $! ?? %( error => $!.message ) !! %( path => $cfg.path, exists => $cfg.path.IO.e, packages => $cfg.configured.elems, policy => $cfg.policy );
        my @bindings;
        with $env.adapters.get('procedure') -> $p { @bindings = $p.bindings if $p ~~ ProcedureAdapter }
        my %d = doctor-document($env.adapters, @bindings, %trust);
        %d<iz4> = %( binary => iz4-binary(), applied => iz4-binary() ne '' );
        $env.stdout.say(encode-json-pretty(%d));
        return $! ?? EXIT-FAILED !! 0;
    }
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
    }
    with $env.adapters.get('procedure') -> $p {
        if $p ~~ ProcedureAdapter {
            $env.stdout.say('tools bound to procedures (by explicit path):');
            my @b = $p.bindings;
            $env.stdout.say('  none') unless @b;
            $env.stdout.say('  ' ~ $_) for @b;
        }
    }
    my $iz4 = iz4-binary();
    $env.stdout.say($iz4 ne ''
        ?? "iz4: $iz4 (the IZ4 protocol is applied to model-driven runs in a workspace that keeps an IZ4)"
        !! 'iz4: not on PATH (an IZ4 in a workspace is reported on the receipt, not applied)');
    my $cfg = try trust-of($env);
    if $! { $env.stdout.say("trust: {$!.message}"); return EXIT-FAILED }
    if $cfg.path.IO.e { $env.stdout.say("trust: {$cfg.path}, {$cfg.configured.elems} configured package(s)") }
    else { $env.stdout.say("trust: no file at {$cfg.path} (only --package-dir packages can run)") }
    $env.stdout.say("policy: {to-wire('Policy', $cfg.policy)}");
    0;
}

# ----------------------------------------------------------------- hooks

sub cmd-hooks(Env $env, Global $g, @args --> Int) {
    my $usage = 'usage: 321 hooks install|status|remove --workspace <dir> --command <cmd> [--strict] [--json]';
    if !@args { $env.stderr.say($usage); return EXIT-USAGE }
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
        if $! { $env.stderr.say("321 hooks: {$!.message}"); return EXIT-USAGE }
        $i++;
    }
    $workspace = $*CWD.Str if $workspace eq '';
    if $command eq '' { $env.stderr.say('321 hooks: --command names the hook command, such as "iz4 hook"'); return EXIT-USAGE }
    unless $workspace.IO.d { $env.stderr.say("321 hooks: no such directory {$workspace}"); return EXIT-USAGE }
    my @records = do given $sub {
        when 'install' { install-all($workspace.IO, $command, :$strict) }
        when 'status'  { status-all($workspace.IO, $command) }
        when 'remove'  { remove-all($workspace.IO, $command) }
        default { $env.stderr.say($usage); return EXIT-USAGE }
    };
    if $json { $env.stdout.say(encode-json-pretty(%( schema => 'hooks.v1', workspace => $workspace.IO.absolute, command => $command, harnesses => [ |@records ] ))) }
    else {
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

sub is-operator-deploy-go(Env $env, Global $g, Loaded $agent, Str $request --> Str) {
    return Str if !$env.interactive || $g.non-interactive;
    return Str unless is-in(CAP-DEPLOY-INVOKE, @($agent.manifest<capabilities><optional> // []));
    my @fields = $request.words;
    return Str unless @fields && @fields[0] eq 'go';
    @fields[0] = 'plan';
    @fields.join(' ');
}

sub mint-operator-approval(%p, Str $by --> Hash) {
    my %params = approval-params(%p);
    doc('Approval', proposalRef => 'operator/' ~ %p<proposalId>, approvalRef => 'operator/' ~ new-ulid(), approvedBy => $by,
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
    my $proposal = operator-plan($env, $g, $cfg, $agent, $plan-request);
    return Str unless $proposal.defined && $proposal<status> eq 'planned';
    my $by = %*ENV<USER> // '';
    my $host = (try qx{hostname}.trim) // '';
    $by ~= "@$host" if $host ne '';
    %wp<approval> = mint-operator-approval($proposal, $by);
    %wp<capabilities><granted>.push(CAP-DEPLOY-INVOKE) unless is-in(CAP-DEPLOY-INVOKE, %wp<capabilities><granted>);
    if validate-work-package(%wp) {
        %wp<approval>:delete;
        return Str;
    }
    my $sha = ($proposal<revision> // {})<sha>; $sha = '' unless $sha ~~ Str;
    "operator approval assumed (you typed the command): deploy {$proposal<service>} to {$proposal<target>} at {short-sha($sha)} — execution proceeds only where DP_EXECUTE enables it";
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

sub render-receipt($w, %r, IO::Path $run-dir) {
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
    if $request eq '' {
        $env.stderr.say("321: what should $name do? Give the request after the agent name.");
        return EXIT-USAGE;
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
    with $err { $env.stderr.say("321: $err"); return EXIT-DENIED }

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
    try { $run-dir.mkdir; $run-dir.chmod(0o700) };
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
    try $run-dir.add('receipt.json').spurt(to-pretty('RunReceipt', %receipt) ~ "\n");
    with %receipt<evidence><proposal> { try $run-dir.add('proposal.json').spurt(to-pretty('DeploymentProposal', $_) ~ "\n") }
    if $g.json-out { $out.say(to-wire('RunReceipt', %receipt)) }
    else { render-receipt($out, %receipt, $run-dir) }
    exit-for(%receipt<status>);
}
