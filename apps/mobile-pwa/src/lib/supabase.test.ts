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

async function loadShim(href: string, routes: Record<string, Route>) {
  calls = [];
  replacedUrl = null;
  vi.resetModules();
  vi.stubEnv('VITE_CONVEX_SITE_URL', AUTH);
  vi.stubGlobal('localStorage', memoryStorage());
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
  it('exchanges the one-time token from an OAuth return, keeps linkCode, and restores the session', async () => {
    const { supabase } = await loadShim('https://app.test/?linkCode=ABC234&ott=one-time', {
      '/cross-domain/one-time-token/verify': ({ init }) => {
        expect(JSON.parse(String(init.body))).toEqual({ token: 'one-time' });
        return Response.json(userPayload('from-ott'));
      },
      '/get-session': ({ headers }) => {
        expect(headers.get('authorization')).toBe('Bearer from-ott');
        return Response.json(userPayload('from-ott'));
      },
    });
    const { data } = await supabase!.auth.getSession();
    expect(data.session?.access_token).toBe('from-ott');
    expect(data.session?.user.id).toBe('legacy-user-1');
    expect(replacedUrl).toBe('https://app.test/?linkCode=ABC234');
    expect(calls).toEqual(['POST /cross-domain/one-time-token/verify', 'GET /get-session']);
  });

  it('turns an OAuth error return into a readable message and no session', async () => {
    const { supabase, takeAuthRedirectError } = await loadShim('https://app.test/?authError=1&error=access_denied', {});
    expect(await takeAuthRedirectError()).toBe('Sign-in was cancelled. Try again when you are ready.');
    expect(await takeAuthRedirectError()).toBeNull();
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
    expect(body).toMatchObject({
      provider: 'google',
      callbackURL: 'https://app.test/?linkCode=ABC234',
      errorCallbackURL: 'https://app.test/?linkCode=ABC234&authError=1',
    });
  });
});
