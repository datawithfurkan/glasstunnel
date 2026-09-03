import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import {
  cleanupPtyProcessRecords,
  newManagedTerminalSessions,
  newPtyProcessRecords,
  parseTerminalScreenSessions,
  projectsForMode,
  runE2E,
} from './e2e.mjs';

const noPtyProcesses = {
  listPtyProcesses: async () => [],
  cleanupPtyProcesses: async () => {},
};

function fixtureConfig(t) {
  const root = mkdtempSync(join(tmpdir(), 'glasstunnel-e2e-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return ensureRuntimeDirectories(labConfig(root));
}

test('projectsForMode isolates the opt-in Codex CLI account journey', () => {
  assert.deepEqual(projectsForMode('codex-cli-chromium'), ['local-codex-cli-mobile-chromium']);
});

test('projectsForMode isolates the opt-in Cursor Agent account journey', () => {
  assert.deepEqual(projectsForMode('cursor-agent-chromium'), ['local-cursor-agent-mobile-chromium']);
  assert.deepEqual(projectsForMode('cursor-agent-webkit'), ['local-cursor-agent-mobile-webkit']);
  assert.deepEqual(projectsForMode('cursor-agent-safari'), ['local-cursor-agent-mobile-webkit']);
});

test('projectsForMode isolates the opt-in Cursor desktop account journey', () => {
  assert.deepEqual(projectsForMode('cursor-desktop-chromium'), ['local-cursor-desktop-mobile-chromium']);
  assert.deepEqual(projectsForMode('cursor-desktop-webkit'), ['local-cursor-desktop-mobile-webkit']);
  assert.deepEqual(projectsForMode('cursor-desktop-safari'), ['local-cursor-desktop-mobile-webkit']);
});

test('projectsForMode isolates the opt-in Claude account journeys', () => {
  assert.deepEqual(projectsForMode('claude-code-chromium'), ['local-claude-code-mobile-chromium']);
  assert.deepEqual(projectsForMode('claude-desktop-chromium'), [
    'local-claude-desktop-mobile-chromium',
  ]);
});

test('projectsForMode offers mobile WebKit variants of the Claude account journeys', () => {
  assert.deepEqual(projectsForMode('claude-code-webkit'), ['local-claude-code-mobile-webkit']);
  assert.deepEqual(projectsForMode('claude-code-safari'), ['local-claude-code-mobile-webkit']);
  assert.deepEqual(projectsForMode('claude-desktop-webkit'), ['local-claude-desktop-mobile-webkit']);
  assert.deepEqual(projectsForMode('claude-desktop-safari'), ['local-claude-desktop-mobile-webkit']);
});

test('runE2E passes only local account and host values to Playwright', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];

  await runE2E({
    config,
    projects: ['fixture-desktop-chromium', 'local-account-chromium'],
    reset: async () => calls.push('reset'),
    start: async () => ({
      host: { linkCode: 'ABC234', label: 'Local test host' },
    }),
    execute: async (command, args, options) => {
      calls.push({ command, args, options });
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    listTerminalSessions: async () => [],
    cleanupTerminalSessions: async () => {},
    ...noPtyProcesses,
    settle: async () => {},
    stop: async () => calls.push('stop'),
  });

  assert.equal(calls[0], 'reset');
  assert.equal(calls.at(-1), 'stop');
  const execution = calls[1];
  assert.equal(execution.command, 'pnpm');
  assert.deepEqual(execution.args, [
    'exec',
    'playwright',
    'test',
    '--project=fixture-desktop-chromium',
    '--project=local-account-chromium',
  ]);
  assert.deepEqual(execution.options.env, {
    ...process.env,
    GT_LAB_BASE_URL: 'http://127.0.0.1:5173',
    GT_LAB_EMAIL: 'lab@glasstunnel.test',
    GT_LAB_PASSWORD: 'Glasstunnel-Lab-Only-2026',
    GT_LAB_LINK_CODE: 'ABC234',
    GT_LAB_HOST_LABEL: 'Local test host',
  });
});

test('runE2E always stops services after Playwright fails', async (t) => {
  const config = fixtureConfig(t);
  let stopped = false;

  await assert.rejects(
    runE2E({
      config,
      reset: async () => {},
      start: async () => ({ host: { linkCode: 'ABC234', label: 'Local test host' } }),
      execute: async () => {
        throw new Error('browser failed');
      },
      listTerminalSessions: async () => [],
      cleanupTerminalSessions: async () => {},
      ...noPtyProcesses,
      settle: async () => {},
      stop: async () => {
        stopped = true;
      },
    }),
    /browser failed/,
  );

  assert.equal(stopped, true);
});

test('runE2E rejects a lab start without link metadata', async (t) => {
  const config = fixtureConfig(t);
  await assert.rejects(
    runE2E({
      config,
      reset: async () => {},
      start: async () => ({ host: null }),
      execute: async () => {},
      listTerminalSessions: async () => [],
      cleanupTerminalSessions: async () => {},
      ...noPtyProcesses,
      settle: async () => {},
      stop: async () => {},
    }),
    /link metadata/i,
  );
});

test('runE2E skips database reset and Swift host for fixture-only projects', async (t) => {
  const config = fixtureConfig(t);
  let resetCalled = false;
  let startOptions = null;

  await runE2E({
    config,
    projects: ['fixture-mobile-webkit'],
    reset: async () => {
      resetCalled = true;
    },
    start: async (options) => {
      startOptions = options;
      return { host: null };
    },
    execute: async () => ({ stdout: '', stderr: '', exitCode: 0 }),
    stop: async () => {},
    listTerminalSessions: async () => [],
    cleanupTerminalSessions: async () => {},
    ...noPtyProcesses,
    settle: async () => {},
  });

  assert.equal(resetCalled, false);
  assert.equal(startOptions.host, false);
});

test('newPtyProcessRecords returns only records absent from the baseline', () => {
  const before = [{ id: '100.json', childPid: 100 }];
  const after = [
    { id: '100.json', childPid: 100 },
    { id: '200.json', childPid: 200 },
  ];

  assert.deepEqual(newPtyProcessRecords(before, after), [{ id: '200.json', childPid: 200 }]);
});

test('cleanupPtyProcessRecords terminates and removes only supplied records', async () => {
  const signals = [];
  const removed = [];
  let alive = true;
  const record = {
    id: '200.json',
    path: '/tmp/200.json',
    childPid: 200,
    preserveOnOwnerExit: false,
  };

  await cleanupPtyProcessRecords([record], {
    processIsAlive: () => alive,
    signalProcessGroup: (pid, signal) => {
      signals.push([pid, signal]);
      alive = false;
    },
    removeRecord: (path) => removed.push(path),
    settle: async () => {},
  });

  assert.deepEqual(signals, [[200, 'SIGTERM']]);
  assert.deepEqual(removed, ['/tmp/200.json']);
});

test('newManagedTerminalSessions returns only lab-created sessions absent from baseline', () => {
  const before = parseTerminalScreenSessions(`
    70712.glasstunnel-terminal (Detached)
    70793.glasstunnel-terminal-same (Detached)
  `);
  const after = parseTerminalScreenSessions(`
    70712.glasstunnel-terminal (Detached)
    70793.glasstunnel-terminal-same (Detached)
    96078.glasstunnel-terminal-1784710493126-30C2A2F2 (Attached)
    96079.unrelated-session (Detached)
  `);

  assert.deepEqual(newManagedTerminalSessions(before, after), [
    {
      id: '96078.glasstunnel-terminal-1784710493126-30C2A2F2',
      name: 'glasstunnel-terminal-1784710493126-30C2A2F2',
      state: 'Attached',
    },
  ]);
});

test('runE2E cleans a managed Terminal session that appears just after teardown', async (t) => {
  const config = fixtureConfig(t);
  const generated = {
    id: '96078.glasstunnel-terminal-1784710493126-30C2A2F2',
    name: 'glasstunnel-terminal-1784710493126-30C2A2F2',
    state: 'Attached',
  };
  const snapshots = [[], [], [generated], [], []];
  const cleaned = [];
  const settleDelays = [];

  await runE2E({
    config,
    reset: async () => {},
    start: async () => ({ host: { linkCode: 'ABC234', label: 'Local test host' } }),
    execute: async () => ({ stdout: '', stderr: '', exitCode: 0 }),
    stop: async () => {},
    listTerminalSessions: async () => snapshots.shift() ?? [],
    cleanupTerminalSessions: async (sessions) => cleaned.push(...sessions),
    ...noPtyProcesses,
    settle: async (delay) => settleDelays.push(delay),
  });

  assert.deepEqual(cleaned, [generated]);
  assert.equal(snapshots.length, 0);
  assert.equal(settleDelays[0], 1_500);
});

test('runE2E cleans only a PTY process record created during the run', async (t) => {
  const config = fixtureConfig(t);
  const existing = { id: '100.json', childPid: 100 };
  const generated = { id: '200.json', childPid: 200 };
  const snapshots = [[existing], [existing, generated], [existing], [existing]];
  const cleaned = [];

  await runE2E({
    config,
    reset: async () => {},
    start: async () => ({ host: { linkCode: 'ABC234', label: 'Local test host' } }),
    execute: async () => ({ stdout: '', stderr: '', exitCode: 0 }),
    stop: async () => {},
    listTerminalSessions: async () => [],
    cleanupTerminalSessions: async () => {},
    listPtyProcesses: async () => snapshots.shift() ?? [existing],
    cleanupPtyProcesses: async (records) => cleaned.push(...records),
    settle: async () => {},
  });

  assert.deepEqual(cleaned, [generated]);
  assert.equal(snapshots.length, 0);
});
