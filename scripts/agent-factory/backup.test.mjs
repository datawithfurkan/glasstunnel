import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { verifyBackupRestore } from './backup.mjs';
import { resolveFactoryPaths } from './config.mjs';

test('backup verification uses Dolt-native backup and a disposable external restore', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-backup-'));
  const repoRoot = join(root, 'source');
  const stateRoot = join(root, 'state');
  await mkdir(repoRoot, { recursive: true });
  const paths = resolveFactoryPaths({ repoRoot, env: { GT_FACTORY_HOME: stateRoot } });
  await mkdir(join(paths.rigs, 'glasstunnel'), { recursive: true });

  const issues = [
    { id: 'gt-open', status: 'open', metadata: {} },
    {
      id: 'gt-retry-1',
      status: 'closed',
      metadata: {
        'gc.step_id': 'controlled-retry',
        'gc.attempt': '1',
        'gc.outcome': 'fail',
        'gc.failure_class': 'transient',
      },
    },
    {
      id: 'gt-ready',
      status: 'closed',
      metadata: { integration_ready: 'true', 'gc.outcome': 'pass' },
    },
  ];
  const calls = [];
  const runner = async (command, args, options = {}) => {
    calls.push({ command, args, cwd: options.cwd });
    if (command === 'bd' && args[0] === 'list') {
      return { code: 0, stdout: JSON.stringify(issues), stderr: '' };
    }
    return { code: 0, stdout: '{}', stderr: '' };
  };

  try {
    const evidence = await verifyBackupRestore({
      paths,
      runner,
      now: new Date('2026-08-04T12:34:56.000Z'),
      portAllocator: async () => 43817,
    });

    assert.deepEqual(evidence.source.counts, { open: 1, closed: 2, other: 0, total: 3 });
    assert.deepEqual(evidence.restored, evidence.source);
    assert.equal(evidence.restorePort, 43817);
    assert.equal(existsSync(evidence.restorePath), false);
    assert.ok(evidence.backupPath.startsWith(paths.backups));
    assert.ok(evidence.restorePath.startsWith(paths.artifacts));

    const backupInit = calls.find(
      (call) => call.command === 'bd' && call.args[0] === 'backup' && call.args[1] === 'init',
    );
    assert.ok(backupInit.args[2].startsWith(paths.backups));
    assert.deepEqual(
      calls.find((call) => call.command === 'bd' && call.args[0] === 'init').args,
      ['init', '--server', '--server-host', '127.0.0.1', '--server-port', '43817'],
    );
    assert.ok(
      calls.some(
        (call) =>
          call.command === 'bd' &&
          call.args[0] === 'backup' &&
          call.args[1] === 'restore' &&
          call.args[2] === '--force' &&
          call.args[3].startsWith(paths.backups),
      ),
    );
    assert.ok(calls.some((call) => call.command === 'bd' && call.args.join(' ') === 'dolt stop'));
    assert.equal(calls.some((call) => call.args.includes('export')), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

