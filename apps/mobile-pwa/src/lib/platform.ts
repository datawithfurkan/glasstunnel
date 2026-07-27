import { DEFAULT_SIGNALING_URL } from '@glasstunnel/protocol';

function normalizeOrigin(value: string): string {
  return value.replace(/\/+$/, '');
}

function currentOrigin(): string {
  if (typeof window === 'undefined') return 'https://app.glasstunnel.io';
  return window.location.origin;
}

export const platformConfig = {
  publicAppUrl: normalizeOrigin(import.meta.env.VITE_PUBLIC_APP_URL || currentOrigin()),
  defaultSignalingUrl: import.meta.env.VITE_SIGNALING_URL || DEFAULT_SIGNALING_URL,
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL || '',
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY || '',
};
