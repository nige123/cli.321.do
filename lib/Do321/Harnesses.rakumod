unit module Do321::Harnesses;

#| Harnesses as Mission Control shows them: a name a person reads, a short
#| tag beside the agent's own name, and what each can do, in words.  The
#| words come from what each adapter claims to enforce (its enforcement
#| map), never from a list kept here by provider, so a new adapter is
#| described the day it is registered.  An agent is the crew; a harness is
#| the engine it runs on; the screen leads with the agent.

use Do321::Protocol;
use Do321::Adapter;
use Do321::CLI;

#| Display names, only where an adapter's own name reads badly.
my constant NAMES = %( claude_code => 'Claude Code', codex => 'Codex', fake => 'a stand-in harness', procedure => 'a procedure' );
my constant TAGS  = %( claude_code => 'claude' );

sub harness-name(Str $adapter --> Str) is export { NAMES{$adapter} // $adapter }
sub harness-tag(Str $adapter --> Str) is export { TAGS{$adapter} // $adapter }

#| The adapters `321 run` will drive: the runtime's own set.
sub runtime-registry(--> Registry) is export { default-registry($*ERR) }

#| Every adapter this build knows: today, the runtime's own set.  An
#| adapter known here but not in the runtime's set would be shown as
#| installed and not driven.
my $known;
sub known-registry(--> Registry) is export {
    return $known with $known;
    $known = runtime-registry();
}

#| What a harness enforces and what it cannot, as feature names: the same
#| words `321`'s harness screens and its refusals use.  Straight from the
#| adapter's own enforcement map, in the protocol's order.
sub abilities(Adapter $a --> Hash) is export {
    my %e = $a.enforcement;
    %( enforces => [ features().grep({ %e{$_} }) ], cannot => [ features().grep({ !%e{$_} }) ] );
}

#| What a steer does on this harness, in one line for the person who sent it.
sub steer-note(Str $adapter --> Str) is export {
    my $a = known-registry().get($adapter) // return 'sent; the run takes it when it can';
    my %e = $a.enforcement;
    %e{FEAT-LIVE-STEER} ?? "sent; {harness-name($adapter)} hands it to the agent now"
        !! "sent; on {harness-name($adapter)} the agent takes it when its current step ends";
}

#| One record per known harness: what it is, whether it is here, whether
#| the runtime drives it, and what it can do.
my ($records, $records-at) = (List, 0e0);
sub harness-records(--> List) is export {
    # detection starts processes: a screen asks often, the answer is kept a while
    return @$records if $records.defined && now.Num - $records-at < 30;
    $records-at = now.Num;
    $records = fresh-records();
    @$records;
}

sub fresh-records(--> List) {
    my $run = runtime-registry();
    my $k = known-registry();
    $k.all.grep({ !$k.hidden{.name} }).map(-> $a {
        my $d = $a.detect;
        my $driven = $run.get($a.name).defined;
        %( name => $a.name, display => harness-name($a.name), available => $d.available, version => $d.version,
           reason => $d.reason, driven => $driven,
           ready => $d.available && $driven,
           |abilities($a) )
    }).List;
}

#| Whether a harness can be asked for here: (adapter name, error).
sub check-harness(Str $want --> List) is export {
    my $w = $want.lc;
    $w = 'claude_code' if $w eq 'claude' | 'claude-code' | 'claudecode';
    my $known = known-registry().get($w);
    return (Str, "no harness is called '$want'; 321 harness can lists them") without $known;
    my $d = $known.detect;
    return (Str, "{harness-name($w)} is not available here: {$d.reason}") unless $d.available;
    return (Str, "{harness-name($w)} is installed, and this 321 does not drive it yet") without runtime-registry().get($w);
    ($w, Str);
}
