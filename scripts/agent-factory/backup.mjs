import { createServer } from 'node:net';
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { factoryEnvironment, isPathInside } from './config.mjs';
import { runProcess } from './process.mjs';

async function checked(runner, command, args, options, label) {
  const result = await runner(command, args, options);
  if (result.code !== 0) {
    const detail = result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
    throw new Error(`${label}: ${detail}`);
  }
  return result;
}

function parseArray(stdout, label) {
  try {
    const value = JSON.parse(stdout);
    if (Array.isArray(value)) return value;
    if (Array.isArray(value?.issues)) return value.issues;
    if (Array.isArray(value?.data)) return value.data;
  } catch {
    // The error below includes the operation name without echoing ledger content.
  }
  throw new Error(`${label} did not return a JSON array`);
}

function parseObject(stdout, label) {
  try {
    const value = JSON.parse(stdout);
    if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  } catch {
    // The error below avoids echoing process output.
  }
  throw new Error(`${label} did not return a JSON object`);
}

function relevantCanaryMetadata(metadata = {}) {
  const selected = {};
  for (const key of [
    'gc.step_id',
    'gc.attempt',
    'gc.outcome',
    'gc.failure_class',
    'canary_reviewed',
    'integration_ready',
  ]) {
    if (metadata[key] !== undefined) selected[key] = String(metadata[key]);
  }
  return selected;
}

export function summarizeLedger(issues) {
  const counts = { open: 0, closed: 0, other: 0, total: issues.length };
  const canary = [];
  for (const issue of issues) {
    if (issue.status === 'open') counts.open += 1;
    else if (issue.status === 'closed') counts.closed += 1;
    else counts.other += 1;

    const metadata = relevantCanaryMetadata(issue.metadata);
    if (Object.keys(metadata).length > 0) {
      canary.push({ id: issue.id, status: issue.status, metadata });
    }
  }
  canary.sort((left, right) => left.id.localeCompare(right.id));
  return { counts, canary };
}

export async function allocateLoopbackPort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port = typeof address === 'object' && address ? address.port : null;
      server.close((error) => {
        if (error) reject(error);
        else if (!port) reject(new Error('Could not allocate a disposable Dolt port'));
        else resolve(port);
      });
    });
  });
}

export async function verifyBackupRestore({
  paths,
  env = process.env,
  runner = runProcess,
  now = new Date(),
  portAllocator = allocateLoopbackPort,
} = {}) {
  const timestamp = now.toISOString().replace(/[:.]/g, '-');
  const backupPath = join(paths.backups, `ledger-${timestamp}`);
  const restorePath = join(paths.artifacts, `backup-restore-${timestamp}`);
  const sourcePath = join(paths.rigs, 'glasstunnel');
  if (!isPathInside(paths.root, backupPath) || !isPathInside(paths.root, restorePath)) {
    throw new Error('Backup and restore paths must remain inside the external factory root');
  }

  await mkdir(paths.backups, { recursive: true, mode: 0o700 });
  await mkdir(paths.artifacts, { recursive: true, mode: 0o700 });
  await mkdir(restorePath, { recursive: false, mode: 0o700 });

  const processEnv = factoryEnvironment(paths, env);
  const cityOptions = { cwd: paths.city, env: processEnv, timeoutMs: 120_000 };
  const sourceOptions = { cwd: sourcePath, env: processEnv, timeoutMs: 120_000 };
  const restorePort = await portAllocator();
  const restoreOptions = { cwd: restorePath, env: processEnv, timeoutMs: 120_000 };
  let managedDoltStarted = false;
  let restoreInitialized = false;
  let evidence;
  let operationError;
  const listArgs = [
    'list',
    '--all',
    '--include-gates',
    '--include-infra',
    '--include-templates',
    '--limit',
    '0',
    '--flat',
    '--json',
  ];

  try {
    const cityStatus = parseObject(
      (
        await checked(
          runner,
          'gc',
          ['status', paths.city, '--json'],
          cityOptions,
          'checking dormant factory state',
        )
      ).stdout,
      'factory city status',
    );
    const rig = (cityStatus.rigs ?? []).find((entry) => entry.name === 'glasstunnel');
    if (cityStatus.running !== false || rig?.suspended !== true) {
      throw new Error('Backup verification requires a stopped city and suspended rig');
    }
    const sourceStatus = parseObject(
      (
        await checked(
          runner,
          'bd',
          ['dolt', 'status', '--json'],
          sourceOptions,
          'checking source Dolt server',
        )
      ).stdout,
      'source Dolt status',
    );
    if (sourceStatus.running !== true) {
      await checked(
        runner,
        'gc',
        ['import', 'install'],
        cityOptions,
        'starting the city-managed Dolt provider',
      );
      managedDoltStarted = true;
      const startedStatus = parseObject(
        (
          await checked(
            runner,
            'bd',
            ['dolt', 'status', '--json'],
            sourceOptions,
            'verifying the city-managed Dolt provider',
          )
        ).stdout,
        'started source Dolt status',
      );
      if (startedStatus.running !== true) {
        throw new Error('City-managed Dolt provider did not become reachable');
      }
    }
    await checked(
      runner,
      'bd',
      ['backup', 'init', backupPath],
      sourceOptions,
      'initializing Dolt-native backup',
    );
    await checked(
      runner,
      'bd',
      ['backup', 'sync'],
      sourceOptions,
      'syncing Dolt-native backup',
    );
    const sourceIssues = parseArray(
      (
        await checked(
          runner,
          'bd',
          listArgs,
          sourceOptions,
          'reading source ledger',
        )
      ).stdout,
      'source ledger',
    );

    await checked(
      runner,
      'bd',
      [
        'init',
        '--server',
        '--server-host',
        '127.0.0.1',
        '--server-port',
        String(restorePort),
      ],
      restoreOptions,
      'initializing disposable restore ledger',
    );
    restoreInitialized = true;
    await checked(
      runner,
      'bd',
      ['backup', 'restore', '--force', backupPath],
      restoreOptions,
      'restoring Dolt-native backup',
    );
    const restoredIssues = parseArray(
      (
        await checked(
          runner,
          'bd',
          listArgs,
          restoreOptions,
          'reading restored ledger',
        )
      ).stdout,
      'restored ledger',
    );
    const source = summarizeLedger(sourceIssues);
    const restored = summarizeLedger(restoredIssues);
    if (JSON.stringify(restored) !== JSON.stringify(source)) {
      throw new Error('Restored ledger counts or canary metadata do not match the source');
    }
    evidence = { backupPath, restorePath, restorePort, source, restored };
  } catch (error) {
    operationError = error;
  }

  const cleanupErrors = [];
  if (restoreInitialized) {
    const stopped = await runner('bd', ['dolt', 'stop'], restoreOptions);
    if (stopped.code !== 0) {
      cleanupErrors.push(
        new Error(
          `stopping disposable Dolt server: ${stopped.stderr.trim() || stopped.stdout.trim()}`,
        ),
      );
    }
  }
  await rm(restorePath, { recursive: true, force: true });
  if (managedDoltStarted) {
    const stopped = await runner(
      'gc',
      ['stop', paths.city, '--timeout', '2m'],
      { ...cityOptions, timeoutMs: 150_000 },
    );
    if (stopped.code !== 0) {
      cleanupErrors.push(
        new Error(
          `stopping city-managed Dolt provider: ${stopped.stderr.trim() || stopped.stdout.trim()}`,
        ),
      );
    }
  }

  if (operationError && cleanupErrors.length > 0) {
    throw new AggregateError([operationError, ...cleanupErrors]);
  }
  if (operationError) throw operationError;
  if (cleanupErrors.length > 0) throw new AggregateError(cleanupErrors);
  return evidence;
}
