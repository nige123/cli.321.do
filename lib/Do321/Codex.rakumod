unit module Do321::Codex;

#| Drives OpenAI's `codex` CLI non-interactively (`codex exec --json`).
#|
#| What it enforces, and how; checked against codex-cli 0.164.0 on Linux:
#|   network_deny       the sandbox: in read-only and workspace-write a
#|                      command cannot resolve or reach a host (tried with
#|                      `codex sandbox`)
#|   structured_output  --output-schema FILE; the last agent message is
#|                      the document
#|   timeout            the runner's cancellation plus SIGTERM
#|   event_stream       --json is read line by line
#|   session_continue   `codex exec resume <thread>` on a later attempt
#|   graceful_stop      SIGTERM, then SIGKILL after a wait
#| What it does not enforce, and says so: tool_allowlist (it has a
#| sandbox, not a list of tools), turn_limit, spend_limit, repo_scope
#| (writes are confined to the workspace, reads are not), live_steer,
#| pause.
#|
#| Its sandbox limits what a command's effects can reach; it does not
#| limit which tools the agent uses.  Its own web search and any MCP
#| servers in the user's Codex config run outside the sandbox, so the
#| sandbox is not a tool allowlist and is not offered as one.
#| codex-sandbox() and confines() say which sandbox matches a grant set,
#| for a per-grant enforcement model if one is agreed; selection does not
#| use them.

use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Async;
use Do321::Tool;
use Do321::Adapter;

#| The sandbox that confines a grant set exactly, or '' when none does.
sub codex-sandbox(@grants --> Str) is export {
    my %g = @grants.map({ $_ => True });
    return '' unless %g{CAP-SHELL-RUN};
    return '' if %g{CAP-NET-FETCH};             # its sandbox has no network to grant
    my @known = CAP-REPO-READ, CAP-REPO-WRITE, CAP-FILES-READ, CAP-FILES-WRITE, CAP-SHELL-RUN, CAP-MODEL-TEXT;
    return '' if %g.keys.grep({ $_ !(elem) @known });
    %g{CAP-REPO-WRITE} || %g{CAP-FILES-WRITE} ?? 'workspace-write' !! 'read-only';
}

sub str-of($v --> Str) { $v ~~ Str ?? $v !! '' }

sub first-line(Str $s, Int $max --> Str) {
    my $l = $s.contains("\n") ?? $s.substr(0, $s.index("\n")) !! $s;
    $l.chars > $max ?? $l.substr(0, $max) ~ '…' !! $l;
}

#| Reads `codex exec --json`, one line at a time, into 321's events.
class CodexStream is export {
    has Control $.ctl;
    has Str $.thread = '';
    has @.said;                  # the agent's messages, in order
    has Int $.tokens = 0;
    has Int $.turns = 0;
    has Str $.failure = '';      # turn.failed, or a final error
    has Bool $.completed = False;
    has @.notices;

    method !emit(Str $kind, %p) { $!ctl.emit.($kind, %p) with $!ctl }

    method line(Str $line) {
        return if $line.trim eq '';
        my $ev = try parse-json($line);
        return if $! || $ev !~~ Associative;
        given str-of($ev<type>) {
            when 'thread.started' { $!thread = str-of($ev<thread_id>) }
            when 'turn.started'   { $!turns++ }
            when 'turn.completed' {
                $!completed = True;
                my $u = $ev<usage>;
                if $u ~~ Associative {
                    $!tokens += ($u<input_tokens> // 0).Int + ($u<output_tokens> // 0).Int;
                }
            }
            when 'turn.failed' {
                $!failure = str-of(($ev<error> // {})<message>) || 'the turn failed';
            }
            when 'error' {
                # Codex says when it retries; that is a notice, not the end
                my $m = str-of($ev<message>);
                @!notices.push($m);
                self!emit(EVENT-PROGRESS, %( notice => first-line($m, 160) ));
            }
            when 'item.started' { self!item($ev<item>, :started) }
            when 'item.completed' { self!item($ev<item>) }
        }
    }

    method !item($item, Bool :$started = False) {
        return unless $item ~~ Associative;
        given str-of($item<type>) {
            when 'command_execution' {
                if $started {
                    self!emit(EVENT-TOOL-CALL, %( tool => 'shell', target => first-line(str-of($item<command>), 60) ));
                }
                elsif ($item<exit_code> // 0) ~~ Numeric && ($item<exit_code> // 0) != 0 {
                    self!emit(EVENT-TOOL-RESULT, %( tool => 'shell', ok => False, exitCode => $item<exit_code> ));
                }
            }
            when 'file_change' {
                return if $started;
                my @paths = @($item<changes> // []).grep(Associative).map({ str-of(.<path>).IO.basename });
                self!emit(EVENT-TOOL-CALL, %( tool => 'edit', target => @paths.join(', ') ));
            }
            when 'mcp_tool_call' {
                return if $started;
                self!emit(EVENT-TOOL-CALL, %( tool => "{str-of($item<server>)}.{str-of($item<tool>)}", target => '' ));
            }
            when 'web_search' {
                return if $started;
                self!emit(EVENT-TOOL-CALL, %( tool => 'web_search', target => first-line(str-of($item<query>), 60) ));
            }
            when 'agent_message' {
                return if $started;
                my $t = str-of($item<text>).trim;
                if $t ne '' {
                    @!said.push($t);
                    self!emit(EVENT-PROGRESS, %( text => cap-tail($t, 500) ));
                }
            }
            when 'error' {
                return if $started;
                self!emit(EVENT-PROGRESS, %( notice => first-line(str-of($item<message>), 160) ));
            }
        }
    }
}

class Codex does Adapter is export {
    has Str $.binary = '';           # '' means "codex"; DO_321_CODEX_BINARY sets it
    has Numeric $.kill-wait = 15;
    has $.stderr;
    has %.env;                       # replaces the environment when given (tests)

    method name(--> Str) { 'codex' }

    method !binary(--> Str) { $!binary ne '' ?? $!binary !! 'codex' }

    method detect(--> Detection) {
        my $bin = self!binary;
        my $path = $bin.contains('/') ?? ($bin.IO.f ?? $bin.IO !! IO::Path) !! on-path($bin);
        return Detection.new(:reason("$bin is not on PATH")) without $path;
        my $p = try run $path.Str, '--version', :out, :err;
        return Detection.new(:available, :version<unknown>) if $! || !$p.defined;
        my $out = $p.out.slurp(:close); $p.err.slurp(:close);
        my $version = $p.exitcode == 0 ?? $out.trim !! 'unknown';
        # without a login every turn fails at the provider: not available
        my $l = try run $path.Str, 'login', 'status', :out, :err;
        if $l.defined {
            $l.out.slurp(:close); $l.err.slurp(:close);
            return Detection.new(:$version, :reason("not logged in")) if $l.exitcode != 0;
        }
        Detection.new(:available, :$version);
    }

    method enforcement(--> Hash) {
        %( FEAT-NETWORK-DENY, True, FEAT-STRUCTURED-OUTPUT, True, FEAT-TIMEOUT, True, FEAT-EVENT-STREAM, True,
           FEAT-SESSION-CONTINUE, True, FEAT-GRACEFUL-STOP, True,
           FEAT-TOOL-ALLOWLIST, False, FEAT-TURN-LIMIT, False, FEAT-SPEND-LIMIT, False,
           FEAT-REPO-SCOPE, False, FEAT-LIVE-STEER, False, FEAT-PAUSE, False );
    }

    #| Whether its sandbox holds the agent to exactly these grants.
    method confines(@grants --> Bool) { codex-sandbox(@grants) ne '' }

    #| The invocation, without a process, so it can be tested.  The prompt
    #| goes on standard input ('-'), never on the command line.
    method args(Spec $spec, Str :$schema-file = '' --> List) {
        my $sandbox = codex-sandbox($spec.grants) || 'read-only';
        my @common = '--json', '-c', 'approval_policy="never"', '-c', "sandbox_mode=\"$sandbox\"",
                     '-c', 'sandbox_workspace_write.network_access=false';
        @common.push('--output-schema', $schema-file) if $schema-file ne '';
        @common.push('--skip-git-repo-check') if $spec.workspace eq '' || !$spec.workspace.IO.add('.git').e;
        with $spec.overlay {
            my $o = try parse-json($_);
            @common.push('--model', $o<model>) if !$! && $o ~~ Associative && $o<model> ~~ Str && $o<model> ne '';
        }
        $spec.session-ref ne ''
            ?? ('exec', 'resume', |@common, $spec.session-ref, '-').List
            !! ('exec', |@common, '-').List;
    }

    method run(Cancel $cancel, Spec $spec, Control $ctl --> Outcome) {
        my $start = now;
        my $schema-file = '';
        if $spec.output-schema ne '' {
            $schema-file = $*TMPDIR.add("321-codex-schema-{$*PID}-{now.Num.Int}-{(^1e6).pick}.json").Str;
            $schema-file.IO.spurt($spec.output-schema);
        }
        LEAVE { try $schema-file.IO.unlink if $schema-file ne '' }
        my $proc = Proc::Async.new(:w, |launch-argv(self!binary, self.args($spec, :$schema-file), %!env, $spec.hook-env));
        my $stream = CodexStream.new(:$ctl);
        my $err = '';
        my $lock = Lock.new;
        $proc.stdout.lines.tap(-> $l { $lock.protect({ $stream.line($l) }) });
        $proc.stderr.tap(-> $s { $err ~= $s; with $!stderr { .print($s) } });
        my $started = try $proc.start(|($spec.workspace ne '' ?? (:cwd($spec.workspace)) !! ()));
        if $! {
            my $out = Outcome.new;
            $out.status = STATUS-FAILED; $out.end-reason = 'process_failed';
            $out.errors.push("codex: process did not start: {$!.message}");
            return $out;
        }
        try { await $proc.write($spec.prompt.encode); $proc.close-stdin };
        my $done = Promise.new;
        start { my $r = try await $started; $done.keep($r // Any) }
        await Promise.anyof($done, $cancel.promise);
        unless $done.status ~~ Kept {
            try $proc.kill(SIGTERM);
            await Promise.anyof($done, Promise.in($!kill-wait));
            try $proc.kill(SIGKILL) unless $done.status ~~ Kept;
            await $done;
        }
        my $result = await $done;
        my $exit = $result.defined ?? $result.exitcode !! -1;
        my ($thread, $said, $failure, $completed, $tokens, $turns) =
            $lock.protect({ ($stream.thread, $stream.said.List, $stream.failure, $stream.completed, $stream.tokens, $stream.turns) });
        my $out = Outcome.new(:session-ref($thread));
        $out.final-words = cap-tail($said.join("\n\n"), 32 * 1024);
        # Codex reports tokens, not money: the cost says so.
        $out.cost = doc('Cost', usd => 0, turns => $turns, tokens => $tokens, basis => COST-UNREPORTED);
        # The last message is the structured result when a schema was asked for.
        my $doc = $said.elems ?? (try parse-json($said.tail)) !! Any;
        if $doc ~~ Associative {
            $out.summary = str-of($doc<summary>);
            $out.blocked-on = str-of($doc<blocked_on>);
            $out.conditions = [ @($doc<conditions> // []).grep(Associative).map({ %( met => so .<met>, proof => str-of(.<proof>) ) }) ];
        }
        else { $out.summary = first-line(($said.tail // ''), 300) }
        if $cancel.done {
            $out.status = STATUS-STOPPED; $out.end-reason = 'cancelled';
            $out.summary = 'stopped before the harness finished' if $out.summary eq '';
        }
        elsif $failure ne '' {
            $out.status = STATUS-FAILED; $out.end-reason = 'harness_error';
            $out.errors.push("codex: $failure");
        }
        elsif !$completed {
            $out.status = STATUS-FAILED; $out.end-reason = $exit != 0 ?? 'process_failed' !! 'no_result';
            $out.errors.push($exit != 0 ?? "exit $exit: " ~ cap-tail($err, 2048) !! 'the harness exited without finishing its turn');
        }
        elsif $doc ~~ Associative && str-of($doc<status>) eq 'blocked' { $out.status = STATUS-BLOCKED; $out.end-reason = 'blocked' }
        elsif $doc ~~ Associative && str-of($doc<status>) eq 'no_change' { $out.status = STATUS-NO-CHANGE; $out.end-reason = 'no_change' }
        else { $out.status = STATUS-COMPLETED; $out.end-reason = 'completed' }
        $ctl.emit.(EVENT-COST, %( turns => $turns, tokens => $tokens, durationMs => ((now - $start) * 1000).Int ));
        $out;
    }
}
