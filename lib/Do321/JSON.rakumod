unit module Do321::JSON;

use Data::Native;

#| JSON for the runtime: parsing (through the compiler's own reader),
#| Go-shaped encoding for the wire and the files on disk, and the
#| canonical form every digest uses.
#|
#| The canonical rules are stated in full in the Go original
#| (internal/protocol/canonical.go) and pinned by testdata/canonical/:
#|
#|  1. Objects: members sorted by key as UTF-8 byte strings, no duplicate
#|     keys, rendered {"k":v,...} with no whitespace.
#|  2. Arrays: elements in order, [a,b] with no whitespace.
#|  3. Strings: raw UTF-8 except \" \\ \b \f \n \r \t and \u00xx (lower
#|     hex) for the other controls below U+0020. Nothing else is escaped.
#|  4. Numbers: an integer literal as its digits, -0 as 0; any other
#|     number as the shortest round-tripping double in ES6
#|     Number.prototype.toString form.
#|  5. true, false and null as those words.
#|  6. No trailing newline.
#|
#| A digest is "sha256:" followed by the lowercase hex sha256 of those bytes.

class X::Do321::JSON is Exception {
    has Str $.message;
}

sub json-error(Str $m) { X::Do321::JSON.new(message => $m).throw }

#| An ordered set of pairs: what marshalling a document produces, so the
#| wire form keeps the struct's field order.  The canonical form sorts it
#| like any object.
class Ordered does Associative is export {
    has @.pairs;
    method keys { @!pairs.map(*.key) }
    method values { @!pairs.map(*.value) }
    method AT-KEY($k) { with @!pairs.first(*.key eq $k) { .value } else { Any } }
    method EXISTS-KEY($k) { so @!pairs.first(*.key eq $k) }
    method elems { @!pairs.elems }
    method kv { @!pairs.map({ |(.key, .value) }) }
    method Hash { %( @!pairs ) }
}

# ------------------------------------------------------------- parsing

#| Parse JSON text into plain data: Hash, Array, Str, Int, Rat/Num, Bool,
#| and Any for null.  Throws X::Do321::JSON on anything that is not one
#| JSON value.
sub parse-json(Str $text --> Any) is export {
    my $v = try from-json($text);
    if $! { json-error("invalid JSON: " ~ ($!.message.lines.head // 'unparseable')) }
    $v;
}

#| Parse bytes as UTF-8 JSON, refusing invalid UTF-8 outright.
sub parse-json-bytes(Blob $b --> Any) is export {
    my $text = try $b.decode('utf-8');
    if $! { json-error("input is not valid UTF-8") }
    parse-json($text);
}

# ------------------------------------------------------------ numbers

#| Render a number the way ES6 Number.prototype.toString and Go's
#| encoding/json do: integers as digits, doubles as the shortest
#| round-tripping decimal, plain notation for magnitudes in [1e-6, 1e21)
#| and d.ddde+x otherwise.
sub format-number(Numeric $n --> Str) is export {
    return $n.Str if $n ~~ Int;
    my Num $f = $n.Num;
    json-error("NaN and infinity cannot be represented") if $f.isNaN || $f == Inf || $f == -Inf;
    return '0' if $f == 0e0;
    my $s = $f.Str;                       # shortest round trip, e.g. 1e-07, 1.5, 1e+21
    my $neg = $s.starts-with('-');
    $s = $s.substr(1) if $neg;
    my ($mant, $exp) = $s.contains('e') ?? $s.split('e') !! ($s, '0');
    my $e = $exp.Int;
    my ($ip, $fp) = $mant.contains('.') ?? $mant.split('.') !! ($mant, '');
    my $digits = $ip ~ $fp;
    my $n-pos = $ip.chars + $e;          # position of the decimal point within $digits
    # strip leading zeros (keeping the point position honest) and trailing zeros
    while $digits.chars > 1 && $digits.starts-with('0') { $digits = $digits.substr(1); $n-pos-- }
    $digits = $digits.subst(/0+$/, '');
    $digits = '0' if $digits eq '';
    my $k = $digits.chars;
    my $out;
    if $k <= $n-pos && $n-pos <= 21 {
        $out = $digits ~ '0' x ($n-pos - $k);
    }
    elsif 0 < $n-pos && $n-pos <= 21 {
        $out = $digits.substr(0, $n-pos) ~ '.' ~ $digits.substr($n-pos);
    }
    elsif -6 < $n-pos && $n-pos <= 0 {
        $out = '0.' ~ '0' x (-$n-pos) ~ $digits;
    }
    else {
        my $ee = $n-pos - 1;
        my $sign = $ee < 0 ?? '-' !! '+';
        $out = $digits.substr(0, 1) ~ ($k > 1 ?? '.' ~ $digits.substr(1) !! '') ~ 'e' ~ $sign ~ $ee.abs;
    }
    ($neg ?? '-' !! '') ~ $out;
}

# ------------------------------------------------------------ strings

sub escape-string(Str $s, Bool :$wire = False --> Str) {
    my $out = '"';
    for $s.comb -> $c {
        my $o = $c.ord;
        $out ~= do given $c {
            when '"'  { '\\"' }
            when '\\' { '\\\\' }
            when "\b" { '\\b' }
            when "\f" { '\\f' }
            when "\n" { '\\n' }
            when "\r" { '\\r' }
            when "\t" { '\\t' }
            default {
                if $o < 0x20 { sprintf('\\u%04x', $o) }
                elsif $wire && ($o == 0x2028 || $o == 0x2029) { sprintf('\\u%04x', $o) }
                else { $c }
            }
        }
    }
    $out ~ '"';
}

# ------------------------------------------------------------ encoding

#| Byte order of keys, which is what Go's sort.Strings and Perl's sort give.
sub byte-sorted(@keys) { @keys.sort({ $^a.encode('utf-8') cmp $^b.encode('utf-8') }) }

#| Canonical JSON of plain data.  Hash keys sorted bytewise; the order of
#| Array elements kept; numbers per format-number.
sub canonical(Any $v --> Str) is export {
    my $out = '';
    write-value($v, $out, :canonical);
    $out;
}

#| Wire JSON of plain data, one line, no whitespace.  The same as the
#| canonical form except that U+2028 and U+2029 are escaped, as Go's
#| encoder does.  Hash keys come out sorted, as Go's map encoding sorts
#| them; a document with a fixed field order is encoded through its shape
#| (Do321::Shape) before it gets here.
sub encode-json(Any $v --> Str) is export {
    my $out = '';
    write-value($v, $out);
    $out;
}

#| Indented JSON for files a person may read (receipt.json, DIGEST's
#| SIGNATURE).  Two-space indent, like Go's MarshalIndent.
sub encode-json-pretty(Any $v --> Str) is export {
    my $out = '';
    write-value($v, $out, :indent(0));
    $out;
}

sub write-value(Any $v, Str $out is rw, Bool :$canonical = False, Int :$indent) {
    my $wire = !$canonical;
    given $v {
        when Bool       { $out ~= $v ?? 'true' !! 'false' }
        when Int        { $out ~= $v.Str }
        when Numeric    { $out ~= format-number($v) }
        when Str        { $out ~= escape-string($v, :$wire) }
        when Associative {
            my @keys = ($v ~~ Ordered && !$canonical) ?? $v.keys !! byte-sorted($v.keys);
            if @keys == 0 { $out ~= '{}'; return }
            $out ~= '{';
            my $first = True;
            for @keys -> $k {
                $out ~= ',' unless $first;
                $first = False;
                $out ~= "\n" ~ '  ' x ($indent + 1) if $indent.defined;
                $out ~= escape-string($k.Str, :$wire) ~ ':';
                $out ~= ' ' if $indent.defined;
                write-value($v{$k}, $out, :$canonical, :indent($indent.defined ?? $indent + 1 !! Int));
            }
            $out ~= "\n" ~ '  ' x $indent if $indent.defined;
            $out ~= '}';
        }
        when Positional {
            if $v.elems == 0 { $out ~= '[]'; return }
            $out ~= '[';
            my $first = True;
            for @$v -> $e {
                $out ~= ',' unless $first;
                $first = False;
                $out ~= "\n" ~ '  ' x ($indent + 1) if $indent.defined;
                write-value($e, $out, :$canonical, :indent($indent.defined ?? $indent + 1 !! Int));
            }
            $out ~= "\n" ~ '  ' x $indent if $indent.defined;
            $out ~= ']';
        }
        when Pair       { write-value({ $v.key => $v.value }, $out, :$canonical, :$indent) }
        default {
            if $v.defined { json-error("unsupported value " ~ $v.^name) }
            $out ~= 'null';
        }
    }
}

#| Re-render JSON text in canonical form.  Refuses invalid UTF-8 and
#| trailing data, as the Go implementation does.
sub canonicalize-json(Blob $raw --> Str) is export {
    canonical(parse-json-bytes($raw));
}

sub canonicalize-json-text(Str $text --> Str) is export {
    canonical(parse-json($text));
}

# ------------------------------------------------------------- digests

#| "sha256:<hex>" over raw bytes.
sub digest-bytes(Blob $b --> Str) is export {
    'sha256:' ~ sha256-hex($b);
}

#| "sha256:<hex>" over a string's UTF-8 bytes.
sub digest-string(Str $s --> Str) is export {
    digest-bytes($s.encode('utf-8'));
}

#| "sha256:<hex>" over the canonical JSON of plain data.
sub digest-of(Any $v --> Str) is export {
    digest-string(canonical($v));
}
