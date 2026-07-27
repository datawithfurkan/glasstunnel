/**
 * Shared crypto helpers.
 *
 * All cryptographic primitives in glasstunnel use ed25519 for identity/signing
 * and rely on WebRTC's DTLS-SRTP for content encryption. This module provides
 * the ed25519-layer helpers needed by the PWA. The Mac host has its own Swift
 * implementation in `apps/host-macos/Sources/Security/DeviceKey.swift`.
 *
 * Never implement new crypto primitives here. Always reach for @noble/ed25519
 * or a browser-native API (WebCrypto).
 */

import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha512';
import { base64FromBytes } from './base64.js';

// @noble/ed25519 v2 uses WebCrypto (subtle.digest) for async hashing in the
// browser by default, but the sync path needs a sha512 shim. Installing both
// keeps us interoperable with Node test environments and non-subtle browsers.
const etcAny = (
  ed as unknown as {
    etc: {
      sha512Sync?: (...m: Uint8Array[]) => Uint8Array;
      sha512Async?: (...m: Uint8Array[]) => Promise<Uint8Array>;
      concatBytes: (...m: Uint8Array[]) => Uint8Array;
    };
  }
).etc;
etcAny.sha512Sync = (...messages) => sha512(etcAny.concatBytes(...messages));
etcAny.sha512Async = async (...messages) => sha512(etcAny.concatBytes(...messages));

export { base64FromBytes, bytesFromBase64 } from './base64.js';

// ------------------------------------------------------------------
// Device key types
// ------------------------------------------------------------------

export interface DeviceKeypair {
  publicKey: Uint8Array;
  privateKey: Uint8Array;
  deviceId: string;
}

export async function generateDeviceKeypair(): Promise<DeviceKeypair> {
  const privateKey = ed.utils.randomPrivateKey();
  const publicKey = await ed.getPublicKeyAsync(privateKey);
  return {
    publicKey,
    privateKey,
    deviceId: deviceIdFromPublicKey(publicKey),
  };
}

export function deviceIdFromPublicKey(publicKey: Uint8Array): string {
  const head = Array.from(publicKey.slice(0, 8))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  return `gt-${head}`;
}

// ------------------------------------------------------------------
// Signing and verification
// ------------------------------------------------------------------

export async function sign(message: Uint8Array, privateKey: Uint8Array): Promise<Uint8Array> {
  return await ed.signAsync(message, privateKey);
}

export async function verify(
  signature: Uint8Array,
  message: Uint8Array,
  publicKey: Uint8Array,
): Promise<boolean> {
  try {
    return await ed.verifyAsync(signature, message, publicKey);
  } catch {
    return false;
  }
}

// ------------------------------------------------------------------
// Canonical message for signing
// ------------------------------------------------------------------
// We canonicalize signed messages as JSON-sorted keys to make cross-language
// signatures verifiable. The fields array describes required attributes.
// ------------------------------------------------------------------

export function canonicalizeForSigning(obj: Record<string, unknown>): Uint8Array {
  const sorted = sortKeys(obj);
  const json = JSON.stringify(sorted);
  return new TextEncoder().encode(json);
}

function sortKeys(value: unknown): unknown {
  if (value instanceof Uint8Array) return base64FromBytes(value);
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === 'object') {
    return Object.keys(value as Record<string, unknown>)
      .sort()
      .reduce<Record<string, unknown>>((acc, k) => {
        acc[k] = sortKeys((value as Record<string, unknown>)[k]);
        return acc;
      }, {});
  }
  return value;
}
