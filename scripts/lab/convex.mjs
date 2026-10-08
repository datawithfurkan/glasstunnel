// Local Convex backend for the lab: accounts, sign-in (Better Auth), and the
// account plane run on 127.0.0.1 exactly as production runs them on Convex
// cloud. Never touches a cloud deployment: the CLI runs in anonymous agent
// mode with a lab-only env file, and every URL is checked to be loopback.

import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { defaultRunCommand } from './commands.mjs';
import { labConfig } from './config.mjs';

const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

export function assertLoopbackUrl(value, description = 'Convex URL') {
  const url = new URL(value);
  if (!LOCAL_HOSTS.has(url.hostname)) {
    throw new Error(`Refusing to use a non-local ${description}: ${url.origin}`);
  }
  return url;
}

function assertLabIdentity(email) {
  if (!String(email).endsWith('@glasstunnel.test')) {
    throw new Error(`Refusing to manage a non-lab identity: ${email}`);
  }
}

/** The CLI environment that pins every convex command to the local anonymous backend. */
export function convexCliEnvironment(config) {
  return {
    CONVEX_AGENT_MODE: 'anonymous',
    // A developer's own .env.local could name a cloud deployment; the lab env
    // file overrides it.
    CONVEX_DEPLOYMENT: 'anonymous:anonymous-agent',
    NO_COLOR: '1',
  };
}

function convexBinary(config) {
  return join(config.root, 'node_modules/.bin/convex');
}

export function writeConvexEnvFile(config) {
  mkdirSync(dirname(config.files.convexEnv), { recursive: true });
  writeFileSync(config.files.convexEnv, 'CONVEX_DEPLOYMENT=anonymous:anonymous-agent\n', { mode: 0o600 });
  return config.files.convexEnv;
}

export function convexServiceDefinition(config) {
  return {
    name: 'convex',
    command: convexBinary(config),
    args: ['dev', '--typecheck', 'disable', '--tail-logs', 'disable', '--env-file', config.files.convexEnv],
    env: convexCliEnvironment(config),
    cwd: config.root,
    healthUrl: `${config.urls.convex}/version`,
  };
}

/** Secrets that only ever exist on this machine; stable across lab restarts. */
export function labConvexSecrets(config) {
  const path = config.files.convexSecrets;
  if (existsSync(path)) {
    const parsed = JSON.parse(readFileSync(path, 'utf8'));
    if (parsed.betterAuthSecret && parsed.workerSecret) return parsed;
  }
  const secrets = {
    betterAuthSecret: randomBytes(32).toString('hex'),
    workerSecret: randomBytes(32).toString('hex'),
  };
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(secrets)}\n`, { mode: 0o600 });
  return secrets;
}

export async function runConvexCli(config, args, { runCommand = defaultRunCommand } = {}) {
  return runCommand(convexBinary(config), [...args, '--env-file', config.files.convexEnv], {
    cwd: config.root,
    env: { ...process.env, ...convexCliEnvironment(config) },
  });
}

/**
 * Waits until `convex dev` has pushed the functions: the gateway route answers
 * (401 without credentials) instead of 404.
 */
export async function waitForConvexFunctions(
  config,
  { timeoutMs = 120_000, intervalMs = 500, fetchImpl = fetch } = {},
) {
  const url = `${config.urls.convexSite}/worker/account-plane`;
  assertLoopbackUrl(url);
  const deadline = Date.now() + timeoutMs;
  let last = 'no response';
  while (Date.now() < deadline) {
    try {
      const response = await fetchImpl(url, { method: 'POST' });
      if (response.status === 401 || response.status === 503) return;
      last = `HTTP ${response.status}`;
    } catch (error) {
      last = error instanceof Error ? error.message : String(error);
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error(`Timed out waiting for the local Convex functions (${url}): ${last}`);
}

export async function configureLabConvex(config, { runCommand = defaultRunCommand } = {}) {
  const secrets = labConvexSecrets(config);
  const values = {
    BETTER_AUTH_SECRET: secrets.betterAuthSecret,
    BETTER_AUTH_URL: config.urls.convexSite,
    PUBLIC_APP_URL: config.urls.pwa,
    WORKER_CONVEX_SECRET: secrets.workerSecret,
    // Account emails (password reset, password changed) land in the local
    // labEmailOutbox table instead of being sent. The backend honours this
    // only while its auth URL is loopback, so it can never reach production.
    AUTH_EMAIL_OUTBOX: 'lab',
  };
  for (const [name, value] of Object.entries(values)) {
    await runConvexCli(config, ['env', 'set', name, value], { runCommand });
  }
  return secrets;
}

/**
 * Parses `convex run` output for the lab outbox. The CLI prints the result as
 * indented JSON when stdout is not a terminal and prints nothing for null.
 * Errors never echo the output: it holds live reset links.
 */
export function parseLabEmails(output) {
  const text = String(output ?? '').trim();
  if (!text) return [];
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Tolerate a stray notice line before the JSON block.
    const lines = text.split(/\r?\n/);
    const start = lines.findIndex((line) => line === '[' || line === '[]');
    if (start === -1) throw new Error('The local email outbox did not return JSON.');
    try {
      parsed = JSON.parse(lines.slice(start).join('\n'));
    } catch {
      throw new Error('The local email outbox did not return JSON.');
    }
  }
  if (!Array.isArray(parsed)) throw new Error('The local email outbox did not return a list.');
  return parsed;
}

/**
 * Reads the account emails the local backend stored for one lab address,
 * newest first (internal query email:labOutbox through the admin CLI).
 * Returns [] when the backend is not in lab outbox mode.
 */
export async function readLabEmails(config, to, { runCommand = defaultRunCommand } = {}) {
  assertLabIdentity(to);
  const { stdout } = await runConvexCli(config, ['run', 'email:labOutbox', JSON.stringify({ to })], {
    runCommand,
  });
  return parseLabEmails(stdout);
}

async function authJson(response, description) {
  const text = await response.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { message: text };
  }
  return { ok: response.ok, status: response.status, body, token: response.headers.get('set-auth-token') };
}

/** Creates the lab account, or signs in when it already exists. Returns the session token. */
export async function upsertLabUser({ config = labConfig(), email, password, name = 'Glasstunnel Lab', fetchImpl = fetch }) {
  assertLabIdentity(email);
  const site = assertLoopbackUrl(config.urls.convexSite);
  const headers = { 'content-type': 'application/json', origin: config.urls.pwa };
  const signUp = await authJson(
    await fetchImpl(new URL('/api/auth/sign-up/email', site), {
      method: 'POST',
      headers,
      body: JSON.stringify({ email, password, name }),
    }),
    'Creating the local lab user',
  );
  if (signUp.ok && signUp.token) return { token: signUp.token, userId: signUp.body?.user?.id, created: true };
  const signIn = await signInLabUser({ config, email, password, fetchImpl });
  return { ...signIn, created: false };
}

export async function signInLabUser({ config = labConfig(), email, password, fetchImpl = fetch }) {
  assertLabIdentity(email);
  const site = assertLoopbackUrl(config.urls.convexSite);
  const result = await authJson(
    await fetchImpl(new URL('/api/auth/sign-in/email', site), {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: config.urls.pwa },
      body: JSON.stringify({ email, password }),
    }),
    'Signing in the local lab user',
  );
  if (!result.ok || !result.token) {
    throw new Error(`Signing in the local lab user failed (${result.status}): ${result.body?.message ?? 'no token'}`);
  }
  return { token: result.token, userId: result.body?.user?.id };
}

/** Deletes a lab account through the internal migration helper (admin CLI on the local backend). */
export async function deleteLabUser(config, legacyUserId, { runCommand = defaultRunCommand } = {}) {
  await runConvexCli(config, ['run', 'auth:deleteUserByLegacyId', JSON.stringify({ legacyUserId })], { runCommand });
}

/** Removes the local backend's database; the next start begins empty. */
export function resetConvexState(config) {
  rmSync(join(config.root, '.convex', 'local'), { recursive: true, force: true });
}
