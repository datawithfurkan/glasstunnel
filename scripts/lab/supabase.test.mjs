import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';

import {
  ensureSupabase,
  resetSupabase,
  signInLabUser,
  supabaseStatus,
  upsertLabUser,
} from './supabase.mjs';

const ENV_OUTPUT = [
  'API_URL="http://127.0.0.1:54321"',
  'ANON_KEY="anon-value"',
  'SERVICE_ROLE_KEY="service-value"',
].join('\n');

function commandResult(stdout = '') {
  return { stdout, stderr: '', exitCode: 0 };
}

async function fakeAuthServer(t, handler) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

test('supabaseStatus parses a healthy local environment', async () => {
  const calls = [];
  const status = await supabaseStatus({
    root: '/tmp/glasstunnel',
    runCommand: async (command, args, options) => {
      calls.push({ command, args, options });
      return commandResult(ENV_OUTPUT);
    },
  });

  assert.deepEqual(calls, [
    {
      command: 'supabase',
      args: ['status', '-o', 'env'],
      options: { cwd: '/tmp/glasstunnel' },
    },
  ]);
  assert.equal(status.apiUrl, 'http://127.0.0.1:54321');
  assert.equal(status.anonKey, 'anon-value');
  assert.equal(status.serviceRoleKey, 'service-value');
});

test('ensureSupabase starts only when status initially fails', async () => {
  const calls = [];
  let statusAttempts = 0;
  const result = await ensureSupabase({
    root: '/tmp/glasstunnel',
    runCommand: async (command, args) => {
      calls.push([command, ...args]);
      if (args[0] === 'status' && statusAttempts++ === 0) {
        throw new Error('not running');
      }
      if (args[0] === 'start') return commandResult();
      return commandResult(ENV_OUTPUT);
    },
  });

  assert.deepEqual(calls, [
    ['supabase', 'status', '-o', 'env'],
    ['supabase', 'start'],
    ['supabase', 'status', '-o', 'env'],
  ]);
  assert.equal(result.startedByLab, true);
});

test('ensureSupabase reuses an already healthy stack', async () => {
  const calls = [];
  const result = await ensureSupabase({
    root: '/tmp/glasstunnel',
    runCommand: async (command, args) => {
      calls.push([command, ...args]);
      return commandResult(ENV_OUTPUT);
    },
  });

  assert.deepEqual(calls, [['supabase', 'status', '-o', 'env']]);
  assert.equal(result.startedByLab, false);
});

test('resetSupabase preserves whether it started the local stack', async () => {
  const calls = [];
  let statusAttempts = 0;
  const result = await resetSupabase({
    root: '/tmp/glasstunnel',
    runCommand: async (command, args) => {
      calls.push([command, ...args]);
      if (args[0] === 'status' && statusAttempts++ === 0) {
        throw new Error('not running');
      }
      return commandResult(args[0] === 'status' ? ENV_OUTPUT : '');
    },
  });

  assert.equal(result.startedByLab, true);
  assert.deepEqual(calls, [
    ['supabase', 'status', '-o', 'env'],
    ['supabase', 'start'],
    ['supabase', 'status', '-o', 'env'],
    ['supabase', 'db', 'reset'],
    ['supabase', 'status', '-o', 'env'],
  ]);
});

test('upsertLabUser waits out the gateway 502s that follow a database reset', async (t) => {
  let listCalls = 0;
  const apiUrl = await fakeAuthServer(t, async (request, response) => {
    if (request.method === 'GET') {
      listCalls += 1;
      if (listCalls <= 2) {
        response.statusCode = 502;
        response.end('An invalid response was received from the upstream server');
        return;
      }
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify({ users: [] }));
      return;
    }
    const body = await readJson(request);
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ id: 'user-2', ...body }));
  });

  const user = await upsertLabUser({
    apiUrl,
    serviceRoleKey: 'service-value',
    email: 'lab@glasstunnel.test',
    password: 'local-password',
    recovery: { retryDelayMs: 1 },
  });

  assert.equal(user.id, 'user-2');
  assert.equal(listCalls, 3);
});

test('upsertLabUser updates an existing local user', async (t) => {
  const requests = [];
  const apiUrl = await fakeAuthServer(t, async (request, response) => {
    requests.push({ method: request.method, url: request.url });
    response.setHeader('content-type', 'application/json');
    if (request.method === 'GET') {
      response.end(JSON.stringify({ users: [{ id: 'user-1', email: 'lab@glasstunnel.test' }] }));
      return;
    }
    const body = await readJson(request);
    response.end(JSON.stringify({ id: 'user-1', ...body }));
  });

  const user = await upsertLabUser({
    apiUrl,
    serviceRoleKey: 'service-value',
    email: 'lab@glasstunnel.test',
    password: 'local-password',
  });

  assert.equal(user.id, 'user-1');
  assert.deepEqual(requests, [
    { method: 'GET', url: '/auth/v1/admin/users?page=1&per_page=1000' },
    { method: 'PUT', url: '/auth/v1/admin/users/user-1' },
  ]);
});

test('upsertLabUser creates a missing local user and signInLabUser proves it works', async (t) => {
  const requests = [];
  const apiUrl = await fakeAuthServer(t, async (request, response) => {
    requests.push({ method: request.method, url: request.url });
    response.setHeader('content-type', 'application/json');
    if (request.method === 'GET') {
      response.end(JSON.stringify({ users: [] }));
      return;
    }
    const body = await readJson(request);
    if (request.url.startsWith('/auth/v1/token')) {
      response.end(JSON.stringify({ access_token: 'local-access-token', user: { id: 'user-2' } }));
      return;
    }
    response.end(JSON.stringify({ id: 'user-2', ...body }));
  });

  const user = await upsertLabUser({
    apiUrl,
    serviceRoleKey: 'service-value',
    email: 'lab@glasstunnel.test',
    password: 'local-password',
  });
  const session = await signInLabUser({
    apiUrl,
    anonKey: 'anon-value',
    email: 'lab@glasstunnel.test',
    password: 'local-password',
  });

  assert.equal(user.id, 'user-2');
  assert.equal(session.accessToken, 'local-access-token');
  assert.deepEqual(requests, [
    { method: 'GET', url: '/auth/v1/admin/users?page=1&per_page=1000' },
    { method: 'POST', url: '/auth/v1/admin/users' },
    { method: 'POST', url: '/auth/v1/token?grant_type=password' },
  ]);
});

test('admin operations reject non-loopback Supabase URLs', async () => {
  await assert.rejects(
    upsertLabUser({
      apiUrl: 'https://project.supabase.co',
      serviceRoleKey: 'service-value',
      email: 'lab@glasstunnel.test',
      password: 'local-password',
    }),
    /local Supabase/i,
  );
});
