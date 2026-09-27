unit module Do321::Async;

#| The two concurrency primitives the runtime is built on, standing in for
#| Go's context and channels.
#|
#| A Cancel is a cancellation scope: a promise that is kept once, with a
#| reason ('cancelled' or 'deadline'), and children that follow their
#| parent.  A Mailbox is an ordered queue with an optional capacity: senders
#| may block or refuse when it is full, receivers wait for an item, a close
#| or a cancellation, and nothing is ever lost or delivered twice.

#| A cancellation scope.
class Cancel is export {
    has Promise $.promise = Promise.new;
    has Str $.reason = '';
    has Lock $!lock = Lock.new;
    has Cancel $.parent;

    submethod TWEAK() {
        with $!parent {
            my $self = self;
            $!parent.promise.then({ $self.cancel($!parent.reason) });
        }
    }

    method cancel(Str $why = 'cancelled') {
        $!lock.protect({
            unless $!promise.status ~~ Kept {
                $!reason = $why;
                $!promise.keep(True);
            }
        });
        self;
    }

    #| True once cancelled.
    method done(--> Bool) { $!promise.status ~~ Kept }

    #| 'cancelled', 'deadline', or '' while live.
    method err(--> Str) { self.done ?? $!reason !! '' }

    method deadline-exceeded(--> Bool) { self.done && $!reason eq 'deadline' }

    #| A child scope: cancelled when this one is, or on its own.
    method child(--> Cancel) { Cancel.new(:parent(self)) }

    #| A child scope that also cancels itself after $seconds.
    method with-timeout(Numeric $seconds --> Cancel) {
        my $c = self.child;
        Promise.in($seconds).then({ $c.cancel('deadline') });
        $c;
    }

    #| A scope that is never cancelled.
    method background(--> Cancel) { Cancel.new }

    #| Wait for this scope or the given promise, whichever first; True
    #| when the promise won.
    method wait-for(Promise $p --> Bool) {
        await Promise.anyof($!promise, $p);
        $p.status ~~ Kept && !self.done || $p.status ~~ Kept;
    }

    #| Sleep, returning early (False) if cancelled.
    method sleep(Numeric $seconds --> Bool) {
        return False if self.done;
        my $t = Promise.in($seconds);
        await Promise.anyof($!promise, $t);
        $t.status ~~ Kept;
    }
}

#| An ordered queue.
class Mailbox is export {
    has Int $.capacity = 0;          # 0: unbounded
    has @!items;
    has Bool $!closed = False;
    has Lock $!lock = Lock.new;
    has Promise $!arrived = Promise.new;   # kept when an item lands or the box closes
    has Promise $!room = Promise.new;      # kept when space frees up

    method !signal-arrived() { my $p = $!arrived; $!arrived = Promise.new; $p.keep(True) }
    method !signal-room()    { my $p = $!room;    $!room    = Promise.new; $p.keep(True) }

    #| Queue an item.  With a capacity, waits for room; returns False if
    #| the box is closed or the wait was cancelled.
    method send($item, Cancel :$cancel --> Bool) {
        loop {
            my ($ok, $wait);
            $!lock.protect({
                if $!closed { $ok = False }
                elsif $!capacity == 0 || @!items < $!capacity {
                    @!items.push($item);
                    self!signal-arrived;
                    $ok = True;
                }
                else { $wait = $!room }
            });
            return $ok if $ok.defined;
            if $cancel { await Promise.anyof($cancel.promise, $wait); return False if $cancel.done }
            else { await $wait }
        }
    }

    #| Queue an item only if there is room; False otherwise.
    method try-send($item --> Bool) {
        my $ok = False;
        $!lock.protect({
            if !$!closed && !($!capacity && @!items >= $!capacity) {
                @!items.push($item);
                self!signal-arrived;
                $ok = True;
            }
        });
        $ok;
    }

    #| Take the next item without waiting; Nil when there is none.
    method poll() {
        my $x;
        $!lock.protect({
            if @!items { $x = @!items.shift; self!signal-room }
        });
        $x // Nil;
    }

    #| Take the next item, waiting for one; Nil once the box is closed and
    #| empty, or when the wait is cancelled.
    method receive(Cancel :$cancel) {
        loop {
            my ($item, $wait, $ended);
            $!lock.protect({
                if @!items { $item = @!items.shift; self!signal-room }
                elsif $!closed { $ended = True }
                else { $wait = $!arrived }
            });
            return $item if $item.defined;
            return Nil if $ended;
            if $cancel { await Promise.anyof($cancel.promise, $wait); return Nil if $cancel.done }
            else { await $wait }
        }
    }

    #| No more items will be sent.  Receivers drain what is queued.
    method close() {
        $!lock.protect({
            $!closed = True;
            self!signal-arrived;
            self!signal-room;
        });
        self;
    }

    method closed(--> Bool) { $!lock.protect({ $!closed }) }
    method elems(--> Int) { $!lock.protect({ @!items.elems }) }
}
