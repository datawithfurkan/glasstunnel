import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AccountApiError, type AccountHost } from './accountApi';
import type { Session } from './authClient';
import type { RelayConnectionOptions } from '../transport/RelayConnection';

const mocks = vi.hoisted(() => ({
  initialize: vi.fn(async () => {}),
  onAuthStateChange: vi.fn(),
  getSession: vi.fn(),
  refreshSession: vi.fn(),
  signOut: vi.fn(async () => ({ error: null })),
  registerBrowserDevice: vi.fn(),
  fetchAccountHosts: vi.fn(),
  renameAccountHost: vi.fn(),
  removeAccountHost: vi.fn(),
  idbGet: vi.fn(),
  idbSet: vi.fn(),
  idbDel: vi.fn(),
  idbKeys: vi.fn(),
  relays: [] as Array<{ opts: RelayConnectionOptions; disconnect: ReturnType<typeof vi.fn> }>,
}));

vi.mock('./authClient', () => ({
  hasAccountAuth: () => true,
  authClient: {
    auth: {
      initialize: mocks.initialize,
      onAuthStateChange: mocks.onAuthStateChange,
      getSession: mocks.getSession,
      refreshSession: mocks.refreshSession,
      signOut: mocks.signOut,
    },
  },
  readPasswordResetToken: () => null,
  takeInvalidPasswordResetLink: () => false,
  clearPasswordResetToken: () => {},
  takeSignInFromThisTab: () => false,
}));
vi.mock('./accountApi', async (importOriginal) => ({
  ...await importOriginal<typeof import('./accountApi')>(),
  registerBrowserDevice: mocks.registerBrowserDevice,
  fetchAccountHosts: mocks.fetchAccountHosts,
  renameAccountHost: mocks.renameAccountHost,
  removeAccountHost: mocks.removeAccountHost,
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
    sendReadOnlyUpdate = vi.fn(() => true);
    sendHeartbeat = vi.fn(() => true);
    connect = vi.fn(async () => 'test-phone');
    constructor(readonly opts: RelayConnectionOptions) {
      mocks.relays.push(this);
    }
  },
}));

const PAIRED_HOST_KEY = 'gt.pairedHost';
const REMOVED_CACHE_FAILED_NOTICE =
  'This Mac was removed from your account. Browser offline copies could not be cleared; retry in Profile.';
const REVOKED_CACHE_FAILED_NOTICE =
  'Access was revoked. Browser offline copies could not be cleared; retry in Profile.';
const cacheKeyFor = (account: string, hostId: string) => `gt.relay.cache.v2.${JSON.stringify([account, hostId])}`;

const host: AccountHost = {
  deviceId: 'gt-desk-mac', publicKeyB64: 'desk-key', label: 'Studio Mac mini',
  signalingUrl: 'wss://signal.example.test/signal', pairedAtUnixMs: 1, online: true, trusted: true,
};
const otherHost: AccountHost = {
  ...host, deviceId: 'gt-old-mac', publicKeyB64: 'old-key', online: false, lastSeenAtUnixMs: 5,
};

function session(userId: string): Session {
  return {
    access_token: `${userId}-token`,
    refresh_token: `${userId}-token`,
    user: { id: userId, email: `${userId}@glasstunnel.test` },
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}

/** A fresh page load, signed in as `one`, with both Macs listed. */
async function signedIn(options: { selected?: AccountHost } = {}) {
  vi.resetModules();
  if (options.selected) {
    const selected = options.selected;
    mocks.idbGet.mockImplementation(async (key: string) => (key === PAIRED_HOST_KEY ? selected : undefined));
  }
  mocks.onAuthStateChange.mockImplementation(() => ({ data: { subscription: { unsubscribe() {} } } }));
  const { useAppStore } = await import('./store');
  await useAppStore.getState().bootstrap();
  return useAppStore;
}

describe('renaming and removing Macs in the store', () => {
  beforeEach(() => {
    vi.stubGlobal('window', {
      setTimeout, clearTimeout, setInterval, clearInterval,
      location: { href: 'https://app.example.test/', origin: 'https://app.example.test', search: '' },
    });
    vi.stubGlobal('navigator', { userAgent: 'test-browser' });
    vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => {}, removeItem: vi.fn() });
    mocks.relays.length = 0;
    mocks.getSession.mockReset().mockResolvedValue({ data: { session: session('one') }, error: null });
    mocks.refreshSession.mockReset().mockResolvedValue({ data: { session: session('one') }, error: null });
    mocks.registerBrowserDevice.mockReset().mockResolvedValue([host, otherHost]);
    mocks.fetchAccountHosts.mockReset().mockResolvedValue([host, otherHost]);
    mocks.renameAccountHost.mockReset();
    mocks.removeAccountHost.mockReset();
    mocks.idbGet.mockReset().mockResolvedValue(undefined);
    mocks.idbSet.mockReset().mockResolvedValue(undefined);
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
    mocks.idbKeys.mockReset().mockResolvedValue([]);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('shows a new name only once the server stored it, and resolves with that name', async () => {
    const store = await signedIn();
    const answer = deferred<AccountHost>();
    mocks.renameAccountHost.mockReturnValue(answer.promise);

    const renaming = store.getState().renameHost(host.deviceId, '  Desk Mac  ');
    await vi.waitFor(() => expect(mocks.renameAccountHost).toHaveBeenCalled());
    expect(mocks.renameAccountHost).toHaveBeenCalledWith('one-token', {
      deviceId: host.deviceId, label: 'Desk Mac', requesterDeviceId: 'test-phone',
    });
    expect(store.getState().availableHosts.map((entry) => entry.label)).toEqual(['Studio Mac mini', 'Studio Mac mini']);

    answer.resolve({ ...host, label: 'Desk Mac', trusted: false, online: false, appVersion: '0.1.10' });
    await expect(renaming).resolves.toBe('Desk Mac');
    const [renamed, untouched] = store.getState().availableHosts;
    // The name and version come from the answer; this browser's view of presence and trust stays.
    expect(renamed).toMatchObject({ deviceId: host.deviceId, label: 'Desk Mac', online: true, trusted: true, appVersion: '0.1.10' });
    expect(untouched).toEqual(otherHost);
  });

  it('renames the Mac this browser has open, and keeps that name in its saved choice', async () => {
    const store = await signedIn({ selected: host });
    expect(store.getState().pairedHost?.deviceId).toBe(host.deviceId);
    mocks.renameAccountHost.mockResolvedValue({ ...host, label: 'Desk Mac' });

    await store.getState().renameHost(host.deviceId, 'Desk Mac');
    expect(store.getState().pairedHost?.label).toBe('Desk Mac');
    expect(mocks.idbSet).toHaveBeenCalledWith(PAIRED_HOST_KEY, expect.objectContaining({ label: 'Desk Mac' }));
  });

  it('checks the name before asking the server', async () => {
    const store = await signedIn();
    await expect(store.getState().renameHost(host.deviceId, '   ')).rejects.toMatchObject({
      status: 400, message: 'Enter a name.',
    });
    await expect(store.getState().renameHost(host.deviceId, 'x'.repeat(41))).rejects.toMatchObject({
      status: 400, message: 'Use 40 characters or fewer.',
    });
    await expect(store.getState().renameHost(host.deviceId, 'Desk\u202EMac')).rejects.toMatchObject({
      status: 400, message: 'Remove hidden characters from the name.',
    });
    expect(mocks.renameAccountHost).not.toHaveBeenCalled();
  });

  it('sends the composed (NFC) name, and counts an emoji as one character', async () => {
    const store = await signedIn();
    const desktop = '\u{1F5A5}';
    mocks.renameAccountHost.mockImplementation(async (_token: string, input: { label: string }) => ({
      ...host, label: input.label,
    }));

    await expect(store.getState().renameHost(host.deviceId, "Zoe\u0301's Mac")).resolves.toBe("Zo\u00E9's Mac");
    expect(mocks.renameAccountHost).toHaveBeenLastCalledWith('one-token', expect.objectContaining({ label: "Zo\u00E9's Mac" }));
    await expect(store.getState().renameHost(host.deviceId, desktop.repeat(40))).resolves.toBe(desktop.repeat(40));
    await expect(store.getState().renameHost(host.deviceId, desktop.repeat(41))).rejects.toMatchObject({
      status: 400, message: 'Use 40 characters or fewer.',
    });
    expect(mocks.renameAccountHost).toHaveBeenCalledTimes(2);
  });

  it.each([
    [new AccountApiError('Mac not found', 404), 'This Mac is no longer in your account.', true],
    // An older Worker without the rename route: nothing is known about the Mac.
    [new AccountApiError('not found', 404), "Couldn't rename this Mac. Try again.", false],
    [new AccountApiError('Use 40 characters or fewer.', 400), 'Use 40 characters or fewer.', false],
    [new AccountApiError('account plane unavailable', 503), "Glasstunnel can't update your account right now. Try again in a moment.", false],
    [new TypeError('Failed to fetch'), "Couldn't reach Glasstunnel. Check your connection and try again.", true],
  ])('keeps the name and explains a failed rename (%s)', async (failure, message, refreshesList) => {
    const store = await signedIn();
    mocks.registerBrowserDevice.mockClear();
    mocks.fetchAccountHosts.mockClear();
    mocks.renameAccountHost.mockRejectedValue(failure);

    await expect(store.getState().renameHost(host.deviceId, 'Desk Mac')).rejects.toMatchObject({ message });
    expect(store.getState().availableHosts.map((entry) => entry.label)).toEqual(['Studio Mac mini', 'Studio Mac mini']);
    // A Mac the server does not know, or an answer that never came: the list loads again.
    const listCalls = () => mocks.registerBrowserDevice.mock.calls.length + mocks.fetchAccountHosts.mock.calls.length;
    if (refreshesList) await vi.waitFor(() => expect(listCalls()).toBeGreaterThan(0));
    else expect(listCalls()).toBe(0);
  });

  it('asks to sign in again when the session cannot be renewed', async () => {
    const store = await signedIn();
    mocks.renameAccountHost.mockRejectedValue(new AccountApiError('auth 401', 401));
    mocks.refreshSession.mockResolvedValue({ data: { session: null }, error: new Error('refresh failed') });

    await expect(store.getState().renameHost(host.deviceId, 'Desk Mac')).rejects.toMatchObject({
      status: 401,
      message: 'Your session expired. Sign out and sign in again to manage your Macs.',
    });
  });

  it('removes a Mac from the list only after the server removed it, with its offline copies', async () => {
    mocks.idbKeys.mockResolvedValue([cacheKeyFor('one', otherHost.deviceId), cacheKeyFor('one', host.deviceId)]);
    const store = await signedIn();
    // Start-up forgets a saved choice the list does not confirm; only the removal counts here.
    mocks.idbDel.mockClear();
    const answer = deferred<void>();
    mocks.removeAccountHost.mockReturnValue(answer.promise);

    const removing = store.getState().removeHost(otherHost.deviceId);
    await vi.waitFor(() => expect(mocks.removeAccountHost).toHaveBeenCalledWith('one-token', { deviceId: otherHost.deviceId }));
    expect(store.getState().availableHosts).toHaveLength(2);

    answer.resolve();
    await removing;
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId]);
    expect(mocks.idbDel).toHaveBeenCalledWith(cacheKeyFor('one', otherHost.deviceId));
    expect(mocks.idbDel).not.toHaveBeenCalledWith(cacheKeyFor('one', host.deviceId));
    expect(mocks.idbDel).not.toHaveBeenCalledWith(PAIRED_HOST_KEY);
  });

  it('clears the open workspace and saved choice when the removed Mac is the one this browser uses', async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    store.setState({ route: 'workspace', messageDetails: { agent: {} } });
    mocks.removeAccountHost.mockResolvedValue(undefined);

    await store.getState().removeHost(host.deviceId);
    expect(relay.disconnect).toHaveBeenCalled();
    expect(store.getState()).toMatchObject({
      pairedHost: null,
      relay: null,
      route: 'hosts',
      workspaceHostDeviceId: null,
      messageDetails: {},
    });
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([otherHost.deviceId]);
    expect(mocks.idbDel).toHaveBeenCalledWith(PAIRED_HOST_KEY);
    expect(localStorage.removeItem).toHaveBeenCalledWith(`gt.webauthn.enrolled.${host.deviceId}`);
  });

  it('keeps the Mac, the selection and the workspace when the removal fails', async () => {
    const store = await signedIn({ selected: host });
    mocks.removeAccountHost.mockRejectedValue(new AccountApiError('account plane unavailable', 503));

    await expect(store.getState().removeHost(host.deviceId)).rejects.toMatchObject({
      status: 503,
      message: "Glasstunnel can't update your account right now. Try again in a moment.",
    });
    expect(store.getState().availableHosts).toHaveLength(2);
    expect(store.getState().pairedHost?.deviceId).toBe(host.deviceId);
    expect(mocks.idbDel).not.toHaveBeenCalledWith(PAIRED_HOST_KEY);
  });

  it.each([
    ['times out', Object.assign(new Error('The operation was aborted.'), { name: 'AbortError' })],
    ['loses its connection', new TypeError('Failed to fetch')],
  ])('counts a removal that %s as done when the list loaded again no longer has the Mac', async (_label, failure) => {
    mocks.idbKeys.mockResolvedValue([cacheKeyFor('one', host.deviceId)]);
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    store.setState({ route: 'workspace' });
    mocks.fetchAccountHosts.mockClear();
    mocks.removeAccountHost.mockRejectedValue(failure);
    // The Worker finished the removal after this browser stopped waiting.
    mocks.fetchAccountHosts.mockResolvedValue([otherHost]);

    await expect(store.getState().removeHost(host.deviceId)).resolves.toBeUndefined();
    expect(mocks.fetchAccountHosts).toHaveBeenCalledWith('one-token', 'test-phone');
    expect(relay.disconnect).toHaveBeenCalled();
    expect(store.getState()).toMatchObject({ pairedHost: null, route: 'hosts', accessRevocationNotice: null });
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([otherHost.deviceId]);
    expect(mocks.idbDel).toHaveBeenCalledWith(PAIRED_HOST_KEY);
    expect(mocks.idbDel).toHaveBeenCalledWith(cacheKeyFor('one', host.deviceId));
  });

  it.each([
    ['still lists the Mac', () => mocks.fetchAccountHosts.mockResolvedValue([host, otherHost])],
    ['cannot load', () => mocks.fetchAccountHosts.mockRejectedValue(new TypeError('Failed to fetch'))],
  ])('reports a removal without an answer as a connection failure when the list %s', async (_label, listAnswer) => {
    const store = await signedIn({ selected: host });
    mocks.removeAccountHost.mockRejectedValue(Object.assign(new Error('The operation was aborted.'), { name: 'AbortError' }));
    listAnswer();

    await expect(store.getState().removeHost(host.deviceId)).rejects.toMatchObject({
      message: "Couldn't reach Glasstunnel. Check your connection and try again.",
    });
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId, otherHost.deviceId]);
    expect(store.getState().pairedHost?.deviceId).toBe(host.deviceId);
    expect(mocks.idbDel).not.toHaveBeenCalledWith(PAIRED_HOST_KEY);
  });

  it('gives up on a list check that never answers and reports the connection failure', async () => {
    const store = await signedIn({ selected: host });
    mocks.removeAccountHost.mockRejectedValue(Object.assign(new Error('The operation was aborted.'), { name: 'AbortError' }));
    // The connection is stalled: the list check never settles.
    mocks.fetchAccountHosts.mockReturnValue(new Promise(() => {}));
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    try {
      const removal = store.getState().removeHost(host.deviceId);
      const outcome = expect(removal).rejects.toMatchObject({
        message: "Couldn't reach Glasstunnel. Check your connection and try again.",
      });
      await vi.waitFor(() => expect(mocks.fetchAccountHosts).toHaveBeenCalled());
      await vi.advanceTimersByTimeAsync(15_000); // HOST_REMOVAL_RECHECK_TIMEOUT_MS
      await outcome;
    } finally {
      vi.useRealTimers();
    }
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId, otherHost.deviceId]);
  });

  it('does not count a removal without an answer as done from another account\'s list', async () => {
    mocks.idbKeys.mockResolvedValue([cacheKeyFor('one', otherHost.deviceId)]);
    const store = await signedIn();
    mocks.removeAccountHost.mockImplementation(async () => {
      // Another account signs in while the request runs; its list has no such Mac.
      mocks.getSession.mockResolvedValue({ data: { session: session('two') }, error: null });
      throw new TypeError('Failed to fetch');
    });
    mocks.fetchAccountHosts.mockResolvedValue([]);

    await expect(store.getState().removeHost(otherHost.deviceId)).rejects.toMatchObject({
      message: "Couldn't reach Glasstunnel. Check your connection and try again.",
    });
    // Not handled as a removal: the Mac's offline copies stay.
    expect(mocks.idbDel).not.toHaveBeenCalledWith(cacheKeyFor('one', otherHost.deviceId));
  });

  it('reports a Mac that is no longer in the account and loads the list again', async () => {
    const store = await signedIn();
    mocks.removeAccountHost.mockRejectedValue(new AccountApiError('Mac not found', 404));
    // Removed elsewhere meanwhile: the account no longer lists it.
    mocks.fetchAccountHosts.mockResolvedValue([host]);

    await expect(store.getState().removeHost(otherHost.deviceId)).rejects.toMatchObject({
      status: 404, message: 'This Mac is no longer in your account.',
    });
    await vi.waitFor(() => expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId]));
  });

  it('treats a 404 from an older Worker without the route as a plain failure, not a missing Mac', async () => {
    const store = await signedIn();
    mocks.registerBrowserDevice.mockClear();
    mocks.fetchAccountHosts.mockClear();
    mocks.removeAccountHost.mockRejectedValue(new AccountApiError('not found', 404));

    await expect(store.getState().removeHost(otherHost.deviceId)).rejects.toMatchObject({
      message: "Couldn't remove this Mac. Try again.",
    });
    // The list stays as it is, and is not loaded again as for a Mac that left the account.
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId, otherHost.deviceId]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.registerBrowserDevice.mock.calls.length + mocks.fetchAccountHosts.mock.calls.length).toBe(0);
  });

  it("says so when this browser's offline copies of a removed Mac could not be cleared", async () => {
    const store = await signedIn();
    // IndexedDB refuses to list its keys (blocked by another tab, or broken).
    mocks.idbKeys.mockRejectedValue(new Error('IndexedDB unavailable'));
    mocks.removeAccountHost.mockResolvedValue(undefined);

    // The removal itself succeeded: no error, and the Mac leaves the list.
    await expect(store.getState().removeHost(otherHost.deviceId)).resolves.toBeUndefined();
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId]);
    expect(store.getState().accessRevocationNotice).toBe(REMOVED_CACHE_FAILED_NOTICE);
  });

  it("says so when the removed Mac's saved choice could not be forgotten", async () => {
    const store = await signedIn({ selected: host });
    mocks.idbDel.mockImplementation(async (key: string) => {
      if (key === PAIRED_HOST_KEY) throw new Error('IndexedDB unavailable');
    });
    mocks.removeAccountHost.mockResolvedValue(undefined);

    await store.getState().removeHost(host.deviceId);
    expect(store.getState()).toMatchObject({ pairedHost: null, accessRevocationNotice: REMOVED_CACHE_FAILED_NOTICE });
  });

  it("keeps the relay's cache-failure notice for the Mac this page is removing", async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    const answer = deferred<void>();
    mocks.removeAccountHost.mockReturnValue(answer.promise);
    mocks.idbDel.mockImplementation(async (key: string) => {
      if (key === PAIRED_HOST_KEY) throw new Error('IndexedDB unavailable');
    });

    const removing = store.getState().removeHost(host.deviceId);
    await vi.waitFor(() => expect(mocks.removeAccountHost).toHaveBeenCalled());
    // The relay closes this browser's socket first, and clearing its copies fails.
    relay.opts.onClose?.({ code: 4003, reason: 'mac removed from account' } as CloseEvent, false);
    await vi.waitFor(() => expect(store.getState().accessRevocationNotice).toBe(REMOVED_CACHE_FAILED_NOTICE));

    // The answer arrives, and this time clearing works: the earlier failure still stands.
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
    answer.resolve();
    await removing;
    expect(store.getState().accessRevocationNotice).toBe(REMOVED_CACHE_FAILED_NOTICE);
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([otherHost.deviceId]);
  });

  it("keeps a cache-failure notice through a rename of the same Mac, not of another one", async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    mocks.idbDel.mockImplementation(async (key: string) => {
      if (key === PAIRED_HOST_KEY) throw new Error('IndexedDB unavailable');
    });
    mocks.relays.at(-1)!.opts.onClose?.({ code: 4003, reason: 'access revoked' } as CloseEvent, false);
    await vi.waitFor(() => expect(store.getState().accessRevocationNotice).toBe(REVOKED_CACHE_FAILED_NOTICE));
    mocks.renameAccountHost.mockImplementation(async (_token: string, input: { deviceId: string; label: string }) => ({
      ...(input.deviceId === host.deviceId ? host : otherHost), label: input.label,
    }));

    // Its offline copies are still in this browser: the notice stays.
    await store.getState().renameHost(host.deviceId, 'Desk Mac');
    expect(store.getState().accessRevocationNotice).toBe(REVOKED_CACHE_FAILED_NOTICE);
    // Another Mac's change says nothing about them: the screen reports that change.
    await store.getState().renameHost(otherHost.deviceId, 'Old Mac');
    expect(store.getState().accessRevocationNotice).toBeNull();
  });

  it("replaces another Mac's cache-failure notice when a removal succeeds", async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    mocks.idbDel.mockImplementation(async (key: string) => {
      if (key === PAIRED_HOST_KEY) throw new Error('IndexedDB unavailable');
    });
    mocks.relays.at(-1)!.opts.onClose?.({ code: 4003, reason: 'access revoked' } as CloseEvent, false);
    await vi.waitFor(() => expect(store.getState().accessRevocationNotice).toBe(REVOKED_CACHE_FAILED_NOTICE));
    mocks.removeAccountHost.mockResolvedValue(undefined);

    await store.getState().removeHost(otherHost.deviceId);
    expect(store.getState().accessRevocationNotice).toBeNull();
  });

  it('replaces an earlier access notice with the outcome of a later change', async () => {
    const store = await signedIn();
    store.setState({ accessRevocationNotice: 'This Mac was removed from your account.' });
    mocks.renameAccountHost.mockResolvedValue({ ...host, label: 'Desk Mac' });

    await store.getState().renameHost(host.deviceId, 'Desk Mac');
    expect(store.getState().accessRevocationNotice).toBeNull();
  });

  it('keeps a rename when a list requested before it answers with the old name', async () => {
    const store = await signedIn();
    const staleList = deferred<AccountHost[]>();
    mocks.fetchAccountHosts.mockReturnValue(staleList.promise);
    const refreshing = store.getState().refreshHosts({ force: true });
    await vi.waitFor(() => expect(mocks.fetchAccountHosts).toHaveBeenCalled());

    mocks.renameAccountHost.mockResolvedValue({ ...host, label: 'Desk Mac' });
    await store.getState().renameHost(host.deviceId, 'Desk Mac');
    staleList.resolve([host, otherHost]);
    await refreshing;
    expect(store.getState().availableHosts.map((entry) => entry.label)).toEqual(['Desk Mac', 'Studio Mac mini']);

    // A list requested after the rename is the account's own answer.
    mocks.fetchAccountHosts.mockResolvedValue([{ ...host, label: 'Renamed elsewhere' }, otherHost]);
    await store.getState().refreshHosts({ force: true });
    expect(store.getState().availableHosts[0].label).toBe('Renamed elsewhere');
  });

  it('does not bring back a removed Mac from a list requested before the removal', async () => {
    const store = await signedIn();
    const staleList = deferred<AccountHost[]>();
    mocks.fetchAccountHosts.mockReturnValue(staleList.promise);
    const refreshing = store.getState().refreshHosts({ force: true });
    await vi.waitFor(() => expect(mocks.fetchAccountHosts).toHaveBeenCalled());

    mocks.removeAccountHost.mockResolvedValue(undefined);
    await store.getState().removeHost(otherHost.deviceId);
    staleList.resolve([host, otherHost]);
    await refreshing;
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([host.deviceId]);
  });

  it('says the Mac was removed when the relay closes because it left the account', async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    store.setState({ route: 'workspace' });

    relay.opts.onClose?.({ code: 4003, reason: 'mac removed from account' } as CloseEvent, false);
    expect(store.getState()).toMatchObject({
      route: 'hosts',
      pairedHost: null,
      accessRevocationNotice: 'This Mac was removed from your account.',
    });
    expect(store.getState().availableHosts.map((entry) => entry.deviceId)).toEqual([otherHost.deviceId]);
    await vi.waitFor(() => expect(mocks.idbDel).toHaveBeenCalledWith(PAIRED_HOST_KEY));
  });

  it('keeps the revocation wording for a 4003 close without the removal reason', async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    mocks.relays.at(-1)!.opts.onClose?.({ code: 4003, reason: 'access revoked' } as CloseEvent, false);
    expect(store.getState().accessRevocationNotice).toBe('Access to this Mac was revoked.');
  });

  it('does not add a removal notice for a Mac this page is removing itself', async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    const answer = deferred<void>();
    mocks.removeAccountHost.mockReturnValue(answer.promise);

    const removing = store.getState().removeHost(host.deviceId);
    await vi.waitFor(() => expect(mocks.removeAccountHost).toHaveBeenCalled());
    // The relay closes this browser's socket before the HTTP answer arrives.
    relay.opts.onClose?.({ code: 4003, reason: 'mac removed from account' } as CloseEvent, false);
    expect(store.getState().accessRevocationNotice).toBeNull();
    answer.resolve();
    await removing;
    expect(store.getState().accessRevocationNotice).toBeNull();
    expect(store.getState().pairedHost).toBeNull();
  });

  it('recognizes its own removal in a relay close that arrives late in the 45 s wait', async () => {
    const store = await signedIn({ selected: host });
    await store.getState().startPeer();
    const relay = mocks.relays.at(-1)!;
    const answer = deferred<void>();
    mocks.removeAccountHost.mockReturnValue(answer.promise);

    const removing = store.getState().removeHost(host.deviceId);
    await vi.waitFor(() => expect(mocks.removeAccountHost).toHaveBeenCalled());
    // 44 s into the request, just before it would give up, the relay closes.
    const startedAt = Date.now();
    const clock = vi.spyOn(Date, 'now').mockReturnValue(startedAt + 44_000);
    try {
      relay.opts.onClose?.({ code: 4003, reason: 'mac removed from account' } as CloseEvent, false);
      expect(store.getState().accessRevocationNotice).toBeNull();
    } finally {
      clock.mockRestore();
    }
    answer.resolve();
    await removing;
    expect(store.getState().accessRevocationNotice).toBeNull();
  });
});
