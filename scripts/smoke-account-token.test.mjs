import assert from 'node:assert/strict';
import test from 'node:test';

import { DEFAULT_CONVEX_SITE_URL, smokeAccountToken } from './smoke-account-token.mjs';

test('signs in with email and password and returns the bearer session token', async () => {
  const requests = [];
  const token = await smokeAccountToken({
    email: 'smoke@example.test',
    password: 'pw',
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return new Response(JSON.stringify({ token: 'body-token', user: { id: 'u1' } }), {
        status: 200,
        headers: { 'content-type': 'application/json', 'set-auth-token': 'header-token' },
      });
    },
  });
  assert.equal(token, 'header-token');
  assert.equal(requests[0].url, `${DEFAULT_CONVEX_SITE_URL}/api/auth/sign-in/email`);
  assert.equal(requests[0].init.headers.origin, 'https://app.glasstunnel.io');
  assert.deepEqual(JSON.parse(requests[0].init.body), { email: 'smoke@example.test', password: 'pw' });
});

test('reports the auth error code without echoing credentials', async () => {
  await assert.rejects(
    smokeAccountToken({
      site: 'http://127.0.0.1:3211/',
      email: 'smoke@example.test',
      password: 'secret-pw',
      fetchImpl: async () =>
        Response.json({ code: 'INVALID_EMAIL_OR_PASSWORD', message: 'Invalid email or password' }, { status: 401 }),
    }),
    (error) => {
      assert.match(error.message, /401: INVALID_EMAIL_OR_PASSWORD/);
      assert.doesNotMatch(error.message, /secret-pw/);
      return true;
    },
  );
});

test('refuses to run without smoke credentials', async () => {
  await assert.rejects(smokeAccountToken({ email: '', password: 'pw', fetchImpl: async () => assert.fail() }), /required/);
});
