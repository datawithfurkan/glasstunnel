import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { runCanary } from './canary.mjs';
import { resolveFactoryPaths } from './config.mjs';
import { listLeases } from './lease.mjs';

test('canary proves retry, independent review, readiness, and cleanup', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-canary-'));
  const repoRoot = join(root, 'source');
  const stateRoot = join(root, 'state');
  await mkdir(repoRoot, { recursive: true });
  const paths = resolveFactoryPaths({ repoRoot, env: { GT_FACTORY_HOME: stateRoot } });
  await mkdir(join(paths.rigs, 'glasstunnel'), { recursive: true });
  await mkdir(paths.leases, { recursive: true });

  // Gas City 1.4 reports the workflow root here; workflow descendants remain
  // queryable through their gc.root_bead_id metadata in Beads.
  const graphNodes = [{ id: 'gt-root', status: 'closed' }];
  const beadDetails = [
    { id: 'gt-root', title: 'Foundation canary', status: 'closed', metadata: {} },
    {
      id: 'gt-retry-1',
      title: 'Prove bounded transient retry',
      status: 'closed',
      metadata: {
        'gc.step_id': 'controlled-retry',
        'gc.attempt': '1',
        'gc.outcome': 'fail',
        'gc.failure_class': 'transient',
      },
    },
    {
      id: 'gt-retry-2',
      title: 'Prove bounded transient retry',
      status: 'closed',
      metadata: {
        'gc.step_id': 'controlled-retry',
        'gc.attempt': '2',
        'gc.outcome': 'pass',
      },
    },
    {
      id: 'gt-review',
      title: 'Independently review the canary evidence',
      status: 'closed',
      metadata: { canary_reviewed: true, 'gc.outcome': 'pass' },
    },
    {
      id: 'gt-ready',
      title: 'Mark the foundation canary integration-ready',
      status: 'closed',
      metadata: { integration_ready: true, 'gc.outcome': 'pass' },
    },
  ];
  const calls = [];
  let graphReads = 0;
  const runner = async (command, args, options = {}) => {
    calls.push({ command, args, cwd: options.cwd, options });
    if (command === 'git') return { code: 0, stdout: '', stderr: '' };
    if (command === 'bd' && args[0] === 'create') {
      return { code: 0, stdout: JSON.stringify({ id: 'gt-lease' }), stderr: '' };
    }
    if (command === 'bd' && args[0] === 'close') {
      return { code: 0, stdout: JSON.stringify({ id: 'gt-lease' }), stderr: '' };
    }
    if (command === 'bd' && args[0] === 'list') {
      return { code: 0, stdout: JSON.stringify(beadDetails), stderr: '' };
    }
    if (command === 'gc' && args[0] === 'status') {
      return {
        code: 0,
        stdout: JSON.stringify({ running: false, rigs: [{ name: 'glasstunnel', suspended: true }] }),
        stderr: '',
      };
    }
    if (command === 'gc' && args[0] === 'agent' && args[1] === 'list') {
      return {
        code: 0,
        stdout: JSON.stringify({
          agents: [
            {
              name: 'glasstunnel.canary-worker',
              qualified_name: 'glasstunnel/glasstunnel.canary-worker',
            },
          ],
        }),
        stderr: '',
      };
    }
    if (command === 'gc' && args[0] === 'sling') {
      return {
        code: 0,
        stdout: JSON.stringify({ success: true, workflow_id: 'gt-root' }),
        stderr: '',
      };
    }
    if (command === 'gc' && args[0] === 'graph') {
      graphReads += 1;
      const closed = graphReads > 1;
      return {
        code: 0,
        stdout: JSON.stringify({
          nodes: graphNodes.map((node, index) =>
            !closed && index === graphNodes.length - 1 ? { ...node, status: 'open' } : node,
          ),
          summary: { total: graphNodes.length, closed: closed ? graphNodes.length : 4 },
        }),
        stderr: '',
      };
    }
    return { code: 0, stdout: '{}', stderr: '' };
  };

  try {
    const evidence = await runCanary({
      paths,
      runner,
      sleep: async () => {},
      pollIntervalMs: 1,
      timeoutMs: 1_000,
    });

    assert.equal(evidence.workflowId, 'gt-root');
    assert.equal(evidence.attempts.length, 2);
    assert.equal(evidence.attempts[0].failureClass, 'transient');
    assert.equal(evidence.attempts[1].outcome, 'pass');
    assert.equal(evidence.reviewed, true);
    assert.equal(evidence.integrationReady, true);
    assert.deepEqual(await listLeases(paths), []);
    assert.ok(
      calls.some(
        (call) =>
          call.command === 'bd' &&
          call.args.join(' ') ===
            'list --all --metadata-field gc.root_bead_id=gt-root --limit 0 --json',
      ),
      'canary evidence must be queried by workflow root metadata',
    );
    assert.ok(calls.some((call) => call.command === 'gc' && call.args[0] === 'start'));
    assert.ok(calls.some((call) => call.command === 'gc' && call.args.join(' ') === 'rig resume glasstunnel --json'));
    assert.ok(calls.some((call) => call.command === 'gc' && call.args.join(' ') === 'rig suspend glasstunnel --json'));
    assert.ok(calls.some((call) => call.command === 'gc' && call.args[0] === 'stop'));
    assert.ok(
      calls.findIndex((call) => call.command === 'bd' && call.args[0] === 'close') <
        calls.findIndex((call) => call.command === 'gc' && call.args[0] === 'stop'),
      'the lease audit must close before managed Dolt stops',
    );
    assert.ok(
      calls
        .filter((call) => call.command === 'bd')
        .every((call) => call.options.env.BD_ROUTING_MODE === 'off'),
      'every direct Beads call must disable contributor routing',
    );

    const flattened = calls.map((call) => `${call.command} ${call.args.join(' ')}`).join('\n');
    for (const forbidden of [
      'git push',
      'gh workflow',
      'gh run',
      'codesign',
      'notarytool',
      'wrangler deploy',
    ]) {
      assert.equal(flattened.includes(forbidden), false, forbidden);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('canary rejects an active city before acquiring a lease', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-canary-active-'));
  const repoRoot = join(root, 'source');
  const paths = resolveFactoryPaths({
    repoRoot,
    env: { GT_FACTORY_HOME: join(root, 'state') },
  });
  await mkdir(repoRoot, { recursive: true });
  await mkdir(join(paths.rigs, 'glasstunnel'), { recursive: true });
  await mkdir(paths.leases, { recursive: true });
  const calls = [];
  const runner = async (command, args) => {
    calls.push({ command, args });
    if (command === 'gc' && args[0] === 'status') {
      return {
        code: 0,
        stdout: JSON.stringify({
          running: true,
          rigs: [{ name: 'glasstunnel', suspended: true }],
        }),
        stderr: '',
      };
    }
    return { code: 0, stdout: '', stderr: '' };
  };

  try {
    await assert.rejects(() => runCanary({ paths, runner }), /requires the city to be stopped/i);
    assert.equal(calls.some((call) => call.command === 'bd' && call.args[0] === 'create'), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
