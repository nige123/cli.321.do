package protocol

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
)

// Canonical renders v as canonical JSON: object keys sorted bytewise at
// every depth, no insignificant whitespace, no HTML escaping, no trailing
// newline. Two values with the same content always produce the same bytes,
// which is what makes a digest over them meaningful.
func Canonical(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var generic any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&generic); err != nil {
		return nil, err
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
		sort.Strings(keys)
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
		buf.WriteString(x.String())
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

func writeString(buf *bytes.Buffer, s string) error {
	enc := json.NewEncoder(buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return err
	}
	// Encode appends a newline; canonical form has none.
	buf.Truncate(buf.Len() - 1)
	return nil
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
// the runtime recomputes: sha256 over the canonical JSON of the params
// object. An absent params object hashes as the empty object.
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
