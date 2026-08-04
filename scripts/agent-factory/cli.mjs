#!/usr/bin/env node
import { runDoctor } from './doctor.mjs';
import { runProcess } from './process.mjs';

async function findRepoRoot() {
  const result = await runProcess('git', ['rev-parse', '--show-toplevel']);
  if (result.code !== 0) throw new Error('Run this command from the Glasstunnel repository');
  return result.stdout.trim();
}

function usage() {
  console.error('Usage: pnpm factory:<doctor|bootstrap|status|down|canary|backup-verify>');
}

async function main() {
  const command = process.argv[2];
  if (command !== 'doctor') {
    usage();
    process.exitCode = 2;
    return;
  }

  const report = await runDoctor({ repoRoot: await findRepoRoot() });
  for (const entry of report.checks) {
    console.log(`${entry.status === 'pass' ? 'PASS' : 'FAIL'} ${entry.id}: ${entry.detail}`);
  }
  if (!report.ok) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
