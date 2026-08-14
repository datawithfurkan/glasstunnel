#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url).pathname.replace(/\/$/, '');
const remote = process.env.GT_PUBLIC_REMOTE_URL || process.argv[2] || 'origin';
const fixturePath = process.env.GT_PUBLIC_REMOTE_REF_AUDIT_FIXTURE;

const forbiddenExactRefs = new Set([
  'refs/dolt/data',
  'refs/heads/__dolt_remote_info__',
]);

const forbiddenRefPatterns = [
  {
    label: 'Dolt ref namespace',
    pattern: /^refs\/dolt(?:\/|$)/u,
  },
  {
    label: 'Dolt metadata branch',
    pattern: /^refs\/heads\/__dolt(?:_|$)/u,
  },
];

function loadLsRemoteOutput() {
  if (fixturePath) return readFileSync(fixturePath, 'utf8');

  return execFileSync('git', ['ls-remote', '--quiet', remote], {
    cwd: root,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function parseRefs(output) {
  return output
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const parts = line.split(/\s+/u);
      return parts[1] ?? '';
    })
    .filter(Boolean);
}

function classifyForbiddenRef(ref) {
  if (forbiddenExactRefs.has(ref)) return 'forbidden exact ref';

  for (const { label, pattern } of forbiddenRefPatterns) {
    if (pattern.test(ref)) return label;
  }

  return null;
}

let refs;
try {
  refs = parseRefs(loadLsRemoteOutput());
} catch (error) {
  const detail = error instanceof Error ? error.message : String(error);
  console.error(`Public remote ref audit could not inspect ${remote}: ${detail}`);
  process.exit(1);
}

const failures = [];
for (const ref of refs) {
  const reason = classifyForbiddenRef(ref);
  if (reason) failures.push({ ref, reason });
}

if (failures.length > 0) {
  console.error('Public remote ref audit failed. Forbidden remote refs are visible:');
  for (const failure of failures) {
    console.error(`- ${failure.reason}: ${failure.ref}`);
  }
  process.exit(1);
}

console.log(`Public remote ref audit passed for ${refs.length} remote refs.`);
