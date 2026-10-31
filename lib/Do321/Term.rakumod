unit module Do321::Term;

#| The terminal, owned for the length of a full-screen session and given
#| back exactly as it was: raw keys in, a cell buffer out, only changed
#| rows redrawn.  Wide characters take two cells (wcwidth from libc).  If
#| the program dies, END and the signal handlers restore the terminal, so
#| a crash never leaves a person typing into a blind screen.

use NativeCall;

sub tcgetattr(int32, Buf --> int32) is native {*}
sub tcsetattr(int32, int32, Buf --> int32) is native {*}
sub cfmakeraw(Buf) is native {*}
sub ioctl(int32, uint64, Buf --> int32) is native {*}
sub c-read(int32, Buf, size_t --> ssize_t) is native is symbol('read') {*}
sub c-wcwidth(int32 --> int32) is native is symbol('wcwidth') {*}
sub setlocale(int32, Str --> Str) is native {*}

# What differs between the systems this runs on.  Linux and macOS share
# the calls but not the numbers: the window-size request, the category
# meaning "every locale setting", and the size of the terminal settings
# (60 bytes on Linux, 72 on macOS; the buffer is roomier than either).
my constant DARWIN = $*KERNEL.name eq 'darwin';
my constant TIOCGWINSZ = DARWIN ?? 0x40087468 !! 0x5413;
my constant LC-ALL     = DARWIN ?? 0 !! 6;
my constant TERMIOS-BYTES = 256;

#| Whether Mission Control runs on this system.  Its host stands on Linux's
#| /proc, subreaper and inotify; macOS and Windows have the rest of 321.
sub screen-supported(--> Bool) is export { $*KERNEL.name eq 'linux' }

my $locale-set = False;

#| Columns a character takes: 2 for wide, 0 for combining, 1 otherwise.
sub cell-width(Str $c --> Int) is export {
    unless $locale-set { setlocale(LC-ALL, ''); $locale-set = True }
    my $o = $c.ord;
    return 1 if $o < 0x300;
    my $w = c-wcwidth($o);
    $w < 0 ?? 1 !! $w;
}

sub text-width(Str $s --> Int) is export { [+] $s.comb.map(&cell-width) }

#| Cut text to a width, with an ellipsis when it had to cut.
sub fit(Str $s, Int $w --> Str) is export {
    return '' if $w <= 0;
    return $s if text-width($s) <= $w;
    my $out = '';
    my $used = 0;
    for $s.comb -> $c {
        my $cw = cell-width($c);
        last if $used + $cw > $w - 1;
        $out ~= $c;
        $used += $cw;
    }
    $out ~ '…';
}

#| Pad (or cut) text to exactly a width.
sub pad(Str $s, Int $w --> Str) is export {
    my $t = fit($s, $w);
    $t ~ ' ' x ($w - text-width($t));
}

#| Words wrapped to a width, a long word broken where it must be.
sub wrap(Str $text, Int $w --> List) is export {
    return ('',) if $text eq '';
    my @out;
    for $text.split("\n") -> $para {
        my $line = '';
        for $para.words -> $word is copy {
            while text-width($word) > $w {
                if $line ne '' { @out.push($line); $line = '' }
                my $part = '';
                for $word.comb -> $c { last if text-width($part ~ $c) > $w; $part ~= $c }
                @out.push($part);
                $word = $word.substr($part.chars);
            }
            if $line eq '' { $line = $word }
            elsif text-width($line) + 1 + text-width($word) <= $w { $line ~= " $word" }
            else { @out.push($line); $line = $word }
        }
        @out.push($line);
    }
    @out.List;
}

# ------------------------------------------------------------ styles

#| A style is a set of names joined by '+': brand, bold, dim, ok, wait,
#| bad, sel, rev.  Colour only where the terminal and NO_COLOR allow it;
#| the selection stays visible without colour (reverse video).
sub sgr(Str $style, Bool $colour --> Str) is export {
    return "\e[0m" if $style eq '';
    my @c = '0';
    for $style.split('+') -> $s {
        given $s {
            when 'bold' { @c.push('1') }
            when 'dim'  { @c.push('2') }
            when 'rev'  { @c.push('7') }
            when 'brand' { @c.push($colour ?? '1;38;5;75' !! '1') }
            when 'ok'   { @c.push('32') if $colour }
            when 'wait' { @c.push('33') if $colour }
            when 'bad'  { @c.push('31') if $colour }
            when 'sel'  { @c.push($colour ?? '48;5;236' !! '7') }
        }
    }
    "\e[" ~ @c.join(';') ~ 'm';
}

# ------------------------------------------------------------ the buffer

#| A screen's worth of cells.  Each row is a list of [text, style] runs;
#| put() writes into a row at a column, clipped to the width.
class Canvas is export {
    has Int $.rows;
    has Int $.cols;
    has @.grid;      # rows x cols of [char, style]; '' marks the right half of a wide char

    submethod TWEAK() { self.clear }

    method clear() {
        @!grid = (^$!rows).map({ [ (^$!cols).map({ [' ', ''] }) ] });
    }

    #| Write text at (row, col) in a style, no further than $max columns.
    #| Returns the column after the last one written.
    method put(Int $r, Int $c is copy, Str $text, Str $style = '', Int :$max = $!cols - $c --> Int) {
        return $c if $r < 0 || $r >= $!rows;
        my $end = ($c + $max) min $!cols;
        for $text.comb -> $ch {
            next if $ch eq "\n" | "\r" | "\t";
            my $w = cell-width($ch);
            next if $w == 0;
            last if $c + $w > $end;
            @!grid[$r][$c] = [$ch, $style];
            @!grid[$r][$c + 1] = ['', $style] if $w == 2;
            $c += $w;
        }
        $c;
    }

    #| Paint a style over a span (for a selected row's tint).
    method tint(Int $r, Int $from, Int $to, Str $style) {
        return if $r < 0 || $r >= $!rows;
        for $from ..^ ($to min $!cols) -> $c {
            my $s = @!grid[$r][$c][1];
            @!grid[$r][$c][1] = $s eq '' ?? $style !! "$s+$style";
        }
    }

    #| The row as plain text, for tests and snapshots.
    method line(Int $r --> Str) { @!grid[$r].map({ .[0] }).join.subst(/\s+$/, '') }
    method text(--> Str) { (^$!rows).map({ self.line($_) }).join("\n") }

    #| The row as terminal bytes.
    method render-row(Int $r, Bool $colour --> Str) {
        my $out = '';
        my $cur = Str;
        for @!grid[$r] -> ($ch, $st) {
            next if $ch eq '';
            if !$cur.defined || $st ne $cur { $out ~= sgr($st, $colour); $cur = $st }
            $out ~= $ch;
        }
        $out ~ "\e[0m";
    }
}

# ------------------------------------------------------------ keys

class Key is export {
    has Str $.name;          # char | enter | tab | backspace | delete | esc | up | down | left | right
                             # home | end | pgup | pgdn | paste | ctrl-a .. ctrl-z | alt-enter | resize
    has Str $.text = '';
    method Str { $!name eq 'char' ?? $!text !! "<$!name>" }
}

#| Bytes from the terminal as keys.  Returns (keys, leftover bytes that
#| are the start of a sequence or a character not yet complete).
sub decode-keys(Blob $b --> List) is export {
    my @k;
    my $i = 0;
    my $n = $b.elems;
    my sub rest() { $b.subbuf($i) }
    while $i < $n {
        my $x = $b[$i];
        if $x == 0x1b {
            # bracketed paste: everything to the closing marker is text
            if $i + 5 < $n && $b.subbuf($i, 6).decode('latin1') eq "\e[200~" {
                my $s = $b.subbuf($i + 6).decode('utf8-c8');
                my $close = $s.index("\e[201~");
                return (@k.List, rest()) without $close;
                @k.push(Key.new(:name<paste>, :text($s.substr(0, $close))));
                $i += 6 + $s.substr(0, $close).encode('utf8-c8').elems + 6;
                next;
            }
            if $i + 1 >= $n { @k.push(Key.new(:name<esc>)); $i++; next }
            my $y = $b[$i + 1];
            if $y == 0x5b || $y == 0x4f {     # CSI or SS3
                my $j = $i + 2;
                $j++ while $j < $n && (($b[$j] >= 0x30 && $b[$j] <= 0x3f) || $b[$j] == 0x3b);
                return (@k.List, rest()) if $j >= $n;
                my $params = $b.subbuf($i + 2, $j - $i - 2).decode('latin1');
                my $final = $b[$j].chr;
                my $name = do given $final {
                    when 'A' { 'up' } when 'B' { 'down' } when 'C' { 'right' } when 'D' { 'left' }
                    when 'H' { 'home' } when 'F' { 'end' } when 'Z' { 'shift-tab' }
                    when '~' { given $params { when '5' { 'pgup' } when '6' { 'pgdn' } when '3' { 'delete' }
                                               when '1' | '7' { 'home' } when '4' | '8' { 'end' } default { '' } } }
                    default { '' }
                };
                @k.push(Key.new(:$name)) if $name ne '';
                $i = $j + 1;
                next;
            }
            if $y == 0x0d || $y == 0x0a { @k.push(Key.new(:name<alt-enter>)); $i += 2; next }
            @k.push(Key.new(:name<esc>));
            $i++;
            next;
        }
        if $x == 0x0d || $x == 0x0a { @k.push(Key.new(:name<enter>)); $i++; next }
        if $x == 0x09 { @k.push(Key.new(:name<tab>)); $i++; next }
        if $x == 0x7f || $x == 0x08 { @k.push(Key.new(:name<backspace>)); $i++; next }
        if $x < 0x20 { @k.push(Key.new(:name('ctrl-' ~ (0x60 + $x).chr))); $i++; next }
        # one UTF-8 character
        my $len = $x < 0x80 ?? 1 !! $x < 0xe0 ?? 2 !! $x < 0xf0 ?? 3 !! 4;
        return (@k.List, rest()) if $i + $len > $n;
        my $ch = try $b.subbuf($i, $len).decode('utf8');
        @k.push(Key.new(:name<char>, :text($ch // '?')));
        $i += $len;
    }
    (@k.List, Buf.new);
}

# ------------------------------------------------------------ the terminal

class Terminal is export {
    has Buf $!saved;
    has Bool $.active = False;
    has @!prev;
    has Bool $.colour = !(%*ENV<NO_COLOR> // '').chars;
    has Int $.rows = 24;
    has Int $.cols = 80;

    method size(--> List) {
        my $ws = Buf.allocate(8);
        if ioctl(1, TIOCGWINSZ, $ws) == 0 && $ws.read-uint16(2) > 0 {
            ($!rows, $!cols) = ($ws.read-uint16(0), $ws.read-uint16(2));
        }
        ($!rows, $!cols);
    }

    method enter() {
        $!saved = Buf.allocate(TERMIOS-BYTES);
        tcgetattr(0, $!saved);
        my $raw = Buf.new($!saved.list);
        cfmakeraw($raw);
        tcsetattr(0, 0, $raw);
        $!active = True;
        self.size;
        # alternate screen, cursor hidden, bracketed paste on
        $*OUT.print("\e[?1049h\e[?25l\e[?2004h\e[2J");
        $*OUT.flush;
        @!prev = ();
    }

    method leave() {
        return unless $!active;
        $!active = False;
        $*OUT.print("\e[0m\e[?2004l\e[?25h\e[?1049l");
        $*OUT.flush;
        tcsetattr(0, 0, $!saved) with $!saved;
    }

    #| Draw a canvas: only rows that changed since the last frame.
    method draw(Canvas $cv, Int :$cursor-row = -1, Int :$cursor-col = 0) {
        my $out = '';
        if @!prev.elems != $cv.rows { @!prev = (); $out ~= "\e[2J" }
        for ^$cv.rows -> $r {
            my $row = $cv.render-row($r, $!colour);
            next if (@!prev[$r] // '') eq $row;
            @!prev[$r] = $row;
            $out ~= "\e[{$r + 1};1H\e[2K" ~ $row;
        }
        $out ~= $cursor-row >= 0 ?? "\e[{$cursor-row + 1};{$cursor-col + 1}H\e[?25h" !! "\e[?25l";
        $*OUT.print($out);
        $*OUT.flush;
    }

    method invalidate() { @!prev = () }

    #| Read keys forever on a thread of their own, into a channel.
    method key-reader(Channel $ch) {
        start {
            my $pending = Buf.new;
            my $buf = Buf.allocate(4096);
            loop {
                my $n = c-read(0, $buf, 4096);
                last if $n <= 0;
                my $b = Buf.new($pending.list, $buf.subbuf(0, $n).list);
                my ($keys, $rest) = decode-keys($b);
                # a lone ESC at the end of a read is the Esc key, not a prefix
                if $rest.elems == 1 && $rest[0] == 0x1b { $ch.send(Key.new(:name<esc>)); $rest = Buf.new }
                $ch.send($_) for @$keys;
                $pending = Buf.new($rest.list);
            }
        }
    }
}
