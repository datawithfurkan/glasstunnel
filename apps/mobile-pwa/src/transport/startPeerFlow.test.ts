import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { DeviceKeypair } from '@glasstunnel/shared-crypto';
import type { PairedHost } from '../lib/store';
import { startPeerFlow } from './startPeerFlow';

const signalingHarness = vi.hoisted(() => ({
  instances: [] as Array<{
    disconnect: ReturnType<typeof vi.fn>;
    rejectConnect: ((error: Error) => void) | null;
  }>,
}));

const peerHarness = vi.hoisted(() => ({
  instances: [] as Array<{ close: ReturnType<typeof vi.fn> }>,
}));

vi.mock('./SignalingClient', () => ({
  SignalingClient: class {
    readonly disconnect = vi.fn(() => {
      this.rejectConnect?.(new Error('signaling disconnected'));
    });
    rejectConnect: ((error: Error) => void) | null = null;

    constructor() {
      signalingHarness.instances.push(this);
    }

    connect(): Promise<string> {
      return new Promise((_resolve, reject) => {
        this.rejectConnect = reject;
      });
    }
  },
}));

vi.mock('./PeerConnection', () => ({
  PeerConnection: class {
    readonly close = vi.fn();

    constructor() {
      peerHarness.instances.push(this);
    }
  },
}));

describe('startPeerFlow cancellation', () => {
  beforeEach(() => {
    signalingHarness.instances.length = 0;
    peerHarness.instances.length = 0;
  });

  it('closes an in-flight transport without publishing it after cancellation', async () => {
    const controller = new AbortController();
    const onSignaling = vi.fn();
    const onPeer = vi.fn();
    const onState = vi.fn();

    const flow = startPeerFlow({
      keypair: {
        deviceId: 'phone-device',
        publicKey: new Uint8Array(),
        privateKey: new Uint8Array(),
      } as DeviceKeypair,
      host: {
        deviceId: 'host-device',
        publicKeyB64: '',
        label: 'Test Mac',
        signalingUrl: 'ws://localhost.test',
        pairedAtUnixMs: 0,
      } as PairedHost,
      signal: controller.signal,
      onState,
      onSignaling,
      onPeer,
      onHello: vi.fn(),
      onAgent: vi.fn(),
      onVideoTrack: vi.fn(),
      onLayout: vi.fn(),
      onRemoteApps: vi.fn(),
    });

    await vi.waitFor(() => expect(signalingHarness.instances).toHaveLength(1));
    controller.abort();
    await flow;

    expect(signalingHarness.instances[0]?.disconnect).toHaveBeenCalledOnce();
    expect(peerHarness.instances[0]?.close).toHaveBeenCalledOnce();
    expect(onSignaling).not.toHaveBeenCalled();
    expect(onPeer).not.toHaveBeenCalled();
    expect(onState).not.toHaveBeenCalled();
  });
});
