unit module X321::Digest;

#| The canonical content digest of a package directory, and ed25519
#| signatures over it.
#|
#| The digest is sha256 over a canonical file listing: every regular file
#| under the root except DIGEST, SIGNATURE and anything under .git, with
#| paths in forward-slash form, sorted bytewise, each contributing
#| "<path>\x00<sha256 of bytes>\n".  Symlinks, absolute paths and any path
#| that resolves outside the root are refused outright rather than
#| skipped, because a package that contains one is not a package the
#| runtime should load.

use Data::Native;
use X321::JSON;
use X321::Shape;
use X321::Ed25519;

constant DIGEST-FILE    is export = 'DIGEST';
constant SIGNATURE-FILE is export = 'SIGNATURE';
constant ALGORITHM-ED25519 is export = 'ed25519';

class X::X321::Digest is Exception is export {
    has Str $.message;
}

sub digest-error(Str $m) { X::X321::Digest.new(message => $m).throw }

#| One file's contribution to the digest.
class Entry is export {
    has Str $.path;
    has Str $.sha256;
    has Int $.size;
}

#| Walk root and return (digest string, listing).  Fails on any symlink,
#| on any path with a backslash or NUL, and on a root that is not a
#| directory.
sub compute(IO() $root --> List) is export {
    digest-error("package root \"$root\" does not exist") unless $root.e;
    digest-error("package root \"$root\" is a symlink") if $root.l;
    digest-error("package root \"$root\" is not a directory") unless $root.d;
    my $abs = $root.absolute.IO;
    my @entries;
    my sub walk(IO::Path $dir, Str $rel-dir) {
        for $dir.dir.sort({ .basename }) -> $e {
            my $rel = $rel-dir eq '' ?? $e.basename !! "$rel-dir/{$e.basename}";
            digest-error("\"$rel\" is a symlink; packages may not contain symlinks") if $e.l;
            if $e.d {
                next if $e.basename eq '.git';
                walk($e, $rel);
                next;
            }
            digest-error("\"$rel\" is not a regular file") unless $e.f;
            next if $rel eq DIGEST-FILE || $rel eq SIGNATURE-FILE;
            digest-error("\"$rel\" has an unsafe path") if $rel.contains('\\') || $rel.contains("\0");
            my $bytes = $e.slurp(:bin);
            @entries.push(Entry.new(:path($rel), :sha256(sha256-hex($bytes)), :size($bytes.elems)));
        }
    }
    walk($abs, '');
    @entries = @entries.sort({ $^a.path.encode('utf-8') cmp $^b.path.encode('utf-8') });
    my $listing = Buf.new;
    for @entries -> $e {
        $listing.append($e.path.encode('utf-8'));
        $listing.append(0);
        $listing.append($e.sha256.encode('utf-8'));
        $listing.append(10);
    }
    ('sha256:' ~ sha256-hex(Blob.new($listing.list)), @entries);
}

#| Read the DIGEST file: one line, "sha256:<hex>".
sub read-digest-file(IO() $root --> Str) is export {
    my $f = $root.add(DIGEST-FILE);
    digest-error("{$f.Str}: no such file") unless $f.f;
    my $s = $f.slurp.trim;
    digest-error('DIGEST file is not a sha256 digest line') unless $s.starts-with('sha256:') && $s.chars == 7 + 64;
    $s;
}

#| Record the computed digest beside the package.
sub write-digest-file(IO() $root, Str $digest) is export {
    $root.add(DIGEST-FILE).spurt($digest ~ "\n");
}

#| Recompute the digest and compare it with the DIGEST file and, when
#| want is given, with the caller's pinned digest.  Returns the computed
#| digest; throws with it in the message otherwise.
sub verify-digest(IO() $root, Str $want = '' --> Str) is export {
    my ($computed, @) = compute($root);
    my $recorded = try read-digest-file($root);
    digest-error("digest: " ~ $!.message) if $!;
    digest-error("digest: DIGEST says $recorded but the content is $computed") if $recorded ne $computed;
    digest-error("digest: pinned $want but the content is $computed") if $want ne '' && $want ne $computed;
    $computed;
}

# ---------------------------------------------------------------- base64

my constant B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

sub base64-encode(Blob $b --> Str) is export {
    my $out = '';
    my @bytes = $b.list;
    loop (my $i = 0; $i < @bytes; $i += 3) {
        my $n = (@bytes[$i] +< 16) +| ((@bytes[$i + 1] // 0) +< 8) +| (@bytes[$i + 2] // 0);
        my $chunk = @bytes.elems - $i;
        $out ~= B64.substr(($n +> 18) +& 63, 1) ~ B64.substr(($n +> 12) +& 63, 1);
        $out ~= $chunk > 1 ?? B64.substr(($n +> 6) +& 63, 1) !! '=';
        $out ~= $chunk > 2 ?? B64.substr($n +& 63, 1) !! '=';
    }
    $out;
}

#| Standard base64 with padding; throws X::X321::Digest on anything else.
sub base64-decode(Str $s --> Blob) is export {
    digest-error('not base64') unless $s ~~ m:P5/^[A-Za-z0-9+\/]*={0,2}$/ && $s.chars %% 4;
    my @out;
    my $stripped = $s.subst(/'='+$/, '');
    my $pad = $s.chars - $stripped.chars;
    loop (my $i = 0; $i < $stripped.chars; $i += 4) {
        my @c = $stripped.substr($i, 4).comb.map({ B64.index($_) });
        my $n = 0;
        $n = ($n +< 6) +| ($_ // 0) for @c[0..3];
        @out.push(($n +> 16) +& 0xff);
        @out.push(($n +> 8) +& 0xff) if @c.elems > 2;
        @out.push($n +& 0xff) if @c.elems > 3;
    }
    Blob.new(@out);
}

# ------------------------------------------------------------ signatures

#| A stable identifier for a public key: the first sixteen hex characters
#| of its sha256.
sub key-id(Blob $pub --> Str) is export { sha256-hex($pub).substr(0, 16) }

#| Sign a digest string.  The private key never leaves the caller.
#| Returns a Signature document.
sub sign-digest(Str $digest, Blob $priv --> Hash) is export {
    my $pub = public-key($priv);
    doc('Signature', keyId => key-id($pub), algorithm => ALGORITHM-ED25519,
        value => base64-encode(sign($priv, $digest.encode('utf-8'))));
}

#| Check a signature document over a digest with a public key; throws
#| with the reason when it does not hold.
sub verify-signature(Str $digest, %sig, Blob $pub) is export {
    digest-error("signature: unsupported algorithm \"{%sig<algorithm>}\"") unless %sig<algorithm> eq ALGORITHM-ED25519;
    digest-error("signature: key id {%sig<keyId>} does not name this key") unless %sig<keyId> eq key-id($pub);
    my $raw = try base64-decode(%sig<value>);
    digest-error('signature: value is not base64') if $!;
    digest-error('signature: verification failed') unless verify($pub, $digest.encode('utf-8'), $raw);
    True;
}

#| Read the SIGNATURE file, a JSON Signature.
sub read-signature-file(IO() $root --> Hash) is export {
    my $f = $root.add(SIGNATURE-FILE);
    digest-error("{$f.Str}: no such file") unless $f.f;
    my $data = try parse-json($f.slurp);
    digest-error("signature: SIGNATURE is not valid JSON: {$!.message}") if $!;
    load('Signature', $data);
}

#| Record a signature beside the package.
sub write-signature-file(IO() $root, %sig) is export {
    $root.add(SIGNATURE-FILE).spurt(to-pretty('Signature', %sig) ~ "\n");
}

#| Decode a base64 ed25519 public key.
sub parse-public-key(Str $b64 --> Blob) is export {
    my $raw = try base64-decode($b64);
    digest-error('public key is not base64') if $!;
    digest-error('public key must be 32 bytes') unless $raw.elems == 32;
    $raw;
}

#| Render a public key as base64 for trust configuration.
sub encode-public-key(Blob $pub --> Str) is export { base64-encode($pub) }
