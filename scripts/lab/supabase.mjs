import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import { labConfig, parseEnvOutput } from './config.mjs';

const execFileAsync = promisify(execFile);

export async function defaultRunCommand(command, args, { cwd, env } = {}) {
  const { stdout, stderr } = await execFileAsync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    maxBuffer: 10 * 1024 * 1024,
  });
  return { stdout, stderr, exitCode: 0 };
}

function requireStatusValue(values, name) {
  const value = values[name];
  if (!value) throw new Error(`Local Supabase status did not provide ${name}.`);
  return value;
}

function assertLocalApiUrl(apiUrl) {
  const url = new URL(apiUrl);
  if (!['127.0.0.1', 'localhost', '::1'].includes(url.hostname)) {
    throw new Error(`Refusing to use a non-local Supabase API URL: ${url.origin}`);
  }
  return url;
}

function assertLabIdentity(email) {
  if (!String(email).endsWith('@glasstunnel.test')) {
    throw new Error(`Refusing to manage a non-lab Supabase identity: ${email}`);
  }
}

async function responseJson(response, description) {
  const body = await response.text();
  let parsed = null;
  try {
    parsed = body ? JSON.parse(body) : {};
  } catch {
    parsed = { message: body };
  }

  if (!response.ok) {
    const detail = parsed?.message ?? parsed?.error_description ?? response.statusText;
    throw new Error(`${description} failed (${response.status}): ${detail}`);
  }
  return parsed;
}

export async function supabaseStatus({
  root = labConfig().root,
  runCommand = defaultRunCommand,
} = {}) {
  const result = await runCommand('supabase', ['status', '-o', 'env'], { cwd: root });
  const values = parseEnvOutput(result.stdout);
  const apiUrl = requireStatusValue(values, 'API_URL');
  assertLocalApiUrl(apiUrl);

  return {
    apiUrl,
    anonKey: requireStatusValue(values, 'ANON_KEY'),
    serviceRoleKey: requireStatusValue(values, 'SERVICE_ROLE_KEY'),
  };
}

export async function ensureSupabase({
  root = labConfig().root,
  runCommand = defaultRunCommand,
} = {}) {
  try {
    return { ...(await supabaseStatus({ root, runCommand })), startedByLab: false };
  } catch (statusError) {
    try {
      await runCommand('supabase', ['start'], { cwd: root });
    } catch (startError) {
      throw new AggregateError(
        [statusError, startError],
        'Local Supabase is unavailable and could not be started.',
      );
    }
    return { ...(await supabaseStatus({ root, runCommand })), startedByLab: true };
  }
}

export async function resetSupabase({
  root = labConfig().root,
  runCommand = defaultRunCommand,
} = {}) {
  const initial = await ensureSupabase({ root, runCommand });
  await runCommand('supabase', ['db', 'reset'], { cwd: root });
  return {
    ...(await supabaseStatus({ root, runCommand })),
    startedByLab: initial.startedByLab,
  };
}

/**
 * Right after `supabase db reset` the gateway answers 502/503 for up to a
 * minute while GoTrue reconnects; the first admin call after a reset must
 * wait that out instead of failing the whole lane.
 */
async function fetchWhileGatewayRecovers(
  fetchImpl,
  url,
  init,
  { attempts = 30, retryDelayMs = 3_000, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {},
) {
  let response = await fetchImpl(url, init);
  for (let attempt = 1; attempt < attempts && (response.status === 502 || response.status === 503); attempt += 1) {
    await sleep(retryDelayMs);
    response = await fetchImpl(url, init);
  }
  return response;
}

export async function upsertLabUser({
  apiUrl,
  serviceRoleKey,
  email,
  password,
  fetchImpl = fetch,
  recovery = {},
}) {
  const baseUrl = assertLocalApiUrl(apiUrl);
  assertLabIdentity(email);
  const headers = {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    'content-type': 'application/json',
  };
  const listUrl = new URL('/auth/v1/admin/users?page=1&per_page=1000', baseUrl);
  const users = await responseJson(
    await fetchWhileGatewayRecovers(fetchImpl, listUrl, { headers }, recovery),
    'Listing local lab users',
  );
  const existing = users.users?.find((user) => user.email?.toLowerCase() === email.toLowerCase());
  const userPayload = {
    email,
    password,
    email_confirm: true,
    user_metadata: { glasstunnel_lab: true },
  };

  if (existing) {
    return responseJson(
      await fetchImpl(new URL(`/auth/v1/admin/users/${existing.id}`, baseUrl), {
        method: 'PUT',
        headers,
        body: JSON.stringify(userPayload),
      }),
      'Updating the local lab user',
    );
  }

  return responseJson(
    await fetchImpl(new URL('/auth/v1/admin/users', baseUrl), {
      method: 'POST',
      headers,
      body: JSON.stringify(userPayload),
    }),
    'Creating the local lab user',
  );
}

export async function signInLabUser({ apiUrl, anonKey, email, password, fetchImpl = fetch }) {
  const baseUrl = assertLocalApiUrl(apiUrl);
  assertLabIdentity(email);
  const session = await responseJson(
    await fetchImpl(new URL('/auth/v1/token?grant_type=password', baseUrl), {
      method: 'POST',
      headers: {
        apikey: anonKey,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ email, password }),
    }),
    'Signing in the local lab user',
  );

  if (!session.access_token) {
    throw new Error('Local lab sign-in succeeded without an access token.');
  }
  return { accessToken: session.access_token, user: session.user };
}

export async function bootstrapSupabase({
  config = labConfig(),
  runCommand = defaultRunCommand,
  fetchImpl = fetch,
} = {}) {
  const status = await ensureSupabase({ root: config.root, runCommand });
  await upsertLabUser({
    ...status,
    ...config.identity,
    fetchImpl,
  });
  const session = await signInLabUser({
    apiUrl: status.apiUrl,
    anonKey: status.anonKey,
    ...config.identity,
    fetchImpl,
  });

  return {
    ...status,
    ...config.identity,
    accessToken: session.accessToken,
  };
}
