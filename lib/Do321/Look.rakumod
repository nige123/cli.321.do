unit module Do321::Look;

#| How 321 speaks to a person: the one place every command's words pass
#| through on their way to a terminal.
#|
#| The words are the same everywhere.  Into a pipe, a file or a test
#| they arrive untouched, byte for byte, so a tool reads what it always
#| read.  On a terminal they are dressed: the icon before a header, the
#| names a person cites in bold, comments dimmed, a tick green, a cross
#| red, a question amber, and a row of air above and below, because a
#| person reading a screen is in the middle of something else and holds
#| only a few things at once.
#|
#| NO_COLOR and TERM=dumb turn the dress off; DO_321_COLOR=0 or 1 says
#| outright, and 1 keeps it into a pipe.

# ------------------------------------------------------------ the icon

#| The 321 mark in text: the 123 mark with a square eye, arrows either
#| side.  Its plain twin stands in wherever the locale is not UTF-8.
#| Windows Terminal is UTF-8 without saying so in LANG.
constant ICON       is export = '❮▣❯';
constant ICON-PLAIN is export = '<#>';

sub utf8-terminal(--> Bool) is export {
    so ((%*ENV<LC_ALL> // %*ENV<LC_CTYPE> // %*ENV<LANG> // '') ~~ /:i 'utf' '-'? '8'/) || (%*ENV<WT_SESSION> // '') ne '';
}

sub icon(--> Str) is export { utf8-terminal() ?? ICON !! ICON-PLAIN }

#| The marks a result carries, each a different shape so it reads without
#| colour, each with a plain twin.
constant %GLYPH = yes => ('✓', '+'), no => ('✗', 'x'), unknown => ('?', '?');
sub glyph(Str $which --> Str) is export { %GLYPH{$which}[utf8-terminal() ?? 0 !! 1] }

# ------------------------------------------------------------ on or off

#| The variables were X321_* and DO321_* before 0.4.2.  An old spelling
#| still works: it is read into the new name when the new one is unset.
#| Called before anything reads the environment.
sub adopt-old-names() is export {
    for %*ENV.keys.grep({ .starts-with('X321_') || .starts-with('DO321_') }) -> $old {
        my $new = $old.subst(/ ^ 'X321_' | ^ 'DO321_' /, 'DO_321_');
        %*ENV{$new} = %*ENV{$old} unless %*ENV{$new}:exists;
    }
}

#| Whether to dress output for a person: only on a terminal, never into a
#| pipe, a file or a test.  NO_COLOR and TERM=dumb turn it off;
#| DO_321_COLOR=1 or 0 says outright.
sub pretty-on(--> Bool) is export {
    return %*ENV<DO_321_COLOR> eq '1' if (%*ENV<DO_321_COLOR> // '') eq any('0', '1');
    return False if (%*ENV<NO_COLOR> // '') ne '' || (%*ENV<TERM> // '') eq 'dumb';
    so $*OUT.t;
}

#| A document for a machine (--json) is never dressed, terminal or not.
my Bool $DRESS = True;
sub dress(Bool $on) is export { $DRESS = $on }

# --------------------------------------------------------------- colour

#| The brand's blue, as this terminal can show it; ink stays the terminal's own.
my sub blue(--> Str) { (%*ENV<COLORTERM> // '') eq 'truecolor' | '24bit' ?? "\e[38;2;59;130;246m" !! "\e[38;5;69m" }
my constant BOLD  = "\e[1m";
my constant DIM   = "\e[2m";
my constant RED   = "\e[31m";
my constant GREEN = "\e[32m";
my constant AMBER = "\e[33m";
my constant OFF   = "\e[0m";

#| The first words a person types: the command words, bold wherever a
#| line cites one as '321 <word>'.
my constant @COMMANDS = <agents status receipt key iz4 doctor trust packages harness run hook hooks help version>;

#| Names a person cites, bold within a line: a work package or receipt id
#| (a ULID), a harness, and '321 <command>'.
my @HARNESSES = <claude_code>;
sub emphasise-harnesses(@names) is export { @HARNESSES = @names.grep(* ne 'fake' | 'procedure').List }

my sub emphasise(Str $s --> Str) {
    $s.subst(/ <!after <[\w / : . \-]>> (<[0..9 A..H J..K M..N P..T V..Z]> ** 26) <!before <[\w /]>> /, { "{BOLD}{$0}{OFF}" }, :g)
      .subst(/ <!after <[\w / . \-]>> ('321 ' @COMMANDS) <!before <[\w \-]>> /, { "{BOLD}{$0}{OFF}" }, :g)
      .subst(/ <!after <[\w / . \-]>> (@HARNESSES) <!before <[\w \-]>> /, { "{BOLD}{$0}{OFF}" }, :g)
}

#| Text as a person sees it on a terminal.  Nothing is added or removed
#| but colour; strip the escapes and every word is as it was.  With :!on
#| the text comes back untouched.
sub pretty(Str $text, Bool :$on = pretty-on() --> Str) is export {
    return $text unless $on && $DRESS;
    my $b = blue();
    $text.lines(:!chomp).map(-> $line {
        my $nl = $line.ends-with("\n") ?? "\n" !! '';
        my $l = $line.chomp;
        # a document for a machine, on a terminal by chance: left alone
        if $l ~~ / ^ \h* <[{}\[\]"]> / { }
        # every header: the icon, then '321', the command and the colon in bold
        elsif $l ~~ / ^ ([ '❮▣❯' | '<#>' ]) (' 321' [' ' <-[:\s]>+]* ':') (.*) $ / { $l = "{$b}{$0}{OFF}{BOLD}{$1}{OFF}{emphasise(~$2)}" }
        # a block's title: the icon, then bold words
        elsif $l ~~ / ^ ([ '❮▣❯' | '<#>' ]) ' ' (.*) $ / { $l = "{$b}{$0}{OFF} {BOLD}{$1}{OFF}" }
        # what comes next
        elsif $l ~~ / ^ ('next:' | 'then:') (.*) $ / { $l = "{BOLD}{$0}{OFF}{emphasise(~$1)}" }
        # comments, dimmed
        elsif $l ~~ / ^ \h* '#' / { $l = "{DIM}{$l}{OFF}" }
        # the marks
        elsif $l ~~ / ^ (\h*) ('✓' | '+') (\h .*) $ / { $l = "{$0}{GREEN}{$1}{OFF}{emphasise(~$2)}" }
        elsif $l ~~ / ^ (\h*) ('✗' | 'x') (\h .*) $ / { $l = "{$0}{RED}{$1}{OFF}{emphasise(~$2)}" }
        elsif $l ~~ / ^ (\h*) '?' (\h .*) $ / { $l = "{$0}{AMBER}?{OFF}{emphasise(~$1)}" }
        # a run's last word, and the lines that open a section
        elsif $l ~~ / ^ ('COMPLETED' | 'NO_CHANGE' | 'BLOCKED' | 'FAILED' | 'DENIED' | 'STOPPED' | 'OK' | 'INVALID' | 'All ' \w+) (':' .*)? $ / { $l = "{BOLD}{$0}{OFF}{emphasise(~($1 // ''))}" }
        # a command a person can type, on its own line or heading a column
        elsif $l ~~ / ^ (\h+ [ \S+ '=' \S* \h+ ]* '321' [\h <-[\h]>+]+?) (\h ** 2..* .*)? $ / { $l = "{BOLD}{$0}{OFF}{emphasise(~($1 // ''))}" }
        # a labelled row: the label in bold
        elsif $l ~~ / ^ (<[a..z A..Z]> <[a..z A..Z \-]> ** 0..12 ':') (\h+ .*) $ / { $l = "{BOLD}{$0}{OFF}{emphasise(~$1)}" }
        else { $l = emphasise($l) }
        $l ~ $nl;
    }).join;
}

# ------------------------------------------------------------------ air

#| A row of air above and below everything 321 says to a person: the
#| first write is preceded by a blank line unless it brings its own, and
#| the last is followed by one.  Only on a terminal (or DO_321_COLOR=1,
#| which asks for the terminal's dress anywhere); a pipe gets the words
#| alone.  Every line is dressed on its way through, so no command has
#| to remember.
class Air is IO::Handle {
    has IO::Handle $.inner is required;
    has Bool $!started = False;
    has Str  $!tail = '';
    method WRITE(Blob:D $data --> True) {
        my $s = $data.decode;
        unless $!started { $!started = True; $!inner.print("\n") unless $s.starts-with("\n") }
        $!tail = ($!tail ~ $s).substr(* - 2 max 0);
        $!inner.print(pretty($s, :on));
        True;
    }
    method settle() { $!inner.print("\n") if $!started && !$!tail.ends-with("\n\n"); $!inner.flush }
    method flush() { $!inner.flush }
    method t() { $!inner.t }
}

sub air-on(--> Bool) is export {
    return True  if (%*ENV<DO_321_COLOR> // '') eq '1';
    return False if (%*ENV<DO_321_COLOR> // '') eq '0';
    $*OUT.t && (%*ENV<TERM> // '') ne 'dumb';
}

my $air;
#| Installed once at startup, before anything is written.
sub install-air() is export {
    adopt-old-names();
    return unless air-on();
    $air = Air.new(:inner($*OUT));
    $air.encoding('utf8');
    $*OUT = $air;
}
sub settle-air() is export { .settle with $air }

# --------------------------------------------------------------- shapes

#| One header shape everywhere: the icon, '321', the command, a summary.
sub header(Str $name, Str $summary --> Str) is export { "{icon()} 321 $name: $summary" }

sub wrap-at(Str $text, Int $width --> List) is export {
    my @lines; my $line = '';
    for $text.words -> $w {
        if $line eq '' { $line = $w }
        elsif $line.chars + 1 + $w.chars <= $width { $line ~= ' ' ~ $w }
        else { @lines.push($line); $line = $w }
    }
    @lines.push($line) if $line ne '';
    @lines.List;
}

#| A short block a person can take in at a glance: a title under the
#| icon, a sentence or two wrapped at 72, a blank line, then the commands
#| that come next with why.  The shape anything a person reads after
#| acting answers in, so nothing is a wall.
sub calm(Str $title, *@body, :@next --> Str) is export {
    my @l = "{icon()} $title";
    if @body { @l.push(''); @l.push("  $_") for wrap-at(@body.join(' '), 72) }
    if @next { @l.push(''); @l.push(sprintf('  321 %-18s %s', .key, .value)) for @next }
    @l.join("\n") ~ "\n";
}

#| What comes next, in one breath: a line of advice and, beneath it, a
#| command that can be typed as it stands.
sub next-text(Str $advice, Str $example --> Str) is export {
    "next:  $advice\n       $example";
}

#| The numbered next steps that clear what a command found, and the one
#| that confirms it.
sub say-next(@steps, Str :$then --> Str) is export {
    my @l = 'next:';
    my $n = 0;
    @l.push("  {++$n}. $_") for @steps;
    @l.push("  then: $then again") with $then;
    @l.join("\n") ~ "\n";
}
