unit module Do321::TuiLog;

#| Mission Control's own record of a session: every key and where it went,
#| every line sent, everything the screen said back, and any error with
#| its backtrace, so a report of "it did something odd" can be read back
#| rather than guessed at.
#|
#| A single typed character is logged as 'typed', never itself: a line in
#| progress may be anything.  A line sent is logged whole, as the run's own
#| inbox already holds it.  The file is the person's alone (0600, in a
#| 0700 directory), and starts again past LOG-MAX bytes, keeping one before.

use Do321::Protocol;

constant LOG-MAX = 1_000_000;

sub tui-log-path(--> IO::Path) is export {
    return %*ENV<DO_321_TUI_LOG>.IO if %*ENV<DO_321_TUI_LOG>;
    (%*ENV<DO_321_HOME> ?? %*ENV<DO_321_HOME>.IO !! $*HOME.add('.321')).add('logs').add('tui.log');
}

class TuiLog is export {
    has IO::Path $.path = tui-log-path();
    has $!fh;
    has Lock $!mu = Lock.new;

    method open(--> TuiLog) {
        try {
            mkdir-private($!path.parent);
            if $!path.e && $!path.s > LOG-MAX { $!path.rename($!path.Str ~ '.1') }
            $!fh = $!path.open(:a);
            $!path.chmod(0o600);
        }
        self;
    }

    #| One line: when, which session, what.  Never throws: a log that
    #| cannot be written is no reason to stop a person working.
    method note(Str $what) {
        $!mu.protect({
            try {
                # a backtrace keeps its lines, indented under the one that has the time
                .say(DateTime.now(:timezone(0)).Str.substr(0, 23) ~ " [{$*PID}] " ~ $what.trim-trailing.subst("\n", "\n    ", :g)) with $!fh;
                .flush with $!fh;
            }
        });
    }

    method close() { $!mu.protect({ try { .close with $!fh }; $!fh = Nil }) }
}
