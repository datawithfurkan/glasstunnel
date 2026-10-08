import { convexClient } from '@convex-dev/better-auth/client/plugins';
import { createAuthClient } from 'better-auth/react';
import { platformConfig } from './platform';

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
    code?: string;
  } | null;
  response?: Response;
};

const BEARER_TOKEN_KEY = 'gt.better-auth.bearer-token';
const listeners = new Set<AuthCallback>();

let authClient: ReturnType<typeof createAuthClient> | null = null;

function getAuthBaseUrl() {
  const url = platformConfig.convexSiteUrl;
  if (!url) {
    throw new Error('VITE_CONVEX_SITE_URL is required for hosted account login.');
  }
  return url;
}

function readBearerToken() {
  return localStorage.getItem(BEARER_TOKEN_KEY);
}

function writeBearerToken(token: string | null | undefined) {
  if (!token) return;
  localStorage.setItem(BEARER_TOKEN_KEY, token);
}

function clearBearerToken() {
  localStorage.removeItem(BEARER_TOKEN_KEY);
}

function persistBearerTokenFromHeaders(headers?: Headers) {
  writeBearerToken(headers?.get('set-auth-token'));
}

function authClientInstance() {
  if (!authClient) {
    authClient = createAuthClient({
      baseURL: getAuthBaseUrl(),
      plugins: [convexClient()],
      fetchOptions: {
        auth: {
          type: 'Bearer',
          token: () => readBearerToken() || undefined,
        },
        onSuccess: (context) => {
          persistBearerTokenFromHeaders(context.response.headers);
        },
      },
    });
  }
  return authClient as any;
}

function assertAuthSuccess<T>(result: BetterAuthResponse<T>, fallbackMessage: string): T | null {
  if (result?.error) {
    throw new Error(result.error.message || result.error.statusText || fallbackMessage);
  }
  return result?.data ?? null;
}

async function sessionFromPayload(payload: unknown): Promise<Session | null> {
  const data = (payload as { data?: unknown })?.data ?? payload;
  const user = (data as any)?.user;
  const session = (data as any)?.session;
  const accessToken = (data as any)?.token || session?.token || readBearerToken();
  if (!user || !accessToken) return null;

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

async function currentSession(): Promise<Session | null> {
  const result = (await authClientInstance().getSession()) as BetterAuthResponse;
  assertAuthSuccess(result, 'Could not restore your session.');
  persistBearerTokenFromHeaders(result.response?.headers);
  return sessionFromPayload(result);
}

async function sessionFromResult(result: BetterAuthResponse, fallbackMessage: string) {
  assertAuthSuccess(result, fallbackMessage);
  persistBearerTokenFromHeaders(result.response?.headers);
  return (await sessionFromPayload(result)) ?? currentSession();
}

function notify(event: AuthChangeEvent, session: Session | null) {
  for (const callback of listeners) {
    callback(event, session);
  }
}

function providerFromSupabaseName(provider: string) {
  const normalized = provider.trim().toLowerCase();
  if (normalized !== 'google' && normalized !== 'github') {
    throw new Error(`Unsupported hosted auth provider: ${provider}`);
  }
  return normalized;
}

export const supabase = platformConfig.convexSiteUrl
  ? {
      auth: {
        onAuthStateChange(callback: AuthCallback) {
          listeners.add(callback);
          void currentSession()
            .then((session) => callback('INITIAL_SESSION', session))
            .catch(() => callback('INITIAL_SESSION', null));
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
        async refreshSession(_input?: { refresh_token?: string }) {
          try {
            return { data: { session: await currentSession() }, error: null };
          } catch (error) {
            return { data: { session: null }, error };
          }
        },
        async signInWithOAuth(input: { provider: string; options?: { redirectTo?: string } }) {
          try {
            const result = (await authClientInstance().signIn.social({
              provider: providerFromSupabaseName(input.provider),
              callbackURL: input.options?.redirectTo,
            })) as BetterAuthResponse;
            assertAuthSuccess(result, `Could not start ${input.provider} sign-in.`);
            return { data: result.data, error: null };
          } catch (error) {
            return { data: null, error };
          }
        },
        async signInWithPassword(input: { email: string; password: string }) {
          try {
            const result = (await authClientInstance().signIn.email({
              email: input.email.trim().toLowerCase(),
              password: input.password,
              callbackURL: platformConfig.publicAppUrl,
            })) as BetterAuthResponse;
            const session = await sessionFromResult(result, 'Could not sign in with that email and password.');
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
            const result = (await authClientInstance().signUp.email({
              name: input.options?.data?.name || input.email.split('@')[0] || 'Glasstunnel user',
              email: input.email.trim().toLowerCase(),
              password: input.password,
              callbackURL: platformConfig.publicAppUrl,
            })) as BetterAuthResponse;
            const session = await sessionFromResult(result, 'Could not create your account.');
            notify('SIGNED_IN', session);
            return { data: { session, user: session?.user ?? null }, error: null };
          } catch (error) {
            return { data: { session: null, user: null }, error };
          }
        },
        async signOut() {
          const result = (await authClientInstance().signOut()) as BetterAuthResponse;
          clearBearerToken();
          if (result?.error) {
            return { error: result.error };
          }
          notify('SIGNED_OUT', null);
          return { error: null };
        },
      },
    }
  : null;

export function hasSupabaseAuth(): boolean {
  return !!supabase;
}
