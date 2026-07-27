import { describe, expect, it } from 'vitest';
import { type Envelope, encodeEnvelopeJson } from '@glasstunnel/protocol';
import {
  base64FromBytes,
  canonicalizeForSigning,
  generateDeviceKeypair,
  sign,
} from '@glasstunnel/shared-crypto';
import { SignalingClient } from './SignalingClient';

describe('SignalingClient envelope verification', () => {
  it('accepts envelopes signed by a trusted peer', async () => {
    const host = await generateDeviceKeypair();
    const phone = await generateDeviceKeypair();
    const env = await signedPing(host, phone.deviceId);
    const received: Envelope[] = [];

    const client = new SignalingClient({
      url: 'ws://localhost/signal',
      keypair: phone,
      trustedPublicKeyForDevice: (deviceId) =>
        deviceId === host.deviceId ? base64FromBytes(host.publicKey) : undefined,
      onEnvelope: (envelope) => received.push(envelope),
    });

    await handleMessage(client, encodeEnvelopeJson(env));

    expect(received).toHaveLength(1);
    expect(received[0].fromDeviceId).toBe(host.deviceId);
  });

  it('drops tampered envelopes from a trusted peer', async () => {
    const host = await generateDeviceKeypair();
    const phone = await generateDeviceKeypair();
    const signed = await signedPing(host, phone.deviceId);
    const tampered = { ...signed, sentAtUnixMs: signed.sentAtUnixMs + 1 };
    const received: Envelope[] = [];
    const errors: Error[] = [];

    const client = new SignalingClient({
      url: 'ws://localhost/signal',
      keypair: phone,
      trustedPublicKeyForDevice: (deviceId) =>
        deviceId === host.deviceId ? base64FromBytes(host.publicKey) : undefined,
      onEnvelope: (envelope) => received.push(envelope),
      onError: (error) => errors.push(error),
    });

    await handleMessage(client, encodeEnvelopeJson(tampered));

    expect(received).toHaveLength(0);
    expect(errors[0]?.message).toContain('invalid envelope signature');
  });
});

async function signedPing(
  from: Awaited<ReturnType<typeof generateDeviceKeypair>>,
  toDeviceId: string,
): Promise<Envelope> {
  const env: Envelope = {
    envelopeId: 'env-1',
    fromDeviceId: from.deviceId,
    toDeviceId,
    sentAtUnixMs: 1234,
    signature: new Uint8Array(),
    payload: {
      kind: 'ping',
      ping: { atUnixMs: 1234 },
    },
  };
  env.signature = await sign(
    canonicalizeForSigning({
      envelopeId: env.envelopeId,
      fromDeviceId: env.fromDeviceId,
      toDeviceId: env.toDeviceId,
      sentAtUnixMs: env.sentAtUnixMs,
      payload: env.payload,
    }),
    from.privateKey,
  );
  return env;
}

async function handleMessage(client: SignalingClient, raw: string): Promise<void> {
  await (client as unknown as { handleMessage(raw: string): Promise<void> }).handleMessage(raw);
}
