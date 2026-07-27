package crypto

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"testing"
)

func TestDeviceIDFromPublicKey(t *testing.T) {
	pub := make([]byte, ed25519.PublicKeySize)
	for i := range pub {
		pub[i] = byte(i)
	}
	got := DeviceIDFromPublicKey(pub)
	want := "gt-" + hex.EncodeToString(pub[:8])
	if got != want {
		t.Fatalf("DeviceIDFromPublicKey() = %q, want %q", got, want)
	}
}

func TestVerifyRoundtrip(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("hello glasstunnel")
	sig := ed25519.Sign(priv, msg)
	if !Verify(pub, msg, sig) {
		t.Fatal("Verify() = false, want true")
	}
}

func TestVerifyRejectsTamperedMessage(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	msg := []byte("hello")
	sig := ed25519.Sign(priv, msg)
	if Verify(pub, []byte("HELLO"), sig) {
		t.Fatal("Verify() accepted tampered message")
	}
}

func TestVerifyRejectsWrongKey(t *testing.T) {
	pub1, priv1, _ := ed25519.GenerateKey(rand.Reader)
	pub2, _, _ := ed25519.GenerateKey(rand.Reader)
	msg := []byte("hello")
	sig := ed25519.Sign(priv1, msg)
	if Verify(pub2, msg, sig) {
		t.Fatal("Verify() accepted wrong key")
	}
	_ = pub1
}

func TestVerifyRejectsBadLengths(t *testing.T) {
	if Verify([]byte{1, 2, 3}, []byte("x"), make([]byte, 64)) {
		t.Fatal("Verify() accepted short pub key")
	}
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	if Verify(pub, []byte("x"), []byte{1, 2, 3}) {
		t.Fatal("Verify() accepted short signature")
	}
}

func TestNonce(t *testing.T) {
	a, err := NewNonce()
	if err != nil {
		t.Fatal(err)
	}
	b, err := NewNonce()
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != NonceLength {
		t.Fatalf("nonce length = %d, want %d", len(a), NonceLength)
	}
	same := true
	for i := range a {
		if a[i] != b[i] {
			same = false
			break
		}
	}
	if same {
		t.Fatal("two nonces were identical, suggesting RNG failure")
	}
}
