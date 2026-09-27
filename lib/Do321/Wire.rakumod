unit module Do321::Wire;

#| The machine-facing invocation of the runtime: NDJSON in, NDJSON out.
#|
#| Input: the WorkPackage comes from exactly one place.  With --package -,
#| the first stdin frame is the package and every later frame is a
#| WorkDirective.  With --package <file>, the file is the package and stdin
#| carries only directives.  Output: run-event.v1 frames, then exactly one
#| terminal run-receipt.v1 frame.  When the input cannot be understood well
#| enough to name a package, a protocol-error.v1 frame is emitted instead
#| and no receipt is fabricated.
#|
#| Rules the caller can rely on:
#|   - Frames are one JSON object per line.  Blank lines are ignored.
#|   - A malformed directive line is answered with a protocol-error frame
#|     naming the line, and the run continues.
#|   - Duplicates and out-of-order directives are handled by the runner.
#|   - Stdin closing means no more directives, not stop.
#|   - SIGTERM or SIGINT is a stop from issuer "signal".
#|   - Events are buffered up to EVENT-BUFFER; when the caller does not
#|     drain, progress-class events are coalesced and counted, never the
#|     acknowledgements or the receipt.  Cancellation does not depend on
#|     the buffer at all.
#|   - The receipt is always written to --receipt when given, even if
#|     stdout is blocked, and stdout gets a bounded time to drain.

use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Trust;
use Do321::Run;

constant EXIT-COMPLETED is export = 0;
constant EXIT-BLOCKED   is export = 2;
constant EXIT-STOPPED   is export = 3;
constant EXIT-FAILED    is export = 4;
constant EXIT-DENIED    is export = 5;
constant EXIT-USAGE     is export = 64;
constant EXIT-MALFORMED is export = 65;
constant EXIT-INTERNAL  is export = 70;

#| How many events may wait for a slow reader.
constant EVENT-BUFFER is export = 4096;
#| How long exit waits for stdout after the run, in seconds.
constant DRAIN-TIMEOUT is export = 5;

#| A receipt status as an exit code.
sub exit-for(Str $status --> Int) is export {
    given $status {
        when STATUS-COMPLETED | STATUS-NO-CHANGE { EXIT-COMPLETED }
        when STATUS-BLOCKED { EXIT-BLOCKED }
        when STATUS-STOPPED { EXIT-STOPPED }
        when STATUS-DENIED  { EXIT-DENIED }
        default { EXIT-FAILED }
    }
}

#| One machine invocation.
class WireOptions is export {
    has Str $.package-source = '-';     # "-" or a file path
    has Str $.package-dir = '';         # explicit local package directory, bypassing trust aliases
    has Str $.workspace = '';           # overrides an absent workspace path
    has Str $.receipt-path = '';
    has Str $.events-path = '';
    has Str $.run-id = '';
    has Str $.history-dir = '';
    has Str $.adapter = '';
    has Str $.continue-from = '';       # path of the terminal receipt this run continues
    has $.stdin;                        # a LineSource
    has $.stdout;                       # an IO::Handle
    has $.stderr;                       # an IO::Handle
    has $.trust;                        # a Trust Config, or Any
    has Runner $.runner;
    has Bool $.signals = False;         # SIGTERM and SIGINT become a stop directive
}

#| Lines from a handle, pulled one at a time, so the first frame can be
#| read here and the rest by another thread.  Under Raku++ a handle's
#| .lines on a pipe waits for EOF and .get stops after the first line, so
#| lines are assembled from getc.
class LineSource is export {
    has $.handle;
    has Int $.line = 0;
    has Bool $!eof = False;
    method next() {
        return Str if $!eof;
        my $s = '';
        loop {
            my $c = $!handle.getc;
            without $c {
                $!eof = True;
                return Str if $s eq '';
                last;
            }
            last if $c eq "\n";
            $s ~= $c;
        }
        $!line++;
        $s.chomp;
    }
}

#| DO321_TRACE names a file that receives one line per step of serve, for
#| debugging a run that a caller cannot see into.
sub trace(Str $what) is export {
    with %*ENV<DO321_TRACE> { try .IO.spurt("{now.Rat.fmt('%.3f')} $what\n", :append) }
}

sub protocol-error(Str $code, Str $message, Int :$line --> Hash) {
    doc('ProtocolError', schema => SCHEMA-PROTOCOL-ERROR, code => $code, message => $message, |($line.defined ?? (line => $line) !! ()));
}

#| Read the WorkPackage from the configured source.  With "-" it consumes
#| the first frame of stdin.  Returns (package, raw bytes, error or Any).
sub load-package(WireOptions $opts --> List) is export {
    my $raw;
    my $line = 0;
    if $opts.package-source eq '-' || $opts.package-source eq '' {
        loop {
            my $l = $opts.stdin.next;
            if !$l.defined {
                return (Any, Any, protocol-error('no_package', 'stdin closed before a work package arrived'));
            }
            $line = $opts.stdin.line;
            next if $l.trim eq '';
            $raw = $l.encode('utf-8');
            last;
        }
    }
    else {
        $raw = try $opts.package-source.IO.slurp(:bin);
        return (Any, Any, protocol-error('package_unreadable', $!.message)) if $!;
    }
    my $data = try parse-json-bytes($raw);
    return (Any, Any, protocol-error('malformed_json', $!.message, :$line)) if $!;
    my $schema = $data ~~ Associative ?? ($data<schema> // '') !! '';
    $schema = '' unless $schema ~~ Str;
    if $schema ne SCHEMA-WORK-PACKAGE {
        return (Any, Any, protocol-error('not_a_work_package', "expected schema \"{SCHEMA-WORK-PACKAGE}\", got \"$schema\"", :$line));
    }
    my $wp = try load('WorkPackage', $data);
    return (Any, Any, protocol-error('malformed_package', $!.message, :$line)) if $!;
    return (Any, Any, protocol-error('unidentified_package', 'the work package has no packageId', :$line)) if $wp<packageId> eq '';
    ($wp, $raw, Any);
}

#| Serialises frames to stdout with a bounded buffer.  Implements the
#| coalescing sink: progress-class events are dropped when the buffer is
#| full; everything else waits.
class Writer does CoalescingSink is export {
    has $.out;
    has Str $.events-path = '';
    has $!events;
    has Mailbox $!box = Mailbox.new(:capacity(EVENT-BUFFER));
    has Promise $!done;
    has Lock $!mu = Lock.new;
    has Int $!dropped = 0;
    has Bool $!closed = False;

    submethod TWEAK() {
        $!events = try $!events-path.IO.open(:a) if $!events-path ne '';
        my $self = self;
        $!done = start { $self!loop }
    }

    method !loop() {
        loop {
            my $v = $!box.receive;
            last without $v;
            self!write($v);
        }
    }

    method !write($v) {
        my ($type, $doc) = $v<type>, $v<doc>;
        my $line = to-wire($type, $doc);
        try { $!out.say($line); $!out.flush };
        with $!events { try { .say($line); .flush } }
    }

    method emit(%e) {
        return if $!mu.protect({ $!closed });
        my %frame = type => 'RunEvent', doc => %e;
        if is-in(%e<kind>, [EVENT-PROGRESS, EVENT-TOOL-CALL, EVENT-TOOL-RESULT, EVENT-COST]) {
            $!mu.protect({ $!dropped++ }) unless $!box.try-send(%frame);
        }
        else { $!box.send(%frame) }
    }

    method coalesced(--> Int) { $!mu.protect({ $!dropped }) }

    #| Write a non-event frame in order with the events.
    method frame(Str $type, %doc) {
        if $!mu.protect({ $!closed }) { self!write(%( type => $type, doc => %doc )); return }
        $!box.send(%( type => $type, doc => %doc ));
    }

    #| Wait for the buffer to empty, bounded.  False when it did not.
    method drain(Numeric $timeout --> Bool) {
        my $deadline = now + $timeout;
        while $!box.elems > 0 {
            return False if now > $deadline;
            sleep 0.005;
        }
        True;
    }

    method close() {
        return if $!mu.protect({ my $c = $!closed; $!closed = True; $c });
        $!box.close;
        await Promise.anyof($!done, Promise.in(DRAIN-TIMEOUT));
        with $!events { try .close }
    }
}

sub read-receipt(Str $path --> Hash) {
    my $data = parse-json($path.IO.slurp);
    my %r = load('RunReceipt', $data);
    my $ps = validate-run-receipt(%r);
    die "$path: {$ps.Str}" if $ps;
    %r;
}

sub load-agent(WireOptions $opts, %wp --> Loaded) {
    return load-path($opts.package-dir.IO) if $opts.package-dir ne '';
    die 'no trust configuration and no --package-dir' without $opts.trust;
    load-resolved($opts.trust.resolve(%wp<agent><id>));
}

#| Turn stdin frames into directives.  It never stops the run on a bad
#| line; it reports and continues.  EOF just closes the mailbox.
sub read-directives(Cancel $ctx, LineSource $src, Mailbox $ch, Writer $out) {
    LEAVE $ch.close;
    loop {
        last if $ctx.done;
        my $l = $src.next;
        last without $l;
        next if $l.trim eq '';
        my $line = $src.line;
        my $data = try parse-json($l);
        if $! { $out.frame('ProtocolError', protocol-error('malformed_directive', $!.message, :$line)); next }
        my $schema = $data ~~ Associative ?? ($data<schema> // '') !! '';
        $schema = '' unless $schema ~~ Str;
        if $schema ne SCHEMA-WORK-DIRECTIVE {
            $out.frame('ProtocolError', protocol-error('unexpected_frame', "expected \"{SCHEMA-WORK-DIRECTIVE}\" after the package, got \"$schema\"", :$line));
            next;
        }
        my $d = try load('WorkDirective', $data);
        if $! { $out.frame('ProtocolError', protocol-error('malformed_directive', $!.message, :$line)); next }
        trace('reader: directive ' ~ $d<directiveId> ~ ' ' ~ $d<kind>);
        $ch.send($d, :cancel($ctx));
    }
}

#| A stop directive from issuer "signal".
sub signal-directive(Str $package-id, Str $sig --> Hash) is export {
    my %d = doc('WorkDirective', schema => SCHEMA-WORK-DIRECTIVE, directiveId => 'signal-' ~ new-ulid(), packageId => $package-id,
        seq => 1 +< 30, issuer => { kind => 'signal', id => $sig }, issuedAt => now-stamp(), kind => DIRECTIVE-STOP,
        payload => { reason => "signal $sig" });
    %d<digest> = directive-digest(%d);
    %d;
}

#| Run one package to a receipt and return the exit code.
sub serve(Cancel $ctx, WireOptions $opts --> Int) is export {
    my $out = Writer.new(:out($opts.stdout), :events-path($opts.events-path));
    LEAVE $out.close;

    trace('serve: reading the package');
    my ($wp, $raw, $perr) = load-package($opts);
    with $perr { $out.frame('ProtocolError', $perr); return EXIT-MALFORMED }
    trace('serve: package ' ~ $wp<packageId>);
    # The workspace path is the caller's to supply and is NOT part of the
    # issued document: the digest is taken over the bytes as received,
    # before the path is filled in.
    $wp<workspace><path> = $opts.workspace if $opts.workspace ne '' && $wp<workspace><path> eq '';
    $wp<workspace><path> = $wp<workspace><path>.IO.absolute if $wp<workspace><path> ne '';

    my $run-ctx = $ctx.child;
    my $directives = Mailbox.new(:capacity(256));
    my $src = $opts.stdin;
    start { read-directives($run-ctx, $src, $directives, $out) }
    if $opts.signals {
        my $pid = $wp<packageId>;
        signal(SIGTERM, SIGINT).tap(-> $s { $directives.try-send(signal-directive($pid, $s.Str)) });
    }

    my %run-opts = directives => $directives, sink => $out, run-id => $opts.run-id, history-dir => $opts.history-dir,
        adapter => $opts.adapter, package-raw => $raw;
    if $opts.continue-from ne '' {
        my $prev = try read-receipt($opts.continue-from);
        if $! { $out.frame('ProtocolError', protocol-error('continue_unreadable', $!.message)); return EXIT-MALFORMED }
        %run-opts<continue> = $prev;
    }
    %run-opts<policy> = $opts.trust.policy with $opts.trust;
    my $run-options = Options.new(|%run-opts);

    my %receipt;
    my $agent = try load-agent($opts, $wp);
    if $! { %receipt = $opts.runner.deny($wp, 'the agent package could not be loaded', [$!.message], $run-options) }
    else { %receipt = $opts.runner.run($run-ctx, $wp, $agent, $run-options) }
    $run-ctx.cancel;
    trace('serve: run ended ' ~ %receipt<status>);
    if $opts.receipt-path ne '' {
        try $opts.receipt-path.IO.spurt(to-pretty('RunReceipt', %receipt) ~ "\n");
        with $! { try $opts.stderr.say("321: receipt file: {.message}") }
    }
    trace('serve: draining');
    unless $out.drain(DRAIN-TIMEOUT) {
        try $opts.stderr.say('321: stdout did not drain; the receipt was still written to --receipt if given');
    }
    trace('serve: writing the receipt');
    $out.frame('RunReceipt', %receipt);
    trace('serve: done');
    exit-for(%receipt<status>);
}
