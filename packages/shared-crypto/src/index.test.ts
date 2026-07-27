import { describe, it, expect } from 'vitest';
import {
  generateDeviceKeypair,
  sign,
  verify,
  canonicalizeForSigning,
  deviceIdFromPublicKey,
} from './index.js';

describe('device keypair', () => {
  it('generates unique keypairs', async () => {
    const a = await generateDeviceKeypair();
    const b = await generateDeviceKeypair();
    expect(a.publicKey).not.toEqual(b.publicKey);
    expect(a.deviceId).not.toEqual(b.deviceId);
    expect(a.deviceId.startsWith('gt-')).toBe(true);
  });

  it('derives the same deviceId for the same public key', async () => {
    const a = await generateDeviceKeypair();
    expect(deviceIdFromPublicKey(a.publicKey)).toBe(a.deviceId);
  });
});

describe('sign / verify', () => {
  it('round-trips', async () => {
    const kp = await generateDeviceKeypair();
    const msg = new TextEncoder().encode('hello glasstunnel');
    const sig = await sign(msg, kp.privateKey);
    expect(await verify(sig, msg, kp.publicKey)).toBe(true);
  });

  it('rejects tampered messages', async () => {
    const kp = await generateDeviceKeypair();
    const msg = new TextEncoder().encode('hello');
    const sig = await sign(msg, kp.privateKey);
    const tampered = new TextEncoder().encode('HELLO');
    expect(await verify(sig, tampered, kp.publicKey)).toBe(false);
  });

  it('rejects wrong public keys', async () => {
    const kp = await generateDeviceKeypair();
    const other = await generateDeviceKeypair();
    const msg = new TextEncoder().encode('hello');
    const sig = await sign(msg, kp.privateKey);
    expect(await verify(sig, msg, other.publicKey)).toBe(false);
  });
});

describe('canonicalization', () => {
  it('sorts keys deterministically', () => {
    const a = canonicalizeForSigning({ b: 1, a: 2 });
    const b = canonicalizeForSigning({ a: 2, b: 1 });
    expect(new TextDecoder().decode(a)).toBe(new TextDecoder().decode(b));
  });

  it('canonicalizes byte arrays as base64 strings', () => {
    const canonical = canonicalizeForSigning({ bytes: new Uint8Array([1, 2, 3]) });
    expect(new TextDecoder().decode(canonical)).toBe('{"bytes":"AQID"}');
  });
});
