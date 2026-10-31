unit module Do321::Host;

#| The run host: one detached process per run, which outlives the
#| terminal that started it.  It runs the same runtime a person or a work
#| system runs (`321 run --package FILE`), as its child, so there is one
#| runtime path: trust, grants, approvals, ordered directives and the
#| receipt are all the runtime's, unchanged.  The host adds only what a
#| run needs to be watched and controlled from elsewhere:
#|
#|   - it records who it is (pid, start time, boot) so nothing is mistaken
#|     for it after it is gone;
#|   - it is the only writer of the run's event log;
#|   - it takes requests from the run's inbox, numbers them in the order
#|     they arrive and hands them to the runtime as directives;
#|   - it is the subreaper of everything below it, and when the runtime
#|     ends it stops whatever the agent left running, and records that.
#|
#| It never writes the receipt and never changes one (the receipt is the
#| runtime's: work-package-immutable.cli.321.do).  A stop always reaches
#| the runtime first; signals are the fallback, never the first word
#| (a person can always stop the run, and safely).

use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Trust;
use Do321::CLI;
use Do321::Sys;
use Do321::RunDir;
use Do321::Fold;
use Do321::Harnesses;

constant HOST-VERSION is export = '0.5.0';
#| How long a delivered stop may take before the host signals the runtime.
constant STOP-GRACE = 30;
#| How long a stopped process gets between SIGTERM and SIGKILL.
constant KILL-GRACE = 5;
#| How large a run's log may grow before the agent's words are dropped.
constant LOG-CAP = 64 * 1_048_576;
#| Exit code when a run started and how it ended is unknown.
constant EXIT-LOST is export = 6;

# ---------------------------------------------------------------- launch

#| Start a run that outlives this terminal.  The package is built exactly
#| as `321 <agent> <request>` builds it, through the CLI's own builder:
#| the same trust, the same grants inside the same policy ceiling.  A run
#| launched here carries no approval; an approval stays where a person
#| gives one.  Returns (RunDir, error).
sub launch-run(Str $agent-name, Str $request, Str :$workspace = '', Str :$trust-path = '', IO::Path :$home = home-dir(),
               Str :$via = 'mission-control', :%continues, Str :$harness = '', Bool :$isolate = False --> List) is export {
    return (RunDir, 'say what the agent should do') if $request.trim eq '';
    # The harness is chosen here or left to the runtime, which picks the
    # first one able to enforce what the package needs.  Either way the
    # runtime checks it again: a choice never widens what is enforced.
    my $adapter = '';
    if $harness ne '' {
        my ($name, $why) = check-harness($harness);
        return (RunDir, $why) with $why;
        $adapter = $name;
    }
    private-umask();
    my $cfg = try load-trust($trust-path ne '' ?? $trust-path.IO !! default-trust-path());
    return (RunDir, $!.message) if $!;
    my $g = Do321::CLI::Global.new(:$trust-path, :$workspace);
    my ($agent, $err) = load-agent-named($cfg, $g, $agent-name);
    return (RunDir, $err) with $err;
    my ($ws, $kind) = resolve-workspace($workspace);
    ($ws, $kind) = ('', 'none') unless needs-workspace($agent.manifest);
    # Two runs that write never share a workspace: the second is refused,
    # or given a worktree of its own.
    my %isolation;
    if $ws ne '' && $isolate {
        return (RunDir, "$ws is not a git repository, so a run cannot have a worktree of it") unless $kind eq 'git';
        my ($path, $base, $why) = make-worktree($ws, $home);
        return (RunDir, $why) with $why;
        %isolation = kind => 'git-worktree', of => $ws, path => $path, base => $base;
        $ws = $path;
    }
    elsif $ws ne '' && writes($agent.manifest) {
        with workspace-taken($ws, $home) -> $other {
            my %o = $other.run;
            return (RunDir, "{%o<agent><displayName> // 'another run'} {$other.short} is already working in $ws; --isolate gives this run a worktree of its own");
        }
    }
    my %wp = try build-package($cfg, $agent, $g, $request, $ws, $kind);
    if $! {
        my $why = $!.message;
        drop-worktree(%isolation) if %isolation;
        return (RunDir, $why);
    }

    my $rd = try {
        private-dir(home-dir-of($home));
        private-dir(runs-root($home));
        # Control files rely on rename and O_EXCL meaning the same thing to
        # every reader: on a network filesystem they may not.
        with weak-filesystem(runs-root($home).Str) {
            die "{runs-root($home)} is on $_, and runs need a local filesystem; set DO_321_HOME to a local directory" if $_ ne '';
        }
        my $r = run-dir(%wp<packageId>, $home);
        private-dir($r.dir);
        private-dir($r.inbox);
        $r;
    };
    # a refusal that already says what to do needs no preface
    return (RunDir, ($!.message.contains('DO_321_HOME') || $!.message.contains('not safe to use') ?? '' !! 'cannot make the run directory: ') ~ $!.message) if $!;
    my %m = $agent.manifest;
    write-atomic($rd.package-file, to-wire('WorkPackage', %wp) ~ "\n", :durable);
    my %run = schema => SCHEMA-RUN, runId => %wp<packageId>, attempt => 1, continues => (%continues ?? %continues !! Nil),
        agent => { id => $agent.id, name => $agent-name, version => (%m<version> // ''), displayName => (%m<displayName> // $agent-name),
                   byline => byline-of(%m) },
        request => $request, workspace => $ws, grants => [ |@(%wp<capabilities><granted>) ],
        harness => { requested => $adapter }, isolation => (%isolation ?? %isolation !! Nil),
        launchedBy => { uid => my-uid(), via => $via }, launchedAt => now-iso();
    write-atomic($rd.run-file, encode-json-pretty(%run) ~ "\n", :durable);

    my $spawned = spawn-host($rd);
    return ($rd, "the host did not start: $spawned") with $spawned;
    ($rd, Str);
}

sub home-dir-of(IO::Path $home --> IO::Path) { $home }

#| Take back a worktree no run used.
sub drop-worktree(%iso) {
    try { my $p = run 'git', '-C', %iso<of>, 'worktree', 'remove', '--force', %iso<path>, :out, :err; $p.out.slurp(:close); $p.err.slurp(:close) }
}

#| Whether an agent can change files: one that can, holds its workspace.
sub writes(%m --> Bool) {
    so (|@(%m<capabilities><required> // []), |@(%m<capabilities><optional> // [])).first({ $_ eq 'repo.write' | 'files.write' | 'shell.run' });
}

#| An active run already working in this workspace, or RunDir:U.
sub workspace-taken(Str $ws, IO::Path $home --> RunDir) {
    for all-runs($home) -> $r {
        next unless $r.hosted && ($r.run<workspace> // '') eq $ws;
        return $r if liveness($r)<phase> eq 'starting' | 'running' | 'held' | 'stopping' | 'blocked';
    }
    RunDir;
}

#| A worktree of the workspace at its last commit, for one run, under
#| ~/.321/worktrees.  Nothing is committed: the person reviews what the
#| run changed there and takes it, or removes the worktree.  Returns
#| (path, base commit, error).
sub make-worktree(Str $ws, IO::Path $home --> List) {
    my $root = private-dir($home.add('worktrees'));
    my $path = $root.add(new-ulid()).Str;
    my $head = run 'git', '-C', $ws, 'rev-parse', 'HEAD', :out, :err;
    my $base = $head.out.slurp(:close).trim;
    $head.err.slurp(:close);
    return (Str, Str, "$ws has no commit yet, so there is nothing to make a worktree of") if $head.exitcode != 0 || $base eq '';
    my $add = run 'git', '-C', $ws, 'worktree', 'add', '--detach', $path, $base, :out, :err;
    $add.out.slurp(:close);
    my $err = $add.err.slurp(:close);
    return (Str, Str, "git could not make a worktree: {$err.lines.grep(*.trim ne '').tail // 'it said nothing'}") if $add.exitcode != 0;
    ($path, $base, Str);
}

#| Whether an agent can touch files at all; one that cannot gets no
#| workspace, as at the terminal.
sub needs-workspace(%m --> Bool) {
    for |@(%m<capabilities><required> // []), |@(%m<capabilities><optional> // []) -> $c {
        return True if $c (elem) <repo.read repo.write files.read files.write shell.run>;
    }
    False;
}

#| An agent's byline: its own, or the first clause of its role.
sub byline-of(%m --> Str) is export {
    my $b = (%m<identity><byline> // '').trim;
    return $b if $b ne '';
    my $role = (%m<identity><role> // '').trim;
    my $first = $role.split(/<[.;,]>/)[0] // '';
    $first.chars > 40 ?? $first.substr(0, 39) ~ '…' !! $first;
}

#| Start the host in a session of its own, with no terminal, so closing
#| the terminal, losing the connection or a crash of the screen kills
#| nothing.  Returns an error, or Str.
sub spawn-host(RunDir $r --> Str) {
    my $setsid = </usr/bin/setsid /bin/setsid>.first(*.IO.x) // return 'setsid is not installed';
    my $log = $r.log-file;
    $log.spurt('') unless $log.e;
    $log.chmod(0o600);
    my $p = Proc::Async.new('sh', '-c', 'exec "$1" -f "$@" </dev/null >>"$0" 2>&1', $log.Str, $setsid, |mission-argv(), 'host', $r.dir.Str);
    my $res = try await $p.start;
    return "could not run setsid: {$!.message}" if $!;
    return "setsid exited {$res.exitcode}" if $res.exitcode != 0;
    Str;
}

# ---------------------------------------------------------------- the host

#| `321 host DIR`: be the host of one run.  Returns the exit code.
sub host-main(Str $dir --> Int) is export {
    my $r = RunDir.new(:dir($dir.IO.absolute.IO));
    with unsafe-dir($r.dir.Str) { note "321 host: {$r.dir} is not safe to use: $_" ~ remedy($r.dir, $_); return 70 }
    return 64 unless valid-run-id($r.id) && $r.run-file.e && $r.package-file.e;
    # one host per run: the live marker is taken exclusively
    unless create-exclusive($r.live-file.Str, '') {
        note "321 host: run {$r.id} already has a host";
        return 70;
    }
    private-umask();
    my $reaper = become-subreaper();
    my %run = $r.run;
    my %self = proc-stat(my-pid()) // {};
    my %host = schema => SCHEMA-HOST, runId => $r.id, pid => my-pid(), startTicks => %self<start> // 0, bootId => boot-id(),
        pgid => %self<pgid> // 0, sid => %self<sid> // 0, subreaper => $reaper, version => HOST-VERSION, startedAt => now-iso();
    write-atomic($r.host-file, encode-json-pretty(%host) ~ "\n", :durable);

    my $log = EventLog.new(:path($r.events-file));
    my $state = RunState.new;
    my $mu = Lock.new;
    # Past the cap the agent's own words are dropped, once said; every
    # other event (tools, controls, the end) is still recorded.
    my $cap = (%*ENV<DO_321_MC_LOG_CAP> // LOG-CAP).Int;
    my $capped = 0;
    my sub record(Str $src, Str $kind, %payload, Str :$at = now-iso()) {
        $mu.protect({
            if $kind eq 'progress' && (%payload<text> // '') ne '' && $r.events-file.s > $cap {
                fold-event($state, $log.append('host', 'log_truncated', %( bytes => $cap, dropping => 'progress text' ))) unless $capped++;
            }
            else { fold-event($state, $log.append($src, $kind, %payload, :$at)) }
        });
    }
    my sub write-status() {
        my %d = $mu.protect({ status-doc($state, $r.id) });
        my @below = descendants(my-pid());
        my ($ticks, $rss) = usage-of(@below);
        %d<usage> = %( cpuSeconds => ($ticks / 100).round(0.1), rssBytes => $rss, processes => +@below, basis => '/proc, every process below the host' );
        try write-atomic($r.status-file, encode-json-pretty(%d) ~ "\n");
    }
    record('host', 'host_started', %( pid => my-pid(), request => %run<request> // '', agent => %run<agent><id> // '', subreaper => $reaper,
        continues => (%run<continues> ~~ Associative ?? %run<continues><runId> // '' !! '') ));

    # The runtime, as its own child, told to go when the host goes.
    my @pre = </usr/bin/setpriv /bin/setpriv>.first(*.IO.x) ?? (</usr/bin/setpriv /bin/setpriv>.first(*.IO.x), '--pdeathsig', 'TERM', '--') !! ();
    my @argv = |@pre, |runtime-argv(), 'run', '--package', $r.package-file.Str, '--receipt', $r.receipt-file.Str, '--history-dir', $r.dir.Str;
    my $asked = (%run<harness> // {})<requested> // '';
    @argv.append('--adapter', $asked) if $asked ne '';
    my $proc = Proc::Async.new(:w, |@argv);
    my $receipt-seen = False;
    $proc.stdout.lines.tap(-> $line {
        my $f = try parse-json($line);
        if $f ~~ Associative {
            given $f<schema> // '' {
                when SCHEMA-RUN-EVENT { record('run', $f<kind> // '', ($f<payload> // {}).Hash, :at($f<at> // now-iso())) }
                when SCHEMA-RUN-RECEIPT {
                    $receipt-seen = True;
                    record('host', 'receipt', %( status => $f<status> // '', summary => $f<summary> // '', file => $r.receipt-file.Str ));
                }
                when SCHEMA-PROTOCOL-ERROR { record('host', 'protocol_error', %( code => $f<code> // '', message => $f<message> // '' )) }
            }
        }
    });
    $proc.stderr.tap(-> $s { $*ERR.print($s) });
    my $done = $proc.start;
    my $child = try await $proc.ready;
    with $child {
        %host<runtimePid> = $child;
        %host<runtimeStartTicks> = (proc-stat($child) // {})<start> // 0;
        write-atomic($r.host-file, encode-json-pretty(%host) ~ "\n", :durable);
    }
    my $pkg = (try parse-json($r.package-file.slurp)) // {};
    my $package-id = $pkg<packageId> // $r.id;

    my $seq = 0;
    my %seen;
    my $stop-at;
    my $escalated = False;
    my $ended = False;
    my $send-mu = Lock.new;
    my sub deliver(%d) {
        $send-mu.protect({
            my $id = %d<directiveId>;
            if %seen{$id}++ { record('host', 'directive_duplicate', %( directiveId => $id )); return }
            if $ended { record('host', 'directive_refused', %( directiveId => $id, reason => 'the run has ended' )); return }
            my $kind = %d<kind> eq 'hold' ?? DIRECTIVE-PAUSE !! %d<kind>;
            my %w = doc('WorkDirective', schema => SCHEMA-WORK-DIRECTIVE, directiveId => $id, packageId => $package-id, seq => ++$seq,
                issuer => { kind => 'local', id => "{%*ENV<USER> // ''}/{%d<from><client> // 'client'}" }, issuedAt => %d<sentAt> // now-stamp(),
                kind => $kind, payload => { text => %d<text> // '', reason => %d<reason> // '' });
            %w<digest> = directive-digest(%w);
            my $ok = try { await $proc.say(to-wire('WorkDirective', %w)); True };
            if $ok {
                record('host', 'directive_delivered', %( directiveId => $id, kind => %d<kind>, text => %d<text> // '', seq => $seq ));
                $stop-at //= now if %d<kind> eq 'stop';
            }
            else { $seq--; record('host', 'directive_refused', %( directiveId => $id, reason => 'the runtime is no longer listening' )) }
        });
    }
    # a signal to the host is a stop, from the one who sent it
    signal(SIGHUP).tap({ });
    signal(SIGTERM, SIGINT).tap(-> $s {
        deliver(%( directiveId => new-ulid(), kind => 'stop', reason => "signal {$s.Str} to the host", from => { client => 'signal' } ));
    });

    my $inbox-loop = start {
        # inotify wakes the loop when a request lands; without it, a poll
        my $watch = Watch.new;
        $watch.add($r.inbox.Str);
        until $ended {
            for take-inbox($r) -> %t {
                with %t<refused> { record('host', 'directive_refused', %( directiveId => %t<directiveId>, reason => "the request was not read: $_" )) }
                else { deliver(%t<directive>) }
            }
            # a stop that the runtime has not honoured in time: signal it
            if $stop-at.defined && !$escalated && !$ended && now - $stop-at > STOP-GRACE {
                $escalated = True;
                with $child {
                    record('host', 'escalated', %( signal => 'TERM', pid => $_, after => STOP-GRACE ));
                    send-signal($_, SIGTERM);
                    my $c = $_;
                    start { sleep KILL-GRACE * 3; send-signal($c, SIGKILL) unless $ended }
                }
            }
            $watch.wait(200);
        }
        $watch.close;
    };
    # The heartbeat also notes every process below the host, so that if
    # the host itself is killed, what it was running can still be found
    # and stopped by identity (pid and start time), not by guesswork.
    my $beat = start {
        until $ended {
            write-status();
            snapshot-tree($r);
            for ^10 { last if $ended; sleep 0.2 }
        }
    };

    my $res = try await $done;
    my $exit = $res.defined ?? $res.exitcode !! -1;
    $send-mu.protect({ $ended = True });
    try $proc.close-stdin;
    # The heartbeat and the inbox stop before the sweep: from here on one
    # thread works, so nothing below races the end of the run.
    try await $inbox-loop;
    try await $beat;

    # Whatever the agent left running below the host is stopped now, and
    # each process is named: the model's word that it was killed is not
    # evidence, the kernel's is.
    my @swept = sweep(my-pid());
    record('host', 'swept', %( processes => @swept ));
    if !$r.receipt-file.e {
        record('host', 'runtime_exited', %( exitCode => $exit, receipt => False ));
        record-ended($r, %( summary => "the runtime exited $exit without writing a receipt", exitCode => $exit,
                            lastSeq => $log.seq, observedBy => 'host' ));
    }
    elsif !$receipt-seen {
        my %rc = $r.receipt;
        record('host', 'receipt', %( status => %rc<status> // '', summary => %rc<summary> // '', file => $r.receipt-file.Str ));
    }
    record('host', 'host_ended', %( runtimeExit => $exit ));
    write-status();
    # Anything still in the inbox now cannot be delivered: say so.
    for take-inbox($r) -> %t {
        record('host', 'directive_refused', %( directiveId => %t<directiveId> // %t<directive><directiveId>, reason => 'the run has ended' ));
    }
    $log.close;
    try $r.live-file.unlink;
    0;
}

#| Note the processes below this host, by identity, for a force stop
#| that has to work without the host.
sub snapshot-tree(RunDir $r) is export {
    my @t = descendants(my-pid()).map(-> $pid {
        my %s = proc-stat($pid) // Nil;
        %s ?? %( pid => $pid, start => %s<start>, sid => %s<sid>, pgid => %s<pgid>, command => proc-cmdline($pid).substr(0, 120) ) !! Empty
    });
    try write-atomic($r.dir.add('tree.json'), encode-json(%( at => now-iso(), bootId => boot-id(), processes => @t )) ~ "\n");
}

#| Stop every process below $root: SIGTERM, a grace period, then SIGKILL
#| for what remains.  Returns what was found and what it took.
sub sweep(Int $root, Int :$grace = KILL-GRACE --> List) is export {
    my %found;
    for descendants($root) -> $pid {
        my %s = proc-stat($pid) // next;
        %found{$pid} = %( pid => $pid, start => %s<start>, command => proc-cmdline($pid).substr(0, 200), signal => 'TERM' );
        send-signal($pid, SIGTERM);
    }
    my $deadline = now + $grace;
    while %found && now < $deadline {
        last unless %found.values.grep({ same-process(.<pid>, .<start>, '') });
        sleep 0.1;
    }
    for %found.values -> %p {
        if same-process(%p<pid>, %p<start>, '') { send-signal(%p<pid>, SIGKILL); %p<signal> = 'KILL' }
    }
    # whatever a TERM let fork in the meantime
    for descendants($root) -> $pid {
        my %s = proc-stat($pid) // next;
        send-signal($pid, SIGKILL);
        %found{$pid} //= %( pid => $pid, start => %s<start>, command => proc-cmdline($pid).substr(0, 200), signal => 'KILL' );
    }
    %found.values.sort(*<pid>).map({ %( pid => .<pid>, command => .<command>, signal => .<signal> ) }).List;
}

# ---------------------------------------------------------------- restart

#| Why a run cannot be started again, or Str when it can: only a run that
#| has ended (or is lost) has a request to run again.
sub restart-refusal(RunDir $r --> Str) is export {
    my %l = liveness($r);
    return Str if %l<phase> eq 'ended' | 'lost';
    "it is still {%l<phase>}; stop it first";
}

#| The question a person answers before a run's request is run again: what
#| the old run did, and that the new one starts from nothing.
sub restart-question(RunDir $r, Str :$harness = '' --> Str) is export {
    my %run = $r.run;
    my %rc = $r.receipt;
    my $files = @(%rc<evidence><filesChanged> // []).elems;
    my $tools = $r.events-file.e ?? fold($r.events-file.lines.map({ try parse-json($_) }).grep(Associative)).tools !! 0;
    my $who = "{%run<agent><displayName> // %run<agent><name> // 'the agent'} {$r.short}";
    "Run {$who}'s request again{$harness ne '' ?? ' on ' ~ harness-name($harness) !! ''}? It changed {$files} file{$files == 1 ?? '' !! 's'} and ran {$tools} tool{$tools == 1 ?? '' !! 's'}; "
        ~ "the new run has its own budget, and no approval carries over.";
}

#| A new run of an ended run's request: its own id, its own package, its
#| own budget.  The old run and its receipt are untouched; the new one
#| names the old one and the digest of the receipt it read.
sub restart-run(RunDir $r, Str :$via = 'mission-control', Str :$harness = '' --> List) is export {
    with restart-refusal($r) { return (RunDir, $_) }
    my %run = $r.run;
    my %continues = runId => $r.id, receiptDigest => ($r.receipt-file.e ?? digest-bytes($r.receipt-file.slurp(:bin)) !! Nil);
    # A run that had a worktree gets a fresh one of the same workspace:
    # it never inherits the other run's half-finished files.
    my %iso = (%run<isolation> // {}).Hash;
    my $ws = %iso ?? (%iso<of> // '') !! (%run<workspace> // '');
    my $h = $harness ne '' ?? $harness !! ((%run<harness> // {})<requested> // '');
    launch-run(%run<agent><name> // '', %run<request> // '', :workspace($ws), :$via, :%continues, :harness($h), :isolate(so %iso));
}

# ---------------------------------------------------------------- stopping

#| Ask a run to stop through its inbox.  Returns (directive id, error).
sub request-stop(RunDir $r, Str :$reason = 'stopped from Mission Control', Str :$client = 'mission-control' --> List) is export {
    my %l = liveness($r);
    return (Str, "it has already ended: {%l<outcome>}") if %l<phase> eq 'ended';
    return (Str, "it is lost: {%l<why>}") if %l<phase> eq 'lost';
    my $id = try send-directive($r, 'stop', :$reason, :$client);
    return (Str, $!.message) if $!;
    ($id, Str);
}

#| Stop a run without its host's help: verify the host is the process
#| host.json names, then stop it and everything below it.  When the host
#| is already gone, stop only processes still in its session, each
#| checked against the kernel.  Never a pid whose start time differs,
#| never anything outside the run.  Records ended.json with the basis.
sub force-stop(RunDir $r --> Hash) is export {
    my %l = liveness($r);
    # Ended and swept by its host: nothing to do.  Ended but unswept (the
    # host died before it could look for leftovers) still gets the sweep.
    return %( done => False, why => "it has already ended: {%l<outcome>}" ) if %l<phase> eq 'ended' && !%l<unswept>;
    my %h = $r.host;
    my @signalled;
    if %h && same-process(%h<pid>.Int, %h<startTicks>.Int, %h<bootId> // '') {
        my $hp = %h<pid>.Int;
        @signalled = sweep($hp);
        send-signal($hp, SIGTERM);
        my $deadline = now + KILL-GRACE;
        sleep 0.1 while now < $deadline && same-process($hp, %h<startTicks>.Int, '');
        my $sig = 'TERM';
        if same-process($hp, %h<startTicks>.Int, '') { send-signal($hp, SIGKILL); $sig = 'KILL' }
        @signalled.push(%( pid => $hp, command => 'the run host', signal => $sig ));
    }
    elsif %h && (%h<bootId> // '') eq boot-id() {
        # The host is gone.  What it ran may still be alive: every process
        # its last snapshot named that is still that same process, and
        # every process in the host's session or in a session one of those
        # led (a background task that set up its own).
        my %tree = (read-json-file($r.dir.add('tree.json')) // {}).Hash;
        my %sids;
        %sids{%h<sid>.Int} = True if (%h<sid> // 0) > 1;
        my %kill;
        for @(%tree<processes> // []) -> %p {
            next unless same-process(%p<pid>.Int, %p<start>.Int, '');
            %kill{%p<pid>.Int} = True;
            %sids{%p<sid>.Int} = True if %p<sid>.Int == %p<pid>.Int;    # it leads its own session
        }
        for '/proc'.IO.dir.grep({ .basename ~~ /^ \d+ $/ }) -> $d {
            my %s = proc-stat($d.basename.Int) // next;
            %kill{%s<pid>} = True if %sids{%s<sid>} && %s<pid> != my-pid();
        }
        for %kill.keys.map(*.Int).sort -> $pid {
            my $cmd = proc-cmdline($pid).substr(0, 200);
            send-signal($pid, SIGKILL) and @signalled.push(%( pid => $pid, command => $cmd, signal => 'KILL' ));
        }
    }
    sleep 0.3;
    my $recorded = $r.receipt-file.e ?? False !! record-ended($r, %(
        summary => @signalled ?? "stopped by force; the run left no receipt" !! "the host was gone and left no receipt; nothing of it was still running",
        hostPid => %h<pid> // Nil, lastHeartbeat => ($r.status<heartbeatAt> // ''), signalled => @signalled, observedBy => 'force-stop' ));
    try $r.live-file.unlink;
    %( done => True, signalled => @signalled, recorded => $recorded, receipt => $r.receipt-file.e );
}
