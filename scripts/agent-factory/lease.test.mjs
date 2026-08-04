import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  acquireLease,
  heartbeatLease,
  listLeases,
  recoverExpiredLease,
  releaseLease,
} from './lease.mjs';

async function paths() {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-lease-'));
  return { root, leases: join(root, 'leases'), rigs: join(root, 'rigs') };
}

function fakeRunner(calls = []) {
  let bead = 0;
  return async (command, args, options) => {
    calls.push({ command, args, options });
    if (args[0] === 'create')
      return { code: 0, stdout: JSON.stringify({ id: `gt-${++bead}` }), stderr: '' };
    return { code: 0, stdout: '{}', stderr: '' };
  };
}

test('concurrent lease acquisition has exactly one winner', async () => {
  const factoryPaths = await paths();
  const runner = fakeRunner();
  const results = await Promise.allSettled([
    acquireLease({
      resource: 'canary-exclusive',
      nodeId: 'node-a',
      holder: 'worker-a',
      paths: factoryPaths,
      runner,
    }),
    acquireLease({
      resource: 'canary-exclusive',
      nodeId: 'node-b',
      holder: 'worker-b',
      paths: factoryPaths,
      runner,
    }),
  ]);
  assert.equal(results.filter((entry) => entry.status === 'fulfilled').length, 1);
  assert.equal(results.filter((entry) => entry.status === 'rejected').length, 1);
  assert.equal((await listLeases(factoryPaths)).length, 1);
});

test('only the owning node can heartbeat or release', async () => {
  const factoryPaths = await paths();
  const runner = fakeRunner();
  await acquireLease({
    resource: 'canary-exclusive',
    nodeId: 'node-a',
    holder: 'worker-a',
    paths: factoryPaths,
    runner,
  });
  await assert.rejects(
    () => heartbeatLease({ resource: 'canary-exclusive', nodeId: 'node-b', paths: factoryPaths }),
    /different node/,
  );
  await assert.rejects(
    () =>
      releaseLease({ resource: 'canary-exclusive', nodeId: 'node-b', paths: factoryPaths, runner }),
    /different node/,
  );
  assert.equal((await listLeases(factoryPaths)).length, 1);
});

test('release closes the audit bead before deleting the claim', async () => {
  const factoryPaths = await paths();
  const calls = [];
  const runner = fakeRunner(calls);
  await acquireLease({
    resource: 'canary-exclusive',
    nodeId: 'node-a',
    holder: 'worker-a',
    paths: factoryPaths,
    runner,
  });
  await releaseLease({
    resource: 'canary-exclusive',
    nodeId: 'node-a',
    paths: factoryPaths,
    runner,
    env: { BD_ROUTING_MODE: 'off' },
  });
  assert.equal(calls.at(-1).args[0], 'close');
  assert.equal(calls.at(-1).options.env.BD_ROUTING_MODE, 'off');
  assert.equal((await listLeases(factoryPaths)).length, 0);
});

test('acquire sends the isolated factory environment to Beads', async () => {
  const factoryPaths = await paths();
  const calls = [];
  await acquireLease({
    resource: 'canary-exclusive',
    nodeId: 'node-a',
    holder: 'worker-a',
    paths: factoryPaths,
    runner: fakeRunner(calls),
    env: { BD_ROUTING_MODE: 'off' },
  });

  assert.equal(calls[0].options.env.BD_ROUTING_MODE, 'off');
});

test('expired recovery is blocked until expiry and closes its audit bead', async () => {
  const factoryPaths = await paths();
  const calls = [];
  const runner = fakeRunner(calls);
  const start = new Date('2026-08-04T08:00:00.000Z');
  await acquireLease({
    resource: 'canary-exclusive',
    nodeId: 'node-a',
    holder: 'worker-a',
    ttlSeconds: 60,
    paths: factoryPaths,
    runner,
    now: start,
  });
  await assert.rejects(
    () =>
      recoverExpiredLease({
        resource: 'canary-exclusive',
        paths: factoryPaths,
        runner,
        now: new Date(start.getTime() + 30_000),
      }),
    /not expired/,
  );
  const result = await recoverExpiredLease({
    resource: 'canary-exclusive',
    paths: factoryPaths,
    runner,
    now: new Date(start.getTime() + 61_000),
  });
  assert.equal(result.recoveredNodeId, 'node-a');
  assert.equal(calls.at(-1).args[0], 'close');
  assert.equal((await listLeases(factoryPaths)).length, 0);
});

test('lease files contain no command output or secret material', async () => {
  const factoryPaths = await paths();
  await acquireLease({
    resource: 'canary-exclusive',
    nodeId: 'node-a',
    holder: 'worker-a',
    paths: factoryPaths,
    runner: fakeRunner(),
  });
  const text = await readFile(join(factoryPaths.leases, 'canary-exclusive.json'), 'utf8');
  assert.doesNotMatch(text, /stdout|stderr|token|password/i);
});
