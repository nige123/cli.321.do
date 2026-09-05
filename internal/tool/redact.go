package tool

import (
	"regexp"
	"strings"
)

// Redaction is applied to everything a tool returns before it reaches an
// event, a receipt or a proposal. It is deliberately broad: a value that
// looks like a credential is replaced whether or not it is one.

var (
	sensitiveKey = regexp.MustCompile(`(?i)(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential|authorization|cookie)`)
	assignment   = regexp.MustCompile(`(?i)\b(password|passwd|secret|token|api[_-]?key|private[_-]?key|authorization)\s*[=:]\s*("[^"]*"|'[^']*'|\S+)`)
	bearer       = regexp.MustCompile(`(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}`)
	knownShapes  = regexp.MustCompile(`\b(sk-[A-Za-z0-9_-]{8,}|sk-ant-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})\b`)
	pemBlock     = regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`)
)

const redacted = "<redacted>"

// Redact scrubs free text.
func Redact(s string) string {
	s = pemBlock.ReplaceAllString(s, redacted)
	s = bearer.ReplaceAllString(s, "bearer "+redacted)
	s = assignment.ReplaceAllString(s, "$1=<redacted>")
	s = knownShapes.ReplaceAllString(s, redacted)
	return s
}

// RedactMap scrubs a decoded JSON document in place: values under
// sensitive keys are replaced whole, and every string value is passed
// through Redact.
func RedactMap(m map[string]any) map[string]any {
	for k, v := range m {
		if sensitiveKey.MatchString(k) {
			m[k] = redacted
			continue
		}
		m[k] = redactValue(v)
	}
	return m
}

func redactValue(v any) any {
	switch x := v.(type) {
	case map[string]any:
		return RedactMap(x)
	case []any:
		for i := range x {
			x[i] = redactValue(x[i])
		}
		return x
	case string:
		if strings.ContainsAny(x, "=:") || knownShapes.MatchString(x) || strings.Contains(x, "-----BEGIN") {
			return Redact(x)
		}
		return x
	}
	return v
}
