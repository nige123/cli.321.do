unit module Do321::RunDir;

#| One directory per run, one writer per file.  Processes do the work,
#| files carry the messages, Mission Control presents the state.
#|
#|   run.json        what was launched              launcher, once
#|   work-package.json  the package as issued       launcher, once
#|   host.json       who is running it              host, once
#|   live            empty; exists from host start until the end is written
#|   events.jsonl    what happened, in order        host only, appended
#|   status.json     latest folded state            host, atomic replace
#|   inbox/          requests to the run            any client, one file each
#|   receipt.json    what the runtime attests       the runtime, once
#|   ended.json      an end the host could not record, with its basis
#|
#| The event log is the history, the receipt is the outcome, and the
#| kernel is liveness: a status file is a cache and never proof.

use Do321::JSON;
use Do321::Protocol;
use Do321::Sys;

constant SCHEMA-RUN       is export = '321-run/1';
constant SCHEMA-HOST      is export = '321-host/1';
constant SCHEMA-STATUS    is export = '321-status/1';
constant SCHEMA-DIRECTIVE is export = '321-directive/1';
constant SCHEMA-ENDED     is export = '321-ended/1';

#| What a client may ask of a run through its inbox.  None of them can
#| grant, approve or widen anything (authority-is-intersection.cli.321.do):
#| an approval or a grant has no kind here, so no file can carry one.
constant INBOX-KINDS is export = <steer clarify hold resume stop>;

#| A run's place in its life.  The outcome, once there is one, is the
#| receipt's word, or lost when the run ended and nobody knows how.
constant PHASES is export = <starting running blocked held stopping ended lost>;

#| How old a heartbeat may be before a living host is called quiet.
constant HEARTBEAT-STALE is export = 10;

#| A run id is a ULID: 26 characters of Crockford base32.  Nothing else
#| ever becomes a path.
sub valid-run-id(Str $id --> Bool) is export { so $id ~~ /^ <[0..9 A..H J K M N P..T V..Z]> ** 26 $/ }

sub home-dir(--> IO::Path) is export {
    %*ENV<DO_321_HOME> ?? %*ENV<DO_321_HOME>.IO !! $*HOME.add('.321');
}

sub runs-root(IO::Path $home = home-dir() --> IO::Path) is export { $home.add('runs') }

#| What a person can do about a directory refused as unsafe, in one clause.
sub remedy(IO::Path $d, Str $why --> Str) is export {
    $why eq 'others may write to it' ?? "; chmod go-w {$d} makes it yours alone" !! '';
}

#| Make a directory that holds control files: 0700, and refuse to use one
#| that is a symlink, someone else's, or writable by others.
sub private-dir(IO::Path $d --> IO::Path) is export {
    unless $d.e {
        mkdir-p($d);
        $d.chmod(0o700);
    }
    with unsafe-dir($d.Str) { die "$d is not safe to use: $_" ~ remedy($d, $_) }
    $d;
}

#| Write a file whole and atomically: readers see the old one or the new.
#| With :durable it is on disk before this returns (a launch record, the
#| host's identity), so a crash of the machine cannot leave half of it.
sub write-atomic(IO::Path $p, Str $text, Bool :$durable = False) is export {
    my $tmp = $p.parent.add(".{$p.basename}.{my-pid()}.tmp");
    if $durable { write-synced($tmp.Str, $text) or die "could not write $tmp" }
    else { $tmp.spurt($text) }
    $tmp.chmod(0o600);
    rename-into($tmp.Str, $p.Str) or die "could not replace $p";
    sync-dir($p.parent.Str) if $durable;
}

#| A record the host or the runtime wrote: ours, not a symlink, writable
#| by no one else.  (The inbox, which carries requests, is stricter.)
#| A receipt from a run a terminal held may be group-writable (the
#| runtime keeps the caller's umask); :group-ok accepts that for display.
sub read-json-file(IO::Path $p, Bool :$group-ok = False --> Any) is export {
    my ($text, $why) = read-owned($p.Str, :!private, :$group-ok);
    return Nil without $text;
    try parse-json($text);
}

class RunDir is export {
    has IO::Path $.dir;

    method id(--> Str) { $!dir.basename }
    method short(--> Str) { $!dir.basename.substr(*-3) }
    method run-file    { $!dir.add('run.json') }
    method package-file { $!dir.add('work-package.json') }
    method host-file   { $!dir.add('host.json') }
    method live-file   { $!dir.add('live') }
    method events-file { $!dir.add('events.jsonl') }
    method status-file { $!dir.add('status.json') }
    method inbox       { $!dir.add('inbox') }
    method receipt-file { $!dir.add('receipt.json') }
    method ended-file  { $!dir.add('ended.json') }
    method log-file    { $!dir.add('host.log') }

    method run(--> Hash)     { (read-json-file(self.run-file) // {}).Hash }
    method host(--> Hash)    { (read-json-file(self.host-file) // {}).Hash }
    method status(--> Hash)  { (read-json-file(self.status-file) // {}).Hash }
    method receipt(--> Hash) { (read-json-file(self.receipt-file, :group-ok(!self.hosted)) // {}).Hash }
    method ended(--> Hash)   { (read-json-file(self.ended-file) // {}).Hash }

    #| Whether this directory is a run Mission Control launched (it has a
    #| run.json), as opposed to a run a terminal held in the foreground.
    method hosted(--> Bool) { self.run-file.e }
}

#| A run directory by id, refusing anything that is not a ULID.
sub run-dir(Str $id, IO::Path $home = home-dir() --> RunDir) is export {
    die "'$id' is not a run id" unless valid-run-id($id);
    RunDir.new(:dir(runs-root($home).add($id)));
}

#| Every run directory under the home, newest first (ULIDs sort by time).
sub all-runs(IO::Path $home = home-dir() --> List) is export {
    my $root = runs-root($home);
    return () unless $root.d;
    $root.dir.grep({ valid-run-id(.basename) && .d }).sort({ $^b.basename cmp $^a.basename }).map({ RunDir.new(:dir($_)) }).List;
}

#| A run named by a person: the whole id, or an unambiguous ending of it
#| (the deck shows the last three characters).  Returns (RunDir, error).
sub find-run(Str $name, IO::Path $home = home-dir() --> List) is export {
    my $n = $name.uc;
    return (run-dir($n, $home), Str) if valid-run-id($n) && runs-root($home).add($n).d;
    return (RunDir, "'$name' is not a run id or the end of one") unless $n ~~ /^ <[0..9 A..Z]> ** 3..26 $/;
    my @m = all-runs($home).grep({ .id.ends-with($n) });
    return (RunDir, "no run here ends in $n") unless @m;
    return (RunDir, "{@m.elems} runs end in $n; give more of the id: {@m.map(*.id).join(', ')}") if @m > 1;
    (@m[0], Str);
}

# ------------------------------------------------------------ the inbox

#| Ask something of a run: write the directive whole in inbox/.tmp, then
#| rename it in, so the host never reads half a file.  Returns the
#| directive id, the key that makes a retry harmless.
sub send-directive(RunDir $r, Str $kind, Str :$text = '', Str :$reason = '', Str :$client = 'mission-control', Str :$id = new-ulid() --> Str) is export {
    die "a run can be asked to {INBOX-KINDS.join(', ')}; not '$kind'" unless $kind (elem) INBOX-KINDS;
    die "a $kind needs words" if $kind eq 'steer' | 'clarify' && $text.trim eq '';
    my $inbox = $r.inbox;
    die "run {$r.id} has no inbox; it has not started" unless $inbox.d;
    my $tmpd = private-dir($inbox.add('.tmp'));
    my %d = schema => SCHEMA-DIRECTIVE, directiveId => $id, runId => $r.id, kind => $kind, text => $text, reason => $reason,
        from => { client => $client, uid => my-uid(), tty => (%*ENV<SSH_TTY> // '') }, sentAt => now-stamp();
    my $tmp = $tmpd.add("$id.json");
    create-exclusive($tmp.Str, encode-json(%d) ~ "\n") or die "directive $id was already sent";
    rename-into($tmp.Str, $inbox.add("$id-$kind.json").Str) or die "could not deliver $id to run {$r.id}";
    $id;
}

#| The host's side: every directive waiting, in the order sent, each
#| either accepted (a hash) or refused (a reason), and moved out of the
#| inbox so it is taken once.  A file is believed only when it is ours,
#| a regular file, private, well formed and addressed to this run.
sub take-inbox(RunDir $r --> List) is export {
    my $inbox = $r.inbox;
    return () unless $inbox.d;
    my $done = private-dir($inbox.add('done'));
    my $rejected = private-dir($inbox.add('rejected'));
    my @out;
    for $inbox.dir.grep({ .basename ~~ /^ <[0..9 A..Z]> ** 26 '-' <[a..z]>+ '.json' $/ }).sort(*.basename) -> $f {
        my $name = $f.basename;
        my ($text, $why) = read-owned($f.Str, :max(65536));
        my %d;
        my $reason = $why;
        without $reason {
            my $data = try parse-json($text);
            if $data !~~ Associative { $reason = 'it is not a JSON object' }
            else {
                %d = $data.Hash;
                my $fid = $name.substr(0, 26);
                $reason = do {
                    if (%d<schema> // '') ne SCHEMA-DIRECTIVE { "its schema is not {SCHEMA-DIRECTIVE}" }
                    elsif (%d<directiveId> // '') ne $fid { 'its id does not match its file name' }
                    elsif (%d<runId> // '') ne $r.id { "it is addressed to run {%d<runId> // 'none'}, not {$r.id}" }
                    elsif !((%d<kind> // '') (elem) INBOX-KINDS) { "a run cannot be asked to '{%d<kind> // ''}' through its inbox" }
                    elsif %d<kind> eq 'steer' | 'clarify' && (%d<text> // '').trim eq '' { 'a steer needs words' }
                    else { Str }
                };
            }
        }
        my $to = ($reason.defined ?? $rejected !! $done).add($name);
        rename-into($f.Str, $to.Str) or try $f.unlink;
        @out.push($reason.defined ?? %( file => $name, refused => $reason, directiveId => $name.substr(0, 26) ) !! %( directive => %d ));
    }
    @out.List;
}

# ------------------------------------------------------------ the event log

#| The host's append-only log: one line per event, one write per line, a
#| sequence number with no gaps.  Only the host holds one.
class EventLog is export {
    has IO::Path $.path;
    has Int $.seq = 0;
    has $!h;
    has Lock $!mu = Lock.new;

    submethod TWEAK() {
        # a host that restarts on an existing log continues its sequence
        if $!path.e {
            for $!path.slurp.lines -> $l {
                my $e = try parse-json($l);
                $!seq = $e<seq> if $e ~~ Associative && ($e<seq> // 0) > $!seq;
            }
        }
        $!h = $!path.open(:a);
        $!path.chmod(0o600);
    }

    method append(Str $src, Str $kind, %payload, Str :$at = now-stamp() --> Hash) {
        $!mu.protect({
            $!seq++;
            my %e = seq => $!seq, at => $at, src => $src, kind => $kind, payload => %payload;
            $!h.print(encode-json(%e) ~ "\n");
            $!h.flush;
            %e;
        });
    }

    method close() { $!mu.protect({ try $!h.close }) }
}

#| A reader's view of a log: everything after the saved byte offset,
#| complete lines only.  A line still being written stays unread until
#| its newline arrives; it is never parsed in halves.
class EventTail is export {
    has IO::Path $.path;
    has Int $.offset = 0;
    has Int $.last-seq = 0;
    has Int $.missed = 0;

    method poll(--> List) {
        return () unless $!path.e;
        my $size = $!path.s;
        return () if $size <= $!offset;
        my $h = $!path.open(:r, :bin);
        $h.seek($!offset, SeekFromBeginning);
        my $b = $h.read($size - $!offset);
        $h.close;
        my $nl = -1;
        for ($b.elems - 1) ... 0 -> $i { if $b[$i] == 10 { $nl = $i; last } }
        return () if $nl < 0;
        my $text = $b.subbuf(0, $nl + 1).decode('utf8-c8');
        $!offset += $nl + 1;
        my @ev;
        for $text.lines -> $l {
            next if $l.trim eq '';
            my $e = try parse-json($l);
            next unless $e ~~ Associative;
            my $s = $e<seq> // 0;
            next if $s <= $!last-seq;              # already seen
            $!missed += $s - $!last-seq - 1 if $!last-seq > 0 && $s > $!last-seq + 1;
            $!last-seq = $s;
            @ev.push($e.Hash);
        }
        @ev.List;
    }
}

# ------------------------------------------------------------ liveness

#| Where a run stands, from evidence only:
#|   ended    a receipt, or an ended.json, exists (the receipt wins)
#|   running  the host recorded in host.json is that very process still
#|   starting launched moments ago and the host has not said who it is
#|   lost     no receipt, and the host is gone or was never born
#| Returns a hash: phase, why, and the outcome when ended.
sub liveness(RunDir $r, Int :$grace = 15 --> Hash) is export {
    if $r.receipt-file.e {
        my %rc = $r.receipt;
        my %l = phase => 'ended', outcome => outcome-word(%rc<status> // ''), why => 'the receipt', receipt => %rc;
        # The live marker outlasting a dead host means the host never swept
        # what the agent may have left running.
        if $r.live-file.e {
            my %h = $r.host;
            unless %h && same-process(%h<pid>.Int, %h<startTicks>.Int, %h<bootId> // '') {
                %l<unswept> = True;
                %l<why> = 'the receipt; its host died before checking for anything left running';
            }
        }
        return %l;
    }
    if $r.ended-file.e {
        my %e = $r.ended;
        return %( phase => 'ended', outcome => 'lost', why => (%e<basis><summary> // 'ended.json'), ended => %e );
    }
    my %h = $r.host;
    unless %h {
        my %run = $r.run;
        my $age = run-age(%run<launchedAt> // '');
        return %( phase => 'starting', why => 'the host has not started yet' ) if $age.defined && $age < $grace;
        return %( phase => 'lost', why => 'no host ever started for it' );
    }
    if same-process(%h<pid>.Int, %h<startTicks>.Int, %h<bootId> // '') {
        return %( phase => 'running', why => "host {%h<pid>} is alive", host => %h );
    }
    my $why = (%h<bootId> // '') ne boot-id() ?? 'the machine restarted since it began' !! "host {%h<pid>} is gone";
    %( phase => 'lost', why => "$why and left no receipt", host => %h );
}

sub run-age(Str $iso --> Real) {
    return Nil if $iso eq '';
    my $t = try DateTime.new($iso);
    return Nil without $t;
    now - $t.Instant;
}

#| The receipt's status in the outcome vocabulary a person reads:
#| done, no_change, blocked, denied, failed, stopped (and lost).
sub outcome-word(Str $status --> Str) is export {
    given $status {
        when 'completed' { 'done' }
        when ''          { '' }
        default          { $status }
    }
}

#| Record that a run ended without a receipt, with the basis for saying
#| so.  It states what was observed and names no outcome beyond lost; it
#| never writes over a receipt, and the first writer wins.
sub record-ended(RunDir $r, %basis --> Bool) is export {
    return False if $r.receipt-file.e;
    my %e = schema => SCHEMA-ENDED, runId => $r.id, outcome => 'lost', recordedAt => now-stamp(), recordedBy => my-pid(),
        basis => %basis;
    my $ok = create-exclusive($r.ended-file.Str, encode-json-pretty(%e) ~ "\n");
    try $r.live-file.unlink if $ok;
    $ok;
}
