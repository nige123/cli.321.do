unit module Do321::Screen;

#| What a command says, as values rather than as text.
#|
#| A command builds a Screen: a title, a byline where an agent is
#| answering, chunks of typed blocks, the next step, and the word the run
#| ended on.  Nothing in it is formatted, coloured or wrapped, and no
#| operational code prints.  One renderer turns it into lines.
#|
#| The renderer takes three things it is never allowed to guess:
#|
#|   width    the terminal's own, so nothing is nailed to 72 columns
#|   colour   whether to ink the lines
#|   utf8     whether the marks are their UTF-8 or their plain twins
#|
#| Colour and character set are separate axes: NO_COLOR keeps the marks,
#| a C locale keeps the colour.  Each is tested on its own.  The plain
#| twins stand in for the furniture this module writes - the lockup, the
#| marks, the dots and dashes.  What a person or an agent wrote passes
#| through as it is: 321 does not transliterate somebody else's words.
#|
#| Three registers share a screen and never mix:
#|
#|   321 itself      the lockup, in the brand blue, on the title line only
#|   an agent        its own mark and name: shape and typography, no colour
#|   what happened   one mark, one word and one colour per state
#|
#| An agent therefore looks the same whether its run completed, blocked or
#| failed, and a state reads without any colour at all.

# ----------------------------------------------------------------- the ink

#| The brand's blue, as this terminal can show it.
my sub blue(--> Str) { (%*ENV<COLORTERM> // '') eq 'truecolor' | '24bit' ?? "\e[38;2;59;130;246m" !! "\e[38;5;69m" }
my constant BOLD  = "\e[1m";
my constant DIM   = "\e[2m";
my constant RED   = "\e[31m";
my constant GREEN = "\e[32m";
my constant AMBER = "\e[33m";
my constant OFF   = "\e[0m";

#| The one place ink is applied.  Without colour the text is returned as
#| it stands, so the words are identical on both sides of the switch.
sub ink(Str $text, Str $with, Bool :$colour --> Str) is export {
    return $text unless $colour && $text ne '';
    my $code = do given $with {
        when 'brand' { blue() }
        when 'bold'  { BOLD }
        when 'dim'   { DIM }
        when 'red'   { RED }
        when 'green' { GREEN }
        when 'amber' { AMBER }
        default      { '' }
    };
    $code eq '' ?? $text !! "{$code}{$text}{OFF}";
}

# --------------------------------------------------------------- the marks

#| The 321 lockup: the permanent brand signature, and the only thing that
#| opens a screen.
constant LOCKUP       is export = '❮▣❯';
constant LOCKUP-PLAIN is export = '<#>';

#| What happened, as one mark, one word and one colour.  Four shapes, so a
#| person learns them once and reads the state before the words: a tick
#| for done, a dot for nothing to do, a question for what waits on them, a
#| cross for what did not happen.  A receipt's status maps onto these; the
#| word here is the word the screen says.
my constant %STATE = (
    'done'        => ('✓', '+', 'green'),
    'no change'   => ('·', '-', 'dim'),
    'blocked'     => ('?', '?', 'amber'),
    'waiting'     => ('?', '?', 'amber'),
    'not checked' => ('?', '?', 'amber'),
    'failed'      => ('✗', 'x', 'red'),
    'denied'      => ('✗', 'x', 'red'),
    'stopped'     => ('·', '-', 'dim'),
);

#| The state word a receipt's status is said as.
sub state-of(Str $status --> Str) is export {
    given $status.lc.subst('_', ' ', :g) {
        when 'completed' { 'done' }
        when 'no change' { 'no change' }
        default          { %STATE{$_}:exists ?? $_ !! 'not checked' }
    }
}

sub state-mark(Str $state, Bool :$utf8 = True --> Str) is export {
    my $m = %STATE{$state} // %STATE<not checked>;
    $utf8 ?? $m[0] !! $m[1];
}
sub state-colour(Str $state --> Str) is export { (%STATE{$state} // %STATE<not checked>)[2] }

#| The marks an agent may wear: a family of its own, so nothing an agent
#| carries can be mistaken for the brand (❮ ▣ ❯), for iz4 (◈ ◆ ◇) or for
#| a state (✓ · ? ✗).  A package names one; validation refuses the rest.
constant @AGENT-MARKS is export = '⬢', '⬣', '⬡', '◉', '◍', '⬤', '⯁', '⬠';

# --------------------------------------------------------------- the width

my Int $width-cache;

#| The width to lay a screen out in: the terminal's own, clamped so a
#| narrow window still reads and a wide one is not a ribbon down the left.
#| DO_321_WIDTH says outright, which is how the tests and the snapshots
#| ask for a width.  Into a pipe there is no terminal to ask, and the
#| answer is the settled 72.  The question is asked once.
sub screen-width(--> Int) is export {
    return $_ with $width-cache;
    my $w = do {
        if (%*ENV<DO_321_WIDTH> // '') ~~ / ^ \d+ $ / { %*ENV<DO_321_WIDTH>.Int }
        elsif !$*OUT.t { 72 }
        else {
            my $cols = (try qqx{stty size 2>/dev/null}.words.tail) // '';
            $cols ~~ / ^ \d+ $ / ?? $cols.Int !! 80;
        }
    };
    $width-cache = $w < 40 ?? 40 !! $w > 100 ?? 100 !! $w;
}
sub forget-width() is export { $width-cache = Int }

# -------------------------------------------------------------- the values

#| One labelled fact: 321's word for it, and what was established.
class Row is export {
    has Str $.label is required;
    has Str $.value = '';
}

#| Who is answering.  The mark and the name are the agent's; the version
#| and whether the receipt is signed stand beside the identity and are
#| never part of it.
class Byline is export {
    has Str  $.mark    = '';
    has Str  $.name is required;
    has Str  $.byline  = '';
    has Str  $.id      = '';
    has Str  $.version = '';
    has Bool $.signed  = False;
}

#| A step a person can take: why, and the exact command.
class Step is export {
    has Str $.advice is required;
    has Str $.command = '';
}

#| A cell that is a state, not a word: a table of runs carries outcomes,
#| and they must take the mark, the word and the colour of that state
#| wherever they appear, not a string somebody typed.
class State is export { has Str $.word is required; }

#| A cell that is an agent: its mark and its name, in the identity
#| register, so a column of runs reads as a crew without borrowing a
#| state's colour.
class Who is export {
    has Str $.mark = '';
    has Str $.name is required;
}

role Block is export { }

#| Facts in a column.
class Rows does Block is export { has Row @.rows; }

#| Two or more things with the same fields.
class Table does Block is export {
    has Str @.heads;
    has @.rows;           # each a list of Str
}

#| What happened: the state's mark and word, then one sentence 321 wrote
#| from the receipt.  No agent's words reach this block.
class Upshot does Block is export {
    has Str $.state is required;
    has Str $.sentence = '';
}

#| An agent's own words, attributed.  The only block a model's text may
#| enter, which is what keeps character apart from what was established.
class Said does Block is export {
    has Str $.mark = '';
    has Str $.who is required;
    has Str $.text is required;
}

#| A quiet line: something true that is nobody's claim.
class Note does Block is export { has Str $.text is required; }

#| The marks this screen used, at its foot, where it used more than two.
class Legend does Block is export { has Row @.marks; }

class Screen is export {
    has Str    $.title is required;      # the command words: 'agents', 'b1ll: fix the build'
    has Str    @.subtitle;               # the quiet line under it, in parts the renderer joins
    has Byline $.byline;
    has Block  @.blocks;
    has Step   @.next;
    has Step   $.then;
    has Str    $.closer = '';            # said last, only when something happened
    has Int    $.exit = 0;
}

# ------------------------------------------------------------ the renderer

#| Words folded to a width, each line no wider, no word broken.
sub wrap(Str $text, Int $width --> List) is export {
    return ('',) if $text eq '';
    my @out;
    my $line = '';
    for $text.words -> $w {
        if $line eq '' { $line = $w }
        elsif ($line ~ ' ' ~ $w).chars <= $width { $line ~= " $w" }
        else { @out.push($line); $line = $w }
    }
    @out.push($line) if $line ne '';
    @out.List;
}

constant LABEL = 14;    # where a row's value begins

my sub row-lines(Row $r, Int $width, Bool :$colour --> List) {
    my $label = sprintf('%-*s', LABEL, $r.label);
    my @v = wrap($r.value, $width - LABEL);
    my @out = ink($label, 'dim', :$colour) ~ (@v[0] // '');
    @out.push((' ' x LABEL) ~ $_) for @v[1 .. *];
    @out.List;
}

#| What a cell says, plainly: a state takes its mark and word, an agent
#| its mark and name, anything else the words it was given.
my sub cell-text($c, Bool :$utf8 --> Str) {
    given $c {
        when State { state-mark(.word, :$utf8) ~ ' ' ~ .word }
        when Who   { (.mark ne '' ?? ($utf8 ?? .mark !! .name.substr(0, 1).uc) ~ ' ' !! '') ~ .name }
        default    { ($c // '').Str }
    }
}
#| Which register a cell belongs to: a state is coloured by what happened,
#| an agent and a word are not coloured at all.
my sub cell-ink($c --> Str) { $c ~~ State ?? state-colour($c.word) !! '' }

my sub table-lines(Table $t, Int $width, Bool :$colour, Bool :$utf8 --> List) {
    my @rows = $t.rows.map(*.list);
    return () unless @rows;
    my $cols = @rows.map(*.elems).max;
    my @w = (^$cols).map(-> $i {
        ((@rows.map({ cell-text(.[$i], :$utf8).chars }), ($t.heads[$i] // '').chars).flat).max
    });
    # How much room each column gets.  Where the window is too narrow, the
    # widest column in the middle gives way first - it is the description,
    # and the eye can live with less of it.  The first column and the last
    # are kept whole: the first says which row this is, and the last says
    # what happened, which is the reason the table is being read.
    my $room = $width - 2;
    my @span = (^$cols).map(-> $i { @w[$i] + ($i == $cols - 1 ?? 0 !! 2) });
    my @keep = (^$cols).map({ True });
    my sub width-used() { [+] (^$cols).grep({ @keep[$_] }).map({ @span[$_] }) }
    # A middle column is squeezed to 14 and then dropped: in a narrow
    # window the description is what a person can do without.  The first
    # column and the last are never dropped - the first says which row
    # this is, the last says what happened, and that is the reason the
    # table is being read at all.
    while width-used() > $room {
        my @mid = (1 ..^ $cols - 1).grep({ @keep[$_] });
        last unless @mid;
        my $i = @mid.max({ @span[$_] });
        @span[$i] > 14 ?? @span[$i]-- !! (@keep[$i] = False);
    }
    # whatever is left belongs to the last column, which gives up its
    # words rather than the line
    if $cols > 1 {
        my $used = [+] (^$cols).grep({ @keep[$_] && $_ != $cols - 1 }).map({ @span[$_] });
        @span[$cols - 1] = max(6, $room - $used);
    }
    my sub lay(@cells, Bool :$head = False --> Str) {
        my @parts;
        for (^$cols).grep({ @keep[$_] }) -> $i {
            my $text = $head ?? (@cells[$i] // '').Str !! cell-text(@cells[$i], :$utf8);
            my $fits = @span[$i] - ($i == $cols - 1 ?? 0 !! 2);
            if $text.chars > $fits && $fits > 1 {
                $text = $text.substr(0, $fits - 1) ~ ($utf8 ?? '…' !! '.');
            }
            my $shown = $head ?? ink($text, 'dim', :$colour) !! ink($text, cell-ink(@cells[$i]), :$colour);
            @parts.push($shown ~ ' ' x max(0, @span[$i] - $text.chars));
        }
        ('  ' ~ @parts.join).trim-trailing;
    }
    my @out;
    @out.push(lay($t.heads, :head)) if $t.heads;
    @out.push(lay($_)) for @rows;
    @out.List;
}

my sub upshot-lines(Upshot $v, Int $width, Bool :$colour, Bool :$utf8 --> List) {
    my $mark = ink(state-mark($v.state, :$utf8), state-colour($v.state), :$colour);
    my $word = ink($v.state, 'bold', :$colour);
    my $head = "$mark $word";
    return ($head,) if $v.sentence eq '';
    my $lead = state-mark($v.state, :$utf8).chars + 1 + $v.state.chars + 3;   # mark, word, ' — '
    my @s = wrap($v.sentence, $width - $lead);
    my @out = "$head {$utf8 ?? '—' !! '--'} {@s[0] // ''}";
    @out.push((' ' x $lead) ~ $_) for @s[1 .. *];
    @out.List;
}

my sub said-lines(Said $s, Int $width, Bool :$colour, Bool :$utf8 --> List) {
    my $mark = $s.mark ne '' ?? ($utf8 ?? $s.mark !! $s.who.substr(0, 1).uc) !! '';
    my @out = '  ' ~ ($mark ne '' ?? "$mark " !! '') ~ ink($s.who, 'bold', :$colour);
    @out.push('    ' ~ $_) for wrap($s.text, $width - 4);
    @out.List;
}

my sub byline-lines(Byline $b, Int $width, Bool :$colour, Bool :$utf8 --> List) {
    my $dot = $utf8 ?? '·' !! '-';
    my $mark = $b.mark ne '' ?? ($utf8 ?? $b.mark !! $b.name.substr(0, 1).uc) ~ ' ' !! '';
    my @tail = $b.byline, ("{$b.id} {$b.version}".trim ~ ($b.id ne '' ?? ($b.signed ?? ', signed' !! ', unsigned') !! ''));
    my $rest = @tail.grep(* ne '').join(" $dot ");
    my $who  = $mark ~ $b.name;
    # the name stays with the mark; the words that describe it give way to
    # the next line in a narrow window rather than off the edge
    my @wrap = wrap("$who $dot $rest", $width - 4);
    return ('    ' ~ ink($who, 'bold', :$colour),) if $rest eq '';
    my $first = @wrap[0];
    my @out = '    ' ~ ink($who, 'bold', :$colour) ~ ink($first.substr(min($who.chars, $first.chars)), 'dim', :$colour);
    @out.push('    ' ~ ink($_, 'dim', :$colour)) for @wrap[1 .. *];
    @out.List;
}

my sub step-lines(Str $label, Step $s, Int $width, Bool :$colour --> List) {
    my @a = wrap($s.advice, $width - 7);
    my @out = ink(sprintf('%-7s', $label), 'bold', :$colour) ~ (@a[0] // '');
    @out.push((' ' x 7) ~ $_) for @a[1 .. *];
    # the command is never folded: a person has to be able to copy it whole
    @out.push((' ' x 7) ~ ink($s.command, 'bold', :$colour)) if $s.command ne '';
    @out.List;
}

#| A screen as lines.  The words are the same whatever the switches say;
#| only the ink and the marks change.
sub screen-lines(Screen $s, Int :$width = screen-width(), Bool :$colour = False, Bool :$utf8 = True --> List) is export {
    my $dot = $utf8 ?? '·' !! '-';
    my @out;
    # the lockup, then the words the person typed.  '321' alone is the
    # title of the screen a person meets before they have typed a command.
    my $words = '321' ~ ($s.title ne '' ?? ' ' ~ $s.title !! '');
    my $lockup = ink($utf8 ?? LOCKUP !! LOCKUP-PLAIN, 'brand', :$colour);
    # a long request is folded under the title rather than cut: the words
    # a person typed are how they recognise their own run
    my @title = wrap($words, $width - 4);
    @out.push($lockup ~ ' ' ~ ink(@title[0], 'bold', :$colour));
    @out.push('    ' ~ ink($_, 'bold', :$colour)) for @title[1 .. *];
    @out.append(wrap($s.subtitle.grep(* ne '').join(" $dot "), $width - 4).map({ ink('    ' ~ $_, 'dim', :$colour) })) if $s.subtitle.grep(* ne '');
    @out.append(byline-lines($s.byline, $width, :$colour, :$utf8)) with $s.byline;

    for $s.blocks -> $b {
        @out.push('');
        given $b {
            when Rows    { @out.append(row-lines($_, $width, :$colour)) for .rows }
            when Table   { @out.append(table-lines($_, $width, :$colour, :$utf8)) }
            when Upshot { @out.append(upshot-lines($_, $width, :$colour, :$utf8)) }
            when Said    { @out.append(said-lines($_, $width, :$colour, :$utf8)) }
            when Note    { @out.append(wrap(.text, $width - 2).map({ '  ' ~ ink($_, 'dim', :$colour) })) }
            when Legend  { @out.append(.marks.map(-> $m { '  ' ~ $m.label ~ ' ' ~ ink($m.value, 'dim', :$colour) })) }
        }
    }

    if $s.next || $s.then {
        @out.push('');
        @out.append(step-lines('next:', $_, $width, :$colour)) for $s.next;
        @out.append(step-lines('then:', $_, $width, :$colour)) with $s.then;
    }
    if $s.closer ne '' {
        @out.push('');
        @out.append(wrap($s.closer, $width));
    }
    @out.List;
}

#| A screen onto a handle: air above and below where a person is reading,
#| nothing added where a tool is.
sub say-screen($w, Screen $s, Int :$width = screen-width(), Bool :$colour = False, Bool :$utf8 = True, Bool :$air = False) is export {
    $w.say('') if $air;
    $w.say($_) for screen-lines($s, :$width, :$colour, :$utf8);
    $w.say('') if $air;
}

# -------------------------------------------------------------- progress

#| How long something has taken, as a person says it.
sub took(Duration $d --> Str) is export {
    my $s = $d.Int;
    $s < 60 ?? "{$d.round(0.1)}s" !! sprintf('%d:%02d', $s div 60, $s % 60);
}

#| One line for work whose size is known: the stage, a bar of that share,
#| the count, how long so far, and what it is on right now.  The share is
#| only ever done over total; nothing is invented.
sub bar-line(Str $stage, Int $done, Int $total, Duration $elapsed, Str :$detail = '', Int :$width = screen-width(), Bool :$utf8 = True, Bool :$colour = False --> Str) is export {
    die 'a bar needs a total above zero; use a spinner where the size is unknown' if $total <= 0;
    my $cells = 12;
    my $full = ($done / $total * $cells).Int;
    $full = $cells if $full > $cells;
    my $bar = ($utf8 ?? '█' !! '#') x $full ~ ($utf8 ?? '░' !! '.') x ($cells - $full);
    my $plain = "  $stage  $bar  $done/$total  {took($elapsed)}";
    my $line = "  $stage  " ~ ink($bar, 'brand', :$colour) ~ "  $done/$total  {took($elapsed)}";
    # the detail is the first thing to go: a name cut in half says less
    # than no name at all
    $line ~= "  $detail" if $detail ne '' && $plain.chars + 2 + $detail.chars <= $width;
    $line;
}

my constant @SPIN       = '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏';
my constant @SPIN-PLAIN = '|', '/', '-', '\\';

#| One line for work whose size is not known: a turning mark, the stage it
#| is in by name, and how long it has been there.  A spinner without a
#| stage name says only that something is happening, which is not news.
sub spin-line(Str $stage, Int $tick, Duration $elapsed, Str :$detail = '', Str :$hint = '', Int :$width = screen-width(), Bool :$utf8 = True, Bool :$colour = False --> Str) is export {
    die 'a spinner needs the name of the stage it is in' if $stage.trim eq '';
    my @f = $utf8 ?? @SPIN !! @SPIN-PLAIN;
    my $plain = "  {@f[0]} $stage  {took($elapsed)}";
    my $line = '  ' ~ ink(@f[$tick % @f.elems], 'brand', :$colour) ~ " $stage  {took($elapsed)}";
    for ($detail, $hint) -> $extra {
        next if $extra eq '';
        last if $plain.chars + 2 + $extra.chars > $width;
        $line ~= '  ' ~ ($extra === $hint ?? ink($extra, 'dim', :$colour) !! $extra);
        $plain ~= "  $extra";
    }
    $line;
}

#| Where progress goes.  On a terminal: one line, rewritten in place,
#| wiped when the work ends, so the screen that follows starts clean.
#| Into a pipe: nothing, unless a tool asked for the record with
#| DO_321_PROGRESS=1, which gets one tab-separated line per update and
#| never a control code.
class Live is export {
    has      $.handle is required;
    has Bool $.live is required;          # a terminal is watching
    has Bool $.record = False;            # a tool asked for the record
    has Bool $.wiped = True;

    method show(Str $line) {
        if $!live { $!handle.print("\r\e[2K" ~ $line); $!handle.flush; $!wiped = False }
        elsif $!record { $!handle.say($line.subst(/<[\t\n]>/, ' ', :g)) }
    }
    method record-line(*@fields) {
        return unless $!record && !$!live;
        $!handle.say(@fields.map({ .Str.subst(/<[\t\n]>/, ' ', :g) }).join("\t"));
    }
    method wipe() {
        return if $!wiped || !$!live;
        $!handle.print("\r\e[2K");
        $!handle.flush;
        $!wiped = True;
    }
}
