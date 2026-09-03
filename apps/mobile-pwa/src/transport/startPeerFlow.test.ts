import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { DeviceKeypair } from '@glasstunnel/shared-crypto';
import type { PairedHost } from '../lib/store';
import { SIGNALING_KEEPALIVE_MS, startPeerFlow, type StartPeerFlowParams } from './startPeerFlow';

interface SignalingOpts {
  onClose?: (event: CloseEvent, intentional: boolean) => void;
}

interface PeerOpts {
  onState?: (state: RTCPeerConnectionState) => void;
}

const signalingHarness = vi.hoisted(() => ({
  instances: [] as Array<{
    opts: SignalingOpts;
    disconnect: ReturnType<typeof vi.fn>;
    sendControl: ReturnType<typeof vi.fn>;
    sendEnvelope: ReturnType<typeof vi.fn>;
    resolveConnect: ((deviceId: string) => void) | null;
    rejectConnect: ((error: Error) => void) | null;
  }>,
}));

const peerHarness = vi.hoisted(() => ({
  instances: [] as Array<{
    opts: PeerOpts;
    close: ReturnType<typeof vi.fn>;
    sendHeartbeat: ReturnType<typeof vi.fn>;
  }>,
}));

vi.mock('./SignalingClient', () => ({
  SignalingClient: class {
    readonly disconnect = vi.fn(() => {
      this.rejectConnect?.(new Error('signaling disconnected'));
    });
    readonly sendControl = vi.fn();
    readonly sendEnvelope = vi.fn(async () => {});
    resolveConnect: ((deviceId: string) => void) | null = null;
    rejectConnect: ((error: Error) => void) | null = null;

    constructor(readonly opts: SignalingOpts) {
      signalingHarness.instances.push(this);
    }

    connect(): Promise<string> {
      return new Promise((resolve, reject) => {
        this.resolveConnect = resolve;
        this.rejectConnect = reject;
      });
    }
  },
}));

vi.mock('./PeerConnection', () => ({
  PeerConnection: class {
    readonly close = vi.fn();
    readonly sendHeartbeat = vi.fn();

    constructor(readonly opts: PeerOpts) {
      peerHarness.instances.push(this);
    }
  },
}));

function flowParams(overrides: Partial<StartPeerFlowParams> = {}): StartPeerFlowParams {
  return {
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
    onState: vi.fn(),
    onSignaling: vi.fn(),
    onPeer: vi.fn(),
    onHello: vi.fn(),
    onAgent: vi.fn(),
    onVideoTrack: vi.fn(),
    onLayout: vi.fn(),
    onRemoteApps: vi.fn(),
    ...overrides,
  };
}

/** Runs a flow up to the point where signaling is authenticated and the ping was sent. */
async function connectedFlow(overrides: Partial<StartPeerFlowParams> = {}) {
  const params = flowParams(overrides);
  const flow = startPeerFlow(params);
  await vi.waitFor(() => expect(signalingHarness.instances).toHaveLength(1));
  const signaling = signalingHarness.instances[0]!;
  signaling.resolveConnect?.('phone-device');
  await flow;
  const peer = peerHarness.instances[0]!;
  return { params, signaling, peer };
}

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

    const flow = startPeerFlow(
      flowParams({ signal: controller.signal, onState, onSignaling, onPeer }),
    );

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

describe('startPeerFlow signaling lifetime', () => {
  beforeEach(() => {
    signalingHarness.instances.length = 0;
    peerHarness.instances.length = 0;
    vi.useFakeTimers();
    vi.stubGlobal('window', {
      setTimeout: globalThis.setTimeout.bind(globalThis),
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setInterval: globalThis.setInterval.bind(globalThis),
      clearInterval: globalThis.clearInterval.bind(globalThis),
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('keeps the peer when signaling closes after the peer connected', async () => {
    const onClosed = vi.fn();
    const onState = vi.fn();
    const { signaling, peer } = await connectedFlow({ onClosed, onState });

    peer.opts.onState?.('connected');
    expect(onState).toHaveBeenLastCalledWith({ connected: true });

    signaling.opts.onClose?.({} as CloseEvent, false);

    expect(peer.close).not.toHaveBeenCalled();
    expect(onClosed).not.toHaveBeenCalled();

    // A later transport failure still ends the flow through the peer path.
    peer.opts.onState?.('failed');
    expect(peer.close).toHaveBeenCalledOnce();
    expect(onClosed).toHaveBeenCalledWith(expect.objectContaining({ reason: 'peer' }));
  });

  it('closes the flow when signaling drops before the peer connected', async () => {
    const onClosed = vi.fn();
    const { signaling, peer } = await connectedFlow({ onClosed });

    signaling.opts.onClose?.({} as CloseEvent, false);

    expect(peer.close).toHaveBeenCalledOnce();
    expect(onClosed).toHaveBeenCalledWith(expect.objectContaining({ reason: 'signaling' }));
  });

  it('pings the signaling socket while it is open and stops when it closes', async () => {
    const { signaling, peer } = await connectedFlow();

    vi.advanceTimersByTime(SIGNALING_KEEPALIVE_MS);
    expect(signaling.sendControl).toHaveBeenCalledTimes(1);
    expect(signaling.sendControl).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: 'ping' }),
    );

    peer.opts.onState?.('connected');
    signaling.opts.onClose?.({} as CloseEvent, false);
    vi.advanceTimersByTime(SIGNALING_KEEPALIVE_MS * 2);

    expect(signaling.sendControl).toHaveBeenCalledTimes(1);
  });
});
