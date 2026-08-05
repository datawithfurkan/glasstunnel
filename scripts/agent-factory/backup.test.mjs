import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { stopFactoryManagedDoltWatchdog, verifyBackupRestore } from './backup.mjs';
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
  let providerStopped = false;
  let managedDoltRunning = false;
  const runner = async (command, args, options = {}) => {
    calls.push({ command, args, cwd: options.cwd, env: options.env });
    if (command === 'gc' && args[0] === 'status') {
      return {
        code: 0,
        stdout: JSON.stringify({
          running: false,
          rigs: [{ name: 'glasstunnel', suspended: true }],
        }),
        stderr: '',
      };
    }
    if (command === 'gc' && args[0] === 'start') {
      managedDoltRunning = true;
      return { code: 0, stdout: '{}', stderr: '' };
    }
    if (command === 'gc' && args[0] === 'stop') {
      managedDoltRunning = false;
      return { code: 0, stdout: '{}', stderr: '' };
    }
    if (command === 'bd' && args.join(' ') === 'dolt status --json') {
      return {
        code: 0,
        stdout: JSON.stringify({ running: managedDoltRunning }),
        stderr: '',
      };
    }
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
      providerStopper: async () => {
        providerStopped = true;
      },
      providerProbe: async () => false,
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
    assert.equal(providerStopped, true);
    assert.ok(calls.some((call) => call.command === 'bd' && call.args.join(' ') === 'dolt stop'));
    assert.ok(
      calls.some(
        (call) =>
          call.command === 'gc' &&
          call.args.join(' ') === `start ${paths.city}`,
      ),
    );
    assert.ok(
      calls.some(
        (call) =>
          call.command === 'gc' &&
          call.args.join(' ') === `stop ${paths.city} --timeout 2m`,
      ),
    );
    assert.equal(
      calls.some(
        (call) =>
          call.command === 'bd' &&
          call.cwd === join(paths.rigs, 'glasstunnel') &&
          ['dolt start --json', 'dolt stop'].includes(call.args.join(' ')),
      ),
      false,
    );
    assert.ok(
      calls
        .filter((call) => call.command === 'bd')
        .every((call) => call.env.BD_ROUTING_MODE === 'off'),
    );
    assert.equal(calls.some((call) => call.args.includes('export')), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('backup verification preserves a source Dolt server that was already running', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-backup-running-'));
  const repoRoot = join(root, 'source');
  const paths = resolveFactoryPaths({
    repoRoot,
    env: { GT_FACTORY_HOME: join(root, 'state') },
  });
  const sourcePath = join(paths.rigs, 'glasstunnel');
  await mkdir(repoRoot, { recursive: true });
  await mkdir(sourcePath, { recursive: true });
  const calls = [];
  const runner = async (command, args, options = {}) => {
    calls.push({ command, args, cwd: options.cwd });
    if (command === 'gc' && args[0] === 'status') {
      return {
        code: 0,
        stdout: JSON.stringify({
          running: false,
          rigs: [{ name: 'glasstunnel', suspended: true }],
        }),
        stderr: '',
      };
    }
    if (command === 'bd' && args.join(' ') === 'dolt status --json') {
      return { code: 0, stdout: JSON.stringify({ running: true }), stderr: '' };
    }
    if (command === 'bd' && args[0] === 'list') {
      return { code: 0, stdout: '[]', stderr: '' };
    }
    return { code: 0, stdout: '{}', stderr: '' };
  };

  try {
    await verifyBackupRestore({
      paths,
      runner,
      now: new Date('2026-08-04T13:00:00.000Z'),
      portAllocator: async () => 43818,
      providerProbe: async () => true,
    });

    assert.equal(
      calls.some(
        (call) => call.command === 'gc' && call.args[0] === 'start',
      ),
      false,
    );
    assert.equal(
      calls.some((call) => call.command === 'gc' && call.args[0] === 'stop'),
      false,
    );
    assert.ok(
      calls.some(
        (call) => call.cwd !== sourcePath && call.args.join(' ') === 'dolt stop',
      ),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('backup verification fails when managed provider cleanup fails', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-backup-leak-'));
  const repoRoot = join(root, 'source');
  const paths = resolveFactoryPaths({
    repoRoot,
    env: { GT_FACTORY_HOME: join(root, 'state') },
  });
  await mkdir(repoRoot, { recursive: true });
  await mkdir(join(paths.rigs, 'glasstunnel'), { recursive: true });
  let managedDoltRunning = false;
  const runner = async (command, args) => {
    if (command === 'gc' && args[0] === 'status') {
      return {
        code: 0,
        stdout: JSON.stringify({
          running: false,
          rigs: [{ name: 'glasstunnel', suspended: true }],
        }),
        stderr: '',
      };
    }
    if (command === 'gc' && args[0] === 'start') managedDoltRunning = true;
    if (command === 'bd' && args.join(' ') === 'dolt status --json') {
      return {
        code: 0,
        stdout: JSON.stringify({ running: managedDoltRunning }),
        stderr: '',
      };
    }
    if (command === 'bd' && args[0] === 'list') {
      return { code: 0, stdout: '[]', stderr: '' };
    }
    return { code: 0, stdout: '{}', stderr: '' };
  };

  try {
    await assert.rejects(
      verifyBackupRestore({
        paths,
        runner,
        now: new Date('2026-08-04T13:30:00.000Z'),
        portAllocator: async () => 43819,
        providerStopper: async () => {
          throw new Error('managed provider watchdog remained running');
        },
        providerProbe: async () => false,
      }),
      (error) =>
        error instanceof AggregateError &&
        error.errors.some((entry) =>
          entry.message.includes('managed provider watchdog remained running'),
        ),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('managed provider cleanup targets only the verified factory watchdog', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-provider-stop-'));
  const repoRoot = join(root, 'source');
  const paths = resolveFactoryPaths({
    repoRoot,
    env: { GT_FACTORY_HOME: join(root, 'state') },
  });
  const runtime = join(paths.city, '.gc', 'runtime', 'packs', 'dolt');
  const scripts = join(paths.city, '.gc', 'scripts');
  const stateFile = join(runtime, 'dolt-provider-state.json');
  const configFile = join(runtime, 'dolt-config.yaml');
  const logFile = join(runtime, 'dolt.log');
  const bridge = join(scripts, 'gc-beads-bd.sh');
  await mkdir(runtime, { recursive: true });
  await mkdir(scripts, { recursive: true });
  await writeFile(
    stateFile,
    JSON.stringify({ running: true, pid: 321, port: 12048, data_dir: 'private' }),
  );
  await writeFile(bridge, '#!/bin/sh\n');
  const calls = [];
  let watchdogRunning = true;
  let childRunning = true;
  const runner = async (command, args) => {
    calls.push({ command, args });
    if (command === 'ps' && args.includes('ppid=')) {
      return { code: 0, stdout: '654\n', stderr: '' };
    }
    if (command === 'ps' && args.includes('command=')) {
      if (args.at(-1) === '321') {
        return {
          code: 0,
          stdout: `dolt sql-server --config ${configFile}\n`,
          stderr: '',
        };
      }
      return {
        code: 0,
        stdout: `/opt/homebrew/bin/gc __gc-managed-dolt-scope-watchdog ${configFile} ${logFile} ${paths.city}\n`,
        stderr: '',
      };
    }
    if (command === 'kill' && args[0] === '-TERM') {
      watchdogRunning = false;
      childRunning = false;
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'kill' && args[0] === '-0') {
      const running = args[1] === '654' ? watchdogRunning : childRunning;
      return { code: running ? 0 : 1, stdout: '', stderr: '' };
    }
    if (command === bridge) {
      await writeFile(
        stateFile,
        JSON.stringify({ running: false, pid: 0, port: 12048, data_dir: 'private' }),
      );
      return { code: 2, stdout: '', stderr: '' };
    }
    return { code: 0, stdout: '', stderr: '' };
  };

  try {
    const result = await stopFactoryManagedDoltWatchdog({
      paths,
      runner,
      sleep: async () => {},
    });
    assert.equal(result.stopped, true);
    assert.ok(
      calls.some(
        (call) => call.command === 'kill' && call.args.join(' ') === '-TERM 654',
      ),
    );
    assert.equal(JSON.parse(await readFile(stateFile, 'utf8')).running, false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('managed provider cleanup refuses an unrelated parent process', async () => {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-factory-provider-refuse-'));
  const repoRoot = join(root, 'source');
  const paths = resolveFactoryPaths({
    repoRoot,
    env: { GT_FACTORY_HOME: join(root, 'state') },
  });
  const runtime = join(paths.city, '.gc', 'runtime', 'packs', 'dolt');
  await mkdir(runtime, { recursive: true });
  await writeFile(
    join(runtime, 'dolt-provider-state.json'),
    JSON.stringify({ running: true, pid: 321, port: 12048, data_dir: 'private' }),
  );
  const calls = [];
  const runner = async (command, args) => {
    calls.push({ command, args });
    if (command === 'ps' && args.includes('ppid=')) {
      return { code: 0, stdout: '654\n', stderr: '' };
    }
    if (command === 'ps' && args.includes('command=')) {
      return { code: 0, stdout: '/usr/bin/unrelated-service\n', stderr: '' };
    }
    return { code: 0, stdout: '', stderr: '' };
  };

  try {
    await assert.rejects(
      stopFactoryManagedDoltWatchdog({ paths, runner, sleep: async () => {} }),
      /refusing to signal an unverified process/,
    );
    assert.equal(calls.some((call) => call.command === 'kill'), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
