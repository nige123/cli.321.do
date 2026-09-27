unit module X321Test;

#| Helpers the test suite shares: temp dirs, fixture copies, and one seam
#| through which every CLI test runs the runtime, so X321_TEST_BIN can
#| point the suite at a compiled 321 (a Raku++ binary) and CI tests the
#| executable it ships, not the source it came from.

my @cleanup;
END { for @cleanup -> $d { try rm-rf($d) } }

sub rm-rf(IO::Path $p) {
    return unless $p.e || $p.l;
    if $p.d && !$p.l {
        rm-rf($_) for $p.dir;
        $p.rmdir;
    }
    else { $p.unlink }
}

sub temp-dir(--> IO::Path) is export {
    my $dir = $*TMPDIR.add("x321-test-{$*PID}-{(^1_000_000).pick}");
    $dir.mkdir;
    @cleanup.push($dir);
    $dir;
}

sub repo-root(--> IO::Path) is export { $?FILE.IO.resolve.parent(3) }

sub fixture(Str $rel --> IO::Path) is export { repo-root().add('testdata/packages').add($rel) }

sub fake-claude(--> IO::Path) is export { repo-root().add('testdata/fakeclaude/claude') }
sub fake-engine(--> IO::Path) is export { repo-root().add('testdata/fakeengine/dp') }

#| A writable copy of a fixture package.
sub copy-fixture(Str $rel --> IO::Path) is export {
    my $src = fixture($rel);
    my $dst = temp-dir();
    copy-tree($src, $dst);
    $dst;
}

sub copy-tree(IO::Path $src, IO::Path $dst) is export {
    for $src.dir -> $e {
        my $t = $dst.add($e.basename);
        if $e.d { $t.mkdir; copy-tree($e, $t) }
        else { $t.spurt($e.slurp(:bin)); $t.chmod($e.mode) }
    }
}

sub read-lines(IO::Path $f --> List) is export {
    $f.f ?? $f.slurp.trim.lines.map(*.trim).List !! ();
}

#| The command that runs the runtime: the compiled binary named by
#| X321_TEST_BIN, else the source through rakupp (or raku).
sub runtime-command(--> List) is export {
    return (%*ENV<X321_TEST_BIN>,) if %*ENV<X321_TEST_BIN>;
    my $root = repo-root();
    ($*EXECUTABLE, '-I', $root.add('lib').Str, $root.add('bin/321').Str);
}

#| Run the CLI with arguments and optional stdin; returns (exit code,
#| stdout, stderr).  The environment is the current one plus %env.
sub x321(*@args, Str :$in = '', :%env, IO::Path :$cwd --> List) is export {
    my %e = %*ENV, %env;
    my $proc = run |runtime-command(), |@args, :in, :out, :err, :env(%e), |($cwd ?? (:cwd($cwd.Str)) !! ());
    $proc.in.print($in);
    try $proc.in.close;
    my $out = $proc.out.slurp(:close);
    my $err = $proc.err.slurp(:close);
    ($proc.exitcode, $out, $err);
}
