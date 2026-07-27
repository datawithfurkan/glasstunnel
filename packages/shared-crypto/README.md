# @glasstunnel/shared-crypto

ed25519 helpers shared between the PWA and the signaling layer.

The Mac host has its own Swift-native implementation in `apps/host-macos/Sources/Transport/DeviceKey.swift` that produces identical device IDs and signatures so keys generated on either side are interoperable.

## API

- `generateDeviceKeypair()` - ed25519 keypair + derived device ID.
- `sign(msg, privateKey)` / `verify(sig, msg, publicKey)` - ed25519 signing.
- `canonicalizeForSigning(obj)` - sort-keys-then-JSON canonicalization for cross-language signatures.

## Security notes

- Never log or transmit a private key. Storage is `localStorage` on the phone (acceptable because WebAuthn biometric unlock gates any usage) and macOS Keychain on the Mac.
- We do not implement any new cryptographic primitives here. Only @noble/ed25519 and @noble/hashes are used.
