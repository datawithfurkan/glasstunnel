import { createServer } from 'node:net';
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { isPathInside } from './config.mjs';
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

  const sourceOptions = { cwd: sourcePath, timeoutMs: 120_000 };
  const restorePort = await portAllocator();
  const restoreOptions = { cwd: restorePath, timeoutMs: 120_000 };
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

  let stopError;
  if (restoreInitialized) {
    const stopped = await runner('bd', ['dolt', 'stop'], restoreOptions);
    if (stopped.code !== 0) {
      stopError = new Error(
        `stopping disposable Dolt server: ${stopped.stderr.trim() || stopped.stdout.trim()}`,
      );
    }
  }
  await rm(restorePath, { recursive: true, force: true });

  if (operationError && stopError) throw new AggregateError([operationError, stopError]);
  if (operationError) throw operationError;
  if (stopError) throw stopError;
  return evidence;
}
