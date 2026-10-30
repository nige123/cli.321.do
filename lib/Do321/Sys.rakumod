unit module Do321::Sys;

#| The few operating-system facts Mission Control rests on, read from the
#| kernel rather than believed from any file or any model: who a process
#| is (pid, start time, boot), what it descends from, and whether a file
#| is really ours before a word of it is trusted.  Linux first; where
#| /proc is missing every answer is "unknown", never "alive".

use NativeCall;

sub getpid(--> int32) is native {*}
sub getuid(--> uint32) is native {*}
sub c-kill(int32, int32 --> int32) is native is symbol('kill') {*}
sub prctl(int32, uint64, uint64, uint64, uint64 --> int32) is native {*}
sub c-open(Str, int32, uint32 --> int32) is native is symbol('open') {*}
sub c-close(int32 --> int32) is native is symbol('close') {*}
sub c-write(int32, Buf, size_t --> ssize_t) is native is symbol('write') {*}
sub c-read(int32, Buf, size_t --> ssize_t) is native is symbol('read') {*}
sub c-fstat(int32, Buf --> int32) is native is symbol('fstat') {*}
sub c-lstat(Str, Buf --> int32) is native is symbol('lstat') {*}
sub c-rename(Str, Str --> int32) is native is symbol('rename') {*}
sub c-umask(uint32 --> uint32) is native is symbol('umask') {*}
sub c-fsync(int32 --> int32) is native is symbol('fsync') {*}
sub c-statfs(Str, Buf --> int32) is native is symbol('statfs') {*}
sub c-inotify-init1(int32 --> int32) is native is symbol('inotify_init1') {*}
sub c-inotify-add-watch(int32, Str, uint32 --> int32) is native is symbol('inotify_add_watch') {*}
sub c-poll(Buf, uint64, int32 --> int32) is native is symbol('poll') {*}

constant O-RDONLY   = 0;
constant O-WRONLY   = 0o1;
constant O-CREAT    = 0o100;
constant O-EXCL     = 0o200;
constant O-NOFOLLOW = 0o400000;
constant S-IFMT     = 0o170000;
constant S-IFREG    = 0o100000;
constant S-IFDIR    = 0o040000;

constant SIGTERM is export(:sig) = 15;
constant SIGKILL is export(:sig) = 9;

sub my-pid(--> Int) is export { getpid() }

#| Make everything this process and its children create private.
sub private-umask() is export { c-umask(0o077) }
sub my-uid(--> Int) is export { getuid() }

#| Signal a process.  True when the kernel accepted it.
sub send-signal(Int $pid, Int $sig --> Bool) is export {
    return False if $pid <= 1;    # never init, never "every process"
    c-kill($pid, $sig) == 0;
}

#| Become the reaper of every orphan below this process, so a background
#| task that escapes its harness's process group lands here, where it can
#| be found and stopped, rather than with init.
sub become-subreaper(--> Bool) is export { prctl(36, 1, 0, 0, 0) == 0 }

#| The boot this machine is in; a pid from another boot names nothing.
sub boot-id(--> Str) is export { (try '/proc/sys/kernel/random/boot_id'.IO.slurp.trim) // '' }

#| One process as /proc tells it: parent, group, session, start time in
#| clock ticks since boot (field 22, which no pid reuse can repeat within
#| a boot) and state.  Nil when it is gone.
sub proc-stat(Int $pid --> Hash) is export {
    my $s = try "/proc/$pid/stat".IO.slurp;
    return Nil without $s;
    my $close = $s.rindex(')');
    return Nil without $close;
    my @f = $s.substr($close + 2).words;    # field 3 onwards
    return Nil if @f < 20;
    %( pid => $pid, state => @f[0], ppid => @f[1].Int, pgid => @f[2].Int, sid => @f[3].Int, start => @f[19].Int,
       comm => $s.substr($s.index('(') + 1, $close - $s.index('(') - 1) );
}

sub proc-cmdline(Int $pid --> Str) is export {
    my $b = try "/proc/$pid/cmdline".IO.slurp(:bin);
    return '' without $b;
    $b.decode('utf8-c8').subst("\0", ' ', :g).trim;
}

#| Whether the process recorded as (pid, start, boot) is still that very
#| process.  A recycled pid fails the start time; a reboot fails the boot.
sub same-process(Int $pid, Int $start, Str $boot --> Bool) is export {
    return False if $pid <= 1;
    return False if $boot ne '' && $boot ne boot-id();
    my %s = proc-stat($pid) // return False;
    %s<start> == $start && %s<state> ne 'Z';
}

#| Every live process whose parent chain reaches $root, deepest first, so
#| a stop can take children before their parents re-spawn them.
sub descendants(Int $root --> List) is export {
    my %parent;
    for '/proc'.IO.dir -> $d {
        my $n = $d.basename;
        next unless $n ~~ /^ \d+ $/;
        my %s = proc-stat($n.Int) // next;
        next if %s<state> eq 'Z';
        %parent{$n.Int} = %s<ppid>;
    }
    my %depth;
    for %parent.keys -> $p {
        my ($cur, $d) = ($p, 0);
        my %seen;
        while %parent{$cur}:exists && !%seen{$cur}++ {
            $d++;
            if %parent{$cur} == $root { %depth{$p} = $d; last }
            $cur = %parent{$cur};
        }
    }
    %depth.keys.map(*.Int).sort({ %depth{$^b} <=> %depth{$^a} || $^a <=> $^b }).List;
}

#| Write a new file that must not exist yet, never through a symlink, mode
#| 0600, and on disk before it returns.  False when it exists already:
#| the first writer wins.
sub create-exclusive(Str $path, Str $text --> Bool) is export {
    my $fd = c-open($path, O-CREAT +| O-EXCL +| O-WRONLY +| O-NOFOLLOW, 0o600);
    return False if $fd < 0;
    my $b = Buf.new($text.encode('utf-8').list);
    my $ok = c-write($fd, $b, $b.elems) == $b.elems;
    c-fsync($fd);
    c-close($fd);
    $ok;
}

#| Write a new file and fsync it: for a record that must survive a crash
#| of the machine once this returns.  Truncates an existing file.
sub write-synced(Str $path, Str $text --> Bool) is export {
    my $fd = c-open($path, O-CREAT +| O-WRONLY +| O-NOFOLLOW +| 0o1000, 0o600);   # O_TRUNC
    return False if $fd < 0;
    my $b = Buf.new($text.encode('utf-8').list);
    my $ok = c-write($fd, $b, $b.elems) == $b.elems && c-fsync($fd) == 0;
    c-close($fd);
    $ok;
}

#| fsync a directory, so a rename into it is on disk too.
sub sync-dir(Str $path) is export {
    my $fd = c-open($path, O-RDONLY, 0);
    return if $fd < 0;
    c-fsync($fd);
    c-close($fd);
}

#| The filesystem a path is on, when it is one where rename and O_EXCL
#| are not to be trusted across machines: 'nfs', 'smb', 'fuse'; else ''.
sub weak-filesystem(Str $path --> Str) is export {
    my $b = Buf.allocate(128);
    return '' if c-statfs($path, $b) != 0;
    given $b.read-int64(0) {
        when 0x6969     { 'nfs' }
        when 0xFF534D42 | 0x517B | 0xFE534D42 { 'smb' }
        when 0x65735546 { 'fuse' }
        default         { '' }
    }
}

#| A wake-up hint for changes in some directories: inotify where the
#| kernel has it.  wait() returns after a change or the timeout, whichever
#| comes first; it is a hint only, so a reader still compares offsets and
#| sizes, and a missed event costs latency, never data.
class Watch is export {
    has Int $!fd = -1;
    submethod TWEAK() { $!fd = c-inotify-init1(0o4000) }    # IN_NONBLOCK
    method active(--> Bool) { $!fd >= 0 }
    method add(Str $dir --> Bool) {
        return False if $!fd < 0;
        # IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE
        c-inotify-add-watch($!fd, $dir, 0x2 +| 0x8 +| 0x80 +| 0x100 +| 0x200) >= 0;
    }
    #| Wait up to $ms for a change.  True when something changed.
    method wait(Int $ms --> Bool) {
        if $!fd < 0 { sleep $ms / 1000; return False }
        my $p = Buf.allocate(8);
        $p.write-int32(0, $!fd);
        $p.write-int16(4, 1);    # POLLIN
        my $n = c-poll($p, 1, $ms);
        return False if $n <= 0;
        my $drain = Buf.allocate(4096);
        Nil while c-read($!fd, $drain, 4096) > 0;
        True;
    }
    method close() { c-close($!fd) if $!fd >= 0; $!fd = -1 }
}

#| CPU ticks used so far (user + system) and resident memory in bytes,
#| summed over a set of processes.
sub usage-of(@pids --> List) is export {
    my ($ticks, $rss) = 0, 0;
    for @pids -> $pid {
        my $s = try "/proc/$pid/stat".IO.slurp;
        next without $s;
        my @f = $s.substr($s.rindex(')') + 2).words;
        $ticks += @f[11].Int + @f[12].Int;
        $rss += @f[21].Int * 4096;
    }
    ($ticks, $rss);
}

#| The bytes of a file only when it is a regular file, not a symlink,
#| owned by this user and writable by no one else; with :private (the
#| default, for anything that carries a request) readable by no one else.  Returns (text, reason):
#| the reason says why it was not read.
sub read-owned(Str $path, Int :$max = 1_048_576, Bool :$private = True, Bool :$group-ok = False --> List) is export {
    my $fd = c-open($path, O-RDONLY +| O-NOFOLLOW, 0);
    return (Str, 'it is a symlink or cannot be opened') if $fd < 0;
    LEAVE c-close($fd);
    my $st = Buf.allocate(144);
    return (Str, 'it cannot be examined') if c-fstat($fd, $st) != 0;
    my $mode = $st.read-uint32(24);
    return (Str, 'it is not a regular file') if ($mode +& S-IFMT) != S-IFREG;
    return (Str, 'it is owned by another user') if $st.read-uint32(28) != getuid();
    return (Str, 'others may read or write it') if $private && $mode +& 0o077;
    return (Str, 'others may write it') if $mode +& ($group-ok ?? 0o002 !! 0o022);
    my $size = $st.read-int64(48);
    return (Str, 'it is too large') if $size > $max;
    my $buf = Buf.new;
    my $chunk = Buf.allocate(65536);
    loop {
        my $n = c-read($fd, $chunk, 65536);
        last if $n <= 0;
        $buf.append($chunk.subbuf(0, $n));
        return (Str, 'it is too large') if $buf.elems > $max;
    }
    my $text = try $buf.decode('utf-8');
    return (Str, 'it is not UTF-8') without $text;
    ($text, Str);
}

#| Whether a directory is safe to hold control files: a real directory,
#| not a symlink, ours, and writable by no one else.  Returns the reason
#| when it is not, else Str.
sub unsafe-dir(Str $path --> Str) is export {
    my $st = Buf.allocate(144);
    return 'it does not exist' if c-lstat($path, $st) != 0;
    my $mode = $st.read-uint32(24);
    return 'it is a symlink or not a directory' if ($mode +& S-IFMT) != S-IFDIR;
    return 'it is owned by another user' if $st.read-uint32(28) != getuid();
    return 'others may write to it' if $mode +& 0o022;
    Str;
}

#| rename(2): atomic within a filesystem; a reader sees the old file or
#| the new one, never half of either.
sub rename-into(Str $from, Str $to --> Bool) is export { c-rename($from, $to) == 0 }

#| The command that runs this same 321 build again: the compiled binary
#| itself, or the source through the interpreter.  DO_321_BIN overrides.
sub runtime-argv(--> List) is export {
    return (%*ENV<DO_321_BIN>,) if %*ENV<DO_321_BIN>;
    my $exe = $*EXECUTABLE;
    my $prog = $*PROGRAM.absolute.IO;
    # a compiled entry: 321 itself, or one beside it
    if $exe.basename ne 'rakupp' && $exe.basename ne 'raku' && $exe.basename ne 'rakudo' {
        my $sib = $exe.parent.add('321');
        return ($sib.Str,) if $sib.x;
        return ('321',);
    }
    my $root = $prog.parent.parent;
    ($exe.Str, '-I', $root.add('lib').Str, $root.add('bin/321').Str);
}

#| The command that runs this 321 again as a run's host.
sub mission-argv(--> List) is export {
    return (%*ENV<DO_321_MC_BIN>,) if %*ENV<DO_321_MC_BIN>;
    my $exe = $*EXECUTABLE;
    return ($exe.Str,) if $exe.basename ne 'rakupp' && $exe.basename ne 'raku' && $exe.basename ne 'rakudo';
    my $prog = $*PROGRAM.absolute.IO;
    my $root = $prog.parent.parent;
    ($exe.Str, '-I', $root.add('lib').Str, $root.add('bin/321').Str);
}
