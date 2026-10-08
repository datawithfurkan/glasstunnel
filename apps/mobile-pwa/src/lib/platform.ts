import { DEFAULT_SIGNALING_URL } from '@glasstunnel/protocol';

function normalizeOrigin(value: string): string {
  return value.replace(/\/+$/, '');
}

function currentOrigin(): string {
  if (typeof window === 'undefined') return 'https://app.glasstunnel.io';
  return window.location.origin;
}

function convexSiteUrl(): string {
  const explicit = import.meta.env.VITE_CONVEX_SITE_URL || '';
  if (explicit) return explicit;
  const convexUrl = import.meta.env.VITE_CONVEX_URL || '';
  return convexUrl.replace('.convex.cloud', '.convex.site');
}

export const platformConfig = {
  publicAppUrl: normalizeOrigin(import.meta.env.VITE_PUBLIC_APP_URL || currentOrigin()),
  defaultSignalingUrl: import.meta.env.VITE_SIGNALING_URL || DEFAULT_SIGNALING_URL,
  convexUrl: import.meta.env.VITE_CONVEX_URL || '',
  convexSiteUrl: convexSiteUrl(),
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL || '',
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY || '',
};
