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

async function loadShim(href: string, routes: Record<string, Route>, seed: Record<string, string> = {}) {
  calls = [];
  replacedUrl = null;
  vi.resetModules();
  vi.stubEnv('VITE_CONVEX_SITE_URL', AUTH);
  const store = memoryStorage();
  for (const [key, value] of Object.entries(seed)) store.setItem(key, value);
  vi.stubGlobal('localStorage', store);
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
  return import('./supabase');
}

beforeEach(() => {
  vi.unstubAllEnvs();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

describe('Better Auth session shim', () => {
  const flowSeed = (nonce: string, startedAt = Date.now(), linkCode: string | null = null) => ({
    'gt.better-auth.oauth-flow': JSON.stringify({ nonce, startedAt, linkCode }),
  });

  it('exchanges the one-time token from this browser\'s OAuth flow, keeps linkCode, and restores the session', async () => {
    const { supabase } = await loadShim('https://app.test/?linkCode=ABC234&gtAuthFlow=n1&ott=one-time', {
      '/cross-domain/one-time-token/verify': ({ init }) => {
        expect(JSON.parse(String(init.body))).toEqual({ token: 'one-time' });
        return Response.json(userPayload('from-ott'));
      },
      '/get-session': ({ headers }) => {
        expect(headers.get('authorization')).toBe('Bearer from-ott');
        return Response.json(userPayload('from-ott'));
      },
    }, flowSeed('n1'));
    const { data } = await supabase!.auth.getSession();
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
      const { supabase, readAuthRedirectError } = await loadShim(href, {
        '/cross-domain/one-time-token/verify': () => Response.json(userPayload('attacker')),
      }, { ...seed });
      expect((await supabase!.auth.getSession()).data.session).toBeNull();
      expect(await readAuthRedirectError()).toBe('This sign-in was started in another browser or tab. Start sign-in again here.');
      expect(calls).toEqual([]);
      expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
    }
  });

  it('restores a Mac linkCode the provider round trip dropped', async () => {
    const { supabase } = await loadShim('https://app.test/?gtAuthFlow=n2&ott=one-time', {
      '/cross-domain/one-time-token/verify': () => Response.json(userPayload('from-ott')),
      '/get-session': () => Response.json(userPayload('from-ott')),
    }, flowSeed('n2', Date.now(), 'LINK42'));
    await supabase!.auth.getSession();
    expect(replacedUrl).toBe('https://app.test/?linkCode=LINK42');
  });

  it('retries a one-time token exchange that hit a server error once', async () => {
    let attempts = 0;
    const { supabase } = await loadShim('https://app.test/?gtAuthFlow=n3&ott=one-time', {
      '/cross-domain/one-time-token/verify': () => (++attempts === 1 ? new Response('busy', { status: 503 }) : Response.json(userPayload('from-ott'))),
      '/get-session': () => Response.json(userPayload('from-ott')),
    }, flowSeed('n3'));
    expect((await supabase!.auth.getSession()).data.session?.access_token).toBe('from-ott');
    expect(attempts).toBe(2);
  });

  it('turns an OAuth error return into a readable message and no session', async () => {
    const { supabase, readAuthRedirectError } = await loadShim('https://app.test/?authError=1&error=access_denied&gtAuthFlow=n4', {}, flowSeed('n4'));
    expect(await readAuthRedirectError()).toBe('Sign-in was cancelled. Try again when you are ready.');
    // Still there for a second render (StrictMode), until the next attempt.
    expect(await readAuthRedirectError()).toBe('Sign-in was cancelled. Try again when you are ready.');
    const { data } = await supabase!.auth.getSession();
    expect(data.session).toBeNull();
    expect(replacedUrl).toBe('https://app.test/');
    expect(calls).toEqual([]);
  });

  it('keeps the last confirmed session while the auth server is unreachable', async () => {
    let online = true;
    const { supabase } = await loadShim('https://app.test/', {
      '/sign-in/email': () =>
        new Response(JSON.stringify({ token: 'email-token', user: userPayload().user }), {
          headers: { 'content-type': 'application/json', 'set-auth-token': 'email-token' },
        }),
      '/get-session': () => (online ? Response.json(userPayload('email-token')) : new Response('down', { status: 503 })),
    });
    const signedIn = await supabase!.auth.signInWithPassword({ email: 'Person@Example.test ', password: 'correct horse' });
    expect(signedIn.error).toBeNull();
    expect(signedIn.data.session?.access_token).toBe('email-token');
    online = false;
    const { data, error } = await supabase!.auth.getSession();
    expect(error).toBeNull();
    expect(data.session?.user.id).toBe('legacy-user-1');
  });

  it('signs out locally when the server says the session is gone', async () => {
    let valid = true;
    const { supabase } = await loadShim('https://app.test/', {
      '/sign-in/email': () =>
        new Response(JSON.stringify({ token: 'email-token', user: userPayload().user }), {
          headers: { 'content-type': 'application/json', 'set-auth-token': 'email-token' },
        }),
      '/get-session': () => (valid ? Response.json(userPayload('email-token')) : Response.json(null)),
    });
    await supabase!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });
    valid = false;
    expect((await supabase!.auth.getSession()).data.session).toBeNull();
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
  });

  it('sends email sign-in without a callback URL so the app does not reload', async () => {
    let body: Record<string, unknown> = {};
    const { supabase } = await loadShim('https://app.test/?linkCode=ABC234', {
      '/sign-in/email': ({ init }) => {
        body = JSON.parse(String(init.body));
        return Response.json({ code: 'INVALID_EMAIL_OR_PASSWORD', message: 'Invalid email or password' }, { status: 401 });
      },
    });
    const result = await supabase!.auth.signInWithPassword({ email: 'person@example.test', password: 'wrong' });
    expect(body).not.toHaveProperty('callbackURL');
    expect(result.data.session).toBeNull();
    expect((result.error as { code?: string }).code).toBe('INVALID_EMAIL_OR_PASSWORD');
  });

  it('asks the provider flow to return errors to the app, keeping linkCode', async () => {
    let body: Record<string, unknown> = {};
    const { supabase } = await loadShim('https://app.test/', {
      '/sign-in/social': ({ init }) => {
        body = JSON.parse(String(init.body));
        return Response.json({ url: 'https://accounts.example.test/authorize', redirect: false });
      },
    });
    await supabase!.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: 'https://app.test/?linkCode=ABC234' } });
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
    const { supabase } = await loadShim('https://app.test/', {
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
    await supabase!.auth.signInWithPassword({ email: 'person@example.test', password: 'correct horse' });
    online = false;
    expect((await supabase!.auth.signOut()).error).toBeNull();
    expect(localStorage.getItem('gt.better-auth.bearer-token')).toBeNull();
    expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBe('email-token');
    online = true;
    await supabase!.auth.getSession();
    await vi.waitFor(() => expect(localStorage.getItem('gt.better-auth.pending-revocation')).toBeNull());
    expect(signOutAuth).toEqual(['Bearer email-token', 'Bearer email-token']);
  });

  it('never pairs a cached account with a different account\'s token', async () => {
    const { supabase } = await loadShim('https://app.test/', {
      '/get-session': () => new Response('down', { status: 503 }),
    }, {
      'gt.better-auth.bearer-token': 'token-b',
      'gt.better-auth.session-snapshot': JSON.stringify({ token: 'token-a', user: { id: 'user-a' } }),
    });
    const { data, error } = await supabase!.auth.getSession();
    expect(data.session).toBeNull();
    expect(error).toBeTruthy();
  });
});
