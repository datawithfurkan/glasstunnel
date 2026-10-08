import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const AUTH = 'https://auth.test';

type Route = (request: { path: string; init: RequestInit; headers: Headers }) => Response | Promise<Response>;

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

function userPayload(token = 'session-token') {
  return {
    session: { token, expiresAt: new Date(Date.now() + 3_600_000).toISOString() },
    user: { id: 'auth-user-1', userId: 'legacy-user-1', email: 'person@example.test', name: 'Person' },
  };
}

let calls: string[] = [];
let replacedUrl: string | null = null;

async function loadShim(
  href: string,
  routes: Record<string, Route>,
  seed: Record<string, string> = {},
  tabSeed: Record<string, string> = {},
) {
  calls = [];
  replacedUrl = null;
  vi.resetModules();
  vi.stubEnv('VITE_CONVEX_SITE_URL', AUTH);
  const store = memoryStorage();
  for (const [key, value] of Object.entries(seed)) store.setItem(key, value);
  vi.stubGlobal('localStorage', store);
  const tabStore = memoryStorage();
  for (const [key, value] of Object.entries(tabSeed)) tabStore.setItem(key, value);
  vi.stubGlobal('sessionStorage', tabStore);
  const history = {
    state: null,
    replaceState: (_state: unknown, _title: string, url: string) => {
      replacedUrl = url;
      location.href = url;
    },
  };
  const location = { href, origin: new URL(href).origin };
  vi.stubGlobal('window', { location, history, addEventListener: () => {}, removeEventListener: () => {} });
  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const request = input instanceof Request ? input : null;
    const url = new URL(request ? request.url : String(input));
    const headers = new Headers(request ? request.headers : init.headers);
    const path = url.pathname.replace(/^\/api\/auth/, '');
    calls.push(`${(request?.method ?? init.method ?? 'GET').toUpperCase()} ${path}`);
    const route = routes[path];
    if (!route) return new Response('not found', { status: 404 });
    return route({ path, init: request ? { method: request.method, body: await request.text() } : init, headers });
  });
  return import('./authClient');
}

beforeEach(() => {
  vi.unstubAllEnvs();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

describe('Better Auth session shim', () => {
  const flowSeed = (nonce: string, startedAt = Date.now(), linkCode: string | null = null) => ({
    'gt.better-auth.oauth-flow': JSON.stringify({ nonce, startedAt, linkCode }),
  });

  it('exchanges the one-time token from this browser\'s OAuth flow, keeps linkCode, and restores the session', async () => {
    const { authClient } = await loadShim('https://app.test/?linkCode=ABC234&gtAuthFlow=n1&ott=one-time', {
      '/cross-domain/one-time-token/verify': ({ init }) => {
        expect(JSON.parse(String(init.body))).toEqual({ token: 'one-time' });
        return Response.json(userPayload('from-ott'));
      },
      '/get-session': ({ headers }) => {
        expect(headers.get('authorization')).toBe('Bearer from-ott');
        return Response.json(userPayload('from-ott'));
      },
    }, flowSeed('n1'));
    const { data } = await authClient!.auth.getSession();
    expect(data.session?.access_token).toBe('from-ott');
    expect(data.session?.user.id).toBe('legacy-user-1');
    expect(replacedUrl).toBe('https://app.test/?linkCode=ABC234');
    expect(calls).toEqual(['POST /cross-domain/one-time-token/verify', 'GET /get-session']);
    expect(localStorage.getItem('gt.better-auth.oauth-flow')).toBeNull();
  });

  it('refuses a one-time token this browser did not ask for (login CSRF)', async () => {
    for (const [href, seed] of [
      ['https://app.test/?ott=attacker-token&linkCode=VICTIM', {}],
      ['https://app.test/?ott=attacker-token&gtAuthFlow=guess', flowSeed('real-nonce')],
      ['https://app.test/?ott=attacker-token&gtAuthFlow=old', flowSeed('old', Date.now() - 16 * 60_000)],
    ] as const) {
      const { authClient, readAuthRedirectError } = await loadShim(href, {
        '/cross-domain/one-time-token/verify': () => Response.json(userPayload('attacker')),
      }, { ...seed });
      expect((await authClient!.auth.getSession()).data.session).toBeNull();
      expect(await readAuthRedirectError()).toBe('This sign-in was started in another browser or tab. Start sign-in again here.');
      expect(calls).toEqual([]);
      expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
    }
  });

  it('restores a Mac linkCode the provider round trip dropped', async () => {
    const { authClient } = await loadShim('https://app.test/?gtAuthFlow=n2&ott=one-time', {
      '/cross-domain/one-time-token/verify': () => Response.json(userPayload('from-ott')),
      '/get-session': () => Response.json(userPayload('from-ott')),
    }, flowSeed('n2', Date.now(), 'LINK42'));
    await authClient!.auth.getSession();
    expect(replacedUrl).toBe('https://app.test/?linkCode=LINK42');
  });

  it('retries a one-time token exchange that hit a server error once', async () => {
    let attempts = 0;
    const { authClient } = await loadShim('https://app.test/?gtAuthFlow=n3&ott=one-time', {
      '/cross-domain/one-time-token/verify': () => (++attempts === 1 ? new Response('busy', { status: 503 }) : Response.json(userPayload('from-ott'))),
      '/get-session': () => Response.json(userPayload('from-ott')),
    }, flowSeed('n3'));
    expect((await authClient!.auth.getSession()).data.session?.access_token).toBe('from-ott');
    expect(attempts).toBe(2);
  });

  it('turns an OAuth error return into a readable message and no session', async () => {
    const { authClient, readAuthRedirectError } = await loadShim('https://app.test/?authError=1&error=access_denied&gtAuthFlow=n4', {}, flowSeed('n4'));
    expect(await readAuthRedirectError()).toBe('Sign-in was cancelled. Try again when you are ready.');
    // Still there for a second render (StrictMode), until the next attempt.
    expect(await readAuthRedirectError()).toBe('Sign-in was cancelled. Try again when you are ready.');
    const { data } = await authClient!.auth.getSession();
    expect(data.session).toBeNull();
    expect(replacedUrl).toBe('https://app.test/');
    expect(calls).toEqual([]);
  });

  it('keeps the last confirmed session while the auth server is unreachable', async () => {
    let online = true;
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-in/email': () =>
        new Response(JSON.stringify({ token: 'email-token', user: userPayload().user }), {
          headers: { 'content-type': 'application/json', 'set-auth-token': 'email-token' },
        }),
      '/get-session': () => (online ? Response.json(userPayload('email-token')) : new Response('down', { status: 503 })),
    });
    const signedIn = await authClient!.auth.signInWithPassword({ email: 'Person@Example.test ', password: 'correct horse' });
    expect(signedIn.error).toBeNull();
    expect(signedIn.data.session?.access_token).toBe('email-token');
    online = false;
    const { data, error } = await authClient!.auth.getSession();
    expect(error).toBeNull();
    expect(data.session?.user.id).toBe('legacy-user-1');
  });

  it('signs out locally when the server says the session is gone', async () => {
    let valid = true;
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-in/email': () =>
        new Response(JSON.stringify({ token: 'email-token', user: userPayload().user }), {
          headers: { 'content-type': 'application/json', 'set-auth-token': 'email-token' },
        }),
      '/get-session': () => (valid ? Response.json(userPayload('email-token')) : Response.json(null)),
    });
    await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });
    valid = false;
    expect((await authClient!.auth.getSession()).data.session).toBeNull();
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
  });

  it('sends email sign-in without a callback URL so the app does not reload', async () => {
    let body: Record<string, unknown> = {};
    const { authClient } = await loadShim('https://app.test/?linkCode=ABC234', {
      '/sign-in/email': ({ init }) => {
        body = JSON.parse(String(init.body));
        return Response.json({ code: 'INVALID_EMAIL_OR_PASSWORD', message: 'Invalid email or password' }, { status: 401 });
      },
    });
    const result = await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'wrong' });
    expect(body).not.toHaveProperty('callbackURL');
    expect(result.data.session).toBeNull();
    expect((result.error as { code?: string }).code).toBe('INVALID_EMAIL_OR_PASSWORD');
  });

  it('asks the provider flow to return errors to the app, keeping linkCode', async () => {
    let body: Record<string, unknown> = {};
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-in/social': ({ init }) => {
        body = JSON.parse(String(init.body));
        return Response.json({ url: 'https://accounts.example.test/authorize', redirect: false });
      },
    });
    await authClient!.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: 'https://app.test/?linkCode=ABC234' } });
    const flow = JSON.parse(localStorage.getItem('gt.better-auth.oauth-flow') ?? '{}');
    expect(flow.linkCode).toBe('ABC234');
    expect(flow.nonce).toMatch(/^[0-9a-f]{32}$/);
    expect(body).toMatchObject({
      provider: 'google',
      callbackURL: `https://app.test/?linkCode=ABC234&gtAuthFlow=${flow.nonce}`,
      errorCallbackURL: `https://app.test/?linkCode=ABC234&gtAuthFlow=${flow.nonce}&authError=1`,
    });
  });

  it('ends the local session at once and queues the server revocation when offline', async () => {
    let online = true;
    const signOutAuth: (string | null)[] = [];
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-in/email': () =>
        new Response(JSON.stringify({ token: 'email-token', user: userPayload().user }), {
          headers: { 'content-type': 'application/json', 'set-auth-token': 'email-token' },
        }),
      '/sign-out': ({ headers }) => {
        signOutAuth.push(headers.get('authorization'));
        return online ? Response.json({ success: true }) : new Response('down', { status: 503 });
      },
      '/get-session': () => Response.json(null),
    });
    await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });
    online = false;
    expect((await authClient!.auth.signOut()).error).toBeNull();
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBe('email-token');
    online = true;
    await authClient!.auth.getSession();
    await vi.waitFor(() => expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull());
    expect(signOutAuth).toEqual(['Bearer email-token', 'Bearer email-token']);
  });

  it('retries a queued revocation with only the old token while another account is signed in', async () => {
    const signOutAuth: (string | null)[] = [];
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-out': ({ headers }) => {
        signOutAuth.push(headers.get('authorization'));
        return Response.json({ success: true });
      },
      '/get-session': ({ headers }) => {
        expect(headers.get('authorization')).toBe('Bearer token-b');
        return Response.json(userPayload('token-b'));
      },
    }, {
      'gt.better-auth.bearer-token': 'token-b',
      'gt.better-auth.pending-revocation': 'token-a',
    });
    expect((await authClient!.auth.getSession()).data.session?.access_token).toBe('token-b');
    await vi.waitFor(() => expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull());
    // Never the current session's token, alone or mixed into the same header.
    expect(signOutAuth).toEqual(['Bearer token-a']);
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBe('token-b');
  });

  it('treats 401 on sign-out as already revoked and keeps other failures for a retry', async () => {
    const answers = [
      () => Response.json({ message: 'Unauthorized' }, { status: 401 }),
      () => new Response('down', { status: 503 }),
    ];
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-out': () => answers.shift()!(),
    }, { 'gt.better-auth.bearer-token': 'gone-token' });
    expect((await authClient!.auth.signOut()).error).toBeNull();
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull();

    localStorage.setItem('gt.better-auth.bearer-token', 'busy-token');
    expect((await authClient!.auth.signOut()).error).toBeNull();
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBe('busy-token');
  });

  it('keeps a newer queued revocation when an older retry finishes after it', async () => {
    let releaseFirst!: () => void;
    const firstHeld = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const signOutAuth: (string | null)[] = [];
    const { authClient } = await loadShim('https://app.test/', {
      '/sign-out': async ({ headers }) => {
        const authorization = headers.get('authorization');
        signOutAuth.push(authorization);
        if (authorization === 'Bearer token-a') {
          await firstHeld;
          return Response.json({ success: true });
        }
        return new Response('down', { status: 503 });
      },
      '/get-session': () => Response.json(null),
    }, { 'gt.better-auth.pending-revocation': 'token-a' });
    void authClient!.auth.getSession();
    await vi.waitFor(() => expect(signOutAuth).toEqual(['Bearer token-a']));
    // Meanwhile a sign-out in this tab queues another token and cannot reach the server.
    localStorage.setItem('gt.better-auth.bearer-token', 'token-c');
    await authClient!.auth.signOut();
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBe('token-c');
    releaseFirst();
    await vi.waitFor(() => expect(signOutAuth).toEqual(['Bearer token-a', 'Bearer token-c']));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBe('token-c');
  });

  it('never pairs a cached account with a different account\'s token', async () => {
    const { authClient } = await loadShim('https://app.test/', {
      '/get-session': () => new Response('down', { status: 503 }),
    }, {
      'gt.better-auth.bearer-token': 'token-b',
      'gt.better-auth.session-snapshot': JSON.stringify({ token: 'token-a', user: { id: 'user-a' } }),
    });
    const { data, error } = await authClient!.auth.getSession();
    expect(data.session).toBeNull();
    expect(error).toBeTruthy();
  });
});

describe('password reset', () => {
  const RESET_KEY = 'gt.password-reset-token';
  const signedIn = {
    'gt.better-auth.bearer-token': 'email-token',
    'gt.better-auth.session-snapshot': JSON.stringify({ token: 'email-token', user: { id: 'legacy-user-1' } }),
  };

  it('asks for a reset email with only the address, without the session or cookies', async () => {
    let body: unknown;
    let authorization: string | null = 'unset';
    let credentials: RequestCredentials | undefined;
    const { authClient } = await loadShim('https://app.test/?linkCode=ABC234', {
      '/request-password-reset': ({ init, headers }) => {
        body = JSON.parse(String(init.body));
        authorization = headers.get('authorization');
        credentials = init.credentials;
        return Response.json({ status: true, message: 'If this email exists in our system, check your email for the reset link' });
      },
    }, signedIn);
    const result = await authClient!.auth.requestPasswordReset(' Person@Example.test ');
    expect(result.error).toBeNull();
    expect(body).toEqual({ email: 'person@example.test' });
    expect(authorization).toBeNull();
    expect(credentials).toBe('omit');
    expect(calls).toEqual(['POST /request-password-reset']);
    expect(replacedUrl).toBeNull();
  });

  it('reports disabled reset, rate limits, and outages with status and code', async () => {
    const answers = [
      () => Response.json({ code: 'RESET_PASSWORD_DISABLED', message: "Reset password isn't enabled" }, { status: 400 }),
      () => Response.json({ message: 'Too many requests. Please try again later.' }, { status: 429, headers: { 'X-Retry-After': '60' } }),
      () => new Response('<html>app shell</html>', { status: 200, headers: { 'content-type': 'text/html' } }),
      () => {
        throw new TypeError('Failed to fetch');
      },
    ];
    const { authClient, AuthError, AuthUnavailableError } = await loadShim('https://app.test/', {
      '/request-password-reset': () => answers.shift()!(),
    });
    const disabled = await authClient!.auth.requestPasswordReset('person@example.test');
    expect(disabled.error).toBeInstanceOf(AuthError);
    expect(disabled.error).not.toBeInstanceOf(AuthUnavailableError);
    expect(disabled.error).toMatchObject({ code: 'RESET_PASSWORD_DISABLED', status: 400 });

    const limited = await authClient!.auth.requestPasswordReset('person@example.test');
    expect(limited.error).toBeInstanceOf(AuthUnavailableError);
    expect(limited.error).toMatchObject({ status: 429 });

    const notBetterAuth = await authClient!.auth.requestPasswordReset('person@example.test');
    expect(notBetterAuth.error).toBeInstanceOf(AuthUnavailableError);

    const offline = await authClient!.auth.requestPasswordReset('person@example.test');
    expect(offline.error).toBeInstanceOf(AuthUnavailableError);
    expect((offline.error as { status?: number }).status).toBeUndefined();
  });

  it('takes the token out of the address bar at once, keeps linkCode, and holds it only in this tab', async () => {
    const { readPasswordResetToken, takeInvalidPasswordResetLink, readAuthRedirectError } = await loadShim(
      'https://app.test/?linkCode=ABC234&resetPassword=1&token=tok%2Fen%3D',
      {},
    );
    const before = Date.now();
    expect(readPasswordResetToken()).toBe('tok/en=');
    expect(replacedUrl).toBe('https://app.test/?linkCode=ABC234');
    const stored = JSON.parse(sessionStorage.getItem(RESET_KEY) ?? '{}');
    expect(stored.token).toBe('tok/en=');
    expect(stored.expiresAt).toBeGreaterThanOrEqual(before + 60 * 60_000);
    expect(stored.expiresAt).toBeLessThanOrEqual(Date.now() + 60 * 60_000);
    expect(localStorage.getItem(RESET_KEY)).toBeNull();
    expect(takeInvalidPasswordResetLink()).toBe(false);
    expect(await readAuthRedirectError()).toBeNull();
    expect(calls).toEqual([]);
  });

  it('does not treat a reset link error as a Google/GitHub sign-in error', async () => {
    const { readPasswordResetToken, takeInvalidPasswordResetLink, readAuthRedirectError } = await loadShim(
      'https://app.test/?resetPassword=1&error=INVALID_TOKEN&linkCode=ABC234',
      {},
    );
    expect(await readAuthRedirectError()).toBeNull();
    expect(replacedUrl).toBe('https://app.test/?linkCode=ABC234');
    expect(readPasswordResetToken()).toBeNull();
    expect(takeInvalidPasswordResetLink()).toBe(true);
    // Reported once, so a second read (StrictMode) does not reopen it.
    expect(takeInvalidPasswordResetLink()).toBe(false);
    expect(sessionStorage.getItem(RESET_KEY)).toBeNull();
  });

  it('keeps the token across a reload for one hour, then forgets it', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-10-08T10:00:00Z'));
    const first = await loadShim('https://app.test/?resetPassword=1&token=t1', {});
    expect(first.readPasswordResetToken()).toBe('t1');
    const saved = sessionStorage.getItem(RESET_KEY)!;

    vi.setSystemTime(new Date('2026-10-08T10:59:00Z'));
    const reloaded = await loadShim('https://app.test/', {}, {}, { [RESET_KEY]: saved });
    expect(reloaded.readPasswordResetToken()).toBe('t1');
    expect(replacedUrl).toBeNull();

    vi.setSystemTime(new Date('2026-10-08T11:00:01Z'));
    expect(reloaded.readPasswordResetToken()).toBeNull();
    expect(sessionStorage.getItem(RESET_KEY)).toBeNull();

    const garbled = await loadShim('https://app.test/', {}, {}, { [RESET_KEY]: '{not json' });
    expect(garbled.readPasswordResetToken()).toBeNull();
  });

  it('sets the new password, forgets the token, and signs this browser out without reporting a failure', async () => {
    let body: unknown;
    let authorization: string | null = 'unset';
    const signOutAuth: (string | null)[] = [];
    const { authClient, readPasswordResetToken } = await loadShim('https://app.test/?resetPassword=1&token=reset-token', {
      '/get-session': () => Response.json(userPayload('email-token')),
      '/reset-password': ({ init, headers }) => {
        body = JSON.parse(String(init.body));
        authorization = headers.get('authorization');
        return Response.json({ status: true });
      },
      // Same account: the reset already ended this session on the server.
      '/sign-out': ({ headers }) => {
        signOutAuth.push(headers.get('authorization'));
        return Response.json({ message: 'Unauthorized' }, { status: 401 });
      },
    }, signedIn);
    const events: string[] = [];
    authClient!.auth.onAuthStateChange((event) => events.push(event));
    await vi.waitFor(() => expect(events).toEqual(['INITIAL_SESSION']));
    expect(readPasswordResetToken()).toBe('reset-token');

    const result = await authClient!.auth.resetPassword({ token: 'reset-token', newPassword: 'a new correct horse' });
    expect(result.error).toBeNull();
    expect(body).toEqual({ newPassword: 'a new correct horse', token: 'reset-token' });
    expect(authorization).toBeNull();
    expect(events).toEqual(['INITIAL_SESSION', 'SIGNED_OUT']);
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
    expect(localStorage.getItem('gt.better-auth.session-snapshot')).toBeNull();
    // Revoked through the sign-out path; the server's 401 means it is already gone.
    await vi.waitFor(() => expect(signOutAuth).toEqual(['Bearer email-token']));
    await vi.waitFor(() => expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull());
    expect(readPasswordResetToken()).toBeNull();
    expect(sessionStorage.getItem(RESET_KEY)).toBeNull();
    expect((await authClient!.auth.getSession()).data.session).toBeNull();
    // Nothing is left to retry.
    expect(signOutAuth).toEqual(['Bearer email-token']);
  });

  it('revokes the session of a different account this browser was signed in to', async () => {
    let otherAccountRevoked = false;
    const signOutAuth: (string | null)[] = [];
    const { authClient } = await loadShim('https://app.test/?resetPassword=1&token=reset-token', {
      '/reset-password': () => Response.json({ status: true }),
      '/sign-out': ({ headers }) => {
        const header = headers.get('authorization');
        signOutAuth.push(header);
        otherAccountRevoked = header === 'Bearer other-account-token';
        return Response.json({ success: true });
      },
      '/get-session': ({ headers }) =>
        Response.json(!otherAccountRevoked && headers.get('authorization') === 'Bearer other-account-token' ? userPayload('other-account-token') : null),
    }, {
      'gt.better-auth.bearer-token': 'other-account-token',
      'gt.better-auth.session-snapshot': JSON.stringify({ token: 'other-account-token', user: { id: 'other-user' } }),
    });
    const events: string[] = [];
    authClient!.auth.onAuthStateChange((event) => events.push(event));
    await vi.waitFor(() => expect(events).toEqual(['INITIAL_SESSION']));

    const result = await authClient!.auth.resetPassword({ token: 'reset-token', newPassword: 'a new correct horse' });
    expect(result.error).toBeNull();
    expect(events).toEqual(['INITIAL_SESSION', 'SIGNED_OUT']);
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
    await vi.waitFor(() => expect(signOutAuth).toEqual(['Bearer other-account-token']));
    await vi.waitFor(() => expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull());
    expect(otherAccountRevoked).toBe(true);
  });

  it('queues the other session\'s revocation when the server cannot be reached after a reset', async () => {
    let online = false;
    const signOutAuth: (string | null)[] = [];
    const { authClient } = await loadShim('https://app.test/?resetPassword=1&token=reset-token', {
      '/reset-password': () => Response.json({ status: true }),
      '/sign-out': ({ headers }) => {
        signOutAuth.push(headers.get('authorization'));
        return online ? Response.json({ success: true }) : new Response('down', { status: 503 });
      },
      '/get-session': () => Response.json(null),
    }, { 'gt.better-auth.bearer-token': 'other-account-token' });

    expect((await authClient!.auth.resetPassword({ token: 'reset-token', newPassword: 'a new correct horse' })).error).toBeNull();
    await vi.waitFor(() => expect(signOutAuth).toEqual(['Bearer other-account-token']));
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBe('other-account-token');

    online = true;
    await authClient!.auth.getSession();
    await vi.waitFor(() => expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull());
    expect(signOutAuth).toEqual(['Bearer other-account-token', 'Bearer other-account-token']);
  });

  it('signs nobody out after a reset in a browser that was not signed in', async () => {
    const { authClient } = await loadShim('https://app.test/?resetPassword=1&token=reset-token', {
      '/reset-password': () => Response.json({ status: true }),
    });
    const events: string[] = [];
    authClient!.auth.onAuthStateChange((event) => events.push(event));
    await vi.waitFor(() => expect(events).toEqual(['INITIAL_SESSION']));
    expect((await authClient!.auth.resetPassword({ token: 'reset-token', newPassword: 'a new correct horse' })).error).toBeNull();
    expect(events).toEqual(['INITIAL_SESSION']);
    expect(calls).toEqual(['POST /reset-password']);
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull();
  });

  it('forgets an expired or used token and keeps the current session', async () => {
    const { authClient, readPasswordResetToken, AuthError } = await loadShim('https://app.test/?resetPassword=1&token=used', {
      '/reset-password': () => Response.json({ code: 'INVALID_TOKEN', message: 'Invalid token' }, { status: 400 }),
    }, signedIn);
    expect(readPasswordResetToken()).toBe('used');
    const result = await authClient!.auth.resetPassword({ token: 'used', newPassword: 'a new correct horse' });
    expect(result.error).toBeInstanceOf(AuthError);
    expect(result.error).toMatchObject({ code: 'INVALID_TOKEN', status: 400 });
    expect(readPasswordResetToken()).toBeNull();
    expect(sessionStorage.getItem(RESET_KEY)).toBeNull();
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBe('email-token');
  });

  it('keeps the token for a retry when the server cannot be reached', async () => {
    const { authClient, readPasswordResetToken } = await loadShim('https://app.test/?resetPassword=1&token=keep', {
      '/reset-password': () => new Response('down', { status: 503 }),
    });
    expect(readPasswordResetToken()).toBe('keep');
    const result = await authClient!.auth.resetPassword({ token: 'keep', newPassword: 'a new correct horse' });
    expect(result.error).toMatchObject({ status: 503 });
    expect(readPasswordResetToken()).toBe('keep');
  });
});

describe('sign-in made in this tab', () => {
  const emailSignIn = (token: string) => () =>
    new Response(JSON.stringify({ token, user: userPayload().user }), {
      headers: { 'content-type': 'application/json', 'set-auth-token': token },
    });
  const flowSeed = (nonce: string) => ({
    'gt.better-auth.oauth-flow': JSON.stringify({ nonce, startedAt: Date.now(), linkCode: null }),
  });

  it('is reported once after an email sign-in or a sign-up, when the store hears about it', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/', {
      '/sign-in/email': emailSignIn('email-token'),
      '/sign-up/email': emailSignIn('new-token'),
      '/get-session': () => Response.json(null),
    });
    const heard: boolean[] = [];
    authClient!.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_IN') heard.push(takeSignInFromThisTab());
    });
    await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });
    expect(heard).toEqual([true]);
    expect(takeSignInFromThisTab()).toBe(false);

    await authClient!.auth.signUp({ email: 'new@example.test', password: 'correct horse' });
    expect(heard).toEqual([true, true]);
    expect(takeSignInFromThisTab()).toBe(false);
  });

  it('is not reported for a sign-in that failed', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/', {
      '/sign-in/email': () => Response.json({ code: 'INVALID_EMAIL_OR_PASSWORD', message: 'Invalid email or password' }, { status: 401 }),
    });
    await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'wrong' });
    expect(takeSignInFromThisTab()).toBe(false);
  });

  it('is reported once after a Google/GitHub return to this tab', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/?gtAuthFlow=n1&ott=one-time', {
      '/cross-domain/one-time-token/verify': () => Response.json(userPayload('from-ott')),
      '/get-session': () => Response.json(userPayload('from-ott')),
    }, flowSeed('n1'));
    expect((await authClient!.auth.getSession()).data.session?.access_token).toBe('from-ott');
    expect(takeSignInFromThisTab()).toBe(true);
    expect(takeSignInFromThisTab()).toBe(false);
  });

  it('is not reported for a stored session read on reload or refreshed', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/', {
      '/get-session': () =>
        new Response(JSON.stringify(userPayload('email-token')), {
          headers: { 'content-type': 'application/json', 'set-auth-token': 'email-token' },
        }),
    }, { 'gt.better-auth.bearer-token': 'email-token' });
    expect((await authClient!.auth.getSession()).data.session?.access_token).toBe('email-token');
    expect((await authClient!.auth.refreshSession()).data.session?.access_token).toBe('email-token');
    expect(takeSignInFromThisTab()).toBe(false);
  });

  it('is not reported for a one-time token this browser did not ask for', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/?ott=attacker-token&gtAuthFlow=guess', {
      '/cross-domain/one-time-token/verify': () => Response.json(userPayload('attacker')),
      '/get-session': () => Response.json(userPayload('email-token')),
    }, { ...flowSeed('real-nonce'), 'gt.better-auth.bearer-token': 'email-token' });
    expect((await authClient!.auth.getSession()).data.session?.access_token).toBe('email-token');
    expect(takeSignInFromThisTab()).toBe(false);
  });

  /** Captures the cross-tab listener the shim adds when the store subscribes. */
  function captureStorageListener() {
    const captured: Array<(event: StorageEvent) => void> = [];
    (window as unknown as { addEventListener: (type: string, listener: (event: StorageEvent) => void) => void }).addEventListener = (
      type,
      listener,
    ) => {
      if (type === 'storage') captured.push(listener);
    };
    return captured;
  }

  /** Another tab of this browser stores its session token. */
  function otherTabStores(listeners: Array<(event: StorageEvent) => void>, token: string) {
    localStorage.setItem('gt.better-auth.bearer-token', token);
    for (const listener of listeners) listener({ key: 'gt.better-auth.bearer-token', newValue: token } as StorageEvent);
  }

  it('is not reported for a session adopted from another tab', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/', {
      '/get-session': () => Response.json(userPayload('other-tab-token')),
    });
    const storageListeners = captureStorageListener();
    const heard: Array<[string, boolean]> = [];
    authClient!.auth.onAuthStateChange((event) => heard.push([event, takeSignInFromThisTab()]));
    await vi.waitFor(() => expect(heard).toEqual([['INITIAL_SESSION', false]]));

    otherTabStores(storageListeners, 'other-tab-token');
    await vi.waitFor(() => expect(heard).toEqual([['INITIAL_SESSION', false], ['SIGNED_IN', false]]));
  });

  it('is dropped when another tab stores its session before the store heard of this one', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/', {
      '/sign-in/email': emailSignIn('email-token'),
      '/get-session': () => Response.json(userPayload('other-tab-token')),
    });
    const storageListeners = captureStorageListener();
    const events: string[] = [];
    // A listener that does not take it, so the sign-in stays unreported.
    authClient!.auth.onAuthStateChange((event) => events.push(event));
    await vi.waitFor(() => expect(events).toEqual(['INITIAL_SESSION']));
    await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });

    otherTabStores(storageListeners, 'other-tab-token');
    expect(takeSignInFromThisTab()).toBe(false);
  });

  it('is dropped by a sign-out', async () => {
    const { authClient, takeSignInFromThisTab } = await loadShim('https://app.test/', {
      '/sign-in/email': emailSignIn('email-token'),
      '/sign-out': () => Response.json({ success: true }),
    });
    await authClient!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });
    await authClient!.auth.signOut();
    expect(takeSignInFromThisTab()).toBe(false);
  });
});
