import { createClient } from '@supabase/supabase-js';
import { platformConfig } from './platform';

export const supabase = platformConfig.supabaseUrl && platformConfig.supabaseAnonKey
  ? createClient(platformConfig.supabaseUrl, platformConfig.supabaseAnonKey, {
      auth: {
        autoRefreshToken: true,
        persistSession: true,
        detectSessionInUrl: true,
        flowType: 'pkce',
      },
    })
  : null;

export function hasSupabaseAuth(): boolean {
  return !!supabase;
}
