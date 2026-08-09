import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  assertWorkerCheckout,
  createWorkerWorktree,
  normalizeNodeId,
  removeWorkerWorktree,
} from './branch-guard.mjs';

test('worker authority rejects protected, detached, unprefixed, primary, and escaped checkouts', () => {
  const base = {
    repoRoot: '/state/rigs/glasstunnel',
    cwd: '/state/rigs/glasstunnel/worktrees/a',
    primaryCheckout: '/source/glasstunnel',
  };
  for (const branch of ['main', 'master', 'HEAD', 'feature/a']) {
    assert.throws(() => assertWorkerCheckout({ ...base, branch }), /codex/);
  }
  assert.throws(
    () =>
      assertWorkerCheckout({
        ...base,
        branch: 'codex/a',
        cwd: '/source/glasstunnel',
        primaryCheckout: '/source/glasstunnel',
      }),
    /registered rig|primary checkout/,
  );
  assert.throws(
    () => assertWorkerCheckout({ ...base, branch: 'codex/a', cwd: '/tmp/outside' }),
    /registered rig/,
  );
});

test('node IDs cannot traverse paths', () => {
  for (const nodeId of ['../escape', 'a/b', 'a b', '']) {
    assert.throws(() => normalizeNodeId(nodeId), /letters/);
  }
});

test('worktree creation uses origin main and factory-owned paths', async () => {
  const calls = [];
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    if (args[0] === 'status') return { code: 0, stdout: '', stderr: '' };
    if (args[0] === 'rev-parse') return { code: 0, stdout: 'abc123\n', stderr: '' };
    if (args[0] === 'show-ref') return { code: 1, stdout: '', stderr: '' };
    return { code: 0, stdout: '', stderr: '' };
  };
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-worktree-'));
  const paths = { rigs: join(root, 'rigs'), worktrees: join(root, 'worktrees') };
  const result = await createWorkerWorktree({ nodeId: 'gt-42', paths, runner });
  assert.deepEqual(result, {
    path: join(root, 'worktrees', 'gt-42'),
    branch: 'codex/factory-gt-42',
    head: 'abc123',
    reused: false,
  });
  assert.ok(
    calls.some(
      (entry) =>
        entry.args.join(' ') ===
        `worktree add -b codex/factory-gt-42 ${join(root, 'worktrees', 'gt-42')} origin/main`,
    ),
  );
});

test('existing branches require matching recorded metadata', async () => {
  const runner = async (_command, args) => {
    if (args[0] === 'status') return { code: 0, stdout: '', stderr: '' };
    if (args[0] === 'rev-parse') return { code: 0, stdout: 'base123\n', stderr: '' };
    if (args[0] === 'show-ref') return { code: 0, stdout: 'branch123\n', stderr: '' };
    return { code: 0, stdout: '', stderr: '' };
  };
  const paths = { rigs: '/state/rigs', worktrees: '/state/worktrees' };
  await assert.rejects(
    () => createWorkerWorktree({ nodeId: 'gt-42', paths, runner }),
    /recorded Beads metadata/,
  );
  const result = await createWorkerWorktree({
    nodeId: 'gt-42',
    paths,
    runner,
    recordedHead: 'branch123',
  });
  assert.equal(result.reused, true);
});

test('worktree cleanup requires a terminal node state and never forces removal', async () => {
  const calls = [];
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    return { code: 0, stdout: '', stderr: '' };
  };
  const paths = { rigs: '/state/rigs', worktrees: '/state/worktrees' };
  await assert.rejects(
    () => removeWorkerWorktree({ nodeId: 'gt-42', paths, runner, nodeStatus: 'implementing' }),
    /terminal/,
  );
  await removeWorkerWorktree({ nodeId: 'gt-42', paths, runner, nodeStatus: 'cancelled' });
  assert.deepEqual(calls[0].args, ['worktree', 'remove', '/state/worktrees/gt-42']);
  assert.equal(calls[0].args.includes('--force'), false);
});
