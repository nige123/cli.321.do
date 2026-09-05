package run

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"cli.321.do/internal/protocol"
)

// historyLine is one line of the durable applied-instruction history.
type historyLine struct {
	Kind         string                  `json:"kind"`
	Package      *protocol.WorkPackage   `json:"package,omitempty"`
	Directive    *protocol.WorkDirective `json:"directive,omitempty"`
	Disposition  string                  `json:"disposition,omitempty"`
	Attempt      int                     `json:"attempt,omitempty"`
	Instructions []string                `json:"instructions,omitempty"`
	SessionRef   string                  `json:"sessionRef,omitempty"`
	EndReason    string                  `json:"endReason,omitempty"`
}

// writeHistory renders the history as NDJSON, digests it, and writes it
// under dir when dir is set. The digest is computed either way so a
// receipt always carries it.
func writeHistory(dir string, lines []historyLine) (uri, digest string, err error) {
	var b strings.Builder
	for _, l := range lines {
		raw, err := json.Marshal(l)
		if err != nil {
			return "", "", err
		}
		b.Write(raw)
		b.WriteByte('\n')
	}
	digest = protocol.DigestBytes([]byte(b.String()))
	if dir == "" {
		return "", digest, nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", digest, err
	}
	path := filepath.Join(dir, "instruction-history.ndjson")
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		return "", digest, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	return "file://" + filepath.ToSlash(abs), digest, nil
}

// gitChangedFiles lists changed and untracked paths in a git workspace.
// Read-only; the runtime never commits.
func gitChangedFiles(workspace string) []string {
	out, err := exec.Command("git", "-C", workspace, "status", "--porcelain", "--untracked-files=all").Output()
	if err != nil {
		return nil
	}
	var files []string
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if len(line) < 4 {
			continue
		}
		p := strings.TrimSpace(line[3:])
		if i := strings.Index(p, " -> "); i >= 0 {
			p = p[i+4:]
		}
		files = append(files, p)
	}
	return files
}
