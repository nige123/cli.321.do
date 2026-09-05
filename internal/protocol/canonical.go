package protocol

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"unicode/utf8"
)

// Canonical JSON, as every 321 digest and cross-language hash uses it.
// The rules are deliberately small and stated here in full, because a
// second implementation (the 123 API, in Perl) must produce identical
// bytes. testdata/canonical/ holds the shared fixtures both are tested
// against.
//
//  1. Objects: members sorted by key, comparing keys as UTF-8 byte
//     strings. No duplicate keys. Rendered as {"k":v,...} with no
//     whitespace anywhere.
//  2. Arrays: elements in order, [a,b] with no whitespace.
//  3. Strings: UTF-8, rendered raw except for the escapes: " as \", \ as
//     \\, and the control characters U+0000..U+001F as \b \f \n \r \t
//     where those apply and \u00xx (lowercase hex) otherwise. Nothing
//     else is escaped: no \/ , no  , no non-ASCII escaping. Invalid
//     UTF-8 is an error, never replaced.
//  4. Numbers: an integer literal (an optional minus and digits only) is
//     rendered as its digits; "-0" renders as 0. Any other number is
//     rendered as the shortest decimal that round-trips through an IEEE
//     754 double, in ES6 Number.prototype.toString form: plain decimal
//     notation for magnitudes in [1e-6, 1e21), otherwise d.ddde+x or
//     d.ddde-x with no leading zeros in the exponent. Integer-valued
//     doubles render without a fraction. NaN and infinities are errors.
//  5. true, false and null as those words.
//  6. No trailing newline.
//
// A digest is "sha256:" followed by the lowercase hex sha256 of those bytes.

var integerLiteral = regexp.MustCompile(`^-?[0-9]+$`)

// Canonical renders v in canonical form.
func Canonical(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return CanonicalizeJSON(raw)
}

// CanonicalizeJSON re-renders JSON text in canonical form.
func CanonicalizeJSON(raw []byte) ([]byte, error) {
	if !utf8.Valid(raw) {
		return nil, errors.New("canonical: input is not valid UTF-8")
	}
	var generic any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("canonical: trailing data after the JSON value")
	}
	var buf bytes.Buffer
	if err := writeCanonical(&buf, generic); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func writeCanonical(buf *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys) // bytewise on UTF-8, the same order Perl's sort gives
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeString(buf, k); err != nil {
				return err
			}
			buf.WriteByte(':')
			if err := writeCanonical(buf, x[k]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	case []any:
		buf.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeCanonical(buf, e); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case string:
		return writeString(buf, x)
	case json.Number:
		return writeNumber(buf, x.String())
	case bool:
		if x {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case nil:
		buf.WriteString("null")
	default:
		return fmt.Errorf("canonical: unsupported value %T", v)
	}
	return nil
}

const hexDigits = "0123456789abcdef"

func writeString(buf *bytes.Buffer, s string) error {
	if !utf8.ValidString(s) {
		return errors.New("canonical: string is not valid UTF-8")
	}
	buf.WriteByte('"')
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '"':
			buf.WriteString(`\"`)
		case c == '\\':
			buf.WriteString(`\\`)
		case c == '\b':
			buf.WriteString(`\b`)
		case c == '\f':
			buf.WriteString(`\f`)
		case c == '\n':
			buf.WriteString(`\n`)
		case c == '\r':
			buf.WriteString(`\r`)
		case c == '\t':
			buf.WriteString(`\t`)
		case c < 0x20:
			buf.WriteString(`\u00`)
			buf.WriteByte(hexDigits[c>>4])
			buf.WriteByte(hexDigits[c&0xf])
		default:
			_, size := utf8.DecodeRuneInString(s[i:])
			buf.WriteString(s[i : i+size])
			i += size
			continue
		}
		i++
	}
	buf.WriteByte('"')
	return nil
}

// writeNumber renders a JSON number literal canonically.
func writeNumber(buf *bytes.Buffer, lit string) error {
	if integerLiteral.MatchString(lit) {
		if lit == "-0" {
			lit = "0"
		}
		buf.WriteString(lit)
		return nil
	}
	f, err := strconv.ParseFloat(lit, 64)
	if err != nil {
		return fmt.Errorf("canonical: number %q: %v", lit, err)
	}
	s, err := FormatNumber(f)
	if err != nil {
		return err
	}
	buf.WriteString(s)
	return nil
}

// FormatNumber renders a double in ES6 Number.prototype.toString form.
func FormatNumber(f float64) (string, error) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "", errors.New("canonical: NaN and infinity cannot be represented")
	}
	if f == 0 {
		return "0", nil
	}
	abs := math.Abs(f)
	format := byte('f')
	if abs < 1e-6 || abs >= 1e21 {
		format = 'e'
	}
	b := strconv.AppendFloat(nil, f, format, -1, 64)
	if format == 'e' {
		// strconv writes e-07; ES6 writes e-7.
		n := len(b)
		if n >= 4 && b[n-4] == 'e' && b[n-3] == '-' && b[n-2] == '0' {
			b[n-2] = b[n-1]
			b = b[:n-1]
		}
	}
	return string(b), nil
}

// DigestOf returns "sha256:<hex>" over the canonical JSON of v.
func DigestOf(v any) (string, error) {
	b, err := Canonical(v)
	if err != nil {
		return "", err
	}
	return DigestBytes(b), nil
}

// DigestBytes returns "sha256:<hex>" over raw bytes.
func DigestBytes(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// ParamsHash is the hash a caller computes over an approval's params and
// the runtime recomputes: the digest of the canonical params object. An
// absent params object hashes as the empty object.
func ParamsHash(params map[string]any) (string, error) {
	if params == nil {
		params = map[string]any{}
	}
	return DigestOf(params)
}

// DirectiveDigest is the digest a directive carries: over the canonical
// directive with its own digest field cleared.
func DirectiveDigest(d WorkDirective) (string, error) {
	d.Digest = ""
	return DigestOf(d)
}

// ReceiptDigest is the digest a receipt carries: over the canonical
// receipt with its own digest and signature cleared.
func ReceiptDigest(r RunReceipt) (string, error) {
	r.ReceiptDigest = ""
	r.Signature = nil
	return DigestOf(r)
}

// PackageDigest is the digest of an issued WorkPackage, which a receipt
// carries so the issuer can prove the runtime saw exactly the package it
// issued.
func PackageDigest(wp WorkPackage) (string, error) {
	return DigestOf(wp)
}

// ConditionsDigest is the digest of the ordered completion conditions,
// which a receipt carries so the mapping by index is provably against the
// same list, not merely a list of the same length.
func ConditionsDigest(conditions []string) (string, error) {
	if conditions == nil {
		conditions = []string{}
	}
	return DigestOf(conditions)
}
