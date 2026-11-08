unit module Do321::Palette;

#| The family palette: the colours 123 and 321 share, so two products of
#| one family read as kin on the same screen.  Each product keeps its own
#| mark (❮◉❯ for 123, ❮▣❯ for 321) and its own name; the colours, the
#| rules and the marks for what happened are the same.
#|
#| Each colour is said as the terminal can show it: the 123 TUI's own
#| shade where there are sixteen million, the nearest of 256, and the
#| terminal's named colour on sixteen, which is what the 123 CLI prints.
#| Ink stays the terminal's own.
#|
#|   blue      the person's focus: the mark, the cursor, the selected row,
#|             the prompt, and what is being done now
#|   green     done
#|   amber     what waits on a person
#|   red       what failed: the terminal's own red at every depth
#|   hairline  rules and pane edges
#|   sel       the selected row: the 123 title bar's blue, white on it
#|   #rrggbb   an agent's own accent, as 123 gives each agent one; its
#|             package says it, and a terminal of sixteen shows amber
my constant %SHADE =
    blue     => ('5ab8ff', '75',  '34'),
    green    => ('5aa878', '72',  '32'),
    amber    => ('e0a040', '179', '33'),
    red      => ('',       '',    '31'),
    hairline => ('1a2438', '237', '2'),
;
my constant @SEL = <2a5a88 d0e8ff 24 195>;

#| How many colours this terminal shows: 24 bits, 8 (256 colours) or 4
#| (the sixteen named).  COLORTERM says truecolor outright; TERM says
#| 256color; anything else gets the named sixteen.
sub colour-depth(--> Int) is export {
    return 24 if (%*ENV<COLORTERM> // '') eq 'truecolor' | '24bit';
    return 8 if (%*ENV<TERM> // '').contains('256color');
    4;
}

my sub rgb(Str $hex, Int $ground --> Str) { "$ground;2;" ~ $hex.comb(2).map({ :16($_) }).join(';') }

#| The SGR parameters for a colour, by name, at this terminal's depth:
#| what goes between ESC [ and m.  Empty for a name that is not a colour.
sub colour-sgr(Str $name --> Str) is export {
    my $depth = colour-depth();
    if $name ~~ / ^ '#' (<xdigit> ** 6) $ / {
        my $hex = ~$0;
        return $depth == 24 ?? rgb($hex, 38) !! $depth == 8 ?? "38;5;{nearest-cube($hex)}" !! '33';
    }
    if $name eq 'sel' {
        return $depth == 24 ?? rgb(@SEL[0], 48) ~ ';' ~ rgb(@SEL[1], 38)
            !! $depth == 8 ?? "48;5;{@SEL[2]};38;5;{@SEL[3]}"
            !! '7';
    }
    my @s = %SHADE{$name} // return '';
    return rgb(@s[0], 38) if $depth == 24 && @s[0] ne '';
    return "38;5;{@s[1]}" if $depth >= 8 && @s[1] ne '';
    @s[2];
}

#| The nearest of the 216 in the 256-colour cube to a shade: each
#| channel to the nearest of the cube's six levels.
my constant @LEVEL = 0, 95, 135, 175, 215, 255;
my sub nearest-cube(Str $hex --> Int) {
    my @c = $hex.comb(2).map(-> $h { my $v = :16($h); @LEVEL.pairs.min({ abs(.value - $v) }).key });
    16 + 36 * @c[0] + 6 * @c[1] + @c[2];
}

#| A colour as six hex digits, for a terminal's own cursor (OSC 12),
#| which takes no depth: '' for a colour that has no shade of its own.
sub colour-hex(Str $name --> Str) is export {
    return ~$0 if $name ~~ / ^ '#' (<xdigit> ** 6) $ /;
    (%SHADE{$name} // ('', '', ''))[0];
}

#| The escape that turns a colour on; the terminal's reset turns it off.
sub colour-code(Str $name --> Str) is export {
    my $p = colour-sgr($name);
    $p eq '' ?? '' !! "\e[{$p}m";
}
