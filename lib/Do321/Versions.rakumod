unit module Do321::Versions;

#| Which version of a harness is trusted here.  A harness updates itself
#| on its own schedule; a run is pinned to the version it ran on, and this
#| keeps the one a person promoted as known good, and the one before it to
#| go back to.  Where a harness keeps its versions side by side on disk,
#| the promoted one is the executable 321 runs, whatever PATH has moved to.
#|
#| ~/.321/harnesses.json (harness-versions.v1).  Nothing here calls a model.

use Do321::JSON;
use Do321::RunDir;
use Do321::Adapter;
use Do321::Protocol;

constant SCHEMA-HARNESS-VERSIONS is export = 'harness-versions.v1';

class X::Do321::Versions is Exception is export { has Str $.message }

sub versions-file(IO::Path $home --> IO::Path) is export { $home.add('harnesses.json') }

sub read-versions(IO::Path $home --> Hash) is export {
    my $f = versions-file($home);
    my $d = $f.f ?? (try parse-json($f.slurp)) !! Any;
    ($d ~~ Associative && ($d<harnesses> // {}) ~~ Associative) ?? %($d<harnesses>) !! %();
}

my sub save(IO::Path $home, %h) {
    $home.mkdir unless $home.d;
    write-atomic(versions-file($home), encode-json-pretty(%( schema => SCHEMA-HARNESS-VERSIONS, harnesses => %h )) ~ "\n");
}

#| A version as a bare number, from what a harness prints of itself.
sub version-number(Str $v --> Str) is export { ($v ~~ / (\d+ [ '.' \d+ ]+ <[\w.-]>*) / ?? ~$0 !! $v.trim).Str }

#| What is promoted for a harness: version, binary ('' when it cannot be
#| held on disk), promotedAt and previous; empty when nothing is.
sub known-good(IO::Path $home, Str $harness --> Hash) is export { %(read-versions($home){$harness} // {}) }

#| The executable to run for a harness: the promoted one while it is still
#| on disk, or '' to leave the choice to PATH.
sub pinned-binary(IO::Path $home, Str $harness --> Str) is export {
    my $b = (known-good($home, $harness)<binary> // '').Str;
    $b ne '' && $b.IO.f ?? $b !! '';
}

#| The versions kept beside an executable: version => path.  A harness
#| that installs each version as its own file, with the command a link to
#| one of them, has them; one installed in place has none.
sub versions-beside(Str $exe --> Hash) is export {
    return %() if $exe eq '';
    my $real = (try $exe.IO.resolve) // IO::Path;
    return %() unless $real.defined && $real.f && $real.basename ~~ / ^ \d+ [ '.' \d+ ]+ /;
    %( $real.parent.dir.grep({ .f && .basename ~~ / ^ \d+ [ '.' \d+ ]+ / }).map({ .basename => .Str }) );
}

#| Promote a version as known good; what was promoted becomes the one to
#| go back to.  Promoting the same version again changes nothing.
sub promote(IO::Path $home, Str $harness, Str $version, Str $binary, :@undocumented --> Hash) is export {
    my %all = read-versions($home);
    my %was = %(%all{$harness} // {});
    return %was if (%was<version> // '') eq $version && (%was<binary> // '') eq $binary;
    # The flags its help did not name when it was promoted are kept: a
    # later check reports only what has changed since.
    my %now = version => $version, binary => $binary, promotedAt => DateTime.now.utc.truncated-to('second').Str, undocumented => [ |@undocumented ];
    %now<previous> = %( version => %was<version>, binary => (%was<binary> // ''), promotedAt => (%was<promotedAt> // ''), undocumented => [ |@(%was<undocumented> // []) ] ) if (%was<version> // '') ne '';
    %all{$harness} = %now;
    save($home, %all);
    %now;
}

#| Go back to the version promoted before this one; the two change places,
#| so going back twice returns.
sub roll-back(IO::Path $home, Str $harness --> Hash) is export {
    my %all = read-versions($home);
    my %was = %(%all{$harness} // {});
    X::Do321::Versions.new(message => "nothing is promoted for $harness, so there is nothing to go back from").throw if (%was<version> // '') eq '';
    my %prev = %(%was<previous> // {});
    X::Do321::Versions.new(message => "$harness has no earlier promoted version to go back to").throw if (%prev<version> // '') eq '';
    my %now = version => %prev<version>, binary => (%prev<binary> // ''), promotedAt => DateTime.now.utc.truncated-to('second').Str,
        undocumented => [ |@(%prev<undocumented> // []) ],
        previous => %( version => %was<version>, binary => (%was<binary> // ''), promotedAt => (%was<promotedAt> // ''), undocumented => [ |@(%was<undocumented> // []) ] );
    %all{$harness} = %now;
    save($home, %all);
    %now;
}

#| The contract a harness adapter depends on, checked against the harness
#| installed: that it is here, says its version, and still documents each
#| flag the adapter passes.  No model is called and nothing is spent.
sub contract-check(Adapter $a --> Hash) is export {
    my $d = $a.detect;
    my %r = harness => $a.name, available => $d.available, version => version-number($d.version // ''), reason => ($d.reason // ''), flags => [], undocumented => [];
    my $exe = $a.executable;
    my @argv = $a.help-argv;
    if $exe ne '' && @argv {
        my $p = try run $exe, |@argv, :out, :err;
        my $text = $p.defined ?? ((try $p.out.slurp(:close)) // '') ~ ((try $p.err.slurp(:close)) // '') !! '';
        for $a.flags-used -> $f {
            my $seen = so $text ~~ / <!after <[\w-]>> $f <!before <[\w-]>> /;
            %r<flags>.push(%( flag => $f, documented => $seen ));
            %r<undocumented>.push($f) unless $seen;
        }
        %r<helpRead> = $text ne '';
    }
    %r<beside> = versions-beside($exe);
    # What the command on PATH is now, which a promoted version held on
    # disk may no longer be.
    my $cmd = $a.command-name;
    my $on = $cmd ne '' ?? on-path($cmd) !! IO::Path;
    my $real = $on.defined ?? ((try $on.resolve) // IO::Path) !! IO::Path;
    %r<installed> = ($real.defined && $real.basename ~~ / ^ \d+ [ '.' \d+ ]+ /) ?? $real.basename !! %r<version>;
    %r;
}
