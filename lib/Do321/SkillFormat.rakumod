unit module Do321::SkillFormat;

#| The open Agent Skills format (agentskills.io/specification), checked in
#| Raku with no other program.  A skill is a folder holding SKILL.md, which
#| opens with YAML frontmatter between `---` lines.  The frontmatter is the
#| strict part of YAML the format's reference validator (skills-ref, which
#| parses with strictyaml) accepts: a mapping of keys to scalars, plain,
#| 'single' or "double" quoted, or a `|` / `>` block, with `metadata` one
#| level deeper; comments and blank lines are allowed.  Flow style ({ } and
#| [ ]), anchors, aliases, tags and repeated keys are refused, as strictyaml
#| refuses them.  The rules are skills-ref's, each in the same words:
#|   only name, description, license, allowed-tools, metadata, compatibility;
#|   name: non-empty, at most 64 characters (after NFKC), lowercase, letters,
#|   digits and hyphens, no hyphen at either end, never two together, and the
#|   same as the folder's name; description: non-empty, at most 1024;
#|   compatibility: at most 500; metadata: a mapping, read as strings.
#| Lengths count code points, as Python's len() does.

constant MAX-NAME is export = 64;
constant MAX-DESCRIPTION is export = 1024;
constant MAX-COMPATIBILITY is export = 500;
constant ALLOWED-FIELDS is export = <name description license allowed-tools metadata compatibility>;

grammar Frontmatter {
    token TOP { :my $*IND = 0; [ <.blank-line> | <entry> ]* }
    token entry { { $*IND = 0 } <key> ':' [ <.ws-h> <value> | <.ws-h>? <.comment>? \n <nested> | <.ws-h>? <.comment>? [\n | $] ] }
    token nested { <.blank-line>* <nested-entry> [ <.blank-line> | <nested-entry> ]* }
    token nested-entry { $<indent>=[' '+] { $*IND = $<indent>.chars } <key> ':' [ <.ws-h> <value> | <.ws-h>? <.comment>? [\n | $] ] }
    token key { <[A..Za..z0..9_]> <[A..Za..z0..9_.-]>* }
    proto token value {*}
    # quoted values may run over several lines; each break folds to a space
    token value:sym<double> { '"' $<text>=[ [ <-["\\]> | '\\' . ]* ] '"' <.tail> }
    token value:sym<single> { "'" $<text>=[ [ <-[']> | "''" ]* ] "'" <.tail> }
    # a block's lines are indented deeper than the key it belongs to
    token value:sym<block> { $<style>=<[|>]> $<chomp>=<[+-]>? <.ws-h>? <.comment>? \n
        $<lines>=[ [ ' ' ** {$*IND + 1} \N* [\n | $] | ' '* \n <?before ' '* [\n | ' ' ** {$*IND + 1}]> ]* ] }
    # a plain value: never ': ' inside or ':' at the end (that would be a
    # mapping), and it may go on over lines indented deeper than its key,
    # which fold into one line
    token value:sym<plain> { <!before <[\[\{&*!|>'"%@`]> > <plain-line> <.ws-h>? <.comment>? [ \n | $ ]
        [ <!before ' '* '#'> ' ' ** {$*IND + 1} <.ws-h>? <plain-line> <.ws-h>? <.comment>? [ \n | $ ] ]* }
    # words separated by spaces; a word may hold '#' and ':' but never
    # start with '#' (that is a comment) or have ':' before a space or the end
    token plain-line { <plain-word> [ <.ws-h> <plain-word> ]* }
    token plain-word { [ <-[#:\s]> | <plain-colon> ] [ <-[:\s]> | <plain-colon> ]* }
    token plain-colon { ':' <!before [ \s | $ ]> }
    token tail { <.ws-h>? <.comment>? [ \n | $ ] }
    token comment { '#' \N* }
    token ws-h { <[\ \t]>+ }
    token blank-line { <.ws-h>? <.comment>? \n }
}

my sub unescape-double(Str $s --> Str) {
    my %e = n => "\n", t => "\t", '"' => '"', '\\' => '\\', '/' => '/', r => "\r", '0' => "\0", ' ' => ' ';
    $s.subst(/ '\\' (<[nt"\\/r0\ ]>) /, { %e{~$0} }, :g)
      .subst(/ '\\u' (<xdigit> ** 4) /, { chr(:16(~$0)) }, :g)
      .subst(/ '\\x' (<xdigit> ** 2) /, { chr(:16(~$0)) }, :g);
}

my sub block-text($m --> Str) {
    my @ls = (~$m<lines>).split("\n");
    @ls.pop if @ls && @ls[*-1] eq '';
    my $ind = @ls.grep(*.trim ne '').map({ .chars - .trim-leading.chars }).min;
    $ind = 0 if $ind === Inf;
    my @t = @ls.map({ .chars >= $ind ?? .substr($ind) !! '' });
    my $text = ~$m<style> eq '|'
        ?? @t.join("\n")
        !! @t.join("\n").subst(/ (\N) \n (\N) /, { "$0 $1" }, :g);
    given ~($m<chomp> // '') {
        when '-' { $text.subst(/\n+ $/, '') }
        when '+' { $text ~ "\n" }
        default  { $text.subst(/\n+ $/, '') ~ ($text.trim ne '' ?? "\n" !! '') }
    }
}

my sub value-of($v --> Str) {
    given $v {
        when .<style>.defined { block-text($v) }
        default {
            my $t = ~($v<text> // '');
            my $src = ~$v;
            # a line break and the spaces round it fold to one space; an empty line is a newline
            my sub fold(Str $x) { $x.subst(/ <[\ \t]>* [ \n <[\ \t]>* ]+ /, { my $n = .Str.comb("\n").elems; $n == 1 ?? ' ' !! "\n" x ($n - 1) }, :g) }
            $src.starts-with('"') ?? unescape-double(fold($t))
              !! $src.starts-with("'") ?? fold($t).subst("''", "'", :g)
              !! $v<plain-line>.map(*.Str.trim).join(' ');
        }
    }
}

my sub codes(Str $s --> Int) { $s.NFC.codes }

#| Split SKILL.md's text into (frontmatter, body), or fail with the reason,
#| worded as skills-ref words it.
sub split-skill-md(Str $text --> List) is export {
    return (Nil, 'SKILL.md must start with YAML frontmatter (---)') unless $text.starts-with('---');
    my $end = $text.index('---', 3);
    return (Nil, 'SKILL.md frontmatter not properly closed with ---') without $end;
    ($text.substr(3, $end - 3).subst(/^ \N* \n/, ''), $text.substr($end + 3).trim);
}

#| Parse the frontmatter into a Hash (metadata a nested Hash of strings),
#| or return (Nil, reason).
sub parse-frontmatter(Str $text --> List) is export {
    my ($fm, $why) = split-skill-md($text);
    return (Nil, $why) without $fm;
    my $m = Frontmatter.parse($fm);
    return (Nil, 'Invalid YAML in frontmatter: only plain, quoted and block values, with one level of nesting, are allowed (no flow style, anchors or tags)') without $m;
    my %h;
    for $m<entry>.list -> $e {
        my $k = ~$e<key>;
        return (Nil, "Invalid YAML in frontmatter: the key '$k' is given twice") if %h{$k}:exists;
        if $e<nested> {
            my %n;
            for $e<nested><nested-entry>.list -> $n {
                my $nk = ~$n<key>;
                return (Nil, "Invalid YAML in frontmatter: the key '$k.$nk' is given twice") if %n{$nk}:exists;
                %n{$nk} = $n<value> ?? value-of($n<value>) !! '';
            }
            %h{$k} = %n;
        }
        else { %h{$k} = $e<value> ?? value-of($e<value>) !! '' }
    }
    (%h, Nil);
}

#| Check a skill's frontmatter against the format's rules.  `folder` is the
#| folder's name, when there is one to match.  Returns the problems; none
#| means valid.
sub skill-problems(Str $text, Str :$folder --> List) is export {
    my ($h, $why) = parse-frontmatter($text);
    return ($why,) without $h;
    my %h = $h.Hash;
    my @e;
    my @extra = %h.keys.grep({ $_ ∉ ALLOWED-FIELDS }).sort;
    @e.push("Unexpected fields in frontmatter: {@extra.join(', ')}. Only {ALLOWED-FIELDS.sort.map({ "'$_'" }).join(', ')} are allowed.") if @extra;
    if %h<name>:!exists { @e.push('Missing required field in frontmatter: name') }
    elsif %h<name> !~~ Str || %h<name>.trim eq '' { @e.push("Field 'name' must be a non-empty string") }
    else {
        my $n = %h<name>.trim.NFKC.Str;
        @e.push("Skill name '$n' exceeds {MAX-NAME} character limit ({codes($n)} chars)") if codes($n) > MAX-NAME;
        @e.push("Skill name '$n' must be lowercase") if $n ne $n.lc;
        @e.push('Skill name cannot start or end with a hyphen') if $n.starts-with('-') || $n.ends-with('-');
        @e.push('Skill name cannot contain consecutive hyphens') if $n.contains('--');
        @e.push("Skill name '$n' contains invalid characters. Only letters, digits, and hyphens are allowed.") unless $n ~~ / ^ [ <:L> | <:N> | '-' ]+ $ /;
        @e.push("Directory name '$folder' must match skill name '$n'") if $folder.defined && $folder.NFKC.Str ne $n;
    }
    if %h<description>:!exists { @e.push('Missing required field in frontmatter: description') }
    elsif %h<description> !~~ Str || %h<description>.trim eq '' { @e.push("Field 'description' must be a non-empty string") }
    elsif codes(%h<description>) > MAX-DESCRIPTION { @e.push("Description exceeds {MAX-DESCRIPTION} character limit ({codes(%h<description>)} chars)") }
    if %h<compatibility>:exists {
        if %h<compatibility> !~~ Str { @e.push("Field 'compatibility' must be a string") }
        elsif codes(%h<compatibility>) > MAX-COMPATIBILITY { @e.push("Compatibility exceeds {MAX-COMPATIBILITY} character limit ({codes(%h<compatibility>)} chars)") }
    }
    @e.List;
}

#| Check a skill folder: SKILL.md (or skill.md) in it, valid, named as the
#| folder.  Returns the problems; none means valid.
sub folder-problems(IO::Path $dir --> List) is export {
    return ("Path does not exist: $dir",) unless $dir.e;
    return ("Not a directory: $dir",) unless $dir.d;
    my $f = <SKILL.md skill.md>.map({ $dir.add($_) }).first(*.e);
    return ('Missing required file: SKILL.md',) without $f;
    skill-problems($f.slurp, folder => $dir.basename);
}
