import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import {
  assertLoopbackUrl,
  configureLabConvex,
  convexServiceDefinition,
  deleteLabUser,
  labConvexSecrets,
  parseLabEmails,
  readLabEmails,
  upsertLabUser,
  waitForConvexFunctions,
  writeConvexEnvFile,
} from './convex.mjs';
import { bootstrapConvex } from './services.mjs';

function fixtureConfig(t) {
  const root = mkdtempSync(join(tmpdir(), 'glasstunnel-convex-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return ensureRuntimeDirectories(labConfig(root));
}

function recordingRunner(calls) {
  return async (command, args, options) => {
    calls.push({ command, args, env: options.env });
    return { stdout: '', stderr: '', exitCode: 0 };
  };
}

function authResponse(status, body, token) {
  const headers = { 'content-type': 'application/json' };
  if (token) headers['set-auth-token'] = token;
  return new Response(JSON.stringify(body), { status, headers });
}

test('assertLoopbackUrl accepts only this machine', () => {
  for (const url of ['http://127.0.0.1:3211', 'http://localhost:3210', 'http://[::1]:3211']) {
    assert.equal(assertLoopbackUrl(url).href.startsWith('http'), true);
  }
  assert.throws(() => assertLoopbackUrl('https://adorable-perch-596.convex.site'), /non-local/);
  assert.throws(() => assertLoopbackUrl('http://192.168.1.20:3211'), /non-local/);
});

test('the Convex service runs the anonymous local backend from a lab-only env file', (t) => {
  const config = fixtureConfig(t);
  const envFile = writeConvexEnvFile(config);
  const definition = convexServiceDefinition(config);

  assert.equal(readFileSync(envFile, 'utf8'), 'CONVEX_DEPLOYMENT=anonymous:anonymous-agent\n');
  assert.equal(statSync(envFile).mode & 0o777, 0o600);
  assert.equal(definition.command, join(config.root, 'node_modules/.bin/convex'));
  assert.deepEqual(definition.args, [
    'dev',
    '--typecheck',
    'disable',
    '--tail-logs',
    'disable',
    '--env-file',
    config.files.convexEnv,
  ]);
  assert.equal(definition.env.CONVEX_AGENT_MODE, 'anonymous');
  assert.equal(definition.env.CONVEX_DEPLOYMENT, 'anonymous:anonymous-agent');
  assert.equal(definition.healthUrl, 'http://127.0.0.1:3210/version');
});

test('lab Convex secrets are random, private, and stable across restarts', (t) => {
  const config = fixtureConfig(t);
  const first = labConvexSecrets(config);
  const second = labConvexSecrets(config);

  assert.match(first.betterAuthSecret, /^[0-9a-f]{64}$/);
  assert.match(first.workerSecret, /^[0-9a-f]{64}$/);
  assert.notEqual(first.betterAuthSecret, first.workerSecret);
  assert.deepEqual(second, first);
  assert.equal(statSync(config.files.convexSecrets).mode & 0o777, 0o600);
});

test('configureLabConvex sets the backend environment through the pinned local CLI', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];
  const secrets = await configureLabConvex(config, { runCommand: recordingRunner(calls) });

  assert.deepEqual(
    calls.map(({ args }) => args.slice(0, 3)),
    [
      ['env', 'set', 'BETTER_AUTH_SECRET'],
      ['env', 'set', 'BETTER_AUTH_URL'],
      ['env', 'set', 'PUBLIC_APP_URL'],
      ['env', 'set', 'WORKER_CONVEX_SECRET'],
      ['env', 'set', 'AUTH_EMAIL_OUTBOX'],
    ],
  );
  assert.deepEqual(calls[1].args.slice(3), ['http://127.0.0.1:3211', '--env-file', config.files.convexEnv]);
  assert.deepEqual(calls[2].args.slice(3), ['http://127.0.0.1:5173', '--env-file', config.files.convexEnv]);
  assert.equal(calls[3].args[3], secrets.workerSecret);
  // Account emails stay in the local outbox; nothing is ever sent from the lab.
  assert.deepEqual(calls[4].args.slice(3), ['lab', '--env-file', config.files.convexEnv]);
  for (const call of calls) {
    assert.equal(call.command, join(config.root, 'node_modules/.bin/convex'));
    assert.equal(call.env.CONVEX_AGENT_MODE, 'anonymous');
    assert.equal(call.env.CONVEX_DEPLOYMENT, 'anonymous:anonymous-agent');
  }
});

test('waitForConvexFunctions waits until the gateway route exists', async (t) => {
  const config = fixtureConfig(t);
  const statuses = [404, 404, 401];
  const requests = [];
  await waitForConvexFunctions(config, {
    intervalMs: 1,
    fetchImpl: async (url, init) => {
      requests.push([url, init.method]);
      return new Response('', { status: statuses.shift() });
    },
  });
  assert.equal(requests.length, 3);
  assert.deepEqual(requests[0], ['http://127.0.0.1:3211/worker/account-plane', 'POST']);
});

test('upsertLabUser creates the account, then signs in when it already exists', async (t) => {
  const config = fixtureConfig(t);
  const paths = [];
  const created = await upsertLabUser({
    config,
    email: 'lab@glasstunnel.test',
    password: 'pw',
    fetchImpl: async (url, init) => {
      paths.push(new URL(url).pathname);
      assert.equal(init.headers.origin, 'http://127.0.0.1:5173');
      return authResponse(200, { token: 'new-token', user: { id: 'user-1' } }, 'new-token');
    },
  });
  assert.deepEqual(created, { token: 'new-token', userId: 'user-1', created: true });

  const existing = await upsertLabUser({
    config,
    email: 'lab@glasstunnel.test',
    password: 'pw',
    fetchImpl: async (url) => {
      const path = new URL(url).pathname;
      paths.push(path);
      return path.endsWith('/sign-up/email')
        ? authResponse(422, { code: 'USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL' })
        : authResponse(200, { token: 'old-token', user: { id: 'user-1' } }, 'old-token');
    },
  });
  assert.deepEqual(existing, { token: 'old-token', userId: 'user-1', created: false });
  assert.deepEqual(paths, ['/api/auth/sign-up/email', '/api/auth/sign-up/email', '/api/auth/sign-in/email']);
});

test('upsertLabUser refuses real identities and non-local backends', async (t) => {
  const config = fixtureConfig(t);
  const fetchImpl = async () => assert.fail('must not reach the network');
  await assert.rejects(
    upsertLabUser({ config, email: 'person@example.com', password: 'pw', fetchImpl }),
    /non-lab identity/,
  );
  config.urls.convexSite = 'https://adorable-perch-596.convex.site';
  await assert.rejects(
    upsertLabUser({ config, email: 'lab@glasstunnel.test', password: 'pw', fetchImpl }),
    /non-local/,
  );
});

test('deleteLabUser removes the account through the local admin CLI', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];
  await deleteLabUser(config, 'user-2', { runCommand: recordingRunner(calls) });
  assert.deepEqual(calls[0].args, [
    'run',
    'auth:deleteUserByLegacyId',
    '{"legacyUserId":"user-2"}',
    '--env-file',
    config.files.convexEnv,
  ]);
});

test('readLabEmails reads one lab address from the local outbox through the admin CLI', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];
  const emails = [
    {
      kind: 'password_changed',
      to: 'reset@glasstunnel.test',
      subject: 'Your password was changed',
      text: 'Your password was changed.',
      url: null,
      createdAt: 1_790_000_002_000,
    },
    {
      kind: 'password_reset',
      to: 'reset@glasstunnel.test',
      subject: 'Reset your password',
      text: 'Open the link to reset your password.',
      url: 'http://127.0.0.1:5173/?resetPassword=1&token=abc',
      createdAt: 1_790_000_001_000,
    },
  ];
  const result = await readLabEmails(config, 'reset@glasstunnel.test', {
    runCommand: async (command, args, options) => {
      calls.push({ command, args, env: options.env, cwd: options.cwd });
      // The CLI prints indented JSON when stdout is not a terminal.
      return { stdout: `${JSON.stringify(emails, null, 2)}\n`, stderr: '', exitCode: 0 };
    },
  });

  assert.deepEqual(result, emails);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, join(config.root, 'node_modules/.bin/convex'));
  assert.equal(calls[0].cwd, config.root);
  assert.deepEqual(calls[0].args, [
    'run',
    'email:labOutbox',
    '{"to":"reset@glasstunnel.test"}',
    '--env-file',
    config.files.convexEnv,
  ]);
  assert.equal(calls[0].env.CONVEX_AGENT_MODE, 'anonymous');
  assert.equal(calls[0].env.CONVEX_DEPLOYMENT, 'anonymous:anonymous-agent');
});

test('readLabEmails refuses real identities before running the CLI', async (t) => {
  const config = fixtureConfig(t);
  const runCommand = async () => assert.fail('must not run the CLI');
  await assert.rejects(readLabEmails(config, 'person@example.com', { runCommand }), /non-lab identity/);
  await assert.rejects(readLabEmails(config, 'lab@glasstunnel.test.example.com', { runCommand }), /non-lab identity/);
});

test('parseLabEmails accepts empty output and a leading notice, and never echoes the outbox', () => {
  assert.deepEqual(parseLabEmails(''), []);
  assert.deepEqual(parseLabEmails(undefined), []);
  assert.deepEqual(parseLabEmails('[]\n'), []);
  assert.deepEqual(parseLabEmails('Some CLI notice\n[\n  {\n    "kind": "password_reset"\n  }\n]\n'), [
    { kind: 'password_reset' },
  ]);

  const secretLink = 'http://127.0.0.1:5173/?resetPassword=1&token=secret-token-value';
  for (const output of [`{"url":"${secretLink}"}`, `not json ${secretLink}`, `[\n{"url":"${secretLink}"`]) {
    assert.throws(
      () => parseLabEmails(output),
      (error) => {
        assert.match(error.message, /local email outbox/);
        assert.doesNotMatch(error.message, /secret-token-value/);
        return true;
      },
    );
  }
});

test('bootstrapConvex starts the backend, waits for functions, configures it, then creates the lab account', async (t) => {
  const config = fixtureConfig(t);
  const steps = [];
  const manifest = { version: 2, runId: 'run-1', services: [] };
  const secrets = await bootstrapConvex({
    config,
    runId: 'run-1',
    manifest,
    spawnService: async (_config, definition) => {
      steps.push(`spawn ${definition.name}`);
      return { name: definition.name, pid: 1234, runId: definition.runId, managed: true };
    },
    waitHealth: async (url) => steps.push(`health ${url}`),
    runCommand: async (_command, args) => {
      steps.push(args.slice(0, 3).join(' '));
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    fetchImpl: async (url) => {
      const path = new URL(url).pathname;
      steps.push(`fetch ${path}`);
      if (path === '/worker/account-plane') return new Response('', { status: 401 });
      return authResponse(200, { token: 'lab-token', user: { id: 'lab-user' } }, 'lab-token');
    },
  });

  assert.equal(secrets.workerSecret, labConvexSecrets(config).workerSecret);
  assert.deepEqual(manifest.services.map((service) => service.name), ['convex']);
  assert.deepEqual(steps, [
    'spawn convex',
    'health http://127.0.0.1:3210/version',
    'fetch /worker/account-plane',
    'env set BETTER_AUTH_SECRET',
    'env set BETTER_AUTH_URL',
    'env set PUBLIC_APP_URL',
    'env set WORKER_CONVEX_SECRET',
    'env set AUTH_EMAIL_OUTBOX',
    'fetch /api/auth/sign-up/email',
  ]);
});
