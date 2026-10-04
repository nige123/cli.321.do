unit module Do321::Tool;

#| The bounded interface between a deterministic procedure and an external
#| program the runtime binds by explicit configuration.
#|
#| A tool exposes named operations.  Each operation carries its own
#| capability requirement, so authority is checked per operation, never
#| per tool.  A procedure step names the tool and the operation; the
#| runtime checks the grant, validates the parameters, builds an argument
#| vector, runs the configured executable with no shell, bounds and
#| redacts what comes back, and records the call on the receipt.
#|
#| Nothing here knows which agent is calling.

use Data::Native;
use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;

class X::Do321::Tool is Exception is export {
    has Str $.message;
}

sub tool-error(Str $m) { X::Do321::Tool.new(message => $m).throw }

#| One operation a tool offers.
class Op is export {
    has Str $.name;
    has Str $.capability;
    has Bool $.mutates = False;
    #| When set, this build never performs the operation: a call is
    #| recorded as not performed with this message, whatever the grants.
    has Str $.unavailable = '';
}

#| What one invocation produced.
class Result is export {
    has Bool $.ok = False;
    has Int $.exit-code = 0;
    has Str $.output = '';          # redacted and capped
    has $.data;                     # the parsed JSON document, or Any
    has @.argv;                     # the exact argument vector that ran
    has Numeric $.duration = 0;     # seconds
    has Str $.unavailable = '';
    has Bool $.truncated = False;

    #| The sha256 of the redacted, capped output, for a receipt to
    #| reference without carrying it.
    method output-digest(--> Str) { digest-string($!output) }
}

#| A bound external program.  run returns a Result; it throws
#| X::Do321::Tool only for a refused call (unknown op, bad parameter, no
#| binding); a process that ran and failed is a Result with ok False.
role Tool is export {
    method name(--> Str) { ... }
    method ops(--> List) { ... }
    method run(Cancel $cancel, Str $op, %params --> Result) { ... }
    method op-of(Str $name --> Op) { self.ops.first(*.name eq $name) // Op }
}

#| Tool names to bound tools, sorted.
sub registry-names(%tools --> List) is export { %tools.keys.sort.List }

# ------------------------------------------------------------ redaction

# Redaction is applied to everything a tool returns before it reaches an
# event, a receipt or a proposal.  It is deliberately broad: a value that
# looks like a credential is replaced whether or not it is one.

my $SENSITIVE_KEY = '(?i)(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential|authorization|cookie)';
my $ASSIGNMENT    = '(?i)\b(password|passwd|secret|token|api[_-]?key|private[_-]?key|authorization)\s*[=:]\s*("[^"]*"|\'[^\']*\'|\S+)';
my $BEARER        = '(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}';
my $KNOWN_SHAPES  = '\b(sk-[A-Za-z0-9_-]{8,}|sk-ant-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})\b';
my $PEM_BLOCK     = '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----';

constant REDACTED is export = '<redacted>';

#| Global substitution with a Perl-style pattern held in a variable.
#| Raku++'s subst does not apply an interpolated pattern, so this walks
#| the matches itself; the replacer gets the Match.
sub gsub(Str $s, Str $pat, &replace --> Str) is export {
    my $out = '';
    my $rest = $s;
    while $rest ne '' && $rest ~~ m:P5/$pat/ {
        my $m = $/;
        last if $m.to == 0 && $m.from == 0 && $m.chars == 0;
        $out ~= $rest.substr(0, $m.from) ~ replace($m);
        $rest = $rest.substr($m.to);
    }
    $out ~ $rest;
}

#| Scrub free text.
sub redact(Str $s is copy --> Str) is export {
    $s = gsub($s, $PEM_BLOCK, { REDACTED });
    $s = gsub($s, $BEARER, { 'bearer ' ~ REDACTED });
    $s = gsub($s, $ASSIGNMENT, -> $m { $m[0] ~ '=' ~ REDACTED });
    $s = gsub($s, $KNOWN_SHAPES, { REDACTED });
    $s;
}

#| Scrub a decoded JSON document in place: values under sensitive keys
#| are replaced whole, and every string value is passed through redact.
sub redact-map(%m --> Hash) is export {
    for %m.keys -> $k {
        if $k ~~ m:P5/$SENSITIVE_KEY/ { %m{$k} = REDACTED; next }
        %m{$k} = redact-value(%m{$k});
    }
    %m;
}

sub redact-value($v) {
    given $v {
        when Associative { redact-map($v) }
        when Positional { [ @$v.map({ redact-value($_) }) ] }
        when Str {
            ($v.contains('=') || $v.contains(':') || $v ~~ m:P5/$KNOWN_SHAPES/ || $v.contains('-----BEGIN')) ?? redact($v) !! $v
        }
        default { $v }
    }
}

# ------------------------------------------------------------ approval

#| The execution boundary.  An approval binds to one proposal's digest and
#| to the exact parameters that matter (service, target, revision,
#| manifest digest); execution re-derives the digest from the proposal it
#| holds, compares the parameters, and refuses if the relevant current
#| state has moved since the plan was observed.

#| What the boundary re-observes immediately before acting.
class CurrentState is export {
    has Str $.manifest-digest = '';
    has Str $.deployed-revision = '';
    has Bool $.revision-exists = False;
}

#| The parameters an approval of a deployment carries.
sub approval-params(%p --> Hash) is export {
    my $sha = (%p<revision> // {})<sha>; $sha = '' unless $sha ~~ Str;
    my $md = (%p<manifest> // {})<digest>; $md = '' unless $md ~~ Str;
    %( proposalId => %p<proposalId>, proposalDigest => %p<proposalDigest>, service => %p<service>,
       target => %p<target>, revision => $sha, manifestDigest => $md );
}

#| Whether approval authorises executing proposal now.  Returns Nil only
#| when every binding holds; otherwise the reason.
sub match-approval($p, $a, CurrentState $now --> Str) is export {
    return 'no proposal' without $p;
    return 'no approval is attached' without $a;
    return "the proposal is {$p<status>}, not planned" unless $p<status> eq 'planned';
    return 'the proposal does not match its own digest' unless proposal-digest($p) eq $p<proposalDigest>;
    return "the approval is for \"{$a<action>}\", not deploy" unless $a<action> eq 'deploy';
    my $want-target = $p<service> ~ '@' ~ $p<target>;
    return "the approval targets \"{$a<target>}\", the proposal \"$want-target\"" unless $a<target> eq $want-target;
    return 'paramsHash does not match the approved params' unless params-hash($a<params>) eq $a<paramsHash>;
    return 'the approved parameters are not this proposal\'s: a changed service, target, revision or manifest needs a new proposal and a renewed approval'
        unless canonical(approval-params($p)) eq canonical($a<params> // {});
    my $md = (%$p<manifest> // {})<digest>; $md = '' unless $md ~~ Str;
    return 'the manifest has changed since the plan was observed; plan again' unless $now.manifest-digest eq $md;
    my $obs = ($p<observed> // {})<deployedRevision>;
    if $obs ~~ Str && $obs ne '' && $now.deployed-revision ne $obs {
        return 'the deployed revision has changed since the plan was observed; plan again';
    }
    return 'the approved revision is no longer reachable' unless $now.revision-exists;
    Str;
}

#| What the boundary calls after match-approval holds.  Returns a short
#| account of what it did.
role Executor is export {
    method name(--> Str) { ... }
    method execute($proposal, $approval --> Str) { ... }
}

#| Records what it was asked to execute; never deploys.
class RecordingExecutor does Executor is export {
    has @.calls;
    has Lock $!lock = Lock.new;
    method name(--> Str) { 'recording' }
    method execute($p, $a --> Str) {
        $!lock.protect({ @!calls.push($p<proposalId> ~ ' under ' ~ $a<approvalRef>) });
        'recorded by the recording executor; nothing was deployed';
    }
}

#| Run the check and, only if it holds, the executor.  Throws with the
#| reason when refused.
sub gate($p, $a, CurrentState $now, Executor $ex --> Str) is export {
    with match-approval($p, $a, $now) -> $why { tool-error($why) }
    $ex.execute($p, $a);
}

#| The current state read off a FRESH plan of the same target, taken
#| immediately before execution, for comparison with the approved one.
sub state-from($fresh, $approved --> CurrentState) is export {
    return CurrentState.new without $fresh;
    my $md = ($fresh<manifest> // {})<digest>; $md = '' unless $md ~~ Str;
    my $dep = ($fresh<observed> // {})<deployedRevision>; $dep = '' unless $dep ~~ Str;
    my $fresh-sha = ($fresh<revision> // {})<sha>; $fresh-sha = '' unless $fresh-sha ~~ Str;
    my $approved-sha = '';
    with $approved { my $s = ($_<revision> // {})<sha>; $approved-sha = $s if $s ~~ Str }
    CurrentState.new(:manifest-digest($md), :deployed-revision($dep),
        :revision-exists($fresh<status> eq 'planned' && $fresh-sha ne '' && $fresh-sha eq $approved-sha));
}

# ---------------------------------------------------------------- processes

#| The argument vector that runs $bin with %env as its whole environment.
#| Raku++'s Proc::Async ignores both :ENV and changes to %*ENV, so an
#| explicit environment travels through env(1), which replaces it exactly
#| as Go's cmd.Env does.  An empty %env inherits.
sub spawn-argv(Str $bin, @argv, %env --> List) is export {
    return ($bin, |@argv) unless %env.elems;
    my $env-bin = on-path('env') // '/usr/bin/env'.IO;
    ($env-bin.Str, '-i', |%env.keys.sort.map({ "$_={%env{$_}}" }), $bin, |@argv);
}

#| Run an executable with an argument vector and no shell, capturing
#| stdout and stderr up to caps, with a timeout and cancellation.
#| Returns (started, exit-code, stdout, stderr, timed-out, cancelled).
sub run-bounded(Str $bin, @argv, :%env, Numeric :$timeout, Int :$max-out, Int :$max-err = 16 * 1024,
                Cancel :$cancel --> List) is export {
    my $proc = Proc::Async.new(|spawn-argv($bin, @argv, %env));
    my ($out, $err) = Buf.new, Buf.new;
    $proc.stdout(:bin).tap(-> $b { $out.append($b.subbuf(0, max(0, $max-out - $out.elems))) if $out.elems < $max-out });
    $proc.stderr(:bin).tap(-> $b { $err.append($b.subbuf(0, max(0, $max-err - $err.elems))) if $err.elems < $max-err });
    my $started = try $proc.start;
    return (False, -1, '', $!.message, False, False) if $!;
    # Under Raku++ a process promise settles only inside an await, and
    # Promise.anyof over it breaks the process, so a helper thread does the
    # awaiting and settles a plain promise everyone else waits on.
    my $done = Promise.new;
    start { my $r = try await $started; $done.keep($r // Any) }
    my $deadline = Promise.in($timeout);
    my ($timed-out, $cancelled) = False, False;
    if $cancel { await Promise.anyof($done, $deadline, $cancel.promise) }
    else { await Promise.anyof($done, $deadline) }
    unless $done.status ~~ Kept {
        $timed-out = $deadline.status ~~ Kept;
        $cancelled = !$timed-out;
        try $proc.kill(SIGTERM);
        await Promise.anyof($done, Promise.in(5));
        try $proc.kill(SIGKILL) unless $done.status ~~ Kept;
        await $done;
    }
    my $result = await $done;
    my $code = $result.defined ?? $result.exitcode !! -1;
    $code = -1 if $timed-out || $cancelled;
    (True, $code, $out.decode('utf-8'), $err.decode('utf-8'), $timed-out, $cancelled);
}

sub go-duration(Numeric $seconds --> Str) is export {
    return "{$seconds}s" if $seconds < 60;
    my $m = ($seconds / 60).floor;
    my $s = $seconds - $m * 60;
    $m >= 60 ?? "{($m / 60).floor}h{$m % 60}m{$s}s" !! "{$m}m{$s}s";
}

# --------------------------------------------------------------------- dp

constant DEFAULT-TIMEOUT    is export = 120;
constant DEFAULT-MAX-OUTPUT is export = 256 * 1024;
#| The message every execute call returns when no executor is bound.
constant EXECUTION-UNAVAILABLE is export = 'execution is unavailable here (DP_EXECUTE is unset): the proposal was prepared and nothing was deployed';

my $SERVICE_RE  = '^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$';
my $TARGET_RE   = '^[a-z][a-z0-9-]{0,15}$';
my $REVISION_RE = '^[0-9a-f]{7,40}$';

#| The deployment engine's explicit entry point (deploy.321.do's bin/dp)
#| bound as a tool.  Operations: status (deploy.read), plan (deploy.plan),
#| execute (deploy.invoke; performed only by a bound executor).  The
#| binding is an explicit path (DP_BIN), never a command name on PATH.
class DP does Tool is export {
    has Str $.bin = '';                 # empty: not bound
    has Numeric $.timeout = 0;          # 0: DEFAULT-TIMEOUT
    has Int $.max-output = 0;           # 0: DEFAULT-MAX-OUTPUT
    has %.env;                          # replaces the environment when given
    has $.exec;                         # an Executor, or Any: execute is unavailable

    method name(--> Str) { 'dp' }
    method executor() { $!exec }
    method bound(--> Bool) { $!bin ne '' }

    method ops(--> List) {
        (Op.new(:name<status>, :capability(CAP-DEPLOY-READ)),
         Op.new(:name<plan>, :capability(CAP-DEPLOY-PLAN)),
         Op.new(:name<execute>, :capability(CAP-DEPLOY-INVOKE), :mutates, :unavailable($!exec.defined ?? '' !! EXECUTION-UNAVAILABLE)));
    }

    #| The argument vector for an operation, refusing anything that is
    #| not a validated parameter.  Every value is checked against a strict
    #| pattern, so no value can begin with "-" or carry a shell
    #| metacharacter; the vector goes to exec directly, never to a shell.
    method argv(Str $op, %params --> List) {
        for %params.keys -> $k {
            tool-error("dp: unsupported parameter \"$k\"") unless is-in($k, <service target revision>);
        }
        my ($service, $target, $revision) = %params<service> // '', %params<target> // '', %params<revision> // '';
        tool-error("dp: service \"$service\" is not a group.name service name") if $service ne '' && $service !~~ m:P5/$SERVICE_RE/;
        tool-error("dp: target \"$target\" is not a target name") if $target ne '' && $target !~~ m:P5/$TARGET_RE/;
        tool-error("dp: revision \"$revision\" is not a commit sha") if $revision ne '' && $revision !~~ m:P5/$REVISION_RE/;
        given $op {
            when 'status' {
                my @argv = 'status';
                @argv.push($service) if $service ne '';
                @argv.push($target) if $target ne '';
                tool-error('dp: status takes no revision') if $revision ne '';
                return (|@argv, '--json');
            }
            when 'plan' | 'execute' {
                my @argv = 'plan';
                @argv.push($service) if $service ne '';
                if $target ne '' {
                    # A lone target would be read as a service name by the
                    # engine; make the ambiguity explicit instead.
                    @argv.push('') if $service eq '';
                    @argv.push($target);
                }
                @argv.push('--revision', $revision) if $revision ne '';
                return (|@argv, '--json');
            }
        }
        tool-error("dp: unsupported operation \"$op\"");
    }

    method run(Cancel $cancel, Str $op, %params --> Result) {
        my $o = self.op-of($op);
        tool-error("dp: unsupported operation \"$op\"") without $o;
        my @argv = self.argv($op, %params);
        if $o.unavailable ne '' {
            # The boundary exists so a caller cannot smuggle execution
            # through planning parameters; it is not enabled.  Nothing runs.
            return Result.new(:!ok, :exit-code(-1), :unavailable($o.unavailable));
        }
        tool-error('dp: not configured (set DP_BIN to the engine\'s explicit entry point)') unless self.bound;
        my $timeout = $!timeout > 0 ?? $!timeout !! DEFAULT-TIMEOUT;
        my $max-out = $!max-output > 0 ?? $!max-output !! DEFAULT-MAX-OUTPUT;
        my $start = now;
        my ($started, $code, $stdout, $stderr, $timed-out, $) =
            run-bounded($!bin, @argv, :%!env, :$timeout, :$max-out, :$cancel);
        tool-error("dp: process did not start: $stderr") unless $started;
        my $duration = now - $start;
        if $timed-out {
            return Result.new(:!ok, :exit-code($code), :@argv, :$duration,
                :output(redact("dp: no answer within {go-duration($timeout)}\n$stderr")));
        }
        my $truncated = $stdout.encode('utf-8').elems >= $max-out;
        my $ok = $code == 0;
        my $doc = $truncated ?? Any !! parse-doc($stdout);
        if $doc.defined {
            my %data = redact-map($doc);
            return Result.new(:$ok, :exit-code($code), :@argv, :$duration, :$truncated, :data(%data), :output(encode-json(%data)));
        }
        Result.new(:$ok, :exit-code($code), :@argv, :$duration, :$truncated, :output(redact(($stdout ~ "\n" ~ $stderr).trim)));
    }
}

#| One JSON object read from a tool's output, or Any.
sub parse-doc(Str $raw) {
    my $v = try parse-json($raw.trim);
    return Any if $! || $v !~~ Associative;
    %($v);
}

#| A compact human line from a status or plan document.
sub summarise(Str $op, $data --> Str) is export {
    return '' without $data;
    given $op {
        when 'status' {
            my @parts;
            for @($data<services> // []) -> $s {
                next unless $s ~~ Associative;
                my $name = $s<name> ~~ Str ?? $s<name> !! '';
                my $ubic = $s<ubic> ~~ Str ?? $s<ubic> !! '';
                my $state = ($s<running> ~~ Bool && $s<running>) ?? 'running' !! 'not running';
                @parts.push("$name $state ($ubic)");
            }
            @parts .= sort;
            return 'no services matched' unless @parts;
            return "{@parts.elems} service(s): {@parts.join('; ')}";
        }
        when 'plan' {
            my $status = $data<status> ~~ Str ?? $data<status> !! '';
            if $status ne 'planned' {
                my $q = $data<question> ~~ Str ?? $data<question> !! '';
                return "plan blocked: $q";
            }
            my $svc = $data<service> ~~ Associative ?? $data<service> !! {};
            my $rev = $data<revision> ~~ Associative ?? $data<revision> !! {};
            my $name = $svc<name> ~~ Str ?? $svc<name> !! '';
            my $target = $svc<target> ~~ Str ?? $svc<target> !! '';
            my $sha = $rev<sha> ~~ Str ?? $rev<sha> !! '';
            my $n = ($data<unperformed> // []).elems;
            return "planned: deploy $name to $target at {short-sha($sha)}; $n check(s) not run";
        }
    }
    '';
}

sub short-sha(Str $sha --> Str) is export { $sha.chars > 12 ?? $sha.substr(0, 12) !! $sha }

#| Performs an approved deployment by calling the engine's own
#| `go <service> <target>` through the same explicit entry point.  Bound
#| only when DP_EXECUTE names the targets it may act on; a target not
#| named is refused before anything runs.
class EngineExecutor does Executor is export {
    has Str $.bin = '';
    has @.allowed-targets;
    has Numeric $.timeout = 0;
    has %.env;

    method name(--> Str) { 'dp go' }
    method allowed(Str $target --> Bool) { is-in($target, @!allowed-targets) }

    method execute($p, $a --> Str) {
        tool-error("execution on target \"{$p<target>}\" is not enabled here (DP_EXECUTE lists: {@!allowed-targets.join(', ')})")
            unless self.allowed($p<target>);
        tool-error('the approved proposal names an invalid service or target')
            unless $p<service> ~~ m:P5/$SERVICE_RE/ && $p<target> ~~ m:P5/$TARGET_RE/;
        tool-error('no engine executable is configured') if $!bin eq '';
        my $timeout = $!timeout > 0 ?? $!timeout !! 15 * 60;
        my @argv = 'go', $p<service>, $p<target>;
        my ($started, $code, $stdout, $stderr, $timed-out, $) =
            run-bounded($!bin, @argv, :%!env, :$timeout, :max-out(64 * 1024), :max-err(64 * 1024));
        my $text = redact(($stdout ~ $stderr).trim);
        my $tail = $text.chars > 2000 ?? '…' ~ $text.substr(*-2000) !! $text;
        tool-error("engine go did not finish within {go-duration($timeout)}: $tail") if $timed-out;
        tool-error("engine go failed: exit $code: $tail") unless $started && $code == 0;
        # The engine's go reports a failed gate, an aborted deploy or a
        # rollback in words and exits 0; read them rather than the exit code.
        my $lower = $text.lc;
        for 'deploy aborted', 'rolled back', '[fail]', 'did not recover', "can't reach" -> $bad {
            tool-error("engine go did not succeed: $tail") if $lower.contains($bad);
        }
        "engine go {$p<service>} {$p<target>} completed: $tail";
    }
}
