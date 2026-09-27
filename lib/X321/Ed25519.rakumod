unit module X321::Ed25519;

#| Ed25519 (RFC 8032) in plain Raku on the compiler's big integers and its
#| built-in SHA-512.  The runtime links no third-party library, and
#| Raku++ ships no ed25519 of its own, so this is the whole of it: key
#| generation from a seed, signing, and verification.  Pinned to the RFC
#| 8032 test vectors in t/02-digest.rakutest.
#|
#| The only hot path in the runtime is one verification per package load,
#| which is a few hundred field operations: milliseconds.

use Data::Native;

my constant P = 2**255 - 19;
my constant L = 2**252 + 27742317777372353535851937790883648493;
my constant D = (-121665 * expmod(121666, P - 2, P)) mod P;
my constant I = expmod(2, (P - 1) div 4, P);   # sqrt(-1)

# The base point, from RFC 8032.
my constant BY = (4 * expmod(5, P - 2, P)) mod P;
sub recover-x(Int $y, Int $sign --> Int) {
    my $xx = (($y * $y - 1) * expmod(D * $y * $y + 1, P - 2, P)) mod P;
    my $x = expmod($xx, (P + 3) div 8, P);
    $x = ($x * I) mod P if (($x * $x - $xx) mod P) != 0;
    die 'point is not on the curve' if (($x * $x - $xx) mod P) != 0;
    $x = P - $x if ($x +& 1) != $sign;
    $x;
}
my constant BX = recover-x(BY, 0);

# Points in extended coordinates (X, Y, Z, T) with x = X/Z, y = Y/Z, xy = T/Z.
sub add(@p, @q --> List) {
    my ($x1, $y1, $z1, $t1) = @p;
    my ($x2, $y2, $z2, $t2) = @q;
    my $a = (($y1 - $x1) * ($y2 - $x2)) mod P;
    my $b = (($y1 + $x1) * ($y2 + $x2)) mod P;
    my $c = (2 * $t1 * $t2 * D) mod P;
    my $d = (2 * $z1 * $z2) mod P;
    my ($e, $f, $g, $h) = $b - $a, $d - $c, $d + $c, $b + $a;
    (($e * $f) mod P, ($g * $h) mod P, ($f * $g) mod P, ($e * $h) mod P);
}

sub mul(Int $s is copy, @p is copy --> List) {
    my @q = (0, 1, 1, 0);
    while $s > 0 {
        @q = add(@q, @p) if $s +& 1;
        @p = add(@p, @p);
        $s +>= 1;
    }
    @q;
}

sub affine(@p --> List) {
    my $zi = expmod(@p[2], P - 2, P);
    ((@p[0] * $zi) mod P, (@p[1] * $zi) mod P);
}

sub to-extended(Int $x, Int $y --> List) { ($x, $y, 1, ($x * $y) mod P) }

my constant BASE = to-extended(BX, BY);

sub encode-point(@p --> Blob) {
    my ($x, $y) = affine(@p);
    my $n = $y +| (($x +& 1) +< 255);
    Blob.new((0..31).map({ ($n +> (8 * $_)) +& 0xff }));
}

sub decode-point(Blob $b --> List) {
    die 'point encoding must be 32 bytes' unless $b.elems == 32;
    my $n = 0;
    for (0..31).reverse -> $i { $n = ($n +< 8) +| $b[$i] }
    my $sign = ($n +> 255) +& 1;
    my $y = $n +& ((1 +< 255) - 1);
    die 'point is not on the curve' if $y >= P;
    my $x = recover-x($y, $sign);
    to-extended($x, $y);
}

sub le-int(Blob $b --> Int) {
    my $n = 0;
    for (0..^$b.elems).reverse -> $i { $n = ($n +< 8) +| $b[$i] }
    $n;
}

sub le-bytes(Int $n, Int $len --> Blob) {
    Blob.new((0..^$len).map({ ($n +> (8 * $_)) +& 0xff }));
}

sub h512(Blob $b --> Blob) { sha512($b) }

sub clamp(Blob $h --> Int) {
    my $a = le-int($h.subbuf(0, 32));
    $a +&= (1 +< 254) - 8;
    $a +|= 1 +< 254;
    $a;
}

#| Generate a key pair: (public key, private key), the private key being
#| the seed followed by the public key, as Go's crypto/ed25519 lays it out.
sub generate-key(--> List) is export {
    my $seed = Blob.new(crypt_random_buf(32).list);
    key-from-seed($seed);
}

sub key-from-seed(Blob $seed --> List) is export {
    die 'seed must be 32 bytes' unless $seed.elems == 32;
    my $h = h512($seed);
    my $a = clamp($h);
    my $pub = encode-point(mul($a, BASE));
    ($pub, Blob.new(|$seed.list, |$pub.list));
}

#| Sign a message with a private key (seed ++ public key).
sub sign(Blob $priv, Blob $msg --> Blob) is export {
    die 'private key must be 64 bytes' unless $priv.elems == 64;
    my $seed = $priv.subbuf(0, 32);
    my $pub = $priv.subbuf(32, 32);
    my $h = h512($seed);
    my $a = clamp($h);
    my $prefix = $h.subbuf(32, 32);
    my $r = le-int(h512(Blob.new(|$prefix.list, |$msg.list))) mod L;
    my $R = encode-point(mul($r, BASE));
    my $k = le-int(h512(Blob.new(|$R.list, |$pub.list, |$msg.list))) mod L;
    my $s = ($r + $k * $a) mod L;
    Blob.new(|$R.list, |le-bytes($s, 32).list);
}

#| Verify a signature over a message with a public key.  False for
#| anything malformed; never throws.
sub verify(Blob $pub, Blob $msg, Blob $sig --> Bool) is export {
    return False unless $pub.elems == 32 && $sig.elems == 64;
    my $ok = try {
        my @A = decode-point($pub);
        my $Rb = $sig.subbuf(0, 32);
        my @R = decode-point($Rb);
        my $s = le-int($sig.subbuf(32, 32));
        return False if $s >= L;
        my $k = le-int(h512(Blob.new(|$Rb.list, |$pub.list, |$msg.list))) mod L;
        my @lhs = affine(mul($s, BASE));
        my @rhs = affine(add(@R, mul($k, @A)));
        @lhs[0] == @rhs[0] && @lhs[1] == @rhs[1];
    };
    so $ok;
}

#| The public key of a private key.
sub public-key(Blob $priv --> Blob) is export { $priv.subbuf(32, 32) }
