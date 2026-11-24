unit module Do321::Promote;

use Do321::JSON;
use Do321::RunDir;
use Do321::Learn;
use Do321::Registry;

#| Lessons become a skill.  A lesson is one piece of advice the runs have
#| tried; a skill is the advice that held, put together under a name, with
#| versions, that a person can give to any run (`--skill`) and share at the
#| registry.  Only KEPT lessons go into a skill: a lesson still on trial has
#| not been borne out, and a reverted one was found wanting.  The words are
#| the lessons' own, so no model is asked; words that carry a path, an
#| address, a secret or a private context's name are refused, since a skill
#| is made to be shared.  The lessons stay as they were and are still told
#| where their scope applies; each says which skill it is in.
#|
#| A skill made here is this machine's, published as `mine/NAME`, private,
#| until a person publishes it: then the registry keeps it PRIVATE to their
#| account, as a new version each time it changes.  Making it public is a
#| person's act on the registry's site, never this program's.

class X::Do321::Promote is Exception is export { has Str $.message }
my sub fail-with(Str $m) { X::Do321::Promote.new(message => $m).throw }
my sub stamp-now(--> Str) { DateTime.now.utc.Str.subst(/\.\d+/, '') }

constant LOCAL-PUBLISHER is export = 'mine';
#| The fewest kept lessons for one agent before a skill is suggested.
constant SKILL-SUGGEST-AT is export = 3;

#| The registry's rule for a skill's name.
sub skill-name-ok(Str $n --> Bool) is export { so $n ~~ / ^ <[a..z 0..9]> <[a..z 0..9 -]> ** 1..47 $ / }

#| The text of a skill made of lessons, in the standard skill format: a
#| SKILL.md whose YAML frontmatter carries `name` and `description` (what
#| it is for and when to use it, which is what an agent reads to decide),
#| then a markdown body: one line a lesson, with its when and because where
#| it has them, and where it came from.  Deterministic, so the same lessons
#| make the same text.
sub skill-text-from(Str $name, Str $description, @lessons --> Str) is export {
    my $desc = $description.subst(/\s+/, ' ', :g).trim;
    my @l = '---', "name: $name", 'description: "' ~ $desc.subst('\\', '\\\\', :g).subst('"', '\\"', :g) ~ '"', '---', '',
        "# $name", '', $desc, '',
        'What was learnt doing this work, kept because the runs bore it out. It is advice on how to work: it grants nothing, and never overrides the task or its limits.', '';
    for @lessons -> %l {
        my $line = '- ' ~ ((%l<when> // '') ne '' ?? "When {%l<when>}: " !! '') ~ %l<text>.Str.trim;
        $line ~= " (because {%l<because>})" if (%l<because> // '') ne '';
        @l.push: $line;
    }
    @l.push: '', 'Made from lessons ' ~ @lessons.map(*<id>).join(', ') ~ '.';
    @l.join("\n") ~ "\n";
}

#| Make (or make the next version of) skill `mine/NAME` from these lessons.
#| Returns (meta, 'installed' | 'updated' | 'unchanged').
sub skill-from-lessons(IO::Path $home, Str $name, @ids, Str :$description = '', Str :$project = '' --> List) is export {
    fail-with("'$name' is not a skill name: 2 to 48 lowercase letters, numbers and hyphens, starting with a letter or number") unless skill-name-ok($name);
    fail-with('name the lessons that make it: 321 lessons lists them') unless @ids;
    my @ls;
    for @ids.unique -> $id {
        my $l = lesson($home, $id, :$project);
        fail-with("no lesson here is called '$id'") without $l;
        my $state = ($l<state> // '').Str;
        fail-with("lesson $id is on trial: it goes into a skill once the runs or a person have kept it (321 lessons keep $id)") if $state eq 'trial';
        fail-with("lesson $id was reverted: it is not advice anyone should be given") unless $state eq 'kept';
        my @why = private-in($l<text>.Str, $home);
        fail-with("lesson $id cannot go into a skill that may be shared: {@why.join('; ')}") if @why;
        @ls.push($l.Hash);
    }
    my @agents = @ls.map({ ((.<scope> // {})<agent> // '').Str }).grep(* ne '').unique;
    # what it is and when to use it, as the format asks of a description
    my $who = @agents ?? @agents.map(*.uc).join(' and ') !! 'an agent';
    my $desc = ($description ne '' ?? $description
        !! "How $who works, from {@ls.elems} {@ls.elems == 1 ?? 'lesson' !! 'lessons'} kept by its runs. Use when giving $who work of this kind.").subst(/\s+/, ' ', :g).trim;
    fail-with('the description is longer than the 300 characters the registry takes') if $desc.chars > 300;
    my $text = skill-text-from($name, $desc, @ls);
    my $id = LOCAL-PUBLISHER ~ "/$name";
    my $was = installed-skill($home, $id);
    my $digest = text-digest($text);
    return ($was.Hash, 'unchanged') if $was ~~ Associative && ($was<digest> // '') eq $digest && ($was<description> // '') eq $desc;
    my $version = ($was ~~ Associative ?? (($was<version> // '0').Int + 1) !! 1).Str;
    my @harnesses = @ls.map({ ((.<scope> // {})<harness> // '').Str }).grep(* ne '').unique;
    my ($meta, $what) = install-skill-doc($home, %( id => $id, name => $name, publisher => LOCAL-PUBLISHER, version => $version,
        digest => $digest, instructions => $text, description => $desc, purpose => "Made from {@ls.elems == 1 ?? 'a lesson' !! 'lessons'} kept by the runs.",
        harnesses => @harnesses.Array, requires => [], sharing => 'private',
        provenance => %( from => 'lessons', lessons => @ls.map(*<id>).Array, agents => @agents.Array, madeAt => stamp-now() ) ), source => 'lessons');
    # each lesson says which skill it is in; it is still told as before
    for @ls -> %l {
        my %n = %l.grep({ .key ne 'kept-in' && .key ne 'file' });
        %n<skills> = [ |@(%l<skills> // []).grep(* ne $id), $id ];
        write-atomic(%l<file>.IO, encode-json(%n) ~ "\n");
    }
    ($meta, $what);
}

#| Agents with at least SKILL-SUGGEST-AT kept lessons that are in no skill
#| yet: agent => ids.  What `321 lessons` suggests making a skill of.
sub skill-ready(IO::Path $home, Str :$project = '' --> Hash) is export {
    my %by;
    for lessons($home, :$project).grep({ (.<state> // '') eq 'kept' && !@(.<skills> // []) && (.<kept-in> // '') ne 'project' }) -> %l {
        my $a = ((%l<scope> // {})<agent> // '').Str;
        next if $a eq '';
        %by{$a}.push(%l<id>.Str);
    }
    %( %by.grep({ .value.elems >= SKILL-SUGGEST-AT }) );
}

#| Send a skill made here to the registry, under the account the token
#| speaks for.  The registry keeps it private and makes a new version only
#| when it changed.  What it answered is kept on the skill.
sub publish-skill(IO::Path $home, Str $id --> Hash) is export {
    my $m = installed-skill($home, $id);
    fail-with("$id is not a skill on this machine: 321 skills lists them") without $m;
    fail-with("$id came from the registry; only a skill made here is published from here") unless ($m<source> // '') eq 'lessons';
    my $text = skill-text($home, $id);
    fail-with("the copy of $id here no longer matches its digest: make it again") unless text-digest($text) eq ($m<digest> // '');
    my @why = private-in($text, $home);
    fail-with("$id cannot be shared: {@why.join('; ')}") if @why;
    fail-with('publishing needs your registry token: 321 registry token') if registry-token($home) eq '';
    my %body = name => $m<name>.Str, description => $m<description>.Str, purpose => ($m<purpose> // '').Str, instructions => $text,
        harnesses => [ |@($m<harnesses> // []) ], requires => [ |@($m<requires> // []) ], note => "version {$m<version>} made from lessons by 321";
    my $doc = registry-get($home, '/api/skills', send => encode-json(%body));
    my %pub = id => ($doc<id> // '').Str, version => ($doc<version> // '').Str, sharing => ($doc<sharing> // '').Str,
        url => ($doc<url> // '').Str, created => so($doc<created>), changed => so($doc<changed>), at => stamp-now(), fromVersion => $m<version>.Str;
    my %n = |$m.Hash, published => %pub;
    write-atomic(skill-dir($home, $id).add('skill.json'), encode-json(%n) ~ "\n");
    %pub;
}
