#!/usr/bin/env node
import { runDoctor } from './doctor.mjs';
import { bootstrapFactory, getFactoryStatus, stopFactory } from './bootstrap.mjs';
import { verifyBackupRestore } from './backup.mjs';
import { runCanary } from './canary.mjs';
import { factoryEnvironment, resolveFactoryPaths } from './config.mjs';
import { createWorkerWorktree, removeWorkerWorktree } from './branch-guard.mjs';
import {
  acquireLease,
  heartbeatLease,
  listLeases,
  recoverExpiredLease,
  releaseLease,
} from './lease.mjs';
import { clearBlockerNotification, notifyBlocker } from './notify.mjs';
import { runProcess } from './process.mjs';
import { formatError } from './error-format.mjs';

async function findRepoRoot() {
  const result = await runProcess('git', ['rev-parse', '--show-toplevel']);
  if (result.code !== 0) throw new Error('Run this command from the Glasstunnel repository');
  return result.stdout.trim();
}

function usage() {
  console.error(`Usage:
  pnpm factory:doctor
  pnpm factory:bootstrap
  pnpm factory:status
  pnpm factory:down
  pnpm factory:canary
  pnpm factory:backup-verify
  pnpm factory:notify -- <send|clear> [options]
  pnpm factory:lease -- <acquire|heartbeat|release|status|recover> [options]
  pnpm factory:worktree -- <create|remove> [options]`);
}

function optionsFrom(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const entry = args[index];
    if (!entry.startsWith('--')) throw new Error(`Unexpected argument: ${entry}`);
    const key = entry.slice(2);
    if (['expired-only', 'human-approved', 'dry-run'].includes(key)) {
      options[key] = true;
      continue;
    }
    const value = args[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${entry}`);
    options[key] = value;
    index += 1;
  }
  return options;
}

function required(options, name) {
  if (!options[name]) throw new Error(`Missing --${name}`);
  return options[name];
}

async function runLease(action, args, paths, env) {
  const options = optionsFrom(args);
  if (action === 'status') {
    console.log(JSON.stringify(await listLeases(paths), null, 2));
    return;
  }
  const resource = required(options, 'resource');
  if (action === 'acquire') {
    const lease = await acquireLease({
      resource,
      nodeId: required(options, 'node'),
      holder: required(options, 'holder'),
      ttlSeconds: options.ttl ? Number(options.ttl) : undefined,
      paths,
      env,
    });
    console.log(JSON.stringify(lease, null, 2));
    return;
  }
  if (action === 'heartbeat') {
    console.log(
      JSON.stringify(
        await heartbeatLease({ resource, nodeId: required(options, 'node'), paths }),
        null,
        2,
      ),
    );
    return;
  }
  if (action === 'release') {
    await releaseLease({ resource, nodeId: required(options, 'node'), paths, env });
    console.log(`Released ${resource}`);
    return;
  }
  if (action === 'recover') {
    if (!options['expired-only']) throw new Error('Lease recovery requires --expired-only');
    const result = await recoverExpiredLease({
      resource,
      paths,
      humanApproved: options['human-approved'] === true,
      env,
    });
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  throw new Error(`Unknown lease action: ${action}`);
}

async function runWorktree(action, args, paths) {
  const options = optionsFrom(args);
  if (action === 'create') {
    const result = await createWorkerWorktree({
      nodeId: required(options, 'node'),
      baseRef: options.base,
      recordedHead: options['recorded-head'],
      paths,
    });
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  if (action === 'remove') {
    await removeWorkerWorktree({
      nodeId: required(options, 'node'),
      nodeStatus: required(options, 'status'),
      paths,
    });
    console.log(`Removed worktree for ${options.node}`);
    return;
  }
  throw new Error(`Unknown worktree action: ${action}`);
}

async function runNotify(action, args, paths) {
  const options = optionsFrom(args);
  const nodeId = required(options, 'node');
  if (action === 'clear') {
    console.log(JSON.stringify(await clearBlockerNotification({ nodeId, paths }), null, 2));
    return;
  }
  if (action === 'send') {
    const result = await notifyBlocker({
      nodeId,
      blocker: required(options, 'blocker'),
      requestedAction: required(options, 'action'),
      diagnostic: options.diagnostic,
      safety: required(options, 'safety'),
      resume: required(options, 'resume'),
      paths,
      dryRun: options['dry-run'] === true || process.env.GT_TELEGRAM_DRY_RUN === '1',
    });
    console.log(result.message ?? JSON.stringify(result, null, 2));
    return;
  }
  throw new Error(`Unknown notify action: ${action}`);
}

async function main() {
  const command = process.argv[2];
  const commandArgs = process.argv.slice(3);
  if (commandArgs[0] === '--') commandArgs.shift();
  const repoRoot = await findRepoRoot();
  if (command === 'doctor') {
    const report = await runDoctor({ repoRoot });
    for (const entry of report.checks) {
      console.log(`${entry.status === 'pass' ? 'PASS' : 'FAIL'} ${entry.id}: ${entry.detail}`);
    }
    if (!report.ok) process.exitCode = 1;
    return;
  }
  if (command === 'bootstrap') {
    console.log(JSON.stringify(await bootstrapFactory({ repoRoot }), null, 2));
    return;
  }
  if (command === 'status') {
    console.log(JSON.stringify(await getFactoryStatus({ repoRoot }), null, 2));
    return;
  }
  if (command === 'down') {
    console.log(JSON.stringify(await stopFactory({ repoRoot }), null, 2));
    return;
  }
  const paths = resolveFactoryPaths({ repoRoot });
  const processEnv = factoryEnvironment(paths);
  if (command === 'canary') {
    console.log(JSON.stringify(await runCanary({ paths }), null, 2));
    return;
  }
  if (command === 'backup-verify') {
    console.log(JSON.stringify(await verifyBackupRestore({ paths }), null, 2));
    return;
  }
  if (command === 'lease') {
    await runLease(commandArgs[0], commandArgs.slice(1), paths, processEnv);
    return;
  }
  if (command === 'worktree') {
    await runWorktree(commandArgs[0], commandArgs.slice(1), paths);
    return;
  }
  if (command === 'notify') {
    await runNotify(commandArgs[0], commandArgs.slice(1), paths);
    return;
  }
  usage();
  process.exitCode = 2;
}

main().catch((error) => {
  console.error(formatError(error));
  process.exitCode = 1;
});
