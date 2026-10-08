import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  requestPasswordReset: vi.fn(),
  resetPassword: vi.fn(),
  getSession: vi.fn(),
  readPasswordResetToken: vi.fn<() => string | null>(),
  takeInvalidPasswordResetLink: vi.fn<() => boolean>(),
  clearPasswordResetToken: vi.fn(),
  takeSignInFromThisTab: vi.fn<() => boolean>(),
  idbDel: vi.fn<(key: string) => Promise<void>>(),
  onAuthStateChange: vi.fn(),
  signOut: vi.fn(async () => ({ error: null })),
}));

vi.mock('./authClient', () => ({
  hasAccountAuth: () => true,
  authClient: {
    auth: {
      initialize: vi.fn(async () => {}),
      onAuthStateChange: mocks.onAuthStateChange,
      getSession: mocks.getSession,
      signOut: mocks.signOut,
      requestPasswordReset: mocks.requestPasswordReset,
      resetPassword: mocks.resetPassword,
    },
  },
  readPasswordResetToken: mocks.readPasswordResetToken,
  takeInvalidPasswordResetLink: mocks.takeInvalidPasswordResetLink,
  clearPasswordResetToken: mocks.clearPasswordResetToken,
  takeSignInFromThisTab: mocks.takeSignInFromThisTab,
}));
vi.mock('idb-keyval', () => ({
  get: vi.fn(async () => undefined),
  set: vi.fn(async () => {}),
  del: mocks.idbDel,
  keys: vi.fn(async () => ['gt.relay.cache.v2.["user-one","test-mac"]']),
}));
vi.mock('@glasstunnel/shared-crypto', async (importOriginal) => ({
  ...await importOriginal<typeof import('@glasstunnel/shared-crypto')>(),
  generateDeviceKeypair: vi.fn(async () => ({
    deviceId: 'test-phone', publicKey: new Uint8Array(32), privateKey: new Uint8Array(32),
  })),
}));
vi.mock('../notifications/push', () => ({ registerPushSubscription: vi.fn(async () => {}) }));

import { useAppStore } from './store';
import { PASSWORD_RESET_COPY as COPY, type PasswordResetFlow } from './passwordReset';
import { clearPendingLinkCode } from './pendingLinkCode';
import type { Session } from './authClient';

const LINK_CODE_KEY = 'gt.pending-link-code';

function memoryStorage(): Storage {
  const data = new Map<string, string>();
  return {
    get length() {
      return data.size;
    },
    clear: () => data.clear(),
    getItem: (key) => data.get(key) ?? null,
    key: (index) => [...data.keys()][index] ?? null,
    removeItem: (key) => void data.delete(key),
    setItem: (key, value) => void data.set(key, String(value)),
  };
}

/** The app's address bar, for checks on the Mac linkCode. */
const page = { location: { href: '', search: '' }, replaced: [] as string[] };

function openAt(href: string) {
  const url = new URL(href);
  page.location.href = url.toString();
  page.location.search = url.search;
}

/** A Mac code kept by a forgot flow, as pendingLinkCode stores it. */
function keepLinkCode(code: string, email: string, savedAt = Date.now()) {
  localStorage.setItem(LINK_CODE_KEY, JSON.stringify({ code, savedAt, email }));
}

function keptLinkCode() {
  return JSON.parse(localStorage.getItem(LINK_CODE_KEY) ?? 'null');
}

function session(userId: string): Session {
  return { access_token: `${userId}-token`, refresh_token: `${userId}-token`, user: { id: userId, email: `${userId}@glasstunnel.test` } };
}

/** The store's auth listener, as bootstrap registered it. */
async function authListener(): Promise<(event: string, session: Session | null) => void> {
  if (mocks.onAuthStateChange.mock.calls.length === 0) await useAppStore.getState().bootstrap();
  return mocks.onAuthStateChange.mock.calls[0][0];
}

const authFailure = (status: number | undefined, code?: string) =>
  Object.assign(new Error('server words'), { status, code });

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe('password reset in the app store', () => {
  beforeEach(() => {
    page.replaced = [];
    openAt('https://app.example.test/');
    vi.stubGlobal('window', {
      setTimeout, clearTimeout, setInterval, clearInterval,
      location: page.location,
      history: {
        state: null,
        replaceState: (_state: unknown, _title: string, url: string) => {
          page.replaced.push(url);
          openAt(new URL(url, page.location.href).toString());
        },
      },
    });
    vi.stubGlobal('localStorage', memoryStorage());
    // No tab holds a Mac code from an earlier test.
    clearPendingLinkCode();
    vi.stubGlobal('navigator', { userAgent: 'test-browser' });
    mocks.requestPasswordReset.mockReset().mockResolvedValue({ error: null });
    mocks.resetPassword.mockReset().mockResolvedValue({ error: null });
    mocks.getSession.mockReset().mockResolvedValue({ data: { session: null }, error: null });
    mocks.readPasswordResetToken.mockReset().mockReturnValue(null);
    mocks.takeInvalidPasswordResetLink.mockReset().mockReturnValue(false);
    mocks.clearPasswordResetToken.mockReset();
    // Sessions come from another tab, a reload, or a refresh unless a test says otherwise.
    mocks.takeSignInFromThisTab.mockReset().mockReturnValue(false);
    mocks.idbDel.mockReset().mockResolvedValue(undefined);
    useAppStore.setState({
      route: 'auth',
      user: null,
      passwordResetFlow: null,
      signingOut: false,
      signOutError: null,
      pairedHost: null,
      availableHosts: [],
      phoneKeypair: null,
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('opens the reset screen for a link before start-up does anything async, even while signed in', async () => {
    mocks.readPasswordResetToken.mockReturnValue('link-token');
    useAppStore.setState({
      route: 'workspace',
      user: { id: 'user-one', email: 'one@glasstunnel.test', displayName: 'One' },
    });
    const starting = useAppStore.getState().bootstrap();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: 'link-token', status: 'idle', error: null });
    await starting;
    expect(useAppStore.getState().passwordResetFlow).toMatchObject({ screen: 'reset', token: 'link-token' });
  });

  it('keeps an open reset screen when the same link is read again (StrictMode, reload)', () => {
    mocks.readPasswordResetToken.mockReturnValue('link-token');
    useAppStore.setState({ passwordResetFlow: { screen: 'reset', token: 'link-token', status: 'idle', error: COPY.unavailable } });
    useAppStore.getState().loadPasswordResetLink();
    expect(useAppStore.getState().passwordResetFlow).toMatchObject({ error: COPY.unavailable });
  });

  it('shows the expired-link state for a reset link without a usable token', () => {
    mocks.takeInvalidPasswordResetLink.mockReturnValue(true);
    useAppStore.getState().loadPasswordResetLink();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: null, status: 'invalid', error: null });
  });

  it('leaves the app alone without a reset link', () => {
    useAppStore.getState().loadPasswordResetLink();
    expect(useAppStore.getState().passwordResetFlow).toBeNull();
  });

  it('sends a reset request with the normalized email and reports it as sent', async () => {
    const answer = deferred<{ error: unknown }>();
    mocks.requestPasswordReset.mockReturnValue(answer.promise);
    useAppStore.getState().openForgotPassword();
    const sending = useAppStore.getState().requestPasswordReset(' Person@Example.test ');
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'forgot', status: 'sending', error: null });
    // A second tap while sending does not send again.
    expect(await useAppStore.getState().requestPasswordReset('person@example.test')).toBe(false);
    answer.resolve({ error: null });
    expect(await sending).toBe(true);
    expect(mocks.requestPasswordReset).toHaveBeenCalledOnce();
    expect(mocks.requestPasswordReset).toHaveBeenCalledWith('person@example.test');
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'forgot', status: 'sent', error: null });
  });

  it('explains disabled reset, rate limits, outages, and an empty email', async () => {
    useAppStore.getState().openForgotPassword();
    mocks.requestPasswordReset.mockResolvedValueOnce({ error: authFailure(400, 'RESET_PASSWORD_DISABLED') });
    expect(await useAppStore.getState().requestPasswordReset('person@example.test')).toBe(false);
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'forgot', status: 'idle', error: COPY.disabled });

    mocks.requestPasswordReset.mockResolvedValueOnce({ error: authFailure(429) });
    await useAppStore.getState().requestPasswordReset('person@example.test');
    expect(useAppStore.getState().passwordResetFlow).toMatchObject({ status: 'idle', error: COPY.rateLimited });

    mocks.requestPasswordReset.mockResolvedValueOnce({ error: authFailure(undefined) });
    await useAppStore.getState().requestPasswordReset('person@example.test');
    expect(useAppStore.getState().passwordResetFlow).toMatchObject({ status: 'idle', error: COPY.unavailable });

    mocks.requestPasswordReset.mockClear();
    await useAppStore.getState().requestPasswordReset('   ');
    expect(useAppStore.getState().passwordResetFlow).toMatchObject({ status: 'idle', error: COPY.emptyEmail });
    expect(mocks.requestPasswordReset).not.toHaveBeenCalled();
  });

  it('does not reopen the forgot screen when the person left before the answer arrived', async () => {
    const answer = deferred<{ error: unknown }>();
    mocks.requestPasswordReset.mockReturnValue(answer.promise);
    useAppStore.getState().openForgotPassword();
    const sending = useAppStore.getState().requestPasswordReset('person@example.test');
    useAppStore.getState().closePasswordReset();
    answer.resolve({ error: authFailure(429) });
    await sending;
    expect(useAppStore.getState().passwordResetFlow).toBeNull();
  });

  it('updates the password, forgets the token, and signs the account out on this browser', async () => {
    useAppStore.setState({
      route: 'workspace',
      user: { id: 'user-one', email: 'one@glasstunnel.test', displayName: 'One' },
      passwordResetFlow: { screen: 'reset', token: 'link-token', status: 'idle', error: null },
    });
    const answer = deferred<{ error: unknown }>();
    mocks.resetPassword.mockReturnValue(answer.promise);
    const updating = useAppStore.getState().completePasswordReset('link-token', 'a new correct horse');
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: 'link-token', status: 'updating', error: null });
    answer.resolve({ error: null });
    expect(await updating).toBe(true);
    expect(mocks.resetPassword).toHaveBeenCalledWith({ token: 'link-token', newPassword: 'a new correct horse' });
    expect(mocks.clearPasswordResetToken).toHaveBeenCalled();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: null, status: 'done', error: null });
    expect(useAppStore.getState().user).toBeNull();
    expect(useAppStore.getState().route).toBe('auth');
    // The signed-out account's offline copies go too.
    expect(mocks.idbDel).toHaveBeenCalledWith('gt.relay.cache.v2.["user-one","test-mac"]');
  });

  it('shows the expired-link state and forgets the token when the server rejects it', async () => {
    useAppStore.setState({ passwordResetFlow: { screen: 'reset', token: 'used', status: 'idle', error: null } });
    mocks.resetPassword.mockResolvedValue({ error: authFailure(400, 'INVALID_TOKEN') });
    expect(await useAppStore.getState().completePasswordReset('used', 'a new correct horse')).toBe(false);
    expect(mocks.clearPasswordResetToken).toHaveBeenCalled();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: null, status: 'invalid', error: null });
  });

  it('keeps the token for a retry after other failures and checks length before sending', async () => {
    useAppStore.setState({ passwordResetFlow: { screen: 'reset', token: 'keep', status: 'idle', error: null } });
    expect(await useAppStore.getState().completePasswordReset('keep', 'short')).toBe(false);
    expect(mocks.resetPassword).not.toHaveBeenCalled();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: 'keep', status: 'idle', error: COPY.tooShort });

    mocks.resetPassword.mockResolvedValue({ error: authFailure(503) });
    expect(await useAppStore.getState().completePasswordReset('keep', 'a new correct horse')).toBe(false);
    expect(mocks.clearPasswordResetToken).not.toHaveBeenCalled();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'reset', token: 'keep', status: 'idle', error: COPY.unavailable });
  });

  it('opens and closes the screens, forgetting a pending token on the way out', () => {
    useAppStore.getState().openForgotPassword();
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'forgot', status: 'idle', error: null });
    useAppStore.getState().closePasswordReset();
    expect(useAppStore.getState().passwordResetFlow).toBeNull();
    expect(mocks.clearPasswordResetToken).toHaveBeenCalledTimes(2);
  });

  it('keeps the Mac linkCode through the forgot flow, bound to the address the reset is sent for', async () => {
    // The Mac opened sign-in with its code; the person typed an email and chose "Forgot password?".
    openAt('https://app.example.test/?linkCode=ABC234&authProvider=email');
    const before = Date.now();
    useAppStore.getState().openForgotPassword(' Typed@Glasstunnel.test ');
    const saved = keptLinkCode();
    expect(saved).toMatchObject({ code: 'ABC234', email: 'typed@glasstunnel.test' });
    expect(saved.savedAt).toBeGreaterThanOrEqual(before);
    // The code leaves this tab's address bar, so this tab cannot claim it a
    // second time when the reset tab's sign-in reaches it.
    expect(page.replaced).toEqual(['/?authProvider=email']);
    expect(page.location.search).toBe('?authProvider=email');

    // The reset is requested for the address on the forgot screen; the kept code follows it.
    expect(await useAppStore.getState().requestPasswordReset(' User-One@Glasstunnel.test ')).toBe(true);
    expect(keptLinkCode()).toEqual({ code: 'ABC234', savedAt: saved.savedAt, email: 'user-one@glasstunnel.test' });

    // A request the server refused changes nothing.
    mocks.requestPasswordReset.mockResolvedValueOnce({ error: authFailure(429) });
    expect(await useAppStore.getState().requestPasswordReset('someone-else@glasstunnel.test')).toBe(false);
    expect(keptLinkCode().email).toBe('user-one@glasstunnel.test');
  });

  it('links the Mac when the reset tab signs in to the reset account, with no linkCode before that sign-in', async () => {
    const notify = await authListener();
    // The Mac's sign-in tab: forgot password, reset email sent for user-one.
    openAt('https://app.example.test/?linkCode=ABC234&authProvider=email');
    useAppStore.getState().openForgotPassword('user-one@glasstunnel.test');
    expect(await useAppStore.getState().requestPasswordReset('user-one@glasstunnel.test')).toBe(true);

    // The emailed link opens a new tab without the code; the reset finishes there.
    page.replaced = [];
    openAt('https://app.example.test/');
    useAppStore.setState({
      user: null,
      phoneKeypair: null,
      passwordResetFlow: { screen: 'reset', token: 'link-token', status: 'idle', error: null },
    });
    expect(await useAppStore.getState().completePasswordReset('link-token', 'a new correct horse')).toBe(true);

    // "Back to sign in" only returns to the sign-in form.
    useAppStore.getState().closePasswordReset();
    expect(useAppStore.getState().passwordResetFlow).toBeNull();
    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('');

    // Signing in there with the reset address: the code is in the address bar
    // before the route is chosen, so the hosts screen claims it as usual.
    mocks.takeSignInFromThisTab.mockReturnValueOnce(true);
    notify('SIGNED_IN', session('user-one'));
    expect(page.replaced).toEqual(['/?linkCode=ABC234']);
    expect(localStorage.getItem(LINK_CODE_KEY)).toBeNull();
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(useAppStore.getState().route).toBe('hosts');
  });

  it('never gives the kept Mac linkCode to a sign-in to another account', async () => {
    const notify = await authListener();
    keepLinkCode('ABC234', 'user-one@glasstunnel.test');
    useAppStore.setState({ user: null, phoneKeypair: null });
    mocks.takeSignInFromThisTab.mockReturnValueOnce(true);
    notify('SIGNED_IN', session('user-two'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-two'));
    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('');
    // It stays for its own account until it expires.
    expect(keptLinkCode()).toMatchObject({ code: 'ABC234', email: 'user-one@glasstunnel.test' });
  });

  it('matches the reset account email in any case', async () => {
    const notify = await authListener();
    keepLinkCode('ABC234', 'user-one@glasstunnel.test');
    useAppStore.setState({ user: null, phoneKeypair: null });
    mocks.takeSignInFromThisTab.mockReturnValueOnce(true);
    const mixedCase = session('user-one');
    mixedCase.user.email = 'User-One@GlassTunnel.TEST';
    notify('SIGNED_IN', mixedCase);
    expect(page.replaced).toEqual(['/?linkCode=ABC234']);
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
  });

  it('does not restore for a session adopted from another tab, a reload, or a token refresh', async () => {
    const notify = await authListener();
    keepLinkCode('ABC234', 'user-one@glasstunnel.test');

    // Another tab signed in to the same account (cross-tab storage sync); this tab did nothing.
    useAppStore.setState({ user: null, phoneKeypair: null });
    notify('SIGNED_IN', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));

    // A reload reads the stored session.
    useAppStore.setState({ user: null });
    notify('INITIAL_SESSION', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(mocks.takeSignInFromThisTab).toHaveBeenCalledTimes(2);

    // A token refresh never asks, even with a sign-in from this tab not yet taken.
    mocks.takeSignInFromThisTab.mockReturnValue(true);
    notify('TOKEN_REFRESHED', session('user-one'));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(mocks.takeSignInFromThisTab).toHaveBeenCalledTimes(2);

    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('');
    expect(keptLinkCode()).toMatchObject({ code: 'ABC234' });
  });

  it('lets only the first of two tabs that sign in to the account restore the Mac linkCode', async () => {
    const notify = await authListener();
    keepLinkCode('ABC234', 'user-one@glasstunnel.test');
    useAppStore.setState({ user: null, phoneKeypair: null });
    mocks.takeSignInFromThisTab.mockReturnValueOnce(true);
    notify('SIGNED_IN', session('user-one'));
    expect(page.replaced).toEqual(['/?linkCode=ABC234']);
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));

    // Another tab of this browser signs in to the same account itself: nothing is left to restore.
    page.replaced = [];
    openAt('https://app.example.test/');
    useAppStore.setState({ user: null });
    mocks.takeSignInFromThisTab.mockReturnValueOnce(true);
    notify('SIGNED_IN', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('');
  });

  it('ignores and removes an expired Mac linkCode at sign-in', async () => {
    const notify = await authListener();
    keepLinkCode('ABC234', 'user-one@glasstunnel.test', Date.now() - 10 * 60_000 - 1_000);
    useAppStore.setState({ user: null, phoneKeypair: null });
    mocks.takeSignInFromThisTab.mockReturnValueOnce(true);
    notify('SIGNED_IN', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(page.replaced).toEqual([]);
    expect(localStorage.getItem(LINK_CODE_KEY)).toBeNull();
  });

  it('never puts the kept Mac linkCode into the address bar on "Back to sign in"', () => {
    openAt('https://app.example.test/?linkCode=ABC234');
    useAppStore.getState().openForgotPassword('user-one@glasstunnel.test');
    page.replaced = [];
    const flows: PasswordResetFlow[] = [
      { screen: 'forgot', status: 'idle', error: null },
      { screen: 'forgot', status: 'sent', error: null },
      { screen: 'reset', token: 'link-token', status: 'idle', error: null },
      { screen: 'reset', token: null, status: 'invalid', error: null },
      { screen: 'reset', token: null, status: 'done', error: null },
    ];
    for (const flow of flows) {
      useAppStore.setState({ user: null, passwordResetFlow: flow });
      useAppStore.getState().closePasswordReset();
      expect(useAppStore.getState().passwordResetFlow).toBeNull();
    }
    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('');
    expect(keptLinkCode()).toMatchObject({ code: 'ABC234', email: 'user-one@glasstunnel.test' });

    // "Request a new link" in the reset tab (no code in the address bar) keeps the saved code.
    useAppStore.getState().openForgotPassword('');
    expect(keptLinkCode()).toMatchObject({ code: 'ABC234', email: 'user-one@glasstunnel.test' });
  });

  it('keeps a linkCode the browser cannot store in the address bar', () => {
    vi.stubGlobal('localStorage', undefined);
    openAt('https://app.example.test/?linkCode=ABC234');
    useAppStore.getState().openForgotPassword('user-one@glasstunnel.test');
    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('?linkCode=ABC234');
  });

  it('forgets a saved Mac linkCode when the person signs out', async () => {
    useAppStore.setState({ user: { id: 'user-one', email: 'user-one@glasstunnel.test', displayName: 'One' } });
    keepLinkCode('ABC234', 'user-one@glasstunnel.test');
    await useAppStore.getState().signOut();
    expect(localStorage.getItem(LINK_CODE_KEY)).toBeNull();
  });

  it('closes the forgot screen when a sign-in finishes, so it never covers the signed-in app', async () => {
    const notify = await authListener();
    useAppStore.setState({ user: null, phoneKeypair: null, passwordResetFlow: { screen: 'forgot', status: 'sending', error: null } });
    notify('SIGNED_IN', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(useAppStore.getState().passwordResetFlow).toBeNull();
    expect(useAppStore.getState().route).toBe('hosts');
  });

  it('closes the Mac tab\'s forgot screen for a sign-in from another tab without handing it the linkCode', async () => {
    const notify = await authListener();
    openAt('https://app.example.test/?linkCode=ABC234');
    useAppStore.getState().openForgotPassword('user-one@glasstunnel.test');
    useAppStore.setState({ user: null, phoneKeypair: null });
    page.replaced = [];
    notify('SIGNED_IN', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(useAppStore.getState().passwordResetFlow).toBeNull();
    expect(page.replaced).toEqual([]);
    expect(page.location.search).toBe('');
    expect(keptLinkCode()).toMatchObject({ code: 'ABC234' });
  });

  it('keeps a reset link screen, and a forgot screen opened while already signed in, when the session updates', async () => {
    const notify = await authListener();
    const resetFlow = { screen: 'reset', token: 'link-token', status: 'idle', error: null } as const;
    useAppStore.setState({ user: null, phoneKeypair: null, passwordResetFlow: resetFlow });
    notify('SIGNED_IN', session('user-one'));
    await vi.waitFor(() => expect(useAppStore.getState().user?.id).toBe('user-one'));
    expect(useAppStore.getState().passwordResetFlow).toEqual(resetFlow);

    // Signed in, an expired link, then "Request a new link": a session refresh leaves it open.
    useAppStore.setState({ passwordResetFlow: { screen: 'forgot', status: 'idle', error: null } });
    notify('SIGNED_IN', session('user-one'));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(useAppStore.getState().passwordResetFlow).toEqual({ screen: 'forgot', status: 'idle', error: null });
  });
});
