#!/usr/bin/env node
import { runDoctor } from './doctor.mjs';
import { bootstrapFactory, getFactoryStatus, stopFactory } from './bootstrap.mjs';
import { resolveFactoryPaths } from './config.mjs';
import { createWorkerWorktree, removeWorkerWorktree } from './branch-guard.mjs';
import {
  acquireLease,
  heartbeatLease,
  listLeases,
  recoverExpiredLease,
  releaseLease,
} from './lease.mjs';
import { runProcess } from './process.mjs';

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
  pnpm factory:lease -- <acquire|heartbeat|release|status|recover> [options]
  pnpm factory:worktree -- <create|remove> [options]`);
}

function optionsFrom(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const entry = args[index];
    if (!entry.startsWith('--')) throw new Error(`Unexpected argument: ${entry}`);
    const key = entry.slice(2);
    if (['expired-only', 'human-approved'].includes(key)) {
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

async function runLease(action, args, paths) {
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
    await releaseLease({ resource, nodeId: required(options, 'node'), paths });
    console.log(`Released ${resource}`);
    return;
  }
  if (action === 'recover') {
    if (!options['expired-only']) throw new Error('Lease recovery requires --expired-only');
    const result = await recoverExpiredLease({
      resource,
      paths,
      humanApproved: options['human-approved'] === true,
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

async function main() {
  const command = process.argv[2];
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
  if (command === 'lease') {
    await runLease(process.argv[3], process.argv.slice(4), paths);
    return;
  }
  if (command === 'worktree') {
    await runWorktree(process.argv[3], process.argv.slice(4), paths);
    return;
  }
  usage();
  process.exitCode = 2;
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
