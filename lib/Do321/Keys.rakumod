unit module Do321::Keys;

#| The runtime's own signing key, so a receipt can be shown to come from
#| this 321 and not from anyone who learned the receipt's shape.  One
#| Ed25519 key per home (~/.321/key.json, or X321_HOME), made on request
#| by '321 key new' and never copied anywhere by 321 itself.  Its public
#| half is what a work issuer pins to check receipts.
#|
#| A receipt is signed over its receiptDigest, which is itself over the
#| receipt's canonical content with the signature left out, so the
#| signature binds the whole receipt and the digest check stays as it was.

use Do321::JSON;
use Do321::Digest;
use Do321::Ed25519;
use Do321::Protocol;

constant KEY-FILE is export = 'key.json';

class X::Do321::Keys is Exception { has Str $.message }
sub keys-error(Str $m) { X::Do321::Keys.new(message => $m).throw }

#| Where the key lives under a home.
sub key-path(IO::Path $home --> IO::Path) is export { $home.add(KEY-FILE) }

#| Make a new key under $home.  Refuses to replace one: a key that signed
#| receipts is history, not something to overwrite by accident.
sub new-key(IO::Path $home --> Hash) is export {
    my $f = key-path($home);
    keys-error("a key already exists at {$f}; remove it yourself if you mean to replace it") if $f.e;
    my ($pub, $priv) = generate-key();
    my %k = algorithm => ALGORITHM-ED25519, keyId => key-id($pub),
            publicKey => base64-encode($pub), privateKey => base64-encode($priv);
    $home.mkdir;
    $f.spurt(encode-json-pretty(%k) ~ "\n");
    try $f.chmod(0o600);
    public-part(%k);
}

#| The key under $home, or Nil when there is none.
sub load-key(IO::Path $home --> Hash) is export {
    my $f = key-path($home);
    return Nil unless $f.f;
    my $k = try parse-json($f.slurp);
    keys-error("{$f}: not a key file: {$!.message}") if $!;
    keys-error("{$f}: not a key file") unless $k ~~ Associative && $k<privateKey> && $k<publicKey> && $k<keyId>;
    keys-error("{$f}: unsupported algorithm {$k<algorithm>}") unless ($k<algorithm> // '') eq ALGORITHM-ED25519;
    %$k;
}

#| What may be shown and pinned: never the private half.
sub public-part(%k --> Hash) is export {
    %( algorithm => %k<algorithm>, keyId => %k<keyId>, publicKey => %k<publicKey> );
}

#| Sign a receipt with the key: its signature is over its receiptDigest.
#| Returns the receipt with the signature set.
sub sign-receipt(%receipt, %key --> Hash) is export {
    keys-error('the receipt has no receiptDigest to sign') unless (%receipt<receiptDigest> // '') ne '';
    my %r = %receipt;
    %r<signature> = sign-digest(%r<receiptDigest>, base64-decode(%key<privateKey>));
    %r;
}

#| Sign with the key under $home when there is one; otherwise the receipt
#| comes back as it was.  A missing key is not an error: signing is what a
#| home that made a key gets, and nothing else changes.
sub sign-receipt-if-keyed(%receipt, IO::Path $home --> Hash) is export {
    my $k = try load-key($home);
    return %receipt without $k;
    sign-receipt(%receipt, %$k);
}

#| Check a receipt against a public key (base64): the digest must match
#| the content and the signature must verify over it.  Throws with the
#| reason when it does not hold; returns the key id when it does.
sub verify-receipt(%receipt, Str $public-key --> Str) is export {
    keys-error('the receipt carries no signature') without %receipt<signature>;
    keys-error("the receipt's digest does not match its content") if receipt-digest(%receipt) ne (%receipt<receiptDigest> // '');
    verify-signature(%receipt<receiptDigest>, %receipt<signature>, base64-decode($public-key));
    %receipt<signature><keyId>;
}
