import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountHost } from './accountApi';
import type { Session } from './authClient';

type AuthEvent = 'INITIAL_SESSION' | 'SIGNED_IN' | 'SIGNED_OUT' | 'TOKEN_REFRESHED';
type AuthListener = (event: AuthEvent, session: Session | null) => void;

const mocks = vi.hoisted(() => ({
  initialize: vi.fn(async () => {}),
  onAuthStateChange: vi.fn(),
  getSession: vi.fn(),
  refreshSession: vi.fn(),
  signOut: vi.fn(async () => ({ error: null })),
  registerBrowserDevice: vi.fn(),
  fetchAccountHosts: vi.fn(),
  claimHostCode: vi.fn(),
  idbGet: vi.fn(),
  idbSet: vi.fn(),
  idbDel: vi.fn(),
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
  claimHostCode: mocks.claimHostCode,
}));
vi.mock('@glasstunnel/shared-crypto', async (importOriginal) => ({
  ...await importOriginal<typeof import('@glasstunnel/shared-crypto')>(),
  generateDeviceKeypair: vi.fn(async () => ({
    deviceId: 'test-phone', publicKey: new Uint8Array(32), privateKey: new Uint8Array(32),
  })),
}));
// Node has no IndexedDB: nothing is stored between loads.
vi.mock('idb-keyval', () => ({
  get: mocks.idbGet,
  set: mocks.idbSet,
  del: mocks.idbDel,
  keys: vi.fn(async () => []),
}));
const PAIRED_HOST_KEY = 'gt.pairedHost';
vi.mock('../notifications/push', () => ({ registerPushSubscription: vi.fn(async () => {}) }));

const host: AccountHost = {
  deviceId: 'test-mac', publicKeyB64: 'test-public-key', label: 'Test Mac',
  signalingUrl: 'wss://signal.example.test/signal', pairedAtUnixMs: 1,
  online: true, trusted: true,
};
const otherHost: AccountHost = { ...host, deviceId: 'other-mac', label: 'Other Mac' };
/** What GET /account/hosts answers for a browser the account does not know yet. */
const untrusted = (entry: AccountHost): AccountHost => ({ ...entry, trusted: false });

function session(userId: string, token = `${userId}-token`): Session {
  return { access_token: token, refresh_token: token, user: { id: userId, email: `${userId}@glasstunnel.test` } };
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

/**
 * The store with fresh module state (auth subscription, sync versions), as on
 * a new page load. The auth listener announces the stored session the way the
 * real client does: once, right after it is attached.
 */
async function loadApp(initialEvent: AuthEvent | null = 'INITIAL_SESSION') {
  vi.resetModules();
  let listener: AuthListener | null = null;
  mocks.onAuthStateChange.mockImplementation((callback: AuthListener) => {
    listener = callback;
    if (initialEvent) {
      void mocks.getSession().then(({ data }: { data: { session: Session | null } }) => callback(initialEvent, data.session));
    }
    return { data: { subscription: { unsubscribe() {} } } };
  });
  const { useAppStore } = await import('./store');
  const notify = (event: AuthEvent, next: Session | null) => {
    if (!listener) throw new Error('bootstrap has not attached the auth listener');
    listener(event, next);
  };
  return { store: useAppStore, notify };
}

describe('host list loading in the app store', () => {
  beforeEach(() => {
    vi.stubGlobal('window', {
      setTimeout, clearTimeout, setInterval, clearInterval,
      location: { href: 'https://app.example.test/', origin: 'https://app.example.test', search: '' },
    });
    vi.stubGlobal('navigator', { userAgent: 'test-browser' });
    vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => {}, removeItem: () => {} });
    mocks.initialize.mockClear();
    mocks.signOut.mockClear();
    mocks.getSession.mockReset().mockResolvedValue({ data: { session: session('one') }, error: null });
    mocks.refreshSession.mockReset().mockResolvedValue({ data: { session: session('one') }, error: null });
    mocks.registerBrowserDevice.mockReset().mockResolvedValue([host]);
    mocks.fetchAccountHosts.mockReset().mockResolvedValue([host]);
    mocks.claimHostCode.mockReset();
    mocks.idbGet.mockReset().mockResolvedValue(undefined);
    mocks.idbSet.mockReset().mockResolvedValue(undefined);
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('shows the list as loading, not as an account without Macs, while this browser registers', async () => {
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    const { store } = await loadApp();
    expect(store.getState().hostsStatus).toBe('idle');

    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalled());
    expect(store.getState()).toMatchObject({
      route: 'hosts',
      user: { id: 'one' },
      availableHosts: [],
      hostsStatus: 'loading',
    });

    registration.resolve([host, otherHost]);
    await starting;
    expect(store.getState()).toMatchObject({
      route: 'hosts',
      availableHosts: [host, otherHost],
      hostsStatus: 'loaded',
      error: null,
    });
  });

  it('marks an account that really has no Macs as loaded, so the add form can show', async () => {
    mocks.registerBrowserDevice.mockResolvedValue([]);
    const { store } = await loadApp();
    await store.getState().bootstrap();
    expect(store.getState()).toMatchObject({ availableHosts: [], hostsStatus: 'loaded' });
  });

  it.each(['INITIAL_SESSION', 'SIGNED_IN'] as const)(
    'registers this browser once when start-up and %s bring the same session',
    async (event) => {
      const { store } = await loadApp(event);
      await store.getState().bootstrap();
      await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
      // Let any late synchronization run before counting.
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();
      expect(store.getState().availableHosts).toEqual([host]);
    },
  );

  it('registers once when the listener announces the session after start-up began its own sync', async () => {
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    const { store, notify } = await loadApp(null);
    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce());

    notify('INITIAL_SESSION', session('one'));
    registration.resolve([host]);
    await starting;
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();
    expect(store.getState().hostsStatus).toBe('loaded');
  });

  it('registers once when start-up runs twice (React StrictMode in development)', async () => {
    const { store } = await loadApp();
    await Promise.all([store.getState().bootstrap(), store.getState().bootstrap()]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();
    expect(store.getState().hostsStatus).toBe('loaded');
  });

  it('re-registers for a different account, showing its Macs as loading, not the old ones', async () => {
    const { store, notify } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));

    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    notify('SIGNED_IN', session('two'));
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2));
    expect(mocks.registerBrowserDevice.mock.calls[1][0]).toBe('two-token');
    expect(store.getState()).toMatchObject({
      user: { id: 'two' },
      availableHosts: [],
      hostsStatus: 'loading',
    });

    registration.resolve([otherHost]);
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
    expect(store.getState().availableHosts).toEqual([otherHost]);
  });

  it('keeps synchronizing every auth event as before, without hiding a list on screen', async () => {
    const { store, notify } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
    expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();

    // Another tab signed in to the same account with a new session.
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    notify('SIGNED_IN', session('one', 'one-new-token'));
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2));
    expect(store.getState()).toMatchObject({ availableHosts: [host], hostsStatus: 'loaded' });

    registration.resolve([host, otherHost]);
    await vi.waitFor(() => expect(store.getState().availableHosts).toEqual([host, otherHost]));
    expect(store.getState().hostsStatus).toBe('loaded');

    // The same session announced again by an auth event still synchronizes, as it always has.
    mocks.registerBrowserDevice.mockResolvedValue([host, otherHost]);
    notify('SIGNED_IN', session('one', 'one-new-token'));
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(3));

    // A token refresh is still ignored.
    notify('TOKEN_REFRESHED', session('one', 'refreshed-token'));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(3);
  });

  it('shows a failed first load as an error, not as an account without Macs', async () => {
    mocks.registerBrowserDevice.mockRejectedValue(new TypeError('Failed to fetch'));
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('error'));
    expect(store.getState()).toMatchObject({
      route: 'hosts',
      user: { id: 'one' },
      availableHosts: [],
      error: expect.stringMatching(/could not reach Glasstunnel/i),
    });
  });

  it('registers this browser again on Try again after the registration failed, not a bare fetch', async () => {
    mocks.registerBrowserDevice.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('error'));
    expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();

    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    mocks.fetchAccountHosts.mockResolvedValue([untrusted(host)]);
    const retrying = store.getState().refreshHosts({ force: true, userInitiated: true });
    // The person asked: the list shows as loading at once, the old failure goes.
    expect(store.getState()).toMatchObject({ hostsStatus: 'loading', error: null });
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2));
    expect(store.getState().hostsStatus).toBe('loading');

    registration.resolve([host]);
    await retrying;
    expect(store.getState()).toMatchObject({ availableHosts: [host], hostsStatus: 'loaded', error: null });
    expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
  });

  it('keeps the person on Your Macs when a refresh registers again, even with a Mac saved earlier', async () => {
    mocks.idbGet.mockImplementation(async (key: string) => (key === PAIRED_HOST_KEY ? host : undefined));
    mocks.registerBrowserDevice.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('error'));
    expect(store.getState().route).toBe('hosts');

    await store.getState().refreshHosts({ force: true });
    expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2);
    // A refresh lists the Macs; it does not open the saved one by itself.
    expect(store.getState()).toMatchObject({ route: 'hosts', hostsStatus: 'loaded', availableHosts: [host] });
  });

  it('keeps the person on the screen they opened when a background refresh registers again', async () => {
    mocks.registerBrowserDevice.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('error'));

    store.getState().navigateTo('profile');
    await store.getState().refreshHosts({ force: true });
    expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2);
    expect(store.getState()).toMatchObject({ route: 'profile', hostsStatus: 'loaded' });
  });

  it('keeps a failed list on screen while background refreshes register again, until one succeeds', async () => {
    mocks.registerBrowserDevice.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('error'));
    const failure = store.getState().error;
    expect(failure).toMatch(/could not reach Glasstunnel/i);

    const statuses: string[] = [];
    const unsubscribe = store.subscribe((state) => statuses.push(state.hostsStatus));
    try {
      // Opening the screen, the timer, focus: none of them hides the failure.
      mocks.registerBrowserDevice.mockRejectedValueOnce(new TypeError('Failed to fetch'));
      await store.getState().refreshHosts({ force: true });
      expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2);
      expect(store.getState()).toMatchObject({ hostsStatus: 'error', error: failure });

      const registration = deferred<AccountHost[]>();
      mocks.registerBrowserDevice.mockReturnValue(registration.promise);
      const refreshing = store.getState().refreshHosts({ force: true });
      await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(3));
      expect(store.getState()).toMatchObject({ hostsStatus: 'error', error: failure });

      registration.resolve([host]);
      await refreshing;
      expect(store.getState()).toMatchObject({ availableHosts: [host], hostsStatus: 'loaded', error: null });
      expect(statuses).not.toContain('loading');
      expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
    } finally {
      unsubscribe();
    }
  });

  it('runs Try again after a background refresh that was already running still failed', async () => {
    mocks.registerBrowserDevice.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('error'));

    const background = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValueOnce(background.promise);
    const refreshing = store.getState().refreshHosts({ force: true });
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2));

    const retry = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValueOnce(retry.promise);
    const retrying = store.getState().refreshHosts({ force: true, userInitiated: true });
    background.reject(new TypeError('Failed to fetch'));
    await refreshing;
    // The person's own attempt follows the failed one, showing progress.
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(3));
    expect(store.getState()).toMatchObject({ hostsStatus: 'loading', error: null });

    retry.resolve([host]);
    await retrying;
    expect(store.getState()).toMatchObject({ availableHosts: [host], hostsStatus: 'loaded', error: null });
  });

  it('shows a refresh of a list already on screen without a loading state, and keeps it when that refresh fails', async () => {
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));

    const fetch = deferred<AccountHost[]>();
    mocks.fetchAccountHosts.mockReturnValue(fetch.promise);
    const refreshing = store.getState().refreshHosts({ force: true });
    await vi.waitFor(() => expect(mocks.fetchAccountHosts).toHaveBeenCalledOnce());
    expect(store.getState()).toMatchObject({ availableHosts: [host], hostsStatus: 'loaded' });

    fetch.reject(new TypeError('Failed to fetch'));
    await refreshing;
    expect(store.getState()).toMatchObject({
      availableHosts: [host],
      hostsStatus: 'loaded',
      error: expect.stringMatching(/could not reach Glasstunnel/i),
    });
  });

  it('waits for this browser\'s registration instead of fetching the list while it runs', async () => {
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    // Before the registration, the Worker lists every Mac as untrusted for this browser.
    mocks.fetchAccountHosts.mockResolvedValue([untrusted(host), untrusted(otherHost)]);
    const { store } = await loadApp();
    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalled());

    // The hosts screen refreshes as soon as it shows.
    let refreshed = false;
    const refreshing = store.getState().refreshHosts({ force: true }).then(() => {
      refreshed = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
    expect(refreshed).toBe(false);
    expect(store.getState()).toMatchObject({ availableHosts: [], hostsStatus: 'loading' });

    registration.resolve([host, otherHost]);
    await Promise.all([starting, refreshing]);
    expect(store.getState()).toMatchObject({
      availableHosts: [host, otherHost],
      hostsStatus: 'loaded',
      error: null,
    });
    // One request per load: the registration brought the list.
    expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();
    expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
  });

  it('shows the failure, without a fetch, when the registration the screen waited for fails', async () => {
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    const { store } = await loadApp();
    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalled());

    const refreshing = store.getState().refreshHosts({ force: true });
    registration.reject(new TypeError('Failed to fetch'));
    await Promise.all([starting, refreshing]);
    expect(store.getState()).toMatchObject({
      availableHosts: [],
      hostsStatus: 'error',
      error: expect.stringMatching(/could not reach Glasstunnel/i),
    });
    expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
  });

  it.each(['the fetch', 'the registration'] as const)(
    'drops a list fetched before a newer registration, when %s answers first',
    async (first) => {
      const { store, notify } = await loadApp();
      await store.getState().bootstrap();
      await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));

      // A refresh for the first account is on its way when another account signs in.
      const fetch = deferred<AccountHost[]>();
      mocks.fetchAccountHosts.mockReturnValue(fetch.promise);
      const refreshing = store.getState().refreshHosts({ force: true });
      await vi.waitFor(() => expect(mocks.fetchAccountHosts).toHaveBeenCalledOnce());
      const registration = deferred<AccountHost[]>();
      mocks.registerBrowserDevice.mockReturnValue(registration.promise);
      notify('SIGNED_IN', session('two'));
      await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2));

      if (first === 'the fetch') {
        fetch.resolve([untrusted(host)]);
        await refreshing;
        expect(store.getState()).toMatchObject({ availableHosts: [], hostsStatus: 'loading' });
        registration.resolve([otherHost]);
      } else {
        registration.resolve([otherHost]);
        await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
        fetch.resolve([untrusted(host)]);
        await refreshing;
      }
      await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
      expect(store.getState()).toMatchObject({ user: { id: 'two' }, availableHosts: [otherHost] });
    },
  );

  it('shows the Macs that arrived when this browser cannot store its Mac choice', async () => {
    mocks.idbDel.mockImplementation(async (key: string) => {
      if (key === PAIRED_HOST_KEY) throw new Error('The quota has been exceeded.');
    });
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    const { store } = await loadApp();
    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalled());
    const refreshing = store.getState().refreshHosts({ force: true });

    registration.resolve([host]);
    await Promise.all([starting, refreshing]);
    expect(store.getState()).toMatchObject({
      route: 'hosts',
      availableHosts: [host],
      hostsStatus: 'loaded',
      error: expect.stringMatching(/could not save your Mac choice/i),
    });
  });

  it('never leaves the list loading when a sync stops on an unexpected failure', async () => {
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));

    // Another account signs in, and this browser's storage fails on the way.
    mocks.getSession.mockResolvedValue({ data: { session: session('two') }, error: null });
    mocks.idbDel.mockImplementation(async (key: string) => {
      if (key === PAIRED_HOST_KEY) throw new Error('The database connection is closing.');
    });
    await store.getState().bootstrap();
    expect(store.getState().hostsStatus).toBe('error');
    expect(store.getState().error).toBeTruthy();
  });

  it('keeps a Mac the person opened while the registration ran open when it answers', async () => {
    const { store, notify } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
    const startPeer = vi.fn(async () => {});
    store.setState({ startPeer });

    // Another tab signed in again; the registration is slow.
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    notify('SIGNED_IN', session('one', 'one-new-token'));
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalledTimes(2));
    expect(store.getState().route).toBe('hosts');

    await store.getState().chooseHost(host.deviceId);
    expect(store.getState()).toMatchObject({ route: 'workspace', workspaceHostDeviceId: host.deviceId });

    registration.resolve([host, otherHost]);
    await vi.waitFor(() => expect(store.getState().availableHosts).toEqual([host, otherHost]));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(store.getState()).toMatchObject({
      route: 'workspace',
      locked: false,
      pairedHost: { deviceId: host.deviceId },
      workspaceHostDeviceId: host.deviceId,
      hostsStatus: 'loaded',
    });
    expect(startPeer).toHaveBeenCalledOnce();
  });

  it('opens the Mac a Mac-started sign-in added, and keeps it open', async () => {
    const claimed: AccountHost = { ...host, deviceId: 'claimed-mac', label: 'Claimed Mac' };
    mocks.claimHostCode.mockResolvedValue(claimed);
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    window.location.search = '?linkCode=ABC234';
    const { store } = await loadApp();
    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalled());
    const startPeer = vi.fn(async () => {});
    store.setState({ startPeer });

    // The hosts screen takes the code out of the address bar, refreshes, and claims it.
    window.location.search = '';
    const refreshing = store.getState().refreshHosts({ force: true });
    const opening = (async () => {
      const added = await store.getState().claimHostLinkCode('ABC234');
      await store.getState().chooseHost(added.deviceId);
    })();
    await vi.waitFor(() => expect(mocks.claimHostCode).toHaveBeenCalledOnce());

    // The registration is the slower one and listed the Macs before the claim.
    registration.resolve([host]);
    await Promise.all([starting, refreshing, opening]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(store.getState()).toMatchObject({
      route: 'workspace',
      pairedHost: { deviceId: claimed.deviceId },
      workspaceHostDeviceId: claimed.deviceId,
      availableHosts: [claimed, host],
      hostsStatus: 'loaded',
    });
    expect(mocks.registerBrowserDevice).toHaveBeenCalledOnce();
    expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
  });

  it('opens a Mac a Mac-started sign-in added as the registration lists it, when the claim answered first', async () => {
    // The claim reached the account before this browser's registration did, and
    // before the Mac's relay was up: it answers untrusted and offline.
    mocks.claimHostCode.mockResolvedValue(untrusted({ ...host, online: false }));
    const registration = deferred<AccountHost[]>();
    mocks.registerBrowserDevice.mockReturnValue(registration.promise);
    window.location.search = '?linkCode=ABC234';
    const { store } = await loadApp();
    const starting = store.getState().bootstrap();
    await vi.waitFor(() => expect(mocks.registerBrowserDevice).toHaveBeenCalled());
    const startPeer = vi.fn(async () => {});
    store.setState({ startPeer });

    window.location.search = '';
    const claiming = store.getState().claimHostLinkCode('ABC234');
    await vi.waitFor(() => expect(mocks.claimHostCode).toHaveBeenCalledOnce());
    // The registration that answers next lists that Mac for this browser, online.
    registration.resolve([host]);
    const added = await claiming;
    await starting;

    expect(added).toMatchObject({ deviceId: host.deviceId, trusted: true, online: true });
    expect(store.getState().availableHosts).toEqual([host]);
    // So it opens at once instead of showing as "Preparing" until a later refresh.
    await store.getState().chooseHost(added.deviceId);
    expect(store.getState()).toMatchObject({ route: 'workspace', workspaceHostDeviceId: host.deviceId });
    expect(mocks.fetchAccountHosts).not.toHaveBeenCalled();
  });

  it('clears the status on sign-out', async () => {
    const { store } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
    await store.getState().signOut();
    expect(store.getState()).toMatchObject({ availableHosts: [], hostsStatus: 'idle', user: null });
  });

  it('clears the status when the session ends elsewhere', async () => {
    const { store, notify } = await loadApp();
    await store.getState().bootstrap();
    await vi.waitFor(() => expect(store.getState().hostsStatus).toBe('loaded'));
    notify('SIGNED_OUT', null);
    await vi.waitFor(() => expect(store.getState().route).toBe('auth'));
    expect(store.getState()).toMatchObject({ availableHosts: [], hostsStatus: 'idle', user: null });
  });
});
