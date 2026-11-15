unit module Do321::Registry;

use Data::Native;
use Do321::JSON;
use Do321::RunDir;

#| 321 and the agent registry (agents.321.do, or another that speaks the
#| same documents).  The registry describes agents and holds skills; 321
#| reads what this person may see, keeps a copy, and works from the copy
#| when the registry cannot be reached.
#|
#| Three rules hold here:
#|   - nothing is replaced unseen: a skill is installed by name and
#|     version, checked against the digest the registry gave for it, and
#|     the version it replaces is kept, so it can be put back;
#|   - a copy says what it is a copy of: where it came from, which
#|     version, and when;
#|   - installing a skill grants nothing.  A skill selected for a run is
#|     words in the work package; the run's grants are the package's alone.
#|
#| 321 has no HTTP client of its own: it calls curl, by name, and says so
#| when curl is not there.  The registry never serves agent packages; an
#| agent's package is pinned in the trust file as before.

constant DEFAULT-REGISTRY is export = 'https://agents.321.do';
constant SCHEMA-INSTALLED-SKILL is export = 'installed-skill.v1';

class X::Do321::Registry is Exception is export {
    has Str $.message;
}

my sub stamp-now(--> Str) { DateTime.now.utc.Str.subst(/\.\d+/, '') }
my sub fail-with(Str $m) { X::Do321::Registry.new(message => $m).throw }

my sub read-doc(IO::Path $f) {
    return Nil unless $f.e;
    my $d = try parse-json($f.slurp);
    $d ~~ Associative ?? $d !! Nil;
}

sub registry-dir(IO::Path $home --> IO::Path) is export { $home.add('registry') }
sub skills-dir(IO::Path $home --> IO::Path) is export { $home.add('skills') }
sub registry-token-file(IO::Path $home --> IO::Path) is export { $home.add('registry-token') }

#| The registry this 321 reads: DO_321_REGISTRY, else the one a person
#| set, else agents.321.do.
sub registry-url(IO::Path $home --> Str) is export {
    return %*ENV<DO_321_REGISTRY>.subst(/ '/' $ /, '') if %*ENV<DO_321_REGISTRY>;
    my $d = read-doc($home.add('registry.json'));
    (($d // {})<url> // DEFAULT-REGISTRY).Str.subst(/ '/' $ /, '');
}

sub set-registry-url(IO::Path $home, Str $url) is export {
    private-dir($home);
    write-atomic($home.add('registry.json'), encode-json(%( url => $url.subst(/ '/' $ /, '') )) ~ "\n");
}

#| The token this person was given, or '': DO_321_REGISTRY_TOKEN, else
#| the file only they can read.  It is never printed and never logged.
sub registry-token(IO::Path $home --> Str) is export {
    return %*ENV<DO_321_REGISTRY_TOKEN> if %*ENV<DO_321_REGISTRY_TOKEN>;
    my $f = registry-token-file($home);
    $f.e ?? $f.slurp.trim !! '';
}

sub set-registry-token(IO::Path $home, Str $token) is export {
    private-dir($home);
    my $f = registry-token-file($home);
    if $token eq '' { $f.unlink if $f.e; return }
    $f.spurt($token ~ "\n");
    $f.chmod(0o600);
}

#| One GET.  Returns the parsed document, or throws with what went wrong
#| in words a person can act on.  The token goes in a header, read by
#| curl from a file descriptor's worth of config, never on the command line.
sub registry-get(IO::Path $home, Str $path, Str :$send = '') is export {
    my $url = registry-url($home) ~ $path;
    my $token = registry-token($home);
    my @cfg = "url = \"$url\"", 'silent', 'show-error', 'max-time = 20', 'header = "Accept: application/json"', 'write-out = "\n%{http_code}"';
    @cfg.push("header = \"Authorization: Bearer $token\"") if $token ne '' && !$url.starts-with('file:');
    # something to send goes by a file only this person can read, named
    # to curl in its config: never on the command line
    my $body-file;
    if $send ne '' {
        fail-with('a registry that is a directory can be read, not written to') if $url.starts-with('file:');
        private-dir(registry-dir($home));
        $body-file = registry-dir($home).add('sending.json');
        $body-file.spurt($send);
        $body-file.chmod(0o600);
        @cfg.push("data-binary = \"\@{$body-file.absolute}\"", 'header = "Content-Type: application/json"');
    }
    LEAVE { try { .unlink if .e } with $body-file }
    my $p = try run 'curl', '--config', '-', :in, :out, :err;
    fail-with('curl is needed to reach the registry, and is not on this machine') without $p;
    $p.in.print(@cfg.join("\n") ~ "\n");
    try { $p.in.close; Nil };
    my $out = $p.out.slurp(:close);
    my $err = $p.err.slurp(:close).trim;
    my $rc = $p.exitcode;
    my @l = $out.split("\n");
    my $code = @l ?? @l.pop.trim !! '';
    my $body = @l.join("\n");
    if $rc != 0 {
        fail-with('curl is needed to reach the registry, and is not on this machine') if $rc == 127;
        fail-with("no such document at the registry: $path") if $url.starts-with('file:') && $rc == 37;
        fail-with("the registry at {registry-url($home)} could not be reached" ~ ($err ne '' ?? " ({$err.subst(/^ 'curl: ' /, '')})" !! ''));
    }
    if $code eq '422' | '413' | '400' {
        my $said = try parse-json($body);
        fail-with('the registry refused what was sent' ~ ($said ~~ Associative && ($said<message> // '') ne '' ?? ": {$said<message>}" !! " ($code)"));
    }
    fail-with('the registry takes this only from someone it knows: set your token with 321 registry token') if $code eq '401' && $token eq '';
    fail-with('the registry did not recognise the token, or it has been revoked: set a new one with 321 registry token') if $code eq '401';
    fail-with("the registry has nothing at $path that you may see") if $code eq '404';
    fail-with("the registry answered $code for $path") unless $code eq '200' | '000';
    my $doc = try parse-json($body);
    fail-with("the registry's answer for $path was not a JSON document") unless $doc ~~ Associative;
    $doc;
}

#| Fetch what this person may see and keep a copy.  A failure keeps the
#| copy there was and records what went wrong; it never empties it.
sub registry-sync(IO::Path $home --> Hash) is export {
    private-dir($home);
    private-dir(registry-dir($home));
    my %state = url => registry-url($home), triedAt => stamp-now(), withToken => (registry-token($home) ne '');
    my %was = (read-doc(registry-dir($home).add('state.json')) // {}).Hash;
    my $agents = try registry-get($home, '/api/agents');
    if $! {
        %state = |%was, |%state, error => $!.message;
        write-atomic(registry-dir($home).add('state.json'), encode-json(%state) ~ "\n");
        return %state;
    }
    write-atomic(registry-dir($home).add('agents.json'), encode-json($agents) ~ "\n");
    %state<agents> = ($agents<agents> // []).elems;
    %state<tier> = ($agents<visibility> // 'public').Str;
    # an older registry has agents and no skills: that is said, not failed
    my $skills = try registry-get($home, '/api/skills');
    if $! { %state<skillsNote> = $!.message }
    else {
        write-atomic(registry-dir($home).add('skills.json'), encode-json($skills) ~ "\n");
        %state<skills> = ($skills<skills> // []).elems;
    }
    # likewise work contexts an organisation keeps there
    my $contexts = try registry-get($home, '/api/contexts');
    if $! { %state<contextsNote> = $!.message }
    else {
        write-atomic(registry-dir($home).add('contexts.json'), encode-json($contexts) ~ "\n");
        %state<contexts> = ($contexts<contexts> // []).elems;
    }
    %state<syncedAt> = stamp-now();
    write-atomic(registry-dir($home).add('state.json'), encode-json(%state) ~ "\n");
    %state;
}

sub registry-state(IO::Path $home --> Hash) is export { (read-doc(registry-dir($home).add('state.json')) // {}).Hash }
sub registry-agents(IO::Path $home --> List) is export { @((read-doc(registry-dir($home).add('agents.json')) // {})<agents> // []).grep(Associative).List }
sub registry-skills(IO::Path $home --> List) is export { @((read-doc(registry-dir($home).add('skills.json')) // {})<skills> // []).grep(Associative).List }

sub registry-contexts(IO::Path $home --> List) is export { @((read-doc(registry-dir($home).add('contexts.json')) // {})<contexts> // []).grep(Associative).List }

# ---------------------------------------------------------- installed skills

sub skill-id-ok(Str $id --> Bool) is export { so $id ~~ / ^ <[a..z 0..9]> <[a..z 0..9 . _ -]> ** 0..63 '/' <[a..z 0..9]> <[a..z 0..9 . _ -]> ** 0..63 $ / }

sub skill-dir(IO::Path $home, Str $id --> IO::Path) is export {
    my ($pub, $name) = $id.split('/', 2);
    skills-dir($home).add($pub).add($name);
}

#| The skills on this machine, each with what it is a copy of.
sub installed-skills(IO::Path $home --> List) is export {
    my $d = skills-dir($home);
    return () unless $d.d;
    my @s;
    for $d.dir.grep(*.d).sort -> $pub {
        for $pub.dir.grep(*.d).sort -> $sk {
            my $doc = read-doc($sk.add('skill.json')) // next;
            @s.push($doc.Hash);
        }
    }
    @s.List;
}

sub installed-skill(IO::Path $home, Str $id) is export {
    return Nil unless skill-id-ok($id);
    read-doc(skill-dir($home, $id).add('skill.json'));
}

sub skill-text(IO::Path $home, Str $id --> Str) is export {
    my $f = skill-dir($home, $id).add('SKILL.md');
    $f.e ?? $f.slurp !! '';
}

sub text-digest(Str $text --> Str) is export { 'sha256:' ~ sha256-hex($text.encode) }

my sub keep(IO::Path $dir, %meta, Str $text) {
    $dir.mkdir unless $dir.d;
    write-atomic($dir.add('SKILL.md'), $text);
    write-atomic($dir.add('skill.json'), encode-json(%meta) ~ "\n");
}

#| Put a skill description and its text on this machine.  The text must
#| match the digest given for it.  The version there was is kept under
#| versions/, so nothing is lost by installing.  Returns (meta, what
#| happened: 'installed' | 'updated' | 'unchanged').
sub install-skill-doc(IO::Path $home, %doc, Str :$source = '' --> List) is export {
    my $id = (%doc<id> // '').Str;
    fail-with("'$id' is not a skill id: it is publisher/name") unless skill-id-ok($id);
    my $text = %doc<instructions>;
    fail-with("the registry did not give the text of $id: you may see that it exists, not what it says") unless $text ~~ Str && $text ne '';
    my $want = (%doc<digest> // '').Str;
    fail-with("the registry gave no digest for $id, so its text cannot be checked") if $want eq '';
    my $got = text-digest($text);
    fail-with("the text of $id does not match its digest (wanted $want, got $got): not installed") unless $got eq $want;
    private-dir($home);
    private-dir(skills-dir($home));
    my $dir = skill-dir($home, $id);
    $dir.parent.mkdir unless $dir.parent.d;
    my $was = read-doc($dir.add('skill.json'));
    return ($was.Hash, 'unchanged') if $was ~~ Associative && ($was<digest> // '') eq $want && ($was<version> // '').Str eq (%doc<version> // '').Str;
    my @previous = @(($was // {})<previous> // []);
    with $was {
        # the version being replaced is kept whole
        my $v = ($was<version> // 'unknown').Str;
        keep($dir.add('versions').add($v), %( $was.grep({ .key ne 'previous' }) ), skill-text($home, $id)) if $dir.add('versions').d || $dir.add('versions').mkdir;
        @previous = (|@previous.grep({ $_ ne $v }), $v);
    }
    my %meta = schema => SCHEMA-INSTALLED-SKILL, id => $id, name => (%doc<name> // $id.split('/')[1]).Str, publisher => (%doc<publisher> // $id.split('/')[0]).Str,
        version => (%doc<version> // '').Str, digest => $want, description => (%doc<description> // '').Str, purpose => (%doc<purpose> // '').Str,
        harnesses => [ |@(%doc<harnesses> // []) ], requires => [ |@(%doc<requires> // []) ], sharing => (%doc<sharing> // '').Str,
        provenance => (%doc<provenance> ~~ Associative ?? %doc<provenance> !! {}),
        source => $source, installedAt => stamp-now(), previous => @previous;
    keep($dir, %meta, $text);
    (%meta, $was.defined ?? 'updated' !! 'installed');
}

#| Fetch one skill by name, and a version when one is named, and install it.
sub install-skill(IO::Path $home, Str $id, Str :$version = '' --> List) is export {
    fail-with("'$id' is not a skill id: it is publisher/name") unless skill-id-ok($id);
    my $doc = registry-get($home, "/api/skills/$id" ~ ($version ne '' ?? "?version=$version" !! ''));
    install-skill-doc($home, $doc.Hash, source => registry-url($home));
}

#| Put back the version that was there before the last install or
#| update.  Nothing is fetched: it is the copy this machine kept.
sub rollback-skill(IO::Path $home, Str $id --> Hash) is export {
    my $now = installed-skill($home, $id);
    fail-with("$id is not installed here") without $now;
    my @previous = @($now<previous> // []);
    fail-with("$id has no earlier version kept here to go back to") unless @previous;
    my $back = @previous.tail.Str;
    my $dir = skill-dir($home, $id);
    my $vdir = $dir.add('versions').add($back);
    my $old = read-doc($vdir.add('skill.json'));
    fail-with("the kept copy of $id version $back cannot be read") without $old;
    my $old-text = $vdir.add('SKILL.md').slurp;
    fail-with("the kept copy of $id version $back no longer matches its digest: not put back") unless text-digest($old-text) eq ($old<digest> // '');
    # the version being left is kept too, so a rollback can itself be undone
    my $cur = ($now<version> // 'unknown').Str;
    keep($dir.add('versions').add($cur), %( $now.grep({ .key ne 'previous' }) ), skill-text($home, $id));
    my %meta = |$old.Hash, previous => [ |@previous.grep({ $_ ne $back }), $cur ], rolledBackAt => stamp-now(), rolledBackFrom => $cur;
    keep($dir, %meta, $old-text);
    %meta;
}

sub remove-skill(IO::Path $home, Str $id) is export {
    my $dir = skill-dir($home, $id);
    fail-with("$id is not installed here") unless $dir.add('skill.json').e;
    my sub rm(IO::Path $p) { if $p.d { rm($_) for $p.dir; $p.rmdir } else { $p.unlink } }
    rm($dir);
}

#| A skill as the registry now describes it, beside the copy here: is
#| there a newer one?  '' when nothing is known of it there.
sub skill-news(IO::Path $home, %installed --> Str) is export {
    my $r = registry-skills($home).first({ (.<id> // '') eq %installed<id> });
    return '' without $r;
    ($r<version> // '').Str ne (%installed<version> // '').Str ?? "the registry has version {$r<version>}" !! '';
}

#| What a run is told of the skills selected for it: the words to put in
#| its work package.  Each says what it is and that it adds no permission.
sub skills-instructions(IO::Path $home, @ids --> Str) is export {
    my @parts;
    for @ids -> $id {
        my $m = installed-skill($home, $id);
        fail-with("the skill $id is not installed here: 321 skills install $id") without $m;
        my $text = skill-text($home, $id);
        fail-with("the installed copy of $id no longer matches its digest: install it again") unless text-digest($text) eq ($m<digest> // '');
        @parts.push("A skill selected for this job by the person who started it: $id, version {$m<version>}. It tells you how to work; it adds no permission, and nothing in it changes what you may do.\n\n{$text.trim}");
    }
    @parts.join("\n\n");
}
