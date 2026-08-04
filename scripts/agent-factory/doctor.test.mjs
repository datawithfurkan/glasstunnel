import assert from 'node:assert/strict';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { runDoctor } from './doctor.mjs';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function fakeRunner(overrides = {}) {
  const versions = {
    gc: 'gc version 1.4.0\n',
    bd: 'bd version 1.1.2\n',
    dolt: 'dolt version 2.1.0\n',
    tmux: 'tmux 3.5\n',
    git: 'git version 2.50.0\n',
    jq: 'jq-1.7\n',
    flock: 'flock from util-linux 2.41.1\n',
    gh: 'gh version 2.76.2\n',
    codex: 'codex-cli 1.0.0\n',
    df: 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk 100 1 50000000 1% /\n',
  };
  return async (command, args = []) => {
    const key = `${command} ${args.join(' ')}`;
    if (overrides[key]) return overrides[key];
    if (command === 'git' && args[0] === 'status') return { code: 0, stdout: '', stderr: '' };
    if (command === 'gh' && args[0] === 'auth') return { code: 0, stdout: '', stderr: '' };
    return { code: 0, stdout: versions[command] ?? '', stderr: '' };
  };
}

test('doctor rejects a factory home inside the source checkout', async () => {
  const report = await runDoctor({
    repoRoot: REPO_ROOT,
    env: { HOME: '/home/test', GT_FACTORY_HOME: join(REPO_ROOT, '.factory-state') },
    runner: fakeRunner(),
  });
  assert.equal(report.ok, false);
  assert.match(report.checks.find((entry) => entry.id === 'external-state').detail, /outside/i);
});

test('doctor reports an incompatible Beads version', async () => {
  const report = await runDoctor({
    repoRoot: REPO_ROOT,
    env: { HOME: '/home/test', GT_FACTORY_HOME: '/state/glasstunnel-factory' },
    runner: fakeRunner({
      'bd version': { code: 0, stdout: 'bd version 0.49.0\n', stderr: '' },
    }),
  });
  assert.equal(report.ok, false);
  assert.equal(report.checks.find((entry) => entry.id === 'bd-version').status, 'fail');
});

test('doctor passes compatible tools, paths, auth, worktree, and disk', async () => {
  const report = await runDoctor({
    repoRoot: REPO_ROOT,
    env: { HOME: '/home/test', GT_FACTORY_HOME: '/state/glasstunnel-factory' },
    runner: fakeRunner(),
  });
  assert.equal(report.ok, true, JSON.stringify(report.checks, null, 2));
});
