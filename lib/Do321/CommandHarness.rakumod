unit module Do321::CommandHarness;

#| The quick way to teach 321 a new harness: a command-line agent that
#| takes a prompt and prints its answer.
#|
#| A harness adapter has two halves.  One is the same for every such
#| command: find it, start it, hand it the prompt, read what it prints,
#| stop it when asked, and turn its last words into a result.  That half
#| is here.  The other is what only its author knows: its name, its
#| command line, what it really enforces, and what its output means.  A
#| new harness is a class that says those four things.
#|
#|     class Acme is CommandHarness {
#|         method name(--> Str)     { 'acme' }
#|         method label(--> Str)    { 'Acme Agent' }
#|         method command(--> Str)  { 'acme' }
#|         method args(Spec $s --> List) { ('run', '--quiet', |self.model-args($s, '--model')) }
#|         method enforcement(--> Hash) { self.claims(FEAT-TIMEOUT, FEAT-GRACEFUL-STOP) }
#|     }
#|
#| Claim only what the harness does.  A feature left out of `claims` is
#| not enforced, and a package that needs it is never placed here: that
#| is the safe direction, and the one a new adapter should start from.
#| docs/harness-authors.md walks through the rest.

use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Adapter;

my sub first-line(Str $s, Int $max --> Str) {
    my $l = $s.contains("\n") ?? $s.substr(0, $s.index("\n")) !! $s;
    $l.chars > $max ?? $l.substr(0, $max) ~ '…' !! $l;
}
my sub str-of($v --> Str) { $v ~~ Str ?? $v !! '' }

#| What a run has said so far.  `read` is handed one of these with each
#| line the harness prints, and tells it what the line meant.
class Reading is export {
    has Control $.ctl;
    has @.said;                    # the agent's messages, in order
    has Str $.session = '';        # the harness's own name for this conversation
    has Int $.tokens = 0;
    has Int $.turns = 0;
    has $.usd;                     # undefined until the harness reports money
    has Str $.failure = '';
    has Bool $.finished = False;

    method !emit(Str $kind, %p) { $!ctl.emit.($kind, %p) with $!ctl }

    #| The agent said this.  The last thing said is the run's result.
    method said-text(Str $text) {
        my $t = $text.trim;
        return if $t eq '';
        @!said.push($t);
        self!emit(EVENT-PROGRESS, %( text => cap-tail($t, 500) ));
    }
    #| The agent used a tool: what kind, and on what.
    method tool(Str $tool, Str $target = '') { self!emit(EVENT-TOOL-CALL, %( :$tool, target => first-line($target, 60) )) }
    #| Something worth showing a person that is not the agent speaking.
    method notice(Str $text) { self!emit(EVENT-PROGRESS, %( notice => first-line($text, 160) )) }
    #| The harness's own id for the conversation, so a later attempt can go on with it.
    method session-is(Str $id) { $!session = $id }
    #| Figures the harness reported.  Say only what it said: money never
    #| reported stays unreported, and is never shown as nothing.
    method add-tokens(Int $n) { $!tokens += $n }
    method add-turn() { $!turns++ }
    method cost-usd(Numeric $usd) { $!usd = ($!usd // 0) + $usd }
    #| The harness said it failed, in its own words.
    method failed(Str $why) { $!failure = $why ne '' ?? $why !! 'the harness reported a failure' }
    #| The harness said its turn is over.  Only matters where `needs-finish` is True.
    method finish() { $!finished = True }
}

class CommandHarness does Adapter is export {
    has Str $.binary = '';           # '' means `command`; a test names a stand-in here
    has Numeric $.kill-wait = 15;
    has $.stderr;
    has %.env;                       # replaces the environment when given (tests)

    # ---- what an author says ------------------------------------------------

    my sub unsaid(Str $what) { die "a harness adapter must say its $what" }
    #| Its name in 321: a short lower-case word, as trust files and --harness spell it.
    method name(--> Str) { unsaid('name') }
    #| The command a person would type, as found on PATH.
    method command(--> Str) { unsaid('command') }
    #| Its arguments for one attempt, after the command itself.
    method args(Spec $spec --> List) { unsaid('args') }
    #| What it really enforces: `self.claims(FEAT-..., ...)`.  Nothing, until said.
    method enforcement(--> Hash) { self.claims() }
    #| How its version is asked for.
    method version-argv(--> List) { ('--version',) }
    #| '' when it can run now; else why not, in a few words ("not logged in").
    method ready(Str $path --> Str) { '' }
    #| Where the prompt goes: on standard input (the default, and the safe
    #| one: a prompt on a command line shows in every process list), or as
    #| the last argument.
    method prompt-on-stdin(--> Bool) { True }
    #| One line of what it printed.  By default every line is something the
    #| agent said; a harness that prints events overrides this.
    method read(Str $line, Reading $r) { $r.said-text($line) }
    #| True when a clean exit is not enough and the harness must say its
    #| turn finished (`$r.finish`): a stream that can end early and exit 0.
    method needs-finish(--> Bool) { False }

    # ---- helpers for the author ---------------------------------------------

    #| An enforcement map: the named features True, every other False.
    method claims(*@features --> Hash) {
        my %yes = @features.map({ $_ => True });
        %( features().map({ $_ => so %yes{$_} }) );
    }
    #| The flag and the model for this attempt, or nothing when none is pinned.
    method model-args(Spec $spec, Str $flag --> List) { $spec.model ne '' ?? ($flag, $spec.model) !! () }
    #| The same for an effort setting.
    method effort-args(Spec $spec, Str $flag --> List) { $spec.effort ne '' ?? ($flag, $spec.effort) !! () }

    # ---- the shared half ----------------------------------------------------

    method !bin(--> Str) { $!binary ne '' ?? $!binary !! self.command }
    method executable(--> Str) {
        my $bin = self!bin;
        my $path = $bin.contains('/') ?? ($bin.IO.f ?? $bin.IO !! IO::Path) !! on-path($bin);
        $path.defined ?? $path.Str !! '';
    }
    method command-name(--> Str) { self.command }

    method detect(--> Detection) {
        my $path = self.executable;
        return Detection.new(:reason("{self!bin} is not on PATH")) if $path eq '';
        my $p = try run $path, |self.version-argv, :out, :err;
        return Detection.new(:available, :version<unknown>) if $! || !$p.defined;
        my $out = $p.out.slurp(:close); $p.err.slurp(:close);
        my $version = $p.exitcode == 0 && $out.trim ne '' ?? first-line($out.trim, 80) !! 'unknown';
        my $why = self.ready($path);
        return Detection.new(:$version, :reason($why)) if $why ne '';
        Detection.new(:available, :$version);
    }

    #| What it can be asked for.  The default asks for nothing: no model
    #| or effort is named, and no money is reported.
    method manifest(--> Hash) {
        %( providers => [], access => 'harness', sets-model => False, efforts => [],
           reports => %( usd => False, tokens => False ), spend-cap => False )
    }

    method run(Cancel $cancel, Spec $spec, Control $ctl --> Outcome) {
        my $start = now;
        my @argv = self.args($spec);
        @argv.push($spec.prompt) unless self.prompt-on-stdin;
        my $proc = Proc::Async.new(:w, |launch-argv(self!bin, @argv, %!env, $spec.hook-env));
        my $reading = Reading.new(:$ctl);
        my $err = '';
        my $lock = Lock.new;
        my $me = self;
        $proc.stdout.lines.tap(-> $l { $lock.protect({ try $me.read($l, $reading) }) });
        $proc.stderr.tap(-> $s { $err ~= $s; with $!stderr { .print($s) } });
        my $started = try $proc.start(|($spec.workspace ne '' ?? (:cwd($spec.workspace)) !! ()));
        if $! {
            my $out = Outcome.new;
            $out.status = STATUS-FAILED; $out.end-reason = 'process_failed';
            $out.errors.push("{self.name}: process did not start: {$!.message}");
            return $out;
        }
        try { await $proc.write($spec.prompt.encode) if self.prompt-on-stdin; $proc.close-stdin };
        my $done = Promise.new;
        start { my $r = try await $started; $done.keep($r // Any) }
        await Promise.anyof($done, $cancel.promise);
        unless $done.status ~~ Kept {
            try $proc.kill(SIGTERM);
            await Promise.anyof($done, Promise.in($!kill-wait));
            try $proc.kill(SIGKILL) unless $done.status ~~ Kept;
        }
        my $result = await $done;
        my $exit = $result.defined ?? $result.exitcode !! -1;
        my ($session, $said, $failure, $finished, $tokens, $turns, $usd) =
            $lock.protect({ ($reading.session, $reading.said.List, $reading.failure, $reading.finished, $reading.tokens, $reading.turns, $reading.usd) });
        my $out = Outcome.new(:session-ref($session));
        $out.final-words = cap-tail($said.join("\n\n"), 32 * 1024);
        # Money is the harness's own figure or it is unreported: never a guess.
        $out.cost = $usd.defined
            ?? doc('Cost', usd => $usd, turns => $turns, tokens => $tokens, basis => COST-HARNESS)
            !! doc('Cost', usd => 0, turns => $turns, tokens => $tokens, basis => COST-UNREPORTED);
        # Where the last message is a result document, it is read as one.
        my $doc = $said.elems ?? (try parse-json($said.tail)) !! Any;
        if $doc ~~ Associative {
            $out.summary = str-of($doc<summary>);
            $out.blocked-on = str-of($doc<blocked_on>);
            $out.conditions = [ @($doc<conditions> // []).grep(Associative).map({ %( met => so .<met>, proof => str-of(.<proof>) ) }) ];
        }
        else { $out.summary = first-line(($said.tail // ''), 300) }
        my $ended = $exit == 0 && (!self.needs-finish || $finished);
        if $cancel.done {
            $out.status = STATUS-STOPPED; $out.end-reason = 'cancelled';
            $out.summary = 'stopped before the harness finished' if $out.summary eq '';
        }
        elsif $failure ne '' {
            $out.status = STATUS-FAILED; $out.end-reason = 'harness_error';
            $out.errors.push("{self.name}: $failure");
        }
        elsif !$ended {
            $out.status = STATUS-FAILED; $out.end-reason = $exit != 0 ?? 'process_failed' !! 'no_result';
            $out.errors.push($exit != 0 ?? "exit $exit: " ~ cap-tail($err, 2048) !! 'the harness exited without finishing its turn');
        }
        elsif $doc ~~ Associative && str-of($doc<status>) eq 'blocked' { $out.status = STATUS-BLOCKED; $out.end-reason = 'blocked' }
        elsif $doc ~~ Associative && str-of($doc<status>) eq 'no_change' { $out.status = STATUS-NO-CHANGE; $out.end-reason = 'no_change' }
        else { $out.status = STATUS-COMPLETED; $out.end-reason = 'completed' }
        $ctl.emit.(EVENT-COST, %( turns => $turns, tokens => $tokens, durationMs => ((now - $start) * 1000).Int,
                                  |($usd.defined ?? (usd => $usd) !! ()) ));
        $out;
    }
}
