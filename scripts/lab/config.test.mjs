import assert from 'node:assert/strict';
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ensureRuntimeDirectories, labConfig, parseEnvOutput, redact } from './config.mjs';

test('parseEnvOutput parses quoted and unquoted Supabase values', () => {
  assert.deepEqual(
    parseEnvOutput(
      ['API_URL="http://127.0.0.1:54321"', 'ANON_KEY=abc', 'IGNORED LINE', ''].join('\n'),
    ),
    {
      API_URL: 'http://127.0.0.1:54321',
      ANON_KEY: 'abc',
    },
  );
});

test('redact recursively hides credential-shaped fields', () => {
  assert.deepEqual(
    redact({
      accessToken: 'secret',
      nested: {
        password: 'also-secret',
        url: 'http://127.0.0.1',
      },
      services: [{ apiKey: 'hidden', name: 'worker' }],
    }),
    {
      accessToken: '<redacted>',
      nested: {
        password: '<redacted>',
        url: 'http://127.0.0.1',
      },
      services: [{ apiKey: '<redacted>', name: 'worker' }],
    },
  );
});

test('labConfig resolves a symlinked root to its physical path', () => {
  const temp = mkdtempSync(join(tmpdir(), 'glasstunnel-config-'));
  const link = join(temp, 'repo-link');
  symlinkSync(process.cwd(), link);

  try {
    const config = labConfig(link);
    assert.equal(config.root, realpathSync(process.cwd()));
    assert.equal(config.urls.pwa, 'http://127.0.0.1:5173');
    assert.equal(config.urls.worker, 'http://127.0.0.1:8787');
    assert.equal(config.urls.signaling, 'ws://127.0.0.1:8787/signal');
    assert.equal(config.urls.supabase, 'http://127.0.0.1:54321');
    assert.equal(config.files.deviceRegistry, join(config.paths.macRuntime, 'devices.json'));
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
});

test('canonical lab keeps signed Mac runtime state off the repository volume', () => {
  const config = labConfig();

  assert.equal(config.paths.macRuntime.startsWith(`${config.root}/`), false);
  assert.equal(config.files.deviceKey.startsWith(`${config.paths.macRuntime}/`), true);
  assert.equal(config.files.deviceRegistry.startsWith(`${config.paths.macRuntime}/`), true);
  assert.equal(config.files.macApp.startsWith(`${config.paths.macRuntime}/`), true);
});

test('ensureRuntimeDirectories creates every generated output directory', () => {
  const root = mkdtempSync(join(tmpdir(), 'glasstunnel-runtime-'));

  try {
    const config = labConfig(root);
    ensureRuntimeDirectories(config);

    for (const path of Object.values(config.paths)) {
      if (path.endsWith('.json')) continue;
      assert.equal(realpathSync(path), path);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('ensureRuntimeDirectories migrates legacy signed Mac identity files once', () => {
  const root = mkdtempSync(join(tmpdir(), 'glasstunnel-runtime-migration-'));

  try {
    const config = labConfig(root);
    ensureRuntimeDirectories(config);
    writeFileSync(join(config.paths.runtime, 'device-key.json'), 'legacy-device-key');
    writeFileSync(join(config.paths.runtime, 'devices.json'), '{"devices":[]}');

    ensureRuntimeDirectories(config);

    assert.equal(readFileSync(config.files.deviceKey, 'utf8'), 'legacy-device-key');
    assert.equal(readFileSync(config.files.deviceRegistry, 'utf8'), '{"devices":[]}');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
