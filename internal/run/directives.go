package run

import (
	"context"
	"fmt"
	"sort"
	"sync"

	"cli.321.do/internal/adapter"
	"cli.321.do/internal/protocol"
)

// Attempt boundaries the runner forces for adapters that cannot act live.
const (
	boundaryNone  = ""
	boundarySteer = "steer"
	boundaryPause = "pause"
)

// directiveState is the ordered intake of directives for one run.
//
// Ordinary directives are applied strictly in sequence: a directive whose
// predecessor has not arrived waits, and is rejected at the end of the run
// if the gap never fills. Stop bypasses the order: it is applied as soon as
// it is authenticated, the gap is recorded, and nothing that is waiting on
// stdout, a full buffer or a slow adapter can hold it up, because stopping
// is a context cancellation and not an event.
type directiveState struct {
	s *session

	mu           sync.Mutex
	seenID       map[string]bool
	seenSeq      map[int]string
	all          map[string]protocol.WorkDirective
	nextSeq      int
	waiting      map[int]protocol.WorkDirective
	instrQueue   []protocol.WorkDirective // received, not yet applied (runner-level)
	appliedSet   map[string]bool
	received     []string
	appliedList  []string
	rejectedList []protocol.RejectedDirective
	duplicates   []string
	gaps         []protocol.SequenceGap

	stop      *protocol.WorkDirective
	stopAt    string
	cancelRun context.CancelFunc
	runDone   bool

	// attempt-scoped
	attemptCancel context.CancelFunc
	live          adapter.Enforcement
	liveCh        chan protocol.WorkDirective
	boundary      string
	pausePending  *protocol.WorkDirective
	paused        bool
	resumeCh      chan struct{}
	resumeID      string
}

func newDirectiveState(s *session) *directiveState {
	return &directiveState{
		s:          s,
		seenID:     map[string]bool{},
		seenSeq:    map[int]string{},
		all:        map[string]protocol.WorkDirective{},
		nextSeq:    1,
		waiting:    map[int]protocol.WorkDirective{},
		appliedSet: map[string]bool{},
	}
}

// start begins reading the caller's directive channel for the life of the
// run. The reader never blocks on the adapter: it records, orders and
// either cancels, queues or forwards.
func (d *directiveState) start(ctx context.Context, cancelRun context.CancelFunc) {
	d.cancelRun = cancelRun
	if d.s.opts.Directives == nil {
		return
	}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case dir, ok := <-d.s.opts.Directives:
				if !ok {
					return
				}
				d.receive(dir)
			}
		}
	}()
}

func (d *directiveState) receive(dir protocol.WorkDirective) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.runDone {
		return
	}
	if ps := protocol.ValidateWorkDirective(&dir); len(ps) > 0 {
		d.rejectLocked(dir.DirectiveID, "invalid directive: "+ps.Error())
		return
	}
	if dir.PackageID != d.s.wp.PackageID {
		d.rejectLocked(dir.DirectiveID, "directive names package "+dir.PackageID+" but this run is "+d.s.wp.PackageID)
		return
	}
	if dir.RunRef != "" && dir.RunRef != d.s.receipt.RunID {
		d.rejectLocked(dir.DirectiveID, "directive names run "+dir.RunRef+" but this run is "+d.s.receipt.RunID)
		return
	}
	if d.seenID[dir.DirectiveID] {
		d.duplicates = append(d.duplicates, dir.DirectiveID)
		d.s.emit(protocol.EventDirectiveDuplicate, map[string]any{"directiveId": dir.DirectiveID, "seq": dir.Seq})
		return
	}
	if prev, ok := d.seenSeq[dir.Seq]; ok {
		d.duplicates = append(d.duplicates, dir.DirectiveID)
		d.s.emit(protocol.EventDirectiveDuplicate, map[string]any{"directiveId": dir.DirectiveID, "seq": dir.Seq, "sameSeqAs": prev})
		return
	}
	d.seenID[dir.DirectiveID] = true
	d.seenSeq[dir.Seq] = dir.DirectiveID
	d.all[dir.DirectiveID] = dir
	d.received = append(d.received, dir.DirectiveID)
	d.s.emit(protocol.EventDirectiveReceived, map[string]any{"directiveId": dir.DirectiveID, "seq": dir.Seq, "kind": dir.Kind})

	if dir.Kind == protocol.DirectiveStop {
		if dir.Seq != d.nextSeq {
			d.gaps = append(d.gaps, protocol.SequenceGap{DirectiveID: dir.DirectiveID, ExpectedSeq: d.nextSeq, ReceivedSeq: dir.Seq})
		}
		if d.stop == nil {
			cp := dir
			d.stop = &cp
			d.stopAt = d.s.now()
			// Cancel first, then tell anyone listening: a full event
			// buffer must never delay the stop itself.
			d.cancelRun()
			if d.paused && d.resumeCh != nil {
				close(d.resumeCh)
				d.resumeCh = nil
			}
			d.s.emit(protocol.EventStopping, map[string]any{"directiveId": dir.DirectiveID, "reason": dir.Payload.Reason})
		} else {
			d.rejectLocked(dir.DirectiveID, "already stopping on "+d.stop.DirectiveID)
		}
		return
	}
	d.waiting[dir.Seq] = dir
	for {
		next, ok := d.waiting[d.nextSeq]
		if !ok {
			break
		}
		delete(d.waiting, d.nextSeq)
		d.nextSeq++
		d.dispatchLocked(next)
	}
}

// dispatchLocked routes one in-order directive: live to the adapter when
// it can act on it, otherwise to the runner's own boundary handling.
func (d *directiveState) dispatchLocked(dir protocol.WorkDirective) {
	switch dir.Kind {
	case protocol.DirectiveClarify, protocol.DirectiveSteer:
		if d.live.Enforces(protocol.FeatLiveSteer) && d.liveCh != nil && !d.paused {
			d.forwardLocked(dir)
			return
		}
		d.instrQueue = append(d.instrQueue, dir)
		if d.attemptCancel != nil && d.boundary == boundaryNone && !d.paused &&
			d.live.Enforces(protocol.FeatSessionContinue) && d.live.Enforces(protocol.FeatGracefulStop) {
			d.boundary = boundarySteer
			d.attemptCancel()
		}
	case protocol.DirectivePause:
		if d.live.Enforces(protocol.FeatPause) && d.liveCh != nil {
			d.forwardLocked(dir)
			return
		}
		if d.paused || d.pausePending != nil {
			d.rejectLocked(dir.DirectiveID, "already paused")
			return
		}
		cp := dir
		d.pausePending = &cp
		if d.attemptCancel != nil {
			d.boundary = boundaryPause
			d.attemptCancel()
		}
	case protocol.DirectiveResume:
		if d.live.Enforces(protocol.FeatPause) && d.liveCh != nil {
			d.forwardLocked(dir)
			return
		}
		if !d.paused {
			d.rejectLocked(dir.DirectiveID, "not paused")
			return
		}
		d.resumeID = dir.DirectiveID
		d.paused = false
		if d.resumeCh != nil {
			close(d.resumeCh)
			d.resumeCh = nil
		}
	}
}

func (d *directiveState) forwardLocked(dir protocol.WorkDirective) {
	select {
	case d.liveCh <- dir:
	default:
		// The adapter is not draining. A directive is never dropped: it
		// is queued for the runner instead, which will apply it at the
		// next boundary.
		d.instrQueue = append(d.instrQueue, dir)
	}
}

func (d *directiveState) rejectLocked(id, reason string) {
	d.rejectedList = append(d.rejectedList, protocol.RejectedDirective{DirectiveID: id, Reason: reason})
	d.s.emit(protocol.EventDirectiveRejected, map[string]any{"directiveId": id, "reason": reason})
}

// applied acknowledges a directive as actually in effect.
func (d *directiveState) applied(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.appliedSet[id] {
		return
	}
	d.appliedSet[id] = true
	d.appliedList = append(d.appliedList, id)
	d.s.emit(protocol.EventDirectiveApplied, map[string]any{"directiveId": id})
	if dir, ok := d.all[id]; ok {
		d.s.appendHistory(historyLine{Kind: "directive", Directive: &dir, Disposition: "applied"})
	}
}

// rejected acknowledges a directive the adapter could not apply.
func (d *directiveState) rejected(id, reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.rejectLocked(id, reason)
}

func (d *directiveState) stopRequested() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.stop != nil
}

// takeInstructions hands the runner the queued instructions for the next
// attempt and the ids to acknowledge once that attempt has started.
func (d *directiveState) takeInstructions() ([]string, []string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var texts, ids []string
	for _, dir := range d.instrQueue {
		texts = append(texts, dir.Payload.Text)
		ids = append(ids, dir.DirectiveID)
	}
	d.instrQueue = nil
	return texts, ids
}

func (d *directiveState) hasInstructions() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.instrQueue) > 0
}

func (d *directiveState) attemptStarted(cancel context.CancelFunc, live adapter.Enforcement) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.attemptCancel = cancel
	d.live = live
	d.boundary = boundaryNone
	if live.Enforces(protocol.FeatLiveSteer) || live.Enforces(protocol.FeatPause) {
		d.liveCh = make(chan protocol.WorkDirective, 64)
		// Directives that arrived before this attempt was listening are
		// replayed to it in order, so nothing that was received is lost
		// between attempts.
		queued := d.instrQueue
		d.instrQueue = nil
		for _, dir := range queued {
			d.forwardLocked(dir)
		}
		if d.pausePending != nil && !d.paused && live.Enforces(protocol.FeatPause) {
			p := *d.pausePending
			d.pausePending = nil
			d.forwardLocked(p)
		}
		return
	}
	d.liveCh = nil
	// A pause that arrived between attempts takes effect before work
	// resumes: end this attempt at once.
	if d.pausePending != nil && !d.paused {
		d.boundary = boundaryPause
		cancel()
	}
}

func (d *directiveState) liveChannel() <-chan protocol.WorkDirective {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.liveCh
}

// attemptEnded returns the boundary that ended the attempt, if the runner
// forced one, and clears attempt state.
func (d *directiveState) attemptEnded() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	b := d.boundary
	d.boundary = boundaryNone
	d.attemptCancel = nil
	if d.liveCh != nil {
		// Anything the adapter did not drain is not lost.
		for {
			select {
			case dir := <-d.liveCh:
				if !d.appliedSet[dir.DirectiveID] {
					if dir.Kind == protocol.DirectiveClarify || dir.Kind == protocol.DirectiveSteer {
						d.instrQueue = append(d.instrQueue, dir)
					} else {
						d.rejectLocked(dir.DirectiveID, "attempt ended before it could be applied")
					}
				}
				continue
			default:
			}
			break
		}
		d.liveCh = nil
	}
	return b
}

// pauseApplied marks the pending pause as in effect: the attempt has ended.
func (d *directiveState) pauseApplied() {
	d.mu.Lock()
	p := d.pausePending
	d.pausePending = nil
	d.paused = true
	d.resumeCh = make(chan struct{})
	d.mu.Unlock()
	d.applied(p.DirectiveID)
}

// waitResumed blocks while paused. It returns false when the run was
// stopped instead of resumed.
func (d *directiveState) waitResumed(ctx context.Context) bool {
	d.mu.Lock()
	ch := d.resumeCh
	d.mu.Unlock()
	if ch != nil {
		select {
		case <-ch:
		case <-ctx.Done():
			return false
		}
	}
	d.mu.Lock()
	id := d.resumeID
	d.resumeID = ""
	stopped := d.stop != nil
	d.mu.Unlock()
	if stopped {
		return false
	}
	if id != "" {
		d.applied(id)
	}
	return true
}

// finishRun settles everything still outstanding: waiting gaps, queued
// instructions, a pause that never took effect, directives already
// delivered but too late to act on, and the stop itself.
func (d *directiveState) finishRun() {
	// Anything the caller has already handed over but the reader has not
	// yet taken is late: it is acknowledged as rejected rather than lost.
	if d.s.opts.Directives != nil {
	late:
		for {
			select {
			case dir, ok := <-d.s.opts.Directives:
				if !ok {
					break late
				}
				d.mu.Lock()
				if !d.runDone && !d.seenID[dir.DirectiveID] {
					d.seenID[dir.DirectiveID] = true
					d.rejectLocked(dir.DirectiveID, "arrived after the run ended")
				}
				d.mu.Unlock()
			default:
				break late
			}
		}
	}
	d.mu.Lock()
	d.runDone = true
	stop := d.stop
	var leftovers []protocol.WorkDirective
	leftovers = append(leftovers, d.instrQueue...)
	d.instrQueue = nil
	if d.pausePending != nil {
		leftovers = append(leftovers, *d.pausePending)
		d.pausePending = nil
	}
	seqs := make([]int, 0, len(d.waiting))
	for seq := range d.waiting {
		seqs = append(seqs, seq)
	}
	sort.Ints(seqs)
	for _, seq := range seqs {
		w := d.waiting[seq]
		d.rejectLocked(w.DirectiveID, fmt.Sprintf("sequence %d never arrived, so seq %d was never applied", d.nextSeq, seq))
	}
	d.waiting = map[int]protocol.WorkDirective{}
	for _, l := range leftovers {
		if !d.appliedSet[l.DirectiveID] {
			d.rejectLocked(l.DirectiveID, "the run ended before it could be applied")
		}
	}
	d.mu.Unlock()
	if stop != nil {
		d.applied(stop.DirectiveID)
	}
}

func (d *directiveState) stopInfo(now string) *protocol.StopInfo {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.stop == nil {
		return &protocol.StopInfo{Issuer: protocol.Issuer{Kind: "runtime", ID: "context"}, At: now, Reason: "cancelled"}
	}
	reason := d.stop.Payload.Reason
	if reason == "" {
		reason = "stop directive"
	}
	return &protocol.StopInfo{Issuer: d.stop.Issuer, At: d.stopAt, Reason: reason, DirectiveID: d.stop.DirectiveID}
}

func (d *directiveState) summarise(r *protocol.RunReceipt) {
	d.mu.Lock()
	defer d.mu.Unlock()
	r.Directives = protocol.DirectiveSummary{
		Received:   orEmpty(d.received),
		Applied:    orEmpty(d.appliedList),
		Rejected:   d.rejectedList,
		Duplicates: d.duplicates,
		Gaps:       d.gaps,
	}
	if r.Directives.Rejected == nil {
		r.Directives.Rejected = []protocol.RejectedDirective{}
	}
}

func orEmpty(xs []string) []string {
	if xs == nil {
		return []string{}
	}
	return xs
}
