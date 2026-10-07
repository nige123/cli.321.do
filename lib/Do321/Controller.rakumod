# Copyright Nige Ltd. Author: Nigel Hamilton.
unit module Do321::Controller;

#| Controllers: things outside a harness that say what must hold while an
#| agent works, and that the runtime drives at the points a harness lets
#| it.  321 knows how each harness works (its adapters); a controller
#| knows what must remain true.  IZ4 is the first; an approval system or a
#| tracer would be another.
#|
#| The seam is deliberately small: discover whether the controller
#| governs a workspace, get the context to give the agent, and ask for a
#| verdict on a consequential action, on a change, and on the finished
#| run.  A controller answers in one vocabulary (pass, warn, block,
#| needs_human), and 'unavailable' for a question it could not answer, so
#| a gap is reported instead of being read as a pass.
#|
#| Nothing here decides what an invariant means.  The IZ4 driver runs the
#| iz4 command line and reads its result documents; the same commands
#| serve a native hook, a Git hook or CI with no 321 anywhere.

use Do321::JSON;
use Do321::Protocol;

constant RESULT-PASS        is export = 'pass';
constant RESULT-WARN        is export = 'warn';
constant RESULT-BLOCK       is export = 'block';
constant RESULT-NEEDS-HUMAN is export = 'needs_human';
constant RESULT-UNAVAILABLE is export = 'unavailable';

sub results(--> List) is export { (RESULT-PASS, RESULT-WARN, RESULT-BLOCK, RESULT-NEEDS-HUMAN, RESULT-UNAVAILABLE) }

constant POINT-CONTEXT is export = 'context';
constant POINT-ACTION  is export = 'action';
constant POINT-CHANGE  is export = 'change';
constant POINT-VERIFY  is export = 'verify';

#| A controller's answer at one point.
class Verdict is export {
    has Str $.point = '';
    has Str $.result = RESULT-UNAVAILABLE;
    has Str $.reason = '';
    has @.invariants;            # what the controller considered, as it names them
    has @.uncertain;             # lines for a receipt's uncertain list
    has Str $.proposal = '';     # for needs_human: what a person is asked to agree to
    has Str $.limits = '';       # what the controller says it did not establish
    has @.parts;                 # for a compound answer: { part, result, detail } each
    has $.evidence;              # the controller's own document, verbatim, or Any

    #| Whether work must not simply continue past this answer.
    method stops(--> Bool) { $!result eq RESULT-BLOCK || $!result eq RESULT-NEEDS-HUMAN }
    method ran(--> Bool) { $!result ne RESULT-UNAVAILABLE }
    #| The answer as a small record for a receipt.
    method record(--> Hash) {
        my %r = point => $!point, result => $!result;
        %r<reason> = $!reason if $!reason ne '';
        %r<invariants> = [ |@!invariants.map(*.Str) ] if @!invariants;
        %r;
    }
}

sub unavailable(Str $point, Str $reason --> Verdict) is export {
    Verdict.new(:$point, :result(RESULT-UNAVAILABLE), :$reason);
}

#| A consequential action in terms no harness owns: what is being done to
#| what.  Adapters translate their harness's native event into one.
class Action is export {
    has Str $.operation = '';    # write, edit, delete, execute, send, fetch, commit, ...
    has Str $.target = '';       # a path, a command name, an address, a resource
    has %.parameters;
    has Str $.resource = '';
    has Str $.repository = '';
    has Str $.recipient = '';
    has Str $.context = '';

    method document(--> Hash) {
        my %d = operation => $!operation, target => $!target;
        %d<parameters> = %!parameters if %!parameters;
        for <resource repository recipient context> -> $k {
            my $v = self."$k"();
            %d{$k} = $v if $v ne '';
        }
        %d;
    }
}

role Controller is export {
    method name(--> Str) { ... }
    #| Whether this controller governs a workspace.  An empty Hash means it
    #| does not apply.  Otherwise: subject (what governs, e.g. a file),
    #| digest (its content identity), available (Bool: can it be driven
    #| here?) and reason (why not, when it cannot).
    method discover(Str $workspace --> Hash) { ... }
    #| The context to give the agent, as (text, error or Str).
    method context(Str $workspace --> List) { ... }
    #| Which of the four points this controller can answer here.
    method answers(--> List) { () }
    #| The harness controls it wants to be driven from, strongest first; an
    #| adapter wires the ones its harness has.
    method wants(--> List) { () }
    method check-action(Str $workspace, Action $action --> Verdict) { unavailable(POINT-ACTION, "{self.name} offers no action check") }
    method check-change(Str $workspace --> Verdict) { unavailable(POINT-CHANGE, "{self.name} offers no change check") }
    #| %run may carry summary: the agent's last words, as text.
    method verify(Str $workspace, %run --> Verdict) { unavailable(POINT-VERIFY, "{self.name} offers no verification") }
}

# --------------------------------------------------------------------- IZ4

#| The iz4 executable: X321_IZ4 when that is set (and nothing else, so a
#| caller can pin or withhold it), else `iz4` on PATH; '' when absent.
sub iz4-binary(--> Str) is export {
    with %*ENV<X321_IZ4> { return ($_.IO.x ?? $_ !! '') if $_ ne '' }
    my $found = on-path('iz4');
    $found.defined ?? $found.Str !! '';
}

#| Run a command in a directory; returns (exit code, stdout, stderr), or
#| (-1, '', message) when it could not start.
sub run-in(Str $dir, @argv, Str :$in --> List) {
    my $p = try run |@argv, :cwd($dir), :in, :out, :err, :env(%*ENV);
    return (-1, '', $!.message) if $!;
    $p.in.print($in) with $in;
    # Raku++ returns the Proc from closing stdin; sinking an unsuccessful
    # one throws, and the exit code is what we want, read below.
    try { $p.in.close; Nil };
    my $out = $p.out.slurp(:close);
    my $err = $p.err.slurp(:close);
    ($p.exitcode, $out, $err);
}

#| The IZ4 driver.  It calls iz4's machine interface and nothing else:
#|
#|     iz4 discover --json          does an IZ4 govern this place?
#|     iz4 context --json           what to tell the agent
#|     iz4 check action --json      one consequential action, on stdin
#|     iz4 check change --json      the change in the working directory
#|     iz4 verify --json            the finished run
#|
#| Each check answers with an iz4-check/1 document: result, reason,
#| invariants_considered, evidence, proposed_invariant_change, limits.
#| Which invariants exist, what they mean and what a change to one is are
#| iz4's business; an iz4 too old to offer a command makes that point
#| unavailable, which is reported, never passed.
class IZ4 does Controller is export {
    has Str $.bin = '';              # '' means X321_IZ4, else iz4 on PATH

    method name(--> Str) { 'iz4' }
    method binary(--> Str) { $!bin ne '' ?? $!bin !! iz4-binary() }
    method answers(--> List) { (POINT-CONTEXT, POINT-ACTION, POINT-CHANGE, POINT-VERIFY) }
    #| Context at the start, every write and shell command before it runs,
    #| and the end of the work.
    method wants(--> List) { (CTRL-AUTHORITATIVE-CONTEXT, CTRL-FILESYSTEM-GUARD, CTRL-SHELL-GUARD, CTRL-POST-RUN) }

    method discover(Str $workspace --> Hash) {
        return %() if $workspace eq '' || !$workspace.IO.d;
        my $bin = self.binary;
        if $bin eq '' {
            # Without iz4 only the file's presence can be seen; say that it
            # is there and cannot be driven.
            my $file = find-iz4-file($workspace);
            return %() without $file;
            return %( subject => $file.Str, digest => '', available => False, reason => 'iz4 is not installed' );
        }
        my ($code, $out, $err) = run-in($workspace, [$bin, 'discover', '--json']);
        my $doc = try parse-json($out);
        unless $code == 0 && $doc ~~ Associative && ($doc<schema> // '') ~~ Str && $doc<schema>.starts-with('iz4-discover/') {
            my $file = find-iz4-file($workspace);
            return %() without $file;
            return %( subject => $file.Str, digest => '', available => False,
                      reason => "this iz4 offers no machine interface (iz4 discover: {($err.trim.lines.head // "exit $code")})" );
        }
        return %() unless $doc<present>;
        return %( subject => $doc<file>.Str, digest => 'sha256:' ~ $doc<sha256>.Str, available => False,
                  reason => 'the IZ4 is invalid: ' ~ @($doc<errors> // []).join('; ') ) unless $doc<valid>;
        %( subject => $doc<file>.Str, digest => 'sha256:' ~ $doc<sha256>.Str, available => True, reason => '',
           invariants => [ |@($doc<invariants> // []).map({ ($_<number> // '').Str }) ] );
    }

    method context(Str $workspace --> List) {
        my ($code, $out, $err) = run-in($workspace, [self.binary, 'context', '--json']);
        return ('', $err) if $code == -1;
        my $doc = try parse-json($out);
        return ('', ($err.trim || "iz4 context exited $code")) unless $code == 0 && $doc ~~ Associative && ($doc<text> // '') ~~ Str;
        ($doc<text>, Str);
    }

    method check-action(Str $workspace, Action $action --> Verdict) {
        self!check(POINT-ACTION, $workspace, ['check', 'action', '--json'], :in(encode-json($action.document)));
    }
    method check-change(Str $workspace --> Verdict) {
        self!check(POINT-CHANGE, $workspace, ['check', 'change', '--worktree', '--json']);
    }
    method verify(Str $workspace, %run --> Verdict) {
        my @args = 'verify', '--worktree', '--json';
        my $file;
        if %run<summary>:exists {
            $file = $*TMPDIR.add("321-summary-{$*PID}-{(^1_000_000).pick}.txt");
            $file.spurt((%run<summary> // '').Str);
            @args.push('--summary=' ~ $file.Str);
        }
        LEAVE { try $file.unlink if $file.defined }
        self!check(POINT-VERIFY, $workspace, @args);
    }

    method !check(Str $point, Str $workspace, @args, Str :$in --> Verdict) {
        my $bin = self.binary;
        return unavailable($point, 'iz4 is not installed') if $bin eq '';
        my ($code, $out, $err) = run-in($workspace, [$bin, |@args], :$in);
        return unavailable($point, "iz4 {@args.head(2).join(' ')} did not run: $err") if $code == -1;
        verdict-from($point, $out, "iz4 {@args.head(2).join(' ')} (exit $code): {$err.trim.lines.head // 'no result document'}");
    }
}

#| A Verdict from an iz4-check/1 document.  Anything that is not one is
#| unavailable: an old iz4, an error, a crash.
sub verdict-from(Str $point, Str $out, Str $otherwise --> Verdict) is export {
    my $doc = try parse-json($out);
    return unavailable($point, $otherwise) unless $doc ~~ Associative && ($doc<schema> // '') ~~ Str && $doc<schema>.starts-with('iz4-check/');
    my $result = ($doc<result> // '').Str;
    return unavailable($point, "iz4 answered an unknown result \"$result\"")
        unless is-in($result, [RESULT-PASS, RESULT-WARN, RESULT-BLOCK, RESULT-NEEDS-HUMAN]);
    my $reason = ($doc<reason> // '').Str;
    my @uncertain = |@((($doc<evidence> // {})<report> // {})<uncertain> // []).grep(Str).map({ "IZ4 $_" });
    @uncertain.push("IZ4: $reason") if $result eq RESULT-WARN || $result eq RESULT-BLOCK;
    my $proposal = '';
    with $doc<proposed_invariant_change> -> $p {
        if $p ~~ Associative {
            my @lines = 'IZ4: ' ~ $reason;
            @lines.push('  ' ~ $p<summary>) if ($p<summary> // '') ne '';
            for @($p<changes> // []) -> $c {
                next unless $c ~~ Associative;
                @lines.push('  - ' ~ ($c<kind> // 'change') ~ (($c<number> // '') ne '' ?? " Invariant {$c<number>}" !! '')
                    ~ (($c<text> // $c<after> // '') ne '' ?? ": {($c<text> // $c<after>).Str.substr(0, 160)}" !! ''));
            }
            @lines.push('  to agree, a person runs: ' ~ $p<agree_with>) if ($p<agree_with> // '') ne '';
            @lines.push('  proposal digest: ' ~ $p<proposal_digest>) if ($p<proposal_digest> // '') ne '';
            $proposal = @lines.join("\n");
        }
    }
    my @parts = @((($doc<evidence> // {})<parts>) // []).grep(Associative).map({
        %( part => ($_<part> // '').Str, result => ($_<result> // '').Str, detail => ($_<detail> // '').Str ) });
    Verdict.new(:$point, :$result, :$reason, :invariants(@($doc<invariants_considered> // []).map(*.Str)),
        :@uncertain, :$proposal, :limits(($doc<limits> // '').Str), :@parts, :evidence($doc));
}

#| The IZ4 file above a directory, for the case where iz4 itself cannot be
#| asked.  Presence only: the runtime never reads what it says.
sub find-iz4-file(Str $workspace --> IO::Path) is export {
    return IO::Path if $workspace eq '';
    my $dir = $workspace.IO;
    loop {
        my $f = $dir.add('IZ4');
        return $f if $f.f;
        last if $dir.add('.git').e || $dir.parent.Str eq $dir.Str;
        $dir = $dir.parent;
    }
    IO::Path;
}

#| The controllers the runtime drives by default.
sub default-controllers(--> List) is export { (IZ4.new,) }

sub controller-named(Str $name, @controllers = default-controllers() --> Controller) is export {
    @controllers.first(*.name eq $name) // Controller;
}
