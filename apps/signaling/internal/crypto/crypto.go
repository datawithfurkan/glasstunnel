// Package crypto wraps ed25519 primitives for the signaling hub.
//
// Scope-limited on purpose: this package only handles nonce generation,
// signature verification, and the hash-derived device id we use for
// addressing. Web Push crypto is in the sibling `push` package and relies
// on a well-audited third-party library.
package crypto

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
)

const NonceLength = 32

// NewNonce returns a fresh 32-byte random nonce for authentication challenges.
func NewNonce() ([]byte, error) {
	n := make([]byte, NonceLength)
	if _, err := rand.Read(n); err != nil {
		return nil, err
	}
	return n, nil
}

// Verify reports whether sig is a valid ed25519 signature of msg for pub.
func Verify(pub, msg, sig []byte) bool {
	if len(pub) != ed25519.PublicKeySize {
		return false
	}
	if len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(pub, msg, sig)
}

// DeviceIDFromPublicKey produces the human-facing `gt-<hex>` identifier
// derived from the first 8 bytes of the ed25519 public key. Identical
// derivation lives in the TypeScript `shared-crypto` package.
func DeviceIDFromPublicKey(pub []byte) string {
	if len(pub) < 8 {
		return ""
	}
	return "gt-" + hex.EncodeToString(pub[:8])
}

// ErrInvalidSignature is the standard signature-failed error for callers.
var ErrInvalidSignature = errors.New("invalid signature")
