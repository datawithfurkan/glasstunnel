import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import { readManifest, writeManifest } from './processes.mjs';
import {
  assertPortsAvailable,
  hostServiceDefinition,
  parseHostMetadata,
  pwaServiceDefinition,
  resetLab,
  runDoctor,
  signedMacLaunchDefinition,
  startCoreLab,
  stopLab,
  waitForHttp,
  workerServiceDefinition,
  writeWorkerEnvironment,
} from './services.mjs';

function fixtureConfig(t) {
  const root = mkdtempSync(join(tmpdir(), 'glasstunnel-services-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return ensureRuntimeDirectories(labConfig(root));
}

const localSupabase = {
  apiUrl: 'http://127.0.0.1:54321',
  anonKey: 'anon-value',
  serviceRoleKey: 'service-value',
};

test('Worker definition uses strict local ports and an ignored generated env file', (t) => {
  const config = fixtureConfig(t);
  writeWorkerEnvironment(config, localSupabase);
  const definition = workerServiceDefinition(config);
  const workerEnvironment = readFileSync(config.files.workerEnv, 'utf8');

  assert.equal(
    definition.command,
    join(config.root, 'apps/cloudflare-signal/node_modules/.bin/wrangler'),
  );
  assert.deepEqual(definition.args, [
    'dev',
    '--cwd',
    join(config.root, 'apps/cloudflare-signal'),
    '--config',
    'wrangler.jsonc',
    '--env-file',
    config.files.workerEnv,
    '--ip',
    '127.0.0.1',
    '--port',
    '8787',
    '--persist-to',
    config.paths.workerState,
    '--local',
    '--show-interactive-dev-session=false',
  ]);
  assert.equal(JSON.stringify(definition).includes('service-value'), false);
  assert.match(workerEnvironment, /ALLOWED_ORIGINS="http:\/\/127\.0\.0\.1:5173"/);
});

test('PWA definition supplies only explicit local account-first environment', (t) => {
  const config = fixtureConfig(t);
  const definition = pwaServiceDefinition(config, localSupabase);

  assert.equal(definition.command, 'pnpm');
  assert.deepEqual(definition.args, [
    '--dir',
    join(config.root, 'apps/mobile-pwa'),
    'exec',
    'vite',
    '--host',
    '127.0.0.1',
    '--port',
    '5173',
    '--strictPort',
  ]);
  assert.deepEqual(definition.env, {
    VITE_PUBLIC_APP_URL: 'http://127.0.0.1:5173',
    VITE_SIGNALING_URL: 'ws://127.0.0.1:8787/signal',
    VITE_SUPABASE_URL: 'http://127.0.0.1:54321',
    VITE_SUPABASE_ANON_KEY: 'anon-value',
  });
});

test('assertPortsAvailable refuses an unknown listener', async (t) => {
  const config = fixtureConfig(t);
  await assert.rejects(
    assertPortsAvailable(config, {
      findOwners: async (port) => (port === 8787 ? [99123] : []),
    }),
    /8787.*99123.*refusing/i,
  );
});

test('waitForHttp retries until the expected endpoint is healthy', async (t) => {
  let requests = 0;
  const server = createServer((_request, response) => {
    requests += 1;
    response.statusCode = requests < 2 ? 503 : 200;
    response.end(requests < 2 ? 'starting' : 'ready');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();

  const result = await waitForHttp(`http://127.0.0.1:${address.port}`, {
    timeoutMs: 1_000,
    intervalMs: 10,
  });

  assert.equal(result.status, 200);
  assert.equal(requests, 2);
});

test('startCoreLab removes its manifest when service health fails', async (t) => {
  const config = fixtureConfig(t);

  await assert.rejects(
    startCoreLab({
      config,
      bootstrap: async () => ({ ...localSupabase, startedByLab: false }),
      findOwners: async () => [],
      spawnService: async (_config, definition) => ({
        name: definition.name,
        pid: 999_999,
        runId: 'test-run',
        logPath: join(config.paths.logs, `${definition.name}.log`),
        managed: true,
      }),
      waitHealth: async () => {
        throw new Error('health failed');
      },
    }),
    /health failed/,
  );

  assert.equal(readManifest(config), null);
});

test('Swift host definition uses the canonical package and isolated dev key', (t) => {
  const config = fixtureConfig(t);
  const definition = hostServiceDefinition(config, { lifetimeSeconds: 900 });

  assert.equal(definition.command, 'swift');
  assert.deepEqual(definition.args, [
    'run',
    '--package-path',
    join(config.root, 'apps/host-macos'),
    '--scratch-path',
    config.paths.swiftScratch,
    'TerminalLiveHostHarness',
  ]);
  assert.equal(definition.env.GLASSTUNNEL_DEV, '1');
  assert.equal(definition.env.GLASSTUNNEL_DEV_DEVICE_KEY_FILE, config.files.deviceKey);
  assert.equal(definition.env.GT_TERMINAL_LIVE_SIGNALING_URL, 'ws://127.0.0.1:8787/signal');
  assert.equal(definition.env.GT_TERMINAL_LIVE_HOST_SECONDS, '900');
  assert.equal(definition.env.GT_TERMINAL_LIVE_SYNTHETIC_SCREEN, '1');
});

test('parseHostMetadata waits for both identity fields and surfaces harness errors', () => {
  assert.equal(parseHostMetadata('HOST_DEVICE_ID device-1\nSTATE connected\n'), null);
  assert.deepEqual(parseHostMetadata('HOST_DEVICE_ID device-1\nLINK_CODE ABCD23\n'), {
    deviceId: 'device-1',
    linkCode: 'ABCD23',
  });
  assert.throws(
    () => parseHostMetadata('HARNESS_ERROR account registration failed\n'),
    /account registration failed/,
  );
});

test('signed Mac definition keeps local URLs, stable identity, and scratch path explicit', (t) => {
  const config = fixtureConfig(t);
  const definition = signedMacLaunchDefinition(config);

  assert.equal(definition.command, 'bash');
  assert.deepEqual(definition.args, [join(config.root, 'scripts/dev-app.sh')]);
  assert.equal(definition.env.GLASSTUNNEL_WEB_APP_URL, config.urls.pwa);
  assert.equal(definition.env.GLASSTUNNEL_SIGNALING_URL, config.urls.signaling);
  assert.equal(definition.env.GLASSTUNNEL_KEYCHAIN_SUFFIX, 'lab');
  assert.equal(definition.env.GLASSTUNNEL_DEVICE_REGISTRY_FILE, config.files.deviceRegistry);
  assert.equal(definition.env.GLASSTUNNEL_SWIFT_SCRATCH_PATH, config.paths.swiftScratch);
  assert.equal(
    definition.env.GLASSTUNNEL_DEV_APP_PATH,
    config.files.macApp,
  );
  assert.equal(definition.env.GLASSTUNNEL_DEV_BUNDLE_ID, 'io.glasstunnel.host.lab');
  assert.equal(definition.env.GLASSTUNNEL_DEV_DISPLAY_NAME, 'Glasstunnel Lab');
  assert.equal(
    definition.env.GLASSTUNNEL_DEV_CODESIGN_IDENTITY,
    'Glasstunnel Local Development',
  );
  assert.equal(definition.env.GLASSTUNNEL_RESET_TCC, undefined);
});

test('stop closes the isolated signed Mac app even without a service manifest', async (t) => {
  const config = fixtureConfig(t);
  let stopCalls = 0;

  const result = await stopLab({
    config,
    stopMacApp: async ({ config: receivedConfig }) => {
      stopCalls += 1;
      assert.equal(receivedConfig, config);
      return true;
    },
  });

  assert.equal(stopCalls, 1);
  assert.equal(result.stopped, true);
  assert.equal(result.macAppStopped, true);
  assert.deepEqual(result.services, []);
});

test('doctor reports tool versions, Docker, browsers, signing, ports, and stale ownership', async (t) => {
  const config = fixtureConfig(t);
  writeManifest(config, {
    version: 1,
    runId: 'stale-run',
    createdAt: '2026-07-22T00:00:00.000Z',
    startedSupabaseByLab: false,
    services: [
      {
        name: 'worker',
        pid: 99123,
        runId: 'stale-run',
        managed: true,
      },
    ],
  });

  const result = await runDoctor({
    config,
    runCommand: async (command, args) => {
      if (command === '/usr/bin/which') return { stdout: `/usr/local/bin/${args[0]}\n` };
      if (command === 'docker' && args[0] === 'info') return { stdout: '27.0.0\n' };
      if (command === '/usr/bin/security') {
        return { stdout: '1) ABC123 "Apple Development: Local Test"\n' };
      }
      return { stdout: `${command} 1.0.0\n` };
    },
    browserExecutables: async () => ({
      chromium: '/test/browsers/chromium',
      webkit: '/test/browsers/webkit',
    }),
    pathExists: (path) =>
      path.startsWith('/test/browsers/') || path.endsWith('node_modules/.bin/wrangler'),
    findOwners: async () => [],
    processStatus: async () => ({ alive: false, owned: false }),
  });

  assert.equal(result.ok, false);
  assert.equal(result.tools.node.available, true);
  assert.match(result.tools.node.version, /1\.0\.0/);
  assert.equal(result.docker.ready, true);
  assert.equal(result.browsers.chromium.available, true);
  assert.equal(result.browsers.webkit.available, true);
  assert.equal(result.signing.stable, true);
  assert.equal(result.ports.pwa.available, true);
  assert.equal(result.manifest.stale, true);
  assert.match(result.actions.join(' '), /lab:down/);
});

test('doctor rejects an installed tool that cannot execute', async (t) => {
  const config = fixtureConfig(t);
  const result = await runDoctor({
    config,
    runCommand: async (command, args) => {
      if (command === '/usr/bin/which') return { stdout: `/usr/local/bin/${args[0]}\n` };
      if (command.endsWith('/node')) throw new Error('broken executable');
      if (command === 'docker' && args[0] === 'info') return { stdout: '27.0.0\n' };
      if (command === '/usr/bin/security') return { stdout: '0 valid identities found\n' };
      return { stdout: `${command} 1.0.0\n` };
    },
    browserExecutables: async () => ({
      chromium: '/test/browsers/chromium',
      webkit: '/test/browsers/webkit',
    }),
    pathExists: (path) =>
      path.startsWith('/test/browsers/') || path.endsWith('node_modules/.bin/wrangler'),
    findOwners: async () => [],
  });

  assert.equal(result.ok, false);
  assert.equal(result.tools.node.available, false);
  assert.match(result.actions.join(' '), /repair node/);
});

test('reset stops Supabase only when the reset had to start it', async (t) => {
  const config = fixtureConfig(t);
  const commands = [];
  const common = {
    config,
    stopMacApp: async () => false,
    runCommand: async (command, args) => {
      commands.push([command, ...args]);
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    bootstrap: async () => ({ email: config.identity.email }),
  };

  await resetLab({
    ...common,
    resetDatabase: async () => ({ startedByLab: true }),
  });
  assert.deepEqual(commands, [['supabase', 'stop']]);

  commands.length = 0;
  await resetLab({
    ...common,
    resetDatabase: async () => ({ startedByLab: false }),
  });
  assert.deepEqual(commands, []);
});
