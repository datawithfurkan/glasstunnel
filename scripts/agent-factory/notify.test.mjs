import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { clearBlockerNotification, notifyBlocker } from './notify.mjs';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-notify-'));
  return {
    root,
    paths: { source: '/repo/glasstunnel', notifications: join(root, 'notifications') },
  };
}

const blocker = {
  nodeId: 'gt-auth-1',
  blocker: 'OAuth approval is waiting in the browser',
  requestedAction: 'Approve the login and reply in Codex',
  safety: 'No credentials are included in this message',
  resume: 'pnpm factory:canary',
};

test('identical normalized blockers send once and changed action sends again', async () => {
  const { paths } = await fixture();
  const calls = [];
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    return { code: 0, stdout: 'sent\n', stderr: '' };
  };

  const first = await notifyBlocker({ ...blocker, paths, runner, env: {} });
  const duplicate = await notifyBlocker({
    ...blocker,
    blocker: '  OAuth approval is waiting in the browser  ',
    paths,
    runner,
    env: {},
  });
  const changed = await notifyBlocker({
    ...blocker,
    requestedAction: 'Approve the login in the open browser tab',
    paths,
    runner,
    env: {},
  });

  assert.equal(first.status, 'sent');
  assert.equal(duplicate.status, 'deduplicated');
  assert.equal(changed.status, 'sent');
  assert.equal(calls.length, 2);
});

test('clearing a resumed node permits a fresh notification', async () => {
  const { paths } = await fixture();
  let sends = 0;
  const runner = async () => {
    sends += 1;
    return { code: 0, stdout: '', stderr: '' };
  };
  await notifyBlocker({ ...blocker, paths, runner, env: {} });
  await clearBlockerNotification({ nodeId: blocker.nodeId, paths });
  await notifyBlocker({ ...blocker, paths, runner, env: {} });
  assert.equal(sends, 2);
});

test('dry run formats locally without invoking the network script', async () => {
  const { paths } = await fixture();
  const result = await notifyBlocker({
    ...blocker,
    paths,
    dryRun: true,
    runner: async () => {
      throw new Error('runner must not be called');
    },
    env: {},
  });
  assert.equal(result.status, 'dry-run');
  assert.match(result.message, /OAuth approval/);
  assert.match(result.message, /Approve the login/);
});

test('notification state is metadata-only and secret values are rejected', async () => {
  const { paths } = await fixture();
  const runner = async () => ({ code: 0, stdout: '', stderr: '' });
  await notifyBlocker({ ...blocker, paths, runner, env: {} });
  const files = await readdir(paths.notifications);
  const state = await readFile(join(paths.notifications, files[0]), 'utf8');
  assert.doesNotMatch(state, /OAuth|Approve|credentials|factory:canary/);
  const parsed = JSON.parse(state);
  assert.deepEqual(Object.keys(parsed).sort(), ['fingerprint', 'nodeId', 'status', 'timestamp']);

  await assert.rejects(
    () =>
      notifyBlocker({
        ...blocker,
        blocker: 'Use super-secret-token-value to continue',
        paths,
        runner,
        env: { GT_TELEGRAM_BOT_TOKEN: 'super-secret-token-value' },
      }),
    /secret/i,
  );
});
