unit module Do321HarnessContract;

#| The checks every harness adapter must pass, for an author to run
#| against their own:
#|
#|     use Do321HarnessContract;
#|     harness-contract-ok(Acme.new);
#|
#| It holds an adapter to the shape the runtime reads.  It cannot tell
#| whether a claim is true: that the harness really enforces what its
#| adapter says is for its author to show, against the real executable.

use Test;
use Do321::Protocol;
use Do321::Models;
use Do321::Adapter;

sub harness-contract-ok(Adapter $a, Str $what = '') is export {
    subtest ($what || "{$a.name} keeps the adapter contract") => {
        like $a.name, / ^ <[a..z]> <[a..z 0..9 _]> ** 0..31 $ /, 'its name is a short lower-case word';
        ok $a.label ne '', 'it has a name a person reads';
        my %e = $a.enforcement;
        my %known = features().map({ $_ => True });
        is-deeply %e.keys.grep({ !%known{$_} }).sort.List, (), 'it claims only features the protocol names';
        ok %e.values.all ~~ Bool, 'each claim is yes or no';
        ok %e{FEAT-TIMEOUT}, 'it can be stopped when its time is up' if %e{FEAT-GRACEFUL-STOP};
        my %m = $a.manifest;
        is-deeply (<providers access sets-model efforts reports spend-cap>.grep({ !(%m{$_}:exists) })).List, (),
            'its manifest says all six things';
        ok %m<access> eq ACCESS-HARNESS | ACCESS-RUNTIME, 'access is harness or runtime';
        is-deeply @(%m<efforts>).grep({ effort-rank(.Str) < 0 }).List, (), 'every effort it offers is one 321 knows';
        ok @(%m<providers>).elems > 0, 'a harness that sets a model says whose models it reaches' if %m<sets-model>;
        ok (%m<reports> // {}) ~~ Associative && (%m<reports><usd>:exists) && (%m<reports><tokens>:exists), 'it says whether money and tokens come back';
        nok %m<spend-cap> && !%e{FEAT-SPEND-LIMIT}, 'a money limit it holds is a spend limit it enforces';
        my $d = $a.detect;
        ok $d ~~ Detection, 'detect answers';
        ok $d.available || $d.reason ne '', 'where it cannot run, it says why';
        ok $a.command-name ne '' || $a.flags-used.elems == 0, 'flags are named only with the command they belong to';
        is-deeply $a.flags-used.grep({ !.Str.starts-with('-') }).List, (), 'the flags it passes are flags';
    }
}
