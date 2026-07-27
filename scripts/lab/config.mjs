import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, mkdirSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const CANONICAL_MODULE_ROOT = realpathSync(MODULE_ROOT);
const REDACTED = '<redacted>';
const SECRET_KEY = /token|password|secret|key/i;

export function labConfig(rootHint = MODULE_ROOT) {
  const root = realpathSync(rootHint);
  const runtime = join(root, '.cache', 'glasstunnel-lab');
  const workspaceKey = createHash('sha256').update(root).digest('hex').slice(0, 12);
  const macRuntime =
    root === CANONICAL_MODULE_ROOT
      ? resolve(
          process.env.GT_LAB_MAC_RUNTIME_DIR ??
            join(homedir(), 'Library', 'Caches', 'Glasstunnel', 'LocalLab', workspaceKey),
        )
      : join(runtime, 'mac');

  return {
    root,
    ports: {
      pwa: 5173,
      worker: 8787,
      supabase: 54321,
    },
    urls: {
      pwa: 'http://127.0.0.1:5173',
      worker: 'http://127.0.0.1:8787',
      signaling: 'ws://127.0.0.1:8787/signal',
      supabase: 'http://127.0.0.1:54321',
    },
    identity: {
      email: 'lab@glasstunnel.test',
      password: 'Glasstunnel-Lab-Only-2026',
    },
    paths: {
      runtime,
      logs: join(runtime, 'logs'),
      state: join(runtime, 'state'),
      playwright: join(runtime, 'playwright'),
      swiftScratch: join(runtime, 'swift'),
      workerState: join(runtime, 'worker'),
      macRuntime,
    },
    files: {
      manifest: join(runtime, 'manifest.json'),
      workerEnv: join(runtime, 'worker.env'),
      deviceKey: join(macRuntime, 'device-key.json'),
      deviceRegistry: join(macRuntime, 'devices.json'),
      macApp: join(macRuntime, 'Glasstunnel-Lab.app'),
    },
  };
}

export function ensureRuntimeDirectories(config = labConfig()) {
  for (const path of Object.values(config.paths)) {
    mkdirSync(path, { recursive: true });
  }

  for (const [legacyName, destination] of [
    ['device-key.json', config.files.deviceKey],
    ['devices.json', config.files.deviceRegistry],
  ]) {
    const source = join(config.paths.runtime, legacyName);
    if (!existsSync(source) || existsSync(destination)) continue;
    copyFileSync(source, destination);
    chmodSync(destination, 0o600);
  }

  return config;
}

export function parseEnvOutput(text) {
  const values = {};

  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;

    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (!match) continue;

    let value = match[2].trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    values[match[1]] = value;
  }

  return values;
}

export function redact(value) {
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (!value || typeof value !== 'object') return value;

  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      SECRET_KEY.test(key) ? REDACTED : redact(entry),
    ]),
  );
}
