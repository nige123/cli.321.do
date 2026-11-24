unit module Do321::Resources;

use Do321::JSON;
use Do321::RunDir;
use Do321::Protocol;

#| The things a piece of work may be given besides its workspace: other
#| repositories, a directory of documents, one file.
#|
#| Two halves are kept apart.  A work package names a resource by what it
#| is (a name, and for a repository the address it is known by): that is
#| the same on every machine, and is all a work system needs to keep.
#| Where it is on this machine is said here, in ~/.321/resources.json,
#| and never leaves it.  A run is given the resources its package names
#| and no others, each to read or to change.
#|
#| This is not a sandbox.  A resource to read is said to be for reading,
#| its state is recorded before and after, and a change to one is
#| reported on the receipt; what stops a harness writing there is the
#| harness's own enforcement, exactly as for the workspace.

constant SCHEMA-RESOURCES is export = 'resources.v1';
constant ACCESS-READ      is export = 'read';
constant ACCESS-WRITE     is export = 'write';

sub resources-file(IO::Path $home --> IO::Path) is export { $home.add('resources.json') }

sub resource-name-ok(Str $n --> Bool) is export { so $n ~~ / ^ <[a..z A..Z 0..9]> <[a..z A..Z 0..9 . _ -]> ** 0..63 $ / }

#| Why an address cannot be kept, or '' when it can.  An address says
#| which repository, never how to get in: a password or token in it would
#| be copied into every package and receipt that names the resource.
sub address-problem(Str $url --> Str) is export {
    return '' if $url eq '';
    return 'an address is one line' if $url.contains("\n");
    return 'the address carries credentials (the part before @); keep the address without them and let git find the credentials on this machine'
        if $url ~~ / ^ <[a..z A..Z]> <[a..z A..Z 0..9 + . -]>* '://' <-[/@]>* '@' /;
    return 'the address carries a token in its query; keep the address without it' if $url ~~ / <[?&]> [ 'token' | 'access_token' | 'key' | 'password' ] '=' /;
    '';
}

#| An address as it is compared: no scheme, no ".git", no trailing slash,
#| lower case host.  git@host:owner/repo and https://host/owner/repo are
#| the same repository.
sub same-address(Str $a, Str $b --> Bool) is export {
    my sub norm(Str $u) {
        my $s = $u.trim;
        $s = $s.subst(/ ^ <[a..z A..Z]> <[a..z A..Z 0..9 + . -]>* '://' /, '');
        $s = $s.subst(/ ^ <-[/@]>* '@' /, '');
        $s = $s.subst(/ ^ (<-[/:]>+) ':' /, { "$0/" });
        $s = $s.subst(/ '/' $ /, '').subst(/ '.git' $ /, '');
        $s.lc;
    }
    $a ne '' && $b ne '' && norm($a) eq norm($b);
}

my sub read-store(IO::Path $home --> Hash) {
    my $f = resources-file($home);
    return {} unless $f.e;
    my $d = try parse-json($f.slurp);
    $d ~~ Associative && $d<resources> ~~ Associative ?? $d<resources>.Hash !! {};
}

my sub write-store(IO::Path $home, %r) {
    private-dir($home);
    write-atomic(resources-file($home), encode-json-pretty(%( schema => SCHEMA-RESOURCES, resources => %r )) ~ "\n");
}

#| What kind of thing is at a path: a git checkout, a directory, a file,
#| or '' when nothing is there.
sub kind-at(Str $path --> Str) is export {
    my $p = $path.IO;
    return 'file' if $p.f;
    return '' unless $p.d;
    ($p.add('.git').d || $p.add('.git').f) ?? 'git' !! 'dir';
}

#| Every resource known on this machine, by name.
sub resources(IO::Path $home --> List) is export {
    my %r = read-store($home);
    %r.keys.sort.map({ %( name => $_, |(%r{$_} ~~ Associative ?? %r{$_}.Hash !! {}) ) }).List;
}

#| Say where a resource is on this machine.  Returns (resource, error).
sub add-resource(IO::Path $home, Str $name, Str $path, Str :$url = '' --> List) is export {
    return (Nil, "'$name' is not a name a resource can have: letters, digits, dot, dash and underscore") unless resource-name-ok($name);
    return (Nil, "'workspace' is the run's own working area, and is not a resource's name") if $name eq 'workspace';
    my $abs = (try $path.IO.absolute.IO.resolve.Str) // '';
    my $kind = $abs ne '' ?? kind-at($abs) !! '';
    return (Nil, "nothing is at $path") if $kind eq '';
    with address-problem($url) { return (Nil, $_) if $_ ne '' }
    my %r = read-store($home);
    my %new = kind => $kind, path => $abs;
    %new<url> = $url if $url ne '';
    %r{$name} = %new;
    write-store($home, %r);
    (%( name => $name, |%new ), Str);
}

sub remove-resource(IO::Path $home, Str $name --> Bool) is export {
    my %r = read-store($home);
    return False unless %r{$name}:exists;
    %r{$name}:delete;
    write-store($home, %r);
    True;
}

#| The resources a package names, found on this machine: by name first,
#| then by the address it is known by.  %at says where one is for this
#| run alone (a worktree made for it), over what the store says.  Returns
#| (found, problems): a resource this machine does not have is a problem,
#| never a guess.
sub resolve-resources(IO::Path $home, @refs, :%at --> List) is export {
    my @known = resources($home);
    my (@found, @problems);
    for @refs.grep(Associative) -> %ref {
        my $name = (%ref<name> // '').Str;
        my $url = (%ref<url> // '').Str;
        my $access = (%ref<access> // '') eq ACCESS-WRITE ?? ACCESS-WRITE !! ACCESS-READ;
        my $hit = @known.first({ .<name> eq $name }) // ($url ne '' ?? @known.first({ same-address((.<url> // '').Str, $url) }) !! Nil);
        without $hit {
            @problems.push("the resource '$name' is not known on this machine; say where it is: 321 resources add $name <path>"
                ~ ($url ne '' ?? " --url $url" !! ''));
            next;
        }
        my %here = %at{$name} ~~ Associative ?? %at{$name}.Hash !! {};
        my $path = (%here<path> // $hit<path> // '').Str;
        my $kind = kind-at($path);
        if $kind eq '' { @problems.push("the resource '$name' was at $path, and nothing is there now"); next }
        my %f = name => $name, kind => $kind, path => $path, access => $access;
        %f<url> = ($hit<url> // $url).Str if ($hit<url> // $url).Str ne '';
        %f<worktreeOf> = %here<of>.Str if (%here<of> // '') ne '';
        @found.push(%f);
    }
    (@found.List, @problems.List);
}

my sub git-out(Str $dir, *@args --> Str) {
    my $p = try run 'git', '-C', $dir, |@args, :out, :err;
    return '' if $! || !$p.defined;
    my $o = $p.out.slurp(:close); $p.err.slurp(:close);
    $p.exitcode == 0 ?? $o !! '';
}

#| Changed and untracked paths in a checkout, as git names them.
sub changed-in(Str $dir --> List) is export {
    my @files;
    for git-out($dir, 'status', '--porcelain', '--untracked-files=all').subst(/\n+$/, '').split("\n") -> $line {
        next if $line.chars < 4;
        my $f = $line.substr(3).trim;
        $f = $f.substr($f.index(' -> ') + 4) if $f.contains(' -> ');
        @files.push($f);
    }
    @files.List;
}

#| What a resource is like now: for a checkout, its branch, its commit
#| and the paths that differ from it.  A directory or a file that is not
#| under git has no state 321 can read cheaply, and says so by silence.
sub resource-state(%r --> Hash) is export {
    return {} unless (%r<kind> // '') eq 'git';
    my $dir = %r<path>.Str;
    %( branch => git-out($dir, 'rev-parse', '--abbrev-ref', 'HEAD').trim,
       commit => git-out($dir, 'rev-parse', 'HEAD').trim,
       changed => [ |changed-in($dir) ] );
}

#| The record of a resource for a receipt: where the work was done, on
#| what branch and commit, and what the run left changed.  Paths that
#| already differed before the run are someone's work in progress and
#| are not counted as the run's.
sub resource-evidence(%r, %before --> Hash) is export {
    my %e = name => %r<name>, kind => %r<kind>, access => %r<access>, path => %r<path>;
    %e<url> = %r<url> if (%r<url> // '') ne '';
    %e<worktreeOf> = %r<worktreeOf> if (%r<worktreeOf> // '') ne '';
    return %e unless %r<kind> eq 'git';
    my %after = resource-state(%r);
    %e<branch> = %after<branch> if (%after<branch> // '') ne '' && %after<branch> ne 'HEAD';
    %e<base> = %before<commit> if (%before<commit> // '') ne '';
    %e<head> = %after<commit> if (%after<commit> // '') ne '';
    my %was = @(%before<changed> // []).map({ $_ => True });
    my @new = @(%after<changed> // []).grep({ !%was{$_} });
    %e<filesChanged> = [ |@new ] if @new;
    %e<changedThoughReadOnly> = True
        if %r<access> ne ACCESS-WRITE && (@new || ((%before<commit> // '') ne '' && %before<commit> ne (%after<commit> // '')));
    %e;
}

#| A worktree of a checkout at its last commit, for one run, under
#| ~/.321/worktrees.  The checkout itself, and anything uncommitted in
#| it, is left exactly as it was.  Returns (path, base commit, error).
sub make-worktree(Str $ws, IO::Path $home --> List) is export {
    my $root = private-dir($home.add('worktrees'));
    my $path = $root.add(new-ulid()).Str;
    my $head = run 'git', '-C', $ws, 'rev-parse', 'HEAD', :out, :err;
    my $base = $head.out.slurp(:close).trim;
    $head.err.slurp(:close);
    return (Str, Str, "$ws has no commit yet, so there is nothing to make a worktree of") if $head.exitcode != 0 || $base eq '';
    my $add = run 'git', '-C', $ws, 'worktree', 'add', '--detach', $path, $base, :out, :err;
    $add.out.slurp(:close);
    my $err = $add.err.slurp(:close);
    return (Str, Str, "git could not make a worktree: {$err.lines.grep(*.trim ne '').tail // 'it said nothing'}") if $add.exitcode != 0;
    ($path, $base, Str);
}

#| Take back a worktree no run used.
sub drop-worktree(%iso) is export {
    try { my $p = run 'git', '-C', %iso<of>, 'worktree', 'remove', '--force', %iso<path>, :out, :err; $p.out.slurp(:close); $p.err.slurp(:close) }
}

#| Where a run's own worktrees of its resources are written, in its run
#| directory, so the host that runs it finds them.
sub run-resources-file(IO::Path $run-dir --> IO::Path) is export { $run-dir.add('resources.json') }

sub read-run-resources(Str $run-dir --> Hash) is export {
    return {} if $run-dir eq '';
    my $f = run-resources-file($run-dir.IO);
    return {} unless $f.e;
    my $d = try parse-json($f.slurp);
    $d ~~ Associative ?? $d.Hash !! {};
}
