import { mkdir, realpath, rm } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { runProcess } from './process.mjs';

function inside(parent, candidate) {
  const rel = relative(resolve(parent), resolve(candidate));
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

export function normalizeNodeId(nodeId) {
  if (!/^[A-Za-z0-9-]+$/.test(nodeId)) {
    throw new Error('Node ID must contain only letters, numbers, and dashes');
  }
  return nodeId;
}

export function assertWorkerCheckout({ repoRoot, cwd, branch, primaryCheckout }) {
  if (['main', 'master', 'HEAD'].includes(branch) || !branch.startsWith('codex/')) {
    throw new Error(`Worker branch must use the codex/ prefix, not ${branch}`);
  }
  if (!inside(repoRoot, cwd)) throw new Error('Worker checkout must be inside its registered rig');
  if (resolve(cwd) === resolve(primaryCheckout))
    throw new Error('Workers may not use the primary checkout');
  return true;
}

async function command(runner, name, args, options) {
  const result = await runner(name, args, options);
  if (result.code !== 0) throw new Error(result.stderr.trim() || `${name} ${args[0]} failed`);
  return result.stdout.trim();
}

export async function createWorkerWorktree({
  nodeId,
  baseRef = 'origin/main',
  paths,
  runner = runProcess,
  recordedHead,
}) {
  normalizeNodeId(nodeId);
  const rig = join(paths.rigs, 'glasstunnel');
  const path = join(paths.worktrees, nodeId);
  const branch = `codex/factory-${nodeId}`;
  if (!inside(paths.worktrees, path)) throw new Error('Worktree path escapes the factory root');

  const state = await runner('git', ['status', '--porcelain'], { cwd: rig });
  if (state.code !== 0 || state.stdout.trim()) throw new Error('External rig mirror must be clean');
  await command(runner, 'git', ['fetch', '--quiet', 'origin', 'main'], {
    cwd: rig,
    timeoutMs: 120_000,
  });
  const baseHead = await command(runner, 'git', ['rev-parse', baseRef], { cwd: rig });
  const existing = await runner('git', ['show-ref', '--verify', '--hash', `refs/heads/${branch}`], {
    cwd: rig,
  });

  if (existing.code === 0) {
    if (!recordedHead || existing.stdout.trim() !== recordedHead) {
      throw new Error(`Existing branch ${branch} does not match recorded Beads metadata`);
    }
    return { path, branch, head: existing.stdout.trim(), reused: true };
  }

  await mkdir(paths.worktrees, { recursive: true, mode: 0o700 });
  await command(runner, 'git', ['worktree', 'add', '-b', branch, path, baseRef], {
    cwd: rig,
    timeoutMs: 120_000,
  });
  return { path, branch, head: baseHead, reused: false };
}

export async function removeWorkerWorktree({ nodeId, paths, runner = runProcess, nodeStatus }) {
  normalizeNodeId(nodeId);
  if (!['accepted', 'cancelled', 'rejected'].includes(nodeStatus)) {
    throw new Error('Worker worktree cleanup requires a terminal node state');
  }
  const rig = join(paths.rigs, 'glasstunnel');
  const path = join(paths.worktrees, nodeId);
  if (!inside(paths.worktrees, path)) throw new Error('Worktree path escapes the factory root');
  const result = await runner('git', ['worktree', 'remove', path], {
    cwd: rig,
    timeoutMs: 120_000,
  });
  if (result.code !== 0)
    throw new Error(result.stderr.trim() || 'Could not remove worker worktree');
  await rm(path, { recursive: true, force: true });
}

export async function canonicalCheckout(path) {
  return realpath(path);
}
