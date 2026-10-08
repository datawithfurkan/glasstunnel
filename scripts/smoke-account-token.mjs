#!/usr/bin/env node
// Signs the disposable smoke account in to Glasstunnel (Better Auth on Convex)
// and writes only its session token to stdout, for hosted smoke scripts that
// call the relay and account API as that account. Never prints the password.
//
// Environment:
//   SMOKE_EMAIL, SMOKE_PASSWORD  the disposable smoke account (.env.smoke.local)
//   CONVEX_SITE_URL              auth server; defaults to production
//   GT_SMOKE_APP_URL             app origin the auth server trusts; defaults to production

import { pathToFileURL } from 'node:url';

export const DEFAULT_CONVEX_SITE_URL = 'https://adorable-perch-596.convex.site';
export const DEFAULT_APP_URL = 'https://app.glasstunnel.io';

export async function smokeAccountToken({
  site = DEFAULT_CONVEX_SITE_URL,
  appUrl = DEFAULT_APP_URL,
  email,
  password,
  fetchImpl = fetch,
}) {
  if (!email || !password) throw new Error('SMOKE_EMAIL and SMOKE_PASSWORD are required.');
  const response = await fetchImpl(`${site.replace(/\/+$/, '')}/api/auth/sign-in/email`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', origin: new URL(appUrl).origin },
    body: JSON.stringify({ email, password }),
  });
  const payload = await response.json().catch(() => ({}));
  const token = response.headers.get('set-auth-token') || payload?.token;
  if (!response.ok || !token) {
    const reason = payload?.code || payload?.message || 'no session token';
    throw new Error(`Smoke account sign-in failed with ${response.status}: ${reason}`);
  }
  return token;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    const token = await smokeAccountToken({
      site: process.env.CONVEX_SITE_URL || DEFAULT_CONVEX_SITE_URL,
      appUrl: process.env.GT_SMOKE_APP_URL || DEFAULT_APP_URL,
      email: process.env.SMOKE_EMAIL,
      password: process.env.SMOKE_PASSWORD,
    });
    process.stdout.write(token);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
