unit module Do321::Record;

use Data::Native;
use Do321::JSON;
use Do321::RunDir;
use Do321::Learn;
use Do321::Registry;
use Do321::Keys;

#| An agent's record: how its versions have done, as the people who ran
#| them reported, kept at the registry; and this person's part in it.
#|
#| What holds here:
#|   - nothing is sent until this person turns sharing on, and off stops it;
#|   - only a run they have said an outcome for is ever reported;
#|   - a report is counts and names of things already public: the agent,
#|     its version, the harness, how the run ended, what was said of it,
#|     tokens, cost, time and attempts.  No request, no file, no path, no
#|     context, no lesson, no note, and not the run's id: the registry
#|     gets a key made from the id and a salt that stays here;
#|   - a figure the harness did not report goes as not known, never zero;
#|   - what was sent is written down here, so it can be read;
#|   - where this 321 has a key, a report carries the signature its
#|     receipt already has, the digest it is over, and the key's public
#|     half.  That shows a receipt was written by this key; it does not
#|     show the registry the receipt, and proves no figure.

constant SCHEMA-REPORT is export = 'outcome-report.v1';
constant REPORT-BATCH is export = 200;

my sub share-file(IO::Path $home --> IO::Path) { registry-dir($home).add('share.json') }
my sub sent-file(IO::Path $home --> IO::Path) { registry-dir($home).add('sent.ndjson') }
my sub read-doc(IO::Path $f) {
    return Nil unless $f.e;
    my $d = try parse-json($f.slurp);
    $d ~~ Associative ?? $d !! Nil;
}
my sub stamp(--> Str) { DateTime.now.utc.Str.subst(/\.\d+/, '') }

sub sharing-on(IO::Path $home --> Bool) is export { so (read-doc(share-file($home)) // {})<on> }
sub sharing-since(IO::Path $home --> Str) is export { ((read-doc(share-file($home)) // {})<since> // '').Str }

my sub fresh-salt(--> Str) {
    my $u = '/dev/urandom'.IO;
    if $u.e {
        my $h = try $u.open(:bin);
        with $h { my $b = .read(16); .close; return $b.list.map(*.fmt('%02x')).join if $b.elems == 16 }
    }
    (^256).roll(16).map(*.fmt('%02x')).join;
}

#| Turn sharing on or off.  The salt is made once and kept: it is what
#| lets a later word about a run replace the earlier one at the registry.
sub set-sharing(IO::Path $home, Bool $on) is export {
    private-dir($home);
    private-dir(registry-dir($home));
    my %was = (read-doc(share-file($home)) // {}).Hash;
    my %d = on => $on, salt => ((%was<salt> // '').Str || fresh-salt()),
        since => ($on ?? ((%was<on> ?? %was<since> !! Str) // stamp()) !! ''), changedAt => stamp();
    write-atomic(share-file($home), encode-json(%d) ~ "\n");
    share-file($home).chmod(0o600);
}

#| The key the registry knows a run by: nothing can be read back from it.
sub run-key(IO::Path $home, Str $run-id --> Str) is export {
    my $salt = ((read-doc(share-file($home)) // {})<salt> // '').Str;
    'sha256:' ~ sha256-hex("$salt:$run-id".encode);
}

#| run key -> the outcome last sent for it.
sub reports-sent(IO::Path $home --> Hash) is export {
    my $f = sent-file($home);
    return %() unless $f.e;
    %( $f.lines.map({ try parse-json($_) }).grep(Associative).map({ (.<run> // '') => (.<outcome> // '').Str }) );
}

#| The public half of this 321's key, or an empty hash when it has none.
sub report-key(IO::Path $home --> Hash) is export {
    my $k = try load-key($home);
    $k ~~ Associative ?? public-part(%$k) !! %();
}

#| One run as it is reported: exactly these keys, and no others.  The
#| last two are there only for a receipt signed by the key this 321
#| has now: a signature nobody here can answer for is not sent.
sub report-of(IO::Path $home, Work $w, Str :$key-id = (report-key($home)<keyId> // '') --> Hash) is export {
    my $signed = $key-id ne '' && $w.signature ne '' && $w.signed-by eq $key-id && $w.receipt-digest ne '';
    %( |($signed ?? (receiptDigest => $w.receipt-digest, signature => $w.signature) !! ()),
       run => run-key($home, $w.id), agent => $w.agent, version => $w.version, digest => $w.digest, harness => $w.harness,
       status => $w.status, outcome => $w.outcome,
       tokens => ($w.tokens.defined ?? $w.tokens.Int !! Nil), usd => ($w.usd.defined ?? $w.usd + 0 !! Nil),
       seconds => $w.seconds.Int, attempts => $w.attempts, endedAt => $w.ended );
}

#| What would be sent now: every run this person has said an outcome
#| for, that has not gone with that outcome already.
sub reports-pending(IO::Path $home, Int :$days = 90 --> List) is export {
    my %sent = reports-sent($home);
    my $key-id = (report-key($home)<keyId> // '').Str;
    read-work($home, :$days).grep({ .outcome ne '' && .agent ne '' && .ended ne '' }).map({ report-of($home, $_, :$key-id) })
        .grep({ (%sent{.<run>} // '') ne .<outcome> }).List;
}

#| Send what is pending.  Returns what the registry said it did with it.
#| Throws, having sent nothing more, when the registry refuses a batch;
#| what went before the refusal stays written down as sent.
sub send-reports(IO::Path $home --> Hash) is export {
    die X::Do321::Registry.new(message => 'sharing is off: 321 record share on turns it on') unless sharing-on($home);
    my @all = reports-pending($home);
    my %sum = sent => 0, stored => 0, replaced => 0, unknownAgent => 0, signed => 0, duplicateReceipt => 0;
    my %key = report-key($home);
    return %sum unless @all;
    my $f = sent-file($home);
    for @all.rotor(REPORT-BATCH, :partial) -> @batch {
        my $said = registry-get($home, '/api/reports', send => encode-json(%( schema => SCHEMA-REPORT, |(@batch.first({ .<signature>:exists }) ?? (key => %key) !! ()), reports => [ |@batch ] )));
        my $h = $f.open(:a);
        $h.say(encode-json(%( run => .<run>, outcome => .<outcome>, agent => .<agent>, at => stamp() ))) for @batch;
        $h.close;
        $f.chmod(0o600);
        %sum<sent> += @batch.elems;
        %sum{$_} += ($said{$_} // 0).Int for <stored replaced unknownAgent signed duplicateReceipt>;
    }
    %sum;
}

#| The registry's name for an agent: the last part, in lower case.
sub record-name(Str $agent --> Str) is export { $agent.split('/').tail.lc }

#| An agent's record, read from the registry now.
sub agent-record(IO::Path $home, Str $agent --> Hash) is export {
    my $n = record-name($agent);
    die X::Do321::Registry.new(message => "'$agent' is not a name the registry could hold") unless $n ~~ / ^ <[a..z 0..9]> <[a..z 0..9 . _ -]> ** 0..63 $ /;
    registry-get($home, "/api/agents/$n/record").Hash;
}

my sub pct(Int $n, Int $of --> Str) { $of > 0 ?? ($n * 100 / $of).round ~ '%' !! '' }

#| One version of a record in words.  A figure that rests on fewer
#| reports than the version has says how many it rests on.
sub version-lines(%v --> List) is export {
    my $name = (%v<version> // '') eq '' ?? 'no version' !! "v%v<version>";
    return ($name, 'not enough reports yet').List unless %v<enough>;
    my $r = (%v<reports> // 0).Int;
    my %o = (%v<outcomes> // {}).Hash;
    my @l = "$r report{$r == 1 ?? '' !! 's'} from {(%v<accounts> // 0).Int} accounts";
    @l.push: <accepted corrected rejected>.map({ pct((%o{$_} // 0).Int, $r) ~ " $_" }).join(', ');
    with %v<tokens> { @l.push: "median {count-text(.<median>.Int)} tokens" ~ ((.<reports> // $r).Int < $r ?? " (of the {.<reports>} that said)" !! '') if $_ ~~ Associative }
    else { @l.push: 'tokens not reported' }
    with %v<usd> { @l.push: "median {money(.<median>)}" ~ ((.<reports> // $r).Int < $r ?? " (of the {.<reports>} that said)" !! '') if $_ ~~ Associative }
    with %v<seconds> { @l.push: "median {duration(.<median>)}" if $_ ~~ Associative }
    with %v<signed> { @l.push: "{(.<reports> // 0).Int} signed" if $_ ~~ Associative }
    ($name, |@l).List;
}
