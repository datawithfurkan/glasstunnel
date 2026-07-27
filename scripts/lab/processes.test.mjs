import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import {
  managedProcessStatus,
  readManifest,
  spawnManagedService,
  stopManagedService,
  stopManifestServices,
  writeManifest,
} from './processes.mjs';

function fixtureConfig(t) {
  const root = mkdtempSync(join(tmpdir(), 'glasstunnel-processes-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return ensureRuntimeDirectories(labConfig(root));
}

test('manifest writes round trip atomically', (t) => {
  const config = fixtureConfig(t);
  const manifest = {
    version: 1,
    runId: 'run-1',
    services: [{ name: 'worker', pid: 123, managed: true }],
  };

  writeManifest(config, manifest);

  assert.deepEqual(readManifest(config), manifest);
  assert.doesNotMatch(readFileSync(config.files.manifest, 'utf8'), /tmp/);
});

test('stops a managed process only when its run id matches', async (t) => {
  const config = fixtureConfig(t);
  const service = await spawnManagedService(config, {
    name: 'fixture',
    runId: 'owned-run',
    command: process.execPath,
    args: ['-e', 'setInterval(() => {}, 1000)'],
  });
  t.after(async () => {
    await stopManagedService(service).catch(() => {});
  });

  const running = await managedProcessStatus(service);
  assert.equal(running.alive, true);
  assert.equal(running.owned, true);
  assert.match(running.commandLine, /owned-run/);

  await assert.rejects(
    stopManagedService({ ...service, runId: 'forged-run' }),
    /ownership mismatch/i,
  );
  assert.equal((await managedProcessStatus(service)).alive, true);

  const result = await stopManagedService(service, { timeoutMs: 2_000 });
  assert.equal(result.stopped, true);
  assert.equal((await managedProcessStatus(service)).alive, false);
});

test('stopManifestServices clears a manifest after owned services exit', async (t) => {
  const config = fixtureConfig(t);
  const runId = 'manifest-run';
  const service = await spawnManagedService(config, {
    name: 'manifest-fixture',
    runId,
    command: process.execPath,
    args: ['-e', 'setInterval(() => {}, 1000)'],
  });
  t.after(async () => {
    await stopManagedService(service).catch(() => {});
  });
  writeManifest(config, { version: 1, runId, services: [service] });

  const results = await stopManifestServices(config);

  assert.equal(results.length, 1);
  assert.equal(results[0].stopped, true);
  assert.equal(readManifest(config), null);
});
