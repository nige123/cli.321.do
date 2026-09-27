unit module Do321RunTest;

#| Helpers the runner suites share: the development-pinned helper agent,
#| package and directive builders, an event collector, stub adapters.

use Do321Test;
use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Digest;
use Do321::Trust;
use Do321::Adapter;
use Do321::Run;

use Test;

#| example.test/helper through a development pin, which is how an unsigned
#| package with a publisher identity is used in practice.
sub helper(--> Loaded) is export {
    my $dir = fixture('example.test/helper');
    my $c = trust-config({ schema => SCHEMA-TRUST-CONFIG, publishers => { 'example.test' => {
        packages => { helper => { path => $dir.Str, version => '1.2.0', digest => compute($dir)[0], trust => LEVEL-DEVELOPMENT } } } } });
    load-resolved($c.resolve('example.test/helper'));
}

sub pkg-for(Loaded $agent, Str $objective, *@conditions --> Hash) is export {
    doc('WorkPackage', schema => SCHEMA-WORK-PACKAGE, packageId => new-ulid(), issuer => { kind => 'test', id => 't' },
        issuedAt => now-stamp(), correlation => { refs => [ %( kind => 'opaque', id => 'step:17' ), ] },
        agent => { id => $agent.id, version => $agent.manifest<version>, digest => $agent.digest },
        placement => PLACEMENT-CLIENT, workspace => { kind => 'none', ownership => 'caller' }, objective => $objective,
        completion => { conditions => [ |@conditions ] }, capabilities => { granted => [CAP-REPO-READ], limits => {} });
}

sub directive(Str $pkg, Int $seq, Str $kind, Str $text --> Hash) is export {
    my %d = doc('WorkDirective', schema => SCHEMA-WORK-DIRECTIVE, directiveId => "d$seq-$kind", packageId => $pkg, seq => $seq,
        issuer => { kind => 'test', id => 'person' }, issuedAt => now-stamp(), kind => $kind, payload => { text => $text, reason => $text });
    %d<digest> = directive-digest(%d);
    %d;
}

#| Gathers events and lets a test wait for one of a kind by polling.
class Collector does Sink is export {
    has @.events;
    has Lock $!mu = Lock.new;
    method emit(%e) { $!mu.protect({ @!events.push(%e) }) }
    method all { $!mu.protect({ [ |@!events ] }) }
    method wait(Str $kind, &match = -> % { True }) {
        my $deadline = now + 10;
        loop {
            my @hit = self.all.grep({ .<kind> eq $kind && match($_) });
            return @hit[0] if @hit;
            die "timed out waiting for $kind; saw {self.all.map(*<kind>).join(',')}" if now > $deadline;
            sleep 0.005;
        }
    }
    method count(Str $kind --> Int) { self.all.grep({ .<kind> eq $kind }).elems }
    method kinds(--> List) { self.all.map(*<kind>).List }
}

sub fake-registry($script = Any --> Registry) is export {
    Registry.new.register-hidden(new-procedure()).register-hidden(new-fake($script));
}

#| Simulates a print-mode harness: no live steer, no pause, optional
#| session continuation.  Each call is one attempt.
class StubAdapter does Adapter is export {
    has %.enf;
    has @.specs;
    has Lock $!mu = Lock.new;
    has Promise $.release;      # when set, the first attempt blocks until kept or cancelled
    has %.cost;
    has Str $.status = STATUS-COMPLETED.Str;
    method name(--> Str) { 'stub' }
    method detect(--> Detection) { Detection.new(:available, :version<stub>) }
    method enforcement(--> Hash) { %!enf }
    method run(Cancel $ctx, Spec $spec, Control $ctl --> Outcome) {
        my ($n, $rel) = $!mu.protect({ @!specs.push($spec); (@!specs.elems, $!release) });
        $ctl.emit.(EVENT-PROGRESS, %( text => 'working' ));
        if $n == 1 && $rel.defined {
            await Promise.anyof($rel, $ctx.promise);
            if $ctx.done && !($rel.status ~~ Kept) {
                return Outcome.new(:status(STATUS-STOPPED.Str), :end-reason<cancelled>, :session-ref<sess-1>, :cost(load('Cost', %!cost)));
            }
        }
        my @conds = (^@($spec.package<completion><conditions>).elems).map({ %( met => True, proof => "stub attempt $n" ) });
        Outcome.new(:status($!status.Str), :end-reason($!status.Str), :summary('stub done'), :conditions(@conds),
            :session-ref("sess-$n"), :cost(load('Cost', %!cost)));
    }
    method attempts { $!mu.protect({ [ |@!specs ] }) }
}

sub new-stub(Bool $session-continue, *%opts --> StubAdapter) is export {
    my %e = FEAT-TOOL-ALLOWLIST, True, FEAT-STRUCTURED-OUTPUT, True, FEAT-TURN-LIMIT, True, FEAT-SPEND-LIMIT, True,
        FEAT-TIMEOUT, True, FEAT-EVENT-STREAM, True, FEAT-GRACEFUL-STOP, True;
    %e{FEAT-SESSION-CONTINUE} = True if $session-continue;
    StubAdapter.new(:enf(%e), |%opts);
}

sub stub-registry(StubAdapter $s --> Registry) is export { Registry.new.register-hidden(new-procedure()).register($s) }

sub check-receipt(%r) is export {
    my $ps = validate-run-receipt(%r);
    ok !$ps, 'the receipt is valid' or diag $ps.Str;
    ok %r<instructionHistory><digest> ne '', 'the receipt carries the instruction history digest';
    is %r<correlation><refs>[0]<id>, 'step:17', 'correlation is echoed verbatim';
}

sub runner(Registry $r --> Runner) is export { Runner.new(:adapters($r)) }
sub run-in-background(Runner $r, %wp, $agent, Options $opts --> Promise) is export {
    start { $r.run(Cancel.new, %wp, $agent, $opts) }
}


#| example.test/operator through a development pin.
sub operator(--> Loaded) is export {
    my $dir = fixture('example.test/operator');
    my $c = trust-config({ schema => SCHEMA-TRUST-CONFIG, publishers => { 'example.test' => {
        packages => { operator => { path => $dir.Str, version => '0.1.0', digest => compute($dir)[0], trust => LEVEL-DEVELOPMENT } } } } });
    load-resolved($c.resolve('example.test/operator'));
}
