import { convexClient } from '@convex-dev/better-auth/client/plugins';
import { createAuthClient } from 'better-auth/react';
import { platformConfig } from './platform';

// Better Auth (on the Convex deployment) behind the small session surface the
// store uses: getSession, sign-in and sign-up, signOut, and auth change events. The auth server lives on another
// site (*.convex.site), so this client never relies on cookies: the session
// token is a bearer token kept in localStorage, delivered either in the
// `set-auth-token` header (email sign-in) or as a one-time token in the URL
// after Google/GitHub (`?ott=`, Better Auth's cross-domain plugin).
//
// A one-time token is only exchanged when it comes back with the nonce this
// browser stored when it started that sign-in (`gtAuthFlow`). Without that
// binding a crafted link could sign a victim into someone else's account and
// let them link their Mac to it (login CSRF).
//
// Password reset emails link straight to the app (`?resetPassword=1&token=`).
// The token leaves the address bar as soon as the app reads it and lives only
// in memory and this tab's sessionStorage, for at most an hour.

type AuthChangeEvent = 'INITIAL_SESSION' | 'SIGNED_IN' | 'SIGNED_OUT' | 'TOKEN_REFRESHED';
type AuthCallback = (event: AuthChangeEvent, session: Session | null) => void;

export interface User {
  id: string;
  email?: string | null;
  user_metadata?: Record<string, unknown> | null;
}

export interface Session {
  access_token: string;
  refresh_token: string;
  user: User;
}

type BetterAuthResponse<T = unknown> = {
  data?: T | null;
  error?: {
    message?: string;
    statusText?: string;
    status?: number;
    code?: string;
  } | null;
  response?: Response;
};

/** An auth failure with Better Auth's machine-readable code (e.g. INVALID_EMAIL_OR_PASSWORD). */
export class AuthError extends Error {
  constructor(
    message: string,
    readonly code?: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = 'AuthError';
  }
}

/** The auth server could not be reached or failed; the stored session is kept. */
export class AuthUnavailableError extends AuthError {}

type AuthClient = ReturnType<typeof createAuthClient>;
type FetchOptions = {
  fetchOptions?: {
    signal?: AbortSignal;
    headers?: Record<string, string>;
    /** Replaces the client's own bearer token (the stored session) for this one request. */
    auth?: { type: 'Bearer'; token: string };
  };
};
// The handful of client actions this shim calls; the plugin-augmented client
// type is too deep for TypeScript to infer usefully here.
interface AuthActions {
  getSession(options?: FetchOptions): Promise<unknown>;
  signIn: {
    social(input: Record<string, unknown>): Promise<unknown>;
    email(input: Record<string, unknown>): Promise<unknown>;
  };
  signUp: { email(input: Record<string, unknown>): Promise<unknown> };
  signOut(options?: FetchOptions): Promise<unknown>;
}

interface AuthUserPayload {
  id?: unknown;
  userId?: unknown;
  email?: unknown;
  name?: unknown;
  image?: unknown;
}

interface SessionPayload {
  token?: unknown;
  user?: AuthUserPayload | null;
  session?: { token?: unknown } | null;
}

interface PendingOAuthFlow {
  nonce: string;
  startedAt: number;
  linkCode?: string | null;
}

const BEARER_TOKEN_KEY = 'gt.better-auth.bearer-token';
const SESSION_SNAPSHOT_KEY = 'gt.better-auth.session-snapshot';
const OAUTH_FLOW_KEY = 'gt.better-auth.oauth-flow';
const PENDING_REVOCATION_KEY = 'gt.better-auth.pending-revocation';
const PASSWORD_RESET_TOKEN_KEY = 'gt.password-reset-token';
const OAUTH_FLOW_MAX_AGE_MS = 15 * 60_000;
const PASSWORD_RESET_TOKEN_MAX_AGE_MS = 60 * 60_000;
const SESSION_READ_TIMEOUT_MS = 10_000;
const AUTH_REQUEST_TIMEOUT_MS = 20_000;
const listeners = new Set<AuthCallback>();

interface PendingPasswordReset {
  token: string;
  expiresAt: number;
}

let betterAuthClient: AuthClient | null = null;
let redirectHandled: Promise<void> | null = null;
let pendingRedirectError: string | null = null;
let sessionRead: Promise<Session | null> | null = null;
let crossTabAttached = false;
let pendingPasswordReset: PendingPasswordReset | null = null;
let invalidPasswordResetLink = false;
/**
 * Set when a sign-in made in this tab stored its session (email and password,
 * sign-up, or a Google/GitHub return to this tab), until the store takes it.
 * A session another tab stored, a reload, and a session refresh never set it,
 * and a session another tab stores afterwards, or a sign-out, clears it.
 */
let signedInHere = false;

function getAuthBaseUrl() {
  const url = platformConfig.convexSiteUrl;
  if (!url) {
    throw new Error('VITE_CONVEX_SITE_URL is required for hosted account login.');
  }
  return url.replace(/\/+$/, '');
}

function storage(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

function tabStorage(): Storage | null {
  try {
    return typeof sessionStorage === 'undefined' ? null : sessionStorage;
  } catch {
    return null;
  }
}

function readBearerToken() {
  return storage()?.getItem(BEARER_TOKEN_KEY) ?? null;
}

function writeBearerToken(token: string | null | undefined) {
  if (!token) return;
  storage()?.setItem(BEARER_TOKEN_KEY, token);
}

function clearStoredSession() {
  signedInHere = false;
  storage()?.removeItem(BEARER_TOKEN_KEY);
  storage()?.removeItem(SESSION_SNAPSHOT_KEY);
}

/** The snapshot names the token it was confirmed with, so it never pairs with another account's token. */
function writeSnapshot(session: Session) {
  storage()?.setItem(SESSION_SNAPSHOT_KEY, JSON.stringify({ token: session.access_token, user: session.user }));
}

/** The last session the server confirmed for the current token, for use while the server is unreachable. */
function snapshotSession(): Session | null {
  const token = readBearerToken();
  const raw = storage()?.getItem(SESSION_SNAPSHOT_KEY);
  if (!token || !raw) return null;
  try {
    const parsed = JSON.parse(raw) as { token?: string; user?: User };
    if (parsed.token !== token || !parsed.user?.id) return null;
    return { access_token: token, refresh_token: token, user: parsed.user };
  } catch {
    return null;
  }
}

function persistBearerTokenFromHeaders(headers?: Headers) {
  writeBearerToken(headers?.get('set-auth-token'));
}

function authClientInstance(): AuthActions {
  if (!betterAuthClient) {
    betterAuthClient = createAuthClient({
      baseURL: getAuthBaseUrl(),
      plugins: [convexClient()],
      fetchOptions: {
        auth: {
          type: 'Bearer',
          token: () => readBearerToken() || undefined,
        },
      },
    });
  }
  return betterAuthClient as unknown as AuthActions;
}

function assertAuthSuccess<T>(result: BetterAuthResponse<T>, fallbackMessage: string): T | null {
  if (result?.error) {
    const status = result.error.status ?? result.response?.status;
    const message = result.error.message || result.error.statusText || fallbackMessage;
    if (status === undefined || status === 0 || status === 429 || status >= 500) {
      throw new AuthUnavailableError(message, result.error.code, status);
    }
    throw new AuthError(message, result.error.code, status);
  }
  return result?.data ?? null;
}

function sessionFromPayload(payload: unknown): Session | null {
  const data = ((payload as { data?: unknown } | null)?.data ?? payload) as SessionPayload | null;
  const user = data?.user;
  const tokenValue = data?.token || data?.session?.token || readBearerToken();
  const accessToken = typeof tokenValue === 'string' ? tokenValue : null;
  if (!user || typeof user.id !== 'string' || !accessToken) return null;

  const legacyUserId = typeof user.userId === 'string' && user.userId ? user.userId : user.id;
  const metadata: Record<string, unknown> = {
    auth_user_id: user.id,
    name: typeof user.name === 'string' ? user.name : undefined,
    full_name: typeof user.name === 'string' ? user.name : undefined,
    avatar_url: typeof user.image === 'string' ? user.image : undefined,
    provider: 'convex',
  };

  return {
    access_token: accessToken,
    refresh_token: accessToken,
    user: {
      id: legacyUserId,
      email: typeof user.email === 'string' ? user.email : null,
      user_metadata: metadata,
    },
  };
}

const FRIENDLY_REDIRECT_ERRORS: Record<string, string> = {
  access_denied: 'Sign-in was cancelled. Try again when you are ready.',
  state_mismatch: 'That sign-in link expired. Start sign-in again.',
  state_not_found: 'That sign-in link expired. Start sign-in again.',
  please_restart_the_process: 'That sign-in link expired. Start sign-in again.',
  invalid_code: 'The provider did not confirm your sign-in. Try again.',
  email_not_found: 'Your account at that provider has no email address Glasstunnel can use.',
  unable_to_link_account: 'That provider account could not be linked to your Glasstunnel account.',
  account_not_linked: 'That email already has a Glasstunnel account with a different sign-in method.',
};
const FOREIGN_FLOW_MESSAGE = 'This sign-in was started in another browser or tab. Start sign-in again here.';
const UNAVAILABLE_MESSAGE = 'Could not reach the sign-in service. Check your connection and try again.';

function readPendingFlow(): PendingOAuthFlow | null {
  const raw = storage()?.getItem(OAUTH_FLOW_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as PendingOAuthFlow;
    return typeof parsed.nonce === 'string' && typeof parsed.startedAt === 'number' ? parsed : null;
  } catch {
    return null;
  }
}

function randomNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

/**
 * Reads what the auth server sent back in the URL after Google/GitHub: a
 * one-time token to exchange (only with this browser's flow nonce), or an
 * error to show. Auth parameters are removed from the address bar; a Mac
 * linkCode carried through the flow is restored if the provider dropped it.
 */
function takeRedirectParameters(): { token: string | null; error: string | null } {
  if (typeof window === 'undefined' || !window.location?.href) return { token: null, error: null };
  const url = new URL(window.location.href);
  const token = url.searchParams.get('ott');
  const flagged = url.searchParams.has('authError');
  const errorCode = flagged ? url.searchParams.get('error') : null;
  const returnedNonce = url.searchParams.get('gtAuthFlow');
  if (!token && !flagged) return { token: null, error: null };

  const flow = readPendingFlow();
  storage()?.removeItem(OAUTH_FLOW_KEY);
  for (const name of ['ott', 'error', 'error_description', 'authError', 'gtAuthFlow']) url.searchParams.delete(name);
  if (flow?.linkCode && !url.searchParams.get('linkCode')) url.searchParams.set('linkCode', flow.linkCode);
  window.history.replaceState(window.history.state, '', url.toString());

  if (flagged) {
    return {
      token: null,
      error: (errorCode && FRIENDLY_REDIRECT_ERRORS[errorCode.toLowerCase()]) || 'Sign-in did not finish. Try again, or use email instead.',
    };
  }
  const fresh = flow && Date.now() - flow.startedAt <= OAUTH_FLOW_MAX_AGE_MS;
  if (!flow || !fresh || !returnedNonce || returnedNonce !== flow.nonce) {
    return { token: null, error: FOREIGN_FLOW_MESSAGE };
  }
  return { token, error: null };
}

function writePasswordResetToken(token: string) {
  pendingPasswordReset = { token, expiresAt: Date.now() + PASSWORD_RESET_TOKEN_MAX_AGE_MS };
  try {
    tabStorage()?.setItem(PASSWORD_RESET_TOKEN_KEY, JSON.stringify(pendingPasswordReset));
  } catch {
    // Storage full or blocked: the in-memory copy still finishes this reset.
  }
}

function storedPasswordResetToken(): PendingPasswordReset | null {
  try {
    const raw = tabStorage()?.getItem(PASSWORD_RESET_TOKEN_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<PendingPasswordReset>;
    return typeof parsed.token === 'string' && parsed.token && typeof parsed.expiresAt === 'number'
      ? { token: parsed.token, expiresAt: parsed.expiresAt }
      : null;
  } catch {
    return null;
  }
}

/** Forgets the pending password reset token (after success, an invalid token, or cancel). */
export function clearPasswordResetToken(): void {
  pendingPasswordReset = null;
  try {
    tabStorage()?.removeItem(PASSWORD_RESET_TOKEN_KEY);
  } catch {
    // Nothing stored.
  }
}

/**
 * Moves a password reset link (`?resetPassword=1&token=…`) out of the address
 * bar so the token is not left in history, bookmarks, or screenshots. Other
 * parameters, such as a Mac linkCode, stay. A reset link's `error` belongs to
 * the reset, never to a Google/GitHub sign-in.
 */
function capturePasswordResetLink(): void {
  if (typeof window === 'undefined' || !window.location?.href) return;
  let url: URL;
  try {
    url = new URL(window.location.href);
  } catch {
    return;
  }
  if (!url.searchParams.has('resetPassword')) return;
  const token = url.searchParams.get('token')?.trim() ?? '';
  const failed = url.searchParams.has('error');
  for (const name of ['resetPassword', 'token', 'error', 'error_description']) url.searchParams.delete(name);
  window.history.replaceState(window.history.state, '', url.toString());
  if (token && !failed) {
    invalidPasswordResetLink = false;
    writePasswordResetToken(token);
  } else {
    clearPasswordResetToken();
    invalidPasswordResetLink = true;
  }
}

/** The reset token from the email link this tab opened, or null once it expired or was used. */
export function readPasswordResetToken(): string | null {
  capturePasswordResetLink();
  pendingPasswordReset = pendingPasswordReset ?? storedPasswordResetToken();
  if (pendingPasswordReset && pendingPasswordReset.expiresAt <= Date.now()) clearPasswordResetToken();
  return pendingPasswordReset?.token ?? null;
}

/** True once after this tab opened a reset link that carried no usable token. */
export function takeInvalidPasswordResetLink(): boolean {
  capturePasswordResetLink();
  const invalid = invalidPasswordResetLink;
  invalidPasswordResetLink = false;
  return invalid;
}

/**
 * POSTs to an auth endpoint that needs no session. No bearer token and no
 * cookies go along: a reset must not depend on, or leak, whoever is signed in.
 */
async function postAuthJson(path: string, body: Record<string, unknown>, fallbackMessage: string) {
  let response: Response;
  try {
    response = await fetch(`${getAuthBaseUrl()}/api/auth${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      credentials: 'omit',
      signal: typeof AbortSignal.timeout === 'function' ? AbortSignal.timeout(AUTH_REQUEST_TIMEOUT_MS) : undefined,
    });
  } catch {
    throw new AuthUnavailableError(UNAVAILABLE_MESSAGE);
  }
  const payload = (await response.json().catch(() => null)) as { status?: unknown; code?: unknown; message?: unknown } | null;
  if (!response.ok) {
    assertAuthSuccess(
      {
        error: {
          status: response.status,
          code: typeof payload?.code === 'string' ? payload.code : undefined,
          message: typeof payload?.message === 'string' ? payload.message : undefined,
        },
      },
      fallbackMessage,
    );
  }
  // A 200 without Better Auth's `status: true` (a proxy page, say) did not do the work.
  if (payload?.status !== true) throw new AuthUnavailableError(fallbackMessage, undefined, response.status);
}

async function postOneTimeToken(token: string): Promise<Response> {
  return fetch(`${getAuthBaseUrl()}/api/auth/cross-domain/one-time-token/verify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token }),
    credentials: 'omit',
  });
}

async function exchangeOneTimeToken(token: string): Promise<void> {
  // A one-time token is single use but survives a dropped request: retry once.
  let response: Response | null = null;
  for (let attempt = 0; attempt < 2 && !response; attempt += 1) {
    try {
      const candidate = await postOneTimeToken(token);
      if (candidate.status >= 500 || candidate.status === 429) {
        if (attempt === 1) throw new AuthUnavailableError(UNAVAILABLE_MESSAGE, undefined, candidate.status);
      } else {
        response = candidate;
      }
    } catch (error) {
      if (attempt === 1) throw error instanceof AuthError ? error : new AuthUnavailableError(UNAVAILABLE_MESSAGE);
    }
    if (!response && attempt === 0) await new Promise((resolve) => setTimeout(resolve, 800));
  }
  if (!response || !response.ok) {
    throw new AuthError('That sign-in link expired. Start sign-in again.', undefined, response?.status);
  }
  const body = (await response.json().catch(() => null)) as SessionPayload | null;
  const sessionToken = response.headers.get('set-auth-token') || (typeof body?.session?.token === 'string' ? body.session.token : null);
  if (!sessionToken) {
    throw new AuthError('Sign-in did not finish. Try again, or use email instead.');
  }
  // A new sign-in replaces whatever this browser held before, including its snapshot.
  clearStoredSession();
  writeBearerToken(sessionToken);
  const session = sessionFromPayload({ ...body, token: sessionToken });
  if (session) writeSnapshot(session);
  // This tab started the flow (the nonce matched) and stored the session.
  signedInHere = true;
}

/**
 * True once after a sign-in made in this tab stored its session, so the store
 * can tell it from a session adopted from another tab, a reload, or a refresh.
 */
export function takeSignInFromThisTab(): boolean {
  const value = signedInHere;
  signedInHere = false;
  return value;
}

/** Runs once per page load, before the first session read. */
function handleRedirect(): Promise<void> {
  if (!redirectHandled) {
    redirectHandled = (async () => {
      // First, so a reset link's parameters never reach the OAuth handling below.
      capturePasswordResetLink();
      const { token, error } = takeRedirectParameters();
      if (error) {
        pendingRedirectError = error;
        return;
      }
      if (!token) return;
      try {
        await exchangeOneTimeToken(token);
      } catch (exchangeError) {
        pendingRedirectError =
          exchangeError instanceof Error ? exchangeError.message : 'Sign-in did not finish. Try again.';
      }
    })();
  }
  return redirectHandled;
}

/** A sign-in error carried back from Google/GitHub; stays until the next sign-in attempt or session. */
export async function readAuthRedirectError(): Promise<string | null> {
  await handleRedirect().catch(() => undefined);
  return pendingRedirectError;
}

/**
 * Ends this browser's session locally: the stored token and snapshot go first,
 * so a reload or a stalled request cannot bring them back. The token is queued
 * for revocation until the server confirms it is gone. Returns that token.
 */
function endLocalSession(): string | null {
  const token = readBearerToken();
  clearStoredSession();
  if (token) storage()?.setItem(PENDING_REVOCATION_KEY, token);
  return token;
}

/**
 * Revokes one session on the server with exactly that session's token.
 *
 * The token replaces the client's own bearer auth for this request. Passing it
 * as an extra Authorization header instead would let better-fetch add the
 * stored session's token too, and the server would read "Bearer old, Bearer
 * new": no session is found, nothing is revoked, and the call still succeeds.
 *
 * A 2xx means it is revoked now (Better Auth also answers 200 for a session
 * that is already gone); a 401 means it already was. Either way the queued revocation for
 * this token is dropped, unless a newer one replaced it meanwhile. Anything
 * else keeps it for the next session read.
 */
async function revokeSessionToken(token: string): Promise<void> {
  try {
    const result = (await authClientInstance().signOut({
      fetchOptions: {
        auth: { type: 'Bearer', token },
        signal: typeof AbortSignal.timeout === 'function' ? AbortSignal.timeout(AUTH_REQUEST_TIMEOUT_MS) : undefined,
      },
    })) as BetterAuthResponse;
    if (result?.error && result.error.status !== 401) return;
    if (storage()?.getItem(PENDING_REVOCATION_KEY) === token) storage()?.removeItem(PENDING_REVOCATION_KEY);
  } catch {
    // Offline or timed out: retried on the next session read.
  }
}

/** Retries a sign-out the server did not acknowledge, so the old session does not live on. */
async function retryPendingRevocation(): Promise<void> {
  const token = storage()?.getItem(PENDING_REVOCATION_KEY);
  if (token) await revokeSessionToken(token);
}

async function readSessionFromServer(): Promise<Session | null> {
  await handleRedirect().catch(() => undefined);
  void retryPendingRevocation();
  const token = readBearerToken();
  if (!token) {
    clearStoredSession();
    return null;
  }
  let result: BetterAuthResponse;
  try {
    result = (await authClientInstance().getSession({
      fetchOptions: { signal: AbortSignal.timeout(SESSION_READ_TIMEOUT_MS) },
    })) as BetterAuthResponse;
    assertAuthSuccess(result, 'Could not restore your session.');
  } catch (error) {
    if (error instanceof AuthError && !(error instanceof AuthUnavailableError) && error.status === 401) {
      if (readBearerToken() === token) clearStoredSession();
      return null;
    }
    const cached = snapshotSession();
    if (cached) return cached;
    throw error instanceof AuthError ? error : new AuthUnavailableError(UNAVAILABLE_MESSAGE);
  }
  // A sign-in or sign-out in this tab while the read was in flight wins.
  if (readBearerToken() !== token) return snapshotSession();
  persistBearerTokenFromHeaders(result.response?.headers);
  const session = sessionFromPayload(result);
  if (session) {
    writeSnapshot(session);
    pendingRedirectError = null;
  } else {
    clearStoredSession();
  }
  return session;
}

/**
 * The confirmed session, null when signed out (no token, 200 null, or 401),
 * or the last confirmed session when the auth server is unreachable.
 * Concurrent callers share one request.
 */
function currentSession(): Promise<Session | null> {
  if (!sessionRead) {
    sessionRead = readSessionFromServer().finally(() => {
      sessionRead = null;
    });
  }
  return sessionRead;
}

async function sessionFromResult(result: BetterAuthResponse, fallbackMessage: string) {
  assertAuthSuccess(result, fallbackMessage);
  clearStoredSession();
  persistBearerTokenFromHeaders(result.response?.headers);
  let session = sessionFromPayload(result);
  // Some proxies strip set-auth-token; the body carries the same token.
  if (!readBearerToken() && session?.access_token) writeBearerToken(session.access_token);
  session = session ?? (await currentSession());
  if (session) {
    writeSnapshot(session);
    pendingRedirectError = null;
  }
  return session;
}

function notify(event: AuthChangeEvent, session: Session | null) {
  for (const callback of listeners) {
    callback(event, session);
  }
}

/** Signing in or out in another tab updates this one, so no tab keeps acting on a dead session. */
function attachCrossTabSync() {
  if (crossTabAttached || typeof window === 'undefined' || typeof window.addEventListener !== 'function') return;
  crossTabAttached = true;
  window.addEventListener('storage', (event: StorageEvent) => {
    if (event.key !== BEARER_TOKEN_KEY) return;
    // Another tab's session (or sign-out) replaced whatever this tab signed in to.
    signedInHere = false;
    if (!event.newValue) {
      notify('SIGNED_OUT', null);
      return;
    }
    void currentSession()
      .then((session) => notify(session ? 'SIGNED_IN' : 'SIGNED_OUT', session))
      .catch(() => undefined);
  });
}

function providerFromName(provider: string) {
  const normalized = provider.trim().toLowerCase();
  if (normalized !== 'google' && normalized !== 'github') {
    throw new Error(`Unsupported hosted auth provider: ${provider}`);
  }
  return normalized;
}

function flowUrl(redirectTo: string | undefined, nonce: string, extra?: Record<string, string>): string {
  const url = new URL(redirectTo || platformConfig.publicAppUrl || window.location.origin);
  url.searchParams.set('gtAuthFlow', nonce);
  for (const [key, value] of Object.entries(extra ?? {})) url.searchParams.set(key, value);
  return url.toString();
}

export const authClient = platformConfig.convexSiteUrl
  ? {
      auth: {
        onAuthStateChange(callback: AuthCallback) {
          listeners.add(callback);
          attachCrossTabSync();
          void currentSession()
            .then((session) => callback('INITIAL_SESSION', session))
            .catch(() => callback('INITIAL_SESSION', snapshotSession()));
          return {
            data: {
              subscription: {
                unsubscribe() {
                  listeners.delete(callback);
                },
              },
            },
          };
        },
        async initialize() {
          await currentSession().catch(() => null);
        },
        async getSession() {
          try {
            return { data: { session: await currentSession() }, error: null };
          } catch (error) {
            return { data: { session: null }, error };
          }
        },
        // The argument is accepted for the store's call shape; Better Auth refreshes from the bearer token.
        async refreshSession(input?: { refresh_token?: string }) {
          void input;
          try {
            return { data: { session: await currentSession() }, error: null };
          } catch (error) {
            return { data: { session: null }, error };
          }
        },
        async signInWithOAuth(input: { provider: string; options?: { redirectTo?: string } }) {
          try {
            pendingRedirectError = null;
            const nonce = randomNonce();
            const redirectTo = input.options?.redirectTo;
            const linkCode = redirectTo ? new URL(redirectTo).searchParams.get('linkCode') : null;
            storage()?.setItem(OAUTH_FLOW_KEY, JSON.stringify({ nonce, startedAt: Date.now(), linkCode } satisfies PendingOAuthFlow));
            const result = (await authClientInstance().signIn.social({
              provider: providerFromName(input.provider),
              callbackURL: flowUrl(redirectTo, nonce),
              errorCallbackURL: flowUrl(redirectTo, nonce, { authError: '1' }),
            })) as BetterAuthResponse;
            assertAuthSuccess(result, `Could not start ${input.provider} sign-in.`);
            return { data: result.data, error: null };
          } catch (error) {
            return { data: null, error };
          }
        },
        async signInWithPassword(input: { email: string; password: string }) {
          try {
            pendingRedirectError = null;
            // No callbackURL: with one, Better Auth answers with a redirect and the
            // client navigates, which reloads the app and drops a pending linkCode.
            const result = (await authClientInstance().signIn.email({
              email: input.email.trim().toLowerCase(),
              password: input.password,
            })) as BetterAuthResponse;
            const session = await sessionFromResult(result, 'Could not sign in with that email and password.');
            signedInHere = !!session;
            notify('SIGNED_IN', session);
            return { data: { session }, error: null };
          } catch (error) {
            return { data: { session: null }, error };
          }
        },
        async signUp(input: {
          email: string;
          password: string;
          options?: { data?: { name?: string } };
        }) {
          try {
            pendingRedirectError = null;
            const result = (await authClientInstance().signUp.email({
              name: input.options?.data?.name || input.email.split('@')[0] || 'Glasstunnel user',
              email: input.email.trim().toLowerCase(),
              password: input.password,
            })) as BetterAuthResponse;
            const session = await sessionFromResult(result, 'Could not create your account.');
            signedInHere = !!session;
            notify('SIGNED_IN', session);
            return { data: { session, user: session?.user ?? null }, error: null };
          } catch (error) {
            return { data: { session: null, user: null }, error };
          }
        },
        /**
         * Asks for a reset email. The server answers the same way whether or
         * not the address has an account; RESET_PASSWORD_DISABLED (400) means
         * email delivery is not configured, 429 means too many requests.
         */
        async requestPasswordReset(email: string): Promise<{ error: unknown }> {
          try {
            // No redirectTo: the email links straight to the app.
            await postAuthJson('/request-password-reset', { email: email.trim().toLowerCase() }, 'Could not send the reset link.');
            return { error: null };
          } catch (error) {
            return { error };
          }
        },
        /**
         * Sets a new password with the token from the email, then signs this
         * browser out the same way signOut does.
         *
         * The server ends every session of the account that was reset. This
         * browser may be signed in to a different account, though (a reset link
         * opened while signed in as someone else), and that session must not
         * live on, so its token is revoked explicitly. For the reset account the
         * session is already gone; the server's 200 or 401 clears the queued revocation.
         * The revocation is not awaited: the reset is done either way, and a
         * revocation that cannot reach the server is retried on the next session read.
         */
        async resetPassword(input: { token: string; newPassword: string }): Promise<{ error: unknown }> {
          try {
            await postAuthJson('/reset-password', { newPassword: input.newPassword, token: input.token }, 'Could not update your password.');
          } catch (error) {
            if (error instanceof AuthError && error.code === 'INVALID_TOKEN') clearPasswordResetToken();
            return { error };
          }
          clearPasswordResetToken();
          // The sign-out is part of a successful reset, not a failure of it.
          const token = endLocalSession();
          if (!token) return { error: null };
          void revokeSessionToken(token);
          try {
            notify('SIGNED_OUT', null);
          } catch {
            // A listener failing must not turn a finished reset into an error.
          }
          return { error: null };
        },
        async signOut() {
          // The local session ends first; the server copy is revoked with the
          // captured token, and kept for a retry if the server cannot be reached now.
          const token = endLocalSession();
          notify('SIGNED_OUT', null);
          if (token) await revokeSessionToken(token);
          return { error: null };
        },
      },
    }
  : null;

export function hasAccountAuth(): boolean {
  return !!authClient;
}
