// Package wire is the machine-facing invocation of the runtime: NDJSON in,
// NDJSON out.
//
// Input: the WorkPackage comes from exactly one place. With --package -,
// the first stdin frame is the package and every later frame is a
// WorkDirective. With --package <file>, the file is the package and stdin
// carries only directives. Output: run-event.v1 frames, then exactly one
// terminal run-receipt.v1 frame. When the input cannot be understood well
// enough to name a package, a protocol-error.v1 frame is emitted instead
// and no receipt is fabricated.
//
// Rules the caller can rely on:
//
//   - Frames are one JSON object per line. Blank lines are ignored.
//   - A malformed directive line is answered with a protocol-error frame
//     naming the line, and the run continues.
//   - Duplicates and out-of-order directives are handled by the runner:
//     duplicates are acknowledged as such, ordinary directives wait for
//     their predecessors, stop never waits.
//   - Stdin closing means no more directives, not stop.
//   - SIGTERM or SIGINT is a stop from issuer "signal".
//   - Events are buffered up to EventBuffer; when the caller does not
//     drain, progress-class events are coalesced and counted, never the
//     acknowledgements or the receipt. Cancellation does not depend on the
//     buffer at all.
//   - The receipt is always written to --receipt when given, even if stdout
//     is blocked, and stdout gets a bounded time to drain before exit.
package wire

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/run"
	"cli.321.do/internal/trust"
)

// Exit codes.
const (
	ExitCompleted = 0
	ExitBlocked   = 2
	ExitStopped   = 3
	ExitFailed    = 4
	ExitDenied    = 5
	ExitUsage     = 64
	ExitMalformed = 65
	ExitInternal  = 70
)

// EventBuffer is how many events may wait for a slow reader.
const EventBuffer = 4096

// DrainTimeout bounds how long exit waits for stdout after the run.
const DrainTimeout = 5 * time.Second

// MaxFrame bounds one input line.
const MaxFrame = 16 * 1024 * 1024

// ExitFor maps a receipt status to an exit code.
func ExitFor(status string) int {
	switch status {
	case protocol.StatusCompleted, protocol.StatusNoChange:
		return ExitCompleted
	case protocol.StatusBlocked:
		return ExitBlocked
	case protocol.StatusStopped:
		return ExitStopped
	case protocol.StatusDenied:
		return ExitDenied
	default:
		return ExitFailed
	}
}

// Options configure one machine invocation.
type Options struct {
	PackageSource string // "-" or a file path
	PackageDir    string // explicit local package directory, bypassing trust aliases
	Workspace     string // overrides an absent workspace path
	ReceiptPath   string
	EventsPath    string
	RunID         string
	HistoryDir    string
	Adapter       string
	ContinueFrom  string // path of the terminal receipt this run continues

	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer

	Trust  *trust.Config
	Runner *run.Runner
	// Signals, when true, turns SIGTERM and SIGINT into a stop directive.
	Signals bool
}

// LoadPackage reads the WorkPackage from the configured source. With "-"
// it consumes the first frame of stdin and returns the scanner positioned
// at the next.
func LoadPackage(opts Options) (*protocol.WorkPackage, *bufio.Scanner, *protocol.ProtocolError) {
	scanner := bufio.NewScanner(opts.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), MaxFrame)
	var raw []byte
	line := 0
	if opts.PackageSource == "-" || opts.PackageSource == "" {
		for scanner.Scan() {
			line++
			if len(trimSpace(scanner.Bytes())) == 0 {
				continue
			}
			raw = append([]byte(nil), scanner.Bytes()...)
			break
		}
		if raw == nil {
			if err := scanner.Err(); err != nil {
				return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "read_failed", Message: err.Error(), Line: line}
			}
			return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "no_package", Message: "stdin closed before a work package arrived"}
		}
	} else {
		b, err := os.ReadFile(opts.PackageSource)
		if err != nil {
			return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "package_unreadable", Message: err.Error()}
		}
		raw = b
	}
	var probe struct {
		Schema string `json:"schema"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "malformed_json", Message: err.Error(), Line: line}
	}
	if probe.Schema != protocol.SchemaWorkPackage {
		return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "not_a_work_package", Message: fmt.Sprintf("expected schema %q, got %q", protocol.SchemaWorkPackage, probe.Schema), Line: line}
	}
	var wp protocol.WorkPackage
	if err := json.Unmarshal(raw, &wp); err != nil {
		return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "malformed_package", Message: err.Error(), Line: line}
	}
	if wp.PackageID == "" {
		return nil, scanner, &protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "unidentified_package", Message: "the work package has no packageId", Line: line}
	}
	return &wp, scanner, nil
}

// Serve runs one package to a receipt and returns the exit code.
func Serve(ctx context.Context, opts Options) int {
	out := newWriter(opts.Stdout, opts.EventsPath)
	defer out.close()

	wp, scanner, perr := LoadPackage(opts)
	if perr != nil {
		out.frame(perr)
		return ExitMalformed
	}
	if opts.Workspace != "" && wp.Workspace.Path == "" {
		wp.Workspace.Path = opts.Workspace
	}
	if wp.Workspace.Path != "" {
		if abs, err := filepath.Abs(wp.Workspace.Path); err == nil {
			wp.Workspace.Path = abs
		}
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	directives := make(chan protocol.WorkDirective, 256)
	go readDirectives(runCtx, scanner, directives, out, wp.PackageID)
	if opts.Signals {
		go signalStop(runCtx, directives, wp.PackageID)
	}

	runOpts := run.Options{
		Directives: directives,
		Sink:       out,
		RunID:      opts.RunID,
		HistoryDir: opts.HistoryDir,
		Adapter:    opts.Adapter,
	}
	if opts.ContinueFrom != "" {
		prev, err := readReceipt(opts.ContinueFrom)
		if err != nil {
			out.frame(&protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "continue_unreadable", Message: err.Error()})
			return ExitMalformed
		}
		runOpts.Continue = prev
	}
	if opts.Trust != nil {
		runOpts.Policy = opts.Trust.Policy
	}

	var receipt *protocol.RunReceipt
	agent, err := loadAgent(opts, wp)
	if err != nil {
		receipt = opts.Runner.Deny(wp, "the agent package could not be loaded", []string{err.Error()}, runOpts)
	} else {
		receipt = opts.Runner.Run(runCtx, wp, agent, runOpts)
	}
	cancel()
	if opts.ReceiptPath != "" {
		if b, err := json.MarshalIndent(receipt, "", "  "); err == nil {
			if werr := os.WriteFile(opts.ReceiptPath, append(b, '\n'), 0o600); werr != nil {
				fmt.Fprintln(opts.Stderr, "321: receipt file:", werr)
			}
		}
	}
	if !out.drain(DrainTimeout) {
		fmt.Fprintln(opts.Stderr, "321: stdout did not drain; the receipt was still written to --receipt if given")
	}
	out.frame(receipt)
	return ExitFor(receipt.Status)
}

func readReceipt(path string) (*protocol.RunReceipt, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r protocol.RunReceipt
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	if ps := protocol.ValidateRunReceipt(&r); len(ps) > 0 {
		return nil, fmt.Errorf("%s: %v", path, ps)
	}
	return &r, nil
}

func loadAgent(opts Options, wp *protocol.WorkPackage) (*trust.Loaded, error) {
	if opts.PackageDir != "" {
		return trust.LoadPath(opts.PackageDir)
	}
	if opts.Trust == nil {
		return nil, errors.New("no trust configuration and no --package-dir")
	}
	res, err := opts.Trust.Resolve(wp.Agent.ID)
	if err != nil {
		return nil, err
	}
	return trust.LoadResolved(res)
}

// readDirectives turns stdin frames into directives. It never stops the
// run on a bad line; it reports and continues. EOF just ends the channel.
func readDirectives(ctx context.Context, scanner *bufio.Scanner, ch chan<- protocol.WorkDirective, out *writer, packageID string) {
	defer close(ch)
	line := 1
	for scanner.Scan() {
		line++
		raw := scanner.Bytes()
		if len(trimSpace(raw)) == 0 {
			continue
		}
		var d protocol.WorkDirective
		if err := json.Unmarshal(raw, &d); err != nil {
			out.frame(&protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "malformed_directive", Message: err.Error(), Line: line})
			continue
		}
		if d.Schema != protocol.SchemaWorkDirective {
			out.frame(&protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "unexpected_frame", Message: fmt.Sprintf("expected %q after the package, got %q", protocol.SchemaWorkDirective, d.Schema), Line: line})
			continue
		}
		select {
		case ch <- d:
		case <-ctx.Done():
			return
		}
	}
	if err := scanner.Err(); err != nil {
		out.frame(&protocol.ProtocolError{Schema: protocol.SchemaProtocolError, Code: "read_failed", Message: err.Error(), Line: line})
	}
}

// signalStop makes SIGTERM and SIGINT a stop directive from issuer signal.
func signalStop(ctx context.Context, ch chan<- protocol.WorkDirective, packageID string) {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)
	select {
	case s := <-sig:
		d := protocol.WorkDirective{
			Schema:      protocol.SchemaWorkDirective,
			DirectiveID: "signal-" + protocol.NewULID(),
			PackageID:   packageID,
			Seq:         1 << 30, // deliberately out of any ordinary sequence; stop bypasses order
			Issuer:      protocol.Issuer{Kind: "signal", ID: s.String()},
			IssuedAt:    protocol.Now(),
			Kind:        protocol.DirectiveStop,
			Payload:     protocol.DirectivePayload{Reason: "signal " + s.String()},
		}
		d.Digest, _ = protocol.DirectiveDigest(d)
		select {
		case ch <- d:
		case <-ctx.Done():
		}
	case <-ctx.Done():
	}
}

// writer serialises frames to stdout with a bounded buffer.
type writer struct {
	w       io.Writer
	events  io.WriteCloser
	ch      chan any
	done    chan struct{}
	mu      sync.Mutex
	dropped int
	closed  bool
}

func newWriter(stdout io.Writer, eventsPath string) *writer {
	wr := &writer{w: stdout, ch: make(chan any, EventBuffer), done: make(chan struct{})}
	if eventsPath != "" {
		if f, err := os.OpenFile(eventsPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			wr.events = f
		}
	}
	go wr.loop()
	return wr
}

func (w *writer) loop() {
	defer close(w.done)
	enc := json.NewEncoder(w.w)
	enc.SetEscapeHTML(false)
	for v := range w.ch {
		_ = enc.Encode(v)
		if w.events != nil {
			if b, err := json.Marshal(v); err == nil {
				w.events.Write(append(b, '\n'))
			}
		}
	}
}

// Emit implements run.Sink with coalescing of progress-class events.
func (w *writer) Emit(e protocol.RunEvent) {
	w.mu.Lock()
	closed := w.closed
	w.mu.Unlock()
	if closed {
		return
	}
	switch e.Kind {
	case protocol.EventProgress, protocol.EventToolCall, protocol.EventToolResult, protocol.EventCost:
		select {
		case w.ch <- e:
		default:
			w.mu.Lock()
			w.dropped++
			w.mu.Unlock()
		}
	default:
		w.ch <- e
	}
}

// Coalesced implements run.CoalescingSink.
func (w *writer) Coalesced() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.dropped
}

// frame writes a non-event frame in order with the events.
func (w *writer) frame(v any) {
	w.mu.Lock()
	closed := w.closed
	w.mu.Unlock()
	if closed {
		enc := json.NewEncoder(w.w)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(v)
		return
	}
	w.ch <- v
}

// drain waits for the buffer to empty, bounded.
func (w *writer) drain(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for len(w.ch) > 0 {
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(5 * time.Millisecond)
	}
	return true
}

func (w *writer) close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	w.mu.Unlock()
	close(w.ch)
	select {
	case <-w.done:
	case <-time.After(DrainTimeout):
	}
	if w.events != nil {
		w.events.Close()
	}
}

func trimSpace(b []byte) []byte {
	i, j := 0, len(b)
	for i < j && (b[i] == ' ' || b[i] == '\t' || b[i] == '\r' || b[i] == '\n') {
		i++
	}
	for j > i && (b[j-1] == ' ' || b[j-1] == '\t' || b[j-1] == '\r' || b[j-1] == '\n') {
		j--
	}
	return b[i:j]
}
