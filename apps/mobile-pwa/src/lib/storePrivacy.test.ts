import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { GridShape, type Hello, type MessageDetail } from '@glasstunnel/protocol';
import type { RelayConnectionOptions } from '../transport/RelayConnection';

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(),
  signOut: vi.fn(),
  registerBrowserDevice: vi.fn(),
  fetchAccountHosts: vi.fn(),
  idbGet: vi.fn<(key: string) => Promise<unknown>>().mockResolvedValue(undefined),
  idbSet: vi.fn(async () => {}),
  idbDel: vi.fn<(key: string) => Promise<void>>().mockResolvedValue(undefined),
  idbKeys: vi.fn(async () => [] as string[]),
  relays: [] as Array<{
    opts: RelayConnectionOptions;
    disconnect: ReturnType<typeof vi.fn>;
    sendMessageDetailRequest: ReturnType<typeof vi.fn>;
    sendReadOnlyUpdate: ReturnType<typeof vi.fn>;
    sendUserInput: ReturnType<typeof vi.fn>;
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
  fetchAccountHosts: mocks.fetchAccountHosts,
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
  del: mocks.idbDel,
  keys: mocks.idbKeys,
}));
vi.mock('../notifications/push', () => ({ registerPushSubscription: vi.fn(async () => {}) }));
vi.mock('../transport/RelayConnection', () => ({
  RelayConnection: class {
    isConnected = true;
    isHostOnline = true;
    disconnect = vi.fn();
    sendMessageDetailRequest = vi.fn(() => true);
    sendReadOnlyUpdate = vi.fn(() => true);
    sendUserInput = vi.fn(() => true);
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
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
    mocks.idbKeys.mockReset().mockResolvedValue([]);
    mocks.signOut.mockReset().mockResolvedValue({ error: null });
    mocks.getSession.mockReset().mockResolvedValue({ data: { session: signedInSession('one') }, error: null });
    mocks.registerBrowserDevice.mockReset().mockResolvedValue([host]);
    mocks.fetchAccountHosts.mockReset().mockResolvedValue([host]);
    useAppStore.setState({
      user: { id: 'one', email: 'one@glasstunnel.test', displayName: 'Test' },
      phoneKeypair: { deviceId: 'test-phone', publicKey: new Uint8Array(32), privateKey: new Uint8Array(32) },
      pairedHost: host, availableHosts: [host], workspaceHostDeviceId: host.deviceId,
      agents: {}, messageDetails: {}, peer: null, signaling: null, relay: null,
      route: 'workspace', locked: false, accessRevocationNotice: null,
      readOnlyMode: false, hostHello: null, signingOut: false, signOutError: null,
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

  it('erases account-scoped offline copies on logout, keeping credentials and other accounts', async () => {
    mocks.idbKeys.mockResolvedValue([
      'gt.relay.cache.v2.["one","test-mac"]', 'gt.relay.cache.v2.["two","test-mac"]',
      'gt.relay.cache.old', 'gt.phoneKeypair',
    ]);
    await useAppStore.getState().signOut();
    expect(mocks.idbDel).toHaveBeenCalledWith('gt.relay.cache.v2.["one","test-mac"]');
    expect(mocks.idbDel).toHaveBeenCalledWith('gt.relay.cache.old');
    expect(mocks.idbDel).not.toHaveBeenCalledWith('gt.relay.cache.v2.["two","test-mac"]');
    expect(mocks.idbDel).not.toHaveBeenCalledWith('gt.phoneKeypair');
  });

  it('still requests remote sign-out and reports incomplete cleanup when browser deletion fails', async () => {
    mocks.idbKeys.mockResolvedValue(['gt.relay.cache.old']);
    mocks.idbDel.mockImplementation(async (key) => {
      if (key === 'gt.relay.cache.old') throw new Error('storage failure');
    });
    await expect(useAppStore.getState().signOut()).rejects.toThrow();
    expect(mocks.signOut).toHaveBeenCalledOnce();
    expect(useAppStore.getState().user).toBeNull();
    expect(useAppStore.getState().signOutError).toMatch(/cleanup.*incomplete/i);
    expect(useAppStore.getState().signingOut).toBe(false);
  });

  it('retries failed account-cache deletion even after local sign-out cleared the user', async () => {
    const key = 'gt.relay.cache.v2.["one","test-mac"]';
    mocks.idbKeys.mockResolvedValue([key]);
    mocks.idbDel.mockImplementation(async (entry) => {
      if (entry === key) throw new Error('storage failure');
    });
    await expect(useAppStore.getState().signOut()).rejects.toThrow();
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
    await useAppStore.getState().signOut();
    expect(mocks.idbDel).toHaveBeenCalledWith(key);
    expect(useAppStore.getState().signOutError).toBeNull();
  });

  it('keeps logout pending until auth removal completes and ignores a stale session during cleanup', async () => {
    let finish!: () => void;
    mocks.signOut.mockImplementation(() => new Promise((resolve) => {
      finish = () => resolve({ error: null });
    }));
    const signingOut = useAppStore.getState().signOut();
    expect(useAppStore.getState().signingOut).toBe(true);
    await useAppStore.getState().bootstrap();
    expect(useAppStore.getState().user).toBeNull();
    finish();
    await signingOut;
    expect(useAppStore.getState().signingOut).toBe(false);
  });

  it('removes only legacy copies when restoring an already signed-out browser', async () => {
    useAppStore.setState({ user: null });
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    mocks.idbKeys.mockResolvedValue(['gt.relay.cache.old', 'gt.relay.cache.v2.["two","test-mac"]']);
    await useAppStore.getState().bootstrap();
    expect(mocks.idbDel).toHaveBeenCalledWith('gt.relay.cache.old');
    expect(mocks.idbDel).not.toHaveBeenCalledWith('gt.relay.cache.v2.["two","test-mac"]');
  });

  it('reports an automatic session-cleanup failure and retains its account scope for retry', async () => {
    const key = 'gt.relay.cache.v2.["one","test-mac"]';
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    mocks.idbKeys.mockResolvedValue([key]);
    mocks.idbDel.mockRejectedValue(new Error('storage failure'));
    await useAppStore.getState().bootstrap();
    expect(useAppStore.getState().signOutError).toMatch(/cleanup.*incomplete/i);
    expect(useAppStore.getState().user).toBeNull();
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
    await useAppStore.getState().signOut();
    expect(mocks.idbDel).toHaveBeenCalledWith(key);
  });

  it('removes expired in-memory content at the relay deadline without a new frame', async () => {
    await useAppStore.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    const now = Date.now();
    relay.opts.onHello?.({ hostVersion: 'test', hostOsVersion: 'test', hostDeviceLabel: 'Test Mac',
      supportedAdapters: [], currentLayout: { shape: GridShape.OneByOne, cells: [] }, remoteApps: [], protocolVersion: 4,
    }, false, { version: 1, receivedAt: now - 100, expiresAt: now + 100 });
    expect(useAppStore.getState().hostHello).not.toBeNull();
    relay.opts.onState?.({ online: false });
    await vi.advanceTimersByTimeAsync(100);
    expect(useAppStore.getState().hostHello).toBeNull();
    expect(useAppStore.getState().layout).toBeNull();
    expect(useAppStore.getState().error).toMatch(/expired/i);
  });

  it.each([true, false])('keeps cached greeting presence truthful when online=%s', async (online) => {
    await useAppStore.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    relay.opts.onState?.({ connected: true, online });
    const hello: Hello = {
      hostVersion: 'test', hostOsVersion: 'test', hostDeviceLabel: 'Test Mac',
      supportedAdapters: [], currentLayout: { shape: GridShape.OneByOne, cells: [] }, remoteApps: [], protocolVersion: 4,
    };
    relay.opts.onHello?.(hello, true);
    expect(useAppStore.getState().relayHostOnline).toBe(online);
    if (online) expect(useAppStore.getState().error).toBeNull();
    else expect(useAppStore.getState().error).toBeTruthy();
  });

  it('blocks control while the Mac restricts access even after a browser requests control', async () => {
    await useAppStore.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    const hello: Hello = {
      hostVersion: 'test', hostOsVersion: 'test', hostDeviceLabel: 'Test Mac',
      supportedAdapters: [], currentLayout: { shape: GridShape.OneByOne, cells: [] },
      remoteApps: [], protocolVersion: 4, hostReadOnly: true,
    };
    relay.opts.onHello?.(hello, false);
    useAppStore.getState().setReadOnly(false);
    expect(useAppStore.getState().sendText('terminal', 'test', true)).toBe(false);
    expect(relay.sendUserInput).not.toHaveBeenCalled();
    expect(useAppStore.getState().requestMessageDetail('terminal', 'message')).toBe(true);
    relay.opts.onHello?.({ ...hello, hostReadOnly: false }, false);
    expect(useAppStore.getState().sendText('terminal', 'test', true)).toBe(true);
  });

  it('does not send permission updates that mutate global policy on older hosts', async () => {
    await useAppStore.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    useAppStore.getState().setReadOnly(true);
    relay.opts.onHello?.({
      hostVersion: 'old', hostOsVersion: 'test', hostDeviceLabel: 'Test Mac',
      supportedAdapters: [], currentLayout: { shape: GridShape.OneByOne, cells: [] },
      remoteApps: [], protocolVersion: 4,
    }, false);
    expect(useAppStore.getState().sendText('terminal', 'test', true)).toBe(false);
    useAppStore.getState().setReadOnly(false);
    expect(relay.sendReadOnlyUpdate).not.toHaveBeenCalled();
    expect(useAppStore.getState().sendText('terminal', 'test', true)).toBe(true);
  });

  it('clears expanded output on disconnect and ignores late responses', async () => {
    const relay = await connectWithDetail();
    useAppStore.getState().disconnectPeer();
    relay.opts.onMessageDetail?.(detail);
    expect(useAppStore.getState().messageDetails).toEqual({});
  });

  it('leaves the workspace and stops reconnecting after access is revoked', async () => {
    const relay = await connectWithDetail();
    relay.opts.onClose?.({ code: 4003, reason: 'access revoked' } as CloseEvent, false);
    relay.opts.onMessageDetail?.(detail);
    expect(useAppStore.getState().route).toBe('hosts');
    expect(useAppStore.getState().pairedHost).toBeNull();
    expect(useAppStore.getState().messageDetails).toEqual({});
    expect(useAppStore.getState().accessRevocationNotice).toMatch(/access.*revoked/i);
    await vi.advanceTimersByTimeAsync(120_000);
    expect(mocks.relays).toHaveLength(1);
    expect(useAppStore.getState().user?.id).toBe('one');
  });

  it('clears expanded output when forgetting the Mac', async () => {
    await connectWithDetail();
    await useAppStore.getState().forgetCurrentMac();
    expect(useAppStore.getState().messageDetails).toEqual({});
    expect(useAppStore.getState().pairedHost).toBeNull();
  });

  it('reauthenticates after routine expiry without treating it as revocation', async () => {
    const relay = await connectWithDetail();
    relay.opts.onClose?.({ code: 4001, reason: 'authentication expired' } as CloseEvent, false);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(mocks.relays.length).toBeGreaterThan(1);
    expect(useAppStore.getState().pairedHost?.deviceId).toBe(host.deviceId);
    expect(useAppStore.getState().route).toBe('workspace');
    expect(useAppStore.getState().accessRevocationNotice).toBeNull();
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
