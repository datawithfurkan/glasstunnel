import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MessageDetail } from '@glasstunnel/protocol';
import type { RelayConnectionOptions } from '../transport/RelayConnection';

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(),
  signOut: vi.fn(),
  registerBrowserDevice: vi.fn(),
  idbGet: vi.fn<(key: string) => Promise<unknown>>().mockResolvedValue(undefined),
  idbSet: vi.fn(async () => {}),
  relays: [] as Array<{
    opts: RelayConnectionOptions;
    disconnect: ReturnType<typeof vi.fn>;
    sendMessageDetailRequest: ReturnType<typeof vi.fn>;
  }>,
}));

vi.mock('./supabase', () => ({
  hasSupabaseAuth: () => true,
  supabase: { auth: {
    initialize: vi.fn(async () => {}),
    onAuthStateChange: vi.fn(),
    getSession: mocks.getSession,
    signOut: mocks.signOut,
  } },
}));
vi.mock('./accountApi', async (importOriginal) => ({
  ...await importOriginal<typeof import('./accountApi')>(),
  registerBrowserDevice: mocks.registerBrowserDevice,
}));
vi.mock('@glasstunnel/shared-crypto', async (importOriginal) => ({
  ...await importOriginal<typeof import('@glasstunnel/shared-crypto')>(),
  generateDeviceKeypair: vi.fn(async () => ({
    deviceId: 'test-phone', publicKey: new Uint8Array(32), privateKey: new Uint8Array(32),
  })),
}));
vi.mock('idb-keyval', () => ({
  get: mocks.idbGet,
  set: mocks.idbSet,
  del: vi.fn(async () => {}),
}));
vi.mock('../notifications/push', () => ({ registerPushSubscription: vi.fn(async () => {}) }));
vi.mock('../transport/RelayConnection', () => ({
  RelayConnection: class {
    isConnected = true;
    isHostOnline = true;
    disconnect = vi.fn();
    sendMessageDetailRequest = vi.fn(() => true);
    connect = vi.fn(async () => 'test-phone');
    constructor(readonly opts: RelayConnectionOptions) { mocks.relays.push(this); }
  },
}));

import { useAppStore } from './store';

const host = {
  deviceId: 'test-mac', publicKeyB64: 'test-public-key', label: 'Test Mac',
  signalingUrl: 'wss://signal.example.test/signal', pairedAtUnixMs: 1,
  online: true, trusted: true,
};
const detail: MessageDetail = {
  agentId: 'agent-one', messageId: 'shared-message-id', text: 'Private test output',
  redacted: false, truncated: false,
};
const signedInSession = (id: string) => ({
  access_token: 'test-token', user: { id, email: `${id}@glasstunnel.test`, user_metadata: {} },
});

describe('browser content security boundaries', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal('window', {
      setTimeout, clearTimeout, setInterval, clearInterval,
      location: { href: 'https://app.example.test/', search: '' },
    });
    vi.stubGlobal('navigator', { userAgent: 'test-browser' });
    vi.stubGlobal('localStorage', { removeItem: vi.fn() });
    mocks.relays.length = 0;
    mocks.idbGet.mockReset().mockResolvedValue(undefined);
    mocks.idbSet.mockReset().mockResolvedValue(undefined);
    mocks.signOut.mockReset().mockResolvedValue({ error: null });
    mocks.getSession.mockReset().mockResolvedValue({ data: { session: signedInSession('one') }, error: null });
    mocks.registerBrowserDevice.mockReset().mockResolvedValue([host]);
    useAppStore.setState({
      user: { id: 'one', email: 'one@glasstunnel.test', displayName: 'Test' },
      phoneKeypair: { deviceId: 'test-phone', publicKey: new Uint8Array(32), privateKey: new Uint8Array(32) },
      pairedHost: host, availableHosts: [host], workspaceHostDeviceId: host.deviceId,
      agents: {}, messageDetails: {}, peer: null, signaling: null, relay: null,
      route: 'workspace', locked: false,
    });
  });

  afterEach(() => {
    useAppStore.getState().disconnectPeer();
    vi.clearAllTimers();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  async function connectWithDetail() {
    await useAppStore.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    relay.opts.onMessageDetail?.(detail);
    expect(useAppStore.getState().requestMessageDetail(detail.agentId, detail.messageId)).toBe(true);
    return relay;
  }

  it('clears expanded output on disconnect and ignores late responses', async () => {
    const relay = await connectWithDetail();
    useAppStore.getState().disconnectPeer();
    relay.opts.onMessageDetail?.(detail);
    expect(useAppStore.getState().messageDetails).toEqual({});
  });

  it('clears expanded output when forgetting the Mac', async () => {
    await connectWithDetail();
    await useAppStore.getState().forgetCurrentMac();
    expect(useAppStore.getState().messageDetails).toEqual({});
    expect(useAppStore.getState().pairedHost).toBeNull();
  });

  it('does not reuse another agent\'s expanded message with the same ID', async () => {
    const relay = await connectWithDetail();
    relay.sendMessageDetailRequest.mockClear();
    useAppStore.getState().requestMessageDetail('agent-two', detail.messageId);
    expect(relay.sendMessageDetailRequest).toHaveBeenCalledWith({ agentId: 'agent-two', messageId: detail.messageId });
  });

  it('keeps expanded messages with identical IDs separate across agents', async () => {
    const relay = await connectWithDetail();
    relay.opts.onMessageDetail?.({ ...detail, agentId: 'agent-two', text: 'Other test output' });
    const cached = useAppStore.getState().messageDetails;
    expect(cached['agent-one'][detail.messageId].text).toBe('Private test output');
    expect(cached['agent-two'][detail.messageId].text).toBe('Other test output');
  });

  it('does not restore a signed-out account after an in-flight refresh finishes', async () => {
    mocks.idbGet.mockImplementation(async (key) => key === 'gt.pairedHost' ? host : undefined);
    let finishSave!: () => void;
    const saving = new Promise<void>((resolve) => {
      // Bootstrap stores a keypair before persisting the selected host.
      mocks.idbSet.mockResolvedValueOnce(undefined).mockImplementationOnce(() => new Promise<void>((done) => {
        finishSave = done;
        resolve();
      }));
    });
    const refreshing = useAppStore.getState().bootstrap();
    await saving;
    await useAppStore.getState().signOut();
    finishSave();
    await refreshing;
    expect(useAppStore.getState().user).toBeNull();
    expect(useAppStore.getState().pairedHost).toBeNull();
    expect(useAppStore.getState().route).toBe('auth');
  });

  it('disconnects the old Mac before awaiting a new host selection', async () => {
    const relay = await connectWithDetail();
    useAppStore.setState({ availableHosts: [host, { ...host, deviceId: 'other-mac' }] });
    let finishSave!: () => void;
    mocks.idbSet.mockImplementationOnce(() => new Promise<void>((resolve) => { finishSave = resolve; }));
    const selecting = useAppStore.getState().chooseHost('other-mac');
    relay.opts.onMessageDetail?.(detail);
    const duringSelection = useAppStore.getState().messageDetails;
    const disconnected = relay.disconnect.mock.calls.length;
    finishSave();
    await selecting;
    expect(disconnected).toBe(1);
    expect(duringSelection).toEqual({});
    expect(useAppStore.getState().messageDetails).toEqual({});
  });

  it('clears local content even when remote sign-out fails', async () => {
    const relay = await connectWithDetail();
    mocks.signOut.mockResolvedValue({ error: new Error('offline') });
    await expect(useAppStore.getState().signOut()).rejects.toThrow('offline');
    relay.opts.onMessageDetail?.(detail);
    expect(useAppStore.getState().messageDetails).toEqual({});
    expect(useAppStore.getState().relay).toBeNull();
    expect(useAppStore.getState().user).toBeNull();
  });

  it('drops content and connections when the authenticated session disappears', async () => {
    const relay = await connectWithDetail();
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    await useAppStore.getState().bootstrap();
    relay.opts.onMessageDetail?.(detail);
    expect(relay.disconnect).toHaveBeenCalled();
    expect(useAppStore.getState().messageDetails).toEqual({});
    expect(useAppStore.getState().relay).toBeNull();
    expect(useAppStore.getState().route).toBe('auth');
  });

  it('does not retain the previous account workspace if new-account registration fails', async () => {
    const relay = await connectWithDetail();
    mocks.getSession.mockResolvedValue({ data: { session: signedInSession('two') }, error: null });
    mocks.registerBrowserDevice.mockRejectedValue(new Error('service unavailable'));
    await useAppStore.getState().bootstrap();
    relay.opts.onMessageDetail?.(detail);
    expect(relay.disconnect).toHaveBeenCalled();
    expect(useAppStore.getState().messageDetails).toEqual({});
    expect(useAppStore.getState().pairedHost).toBeNull();
    expect(useAppStore.getState().route).toBe('hosts');
  });
});
