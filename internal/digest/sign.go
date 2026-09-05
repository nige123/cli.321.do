package digest

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"cli.321.do/internal/protocol"
)

// AlgorithmEd25519 is the only signature algorithm the runtime accepts.
const AlgorithmEd25519 = "ed25519"

// KeyID derives a stable identifier from a public key: the first sixteen
// hex characters of its sha256.
func KeyID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:8])
}

// Sign signs a digest string. The private key never leaves the caller.
func Sign(digest string, priv ed25519.PrivateKey) protocol.Signature {
	pub := priv.Public().(ed25519.PublicKey)
	return protocol.Signature{
		KeyID:     KeyID(pub),
		Algorithm: AlgorithmEd25519,
		Value:     base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(digest))),
	}
}

// VerifySignature checks sig over digest with pub.
func VerifySignature(digest string, sig protocol.Signature, pub ed25519.PublicKey) error {
	if sig.Algorithm != AlgorithmEd25519 {
		return fmt.Errorf("signature: unsupported algorithm %q", sig.Algorithm)
	}
	if sig.KeyID != KeyID(pub) {
		return fmt.Errorf("signature: key id %s does not name this key", sig.KeyID)
	}
	raw, err := base64.StdEncoding.DecodeString(sig.Value)
	if err != nil {
		return fmt.Errorf("signature: value is not base64")
	}
	if !ed25519.Verify(pub, []byte(digest), raw) {
		return errors.New("signature: verification failed")
	}
	return nil
}

// ReadSignatureFile reads the SIGNATURE file, a JSON protocol.Signature.
func ReadSignatureFile(root string) (*protocol.Signature, error) {
	b, err := os.ReadFile(filepath.Join(root, SignatureFile))
	if err != nil {
		return nil, err
	}
	var sig protocol.Signature
	if err := json.Unmarshal(b, &sig); err != nil {
		return nil, fmt.Errorf("signature: SIGNATURE is not valid JSON: %v", err)
	}
	return &sig, nil
}

// WriteSignatureFile records a signature beside the package.
func WriteSignatureFile(root string, sig protocol.Signature) error {
	b, err := json.MarshalIndent(sig, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(root, SignatureFile), append(b, '\n'), 0o644)
}

// ParsePublicKey decodes a base64 ed25519 public key.
func ParsePublicKey(b64 string) (ed25519.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, errors.New("public key is not base64")
	}
	if len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("public key must be %d bytes", ed25519.PublicKeySize)
	}
	return ed25519.PublicKey(raw), nil
}

// EncodePublicKey renders a public key as base64 for trust configuration.
func EncodePublicKey(pub ed25519.PublicKey) string {
	return base64.StdEncoding.EncodeToString(pub)
}
