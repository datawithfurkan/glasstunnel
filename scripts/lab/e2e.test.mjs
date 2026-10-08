import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import {
  cleanupPtyProcessRecords,
  DEVICE_MANAGEMENT_PROJECT,
  newManagedTerminalSessions,
  newPtyProcessRecords,
  PASSWORD_RESET_EMAIL,
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

const quietCleanup = {
  listTerminalSessions: async () => [],
  cleanupTerminalSessions: async () => {},
  ...noPtyProcesses,
  settle: async () => {},
};

// Unit tests never reach a real lab backend, even when one is running locally.
const offlineFetch = async (url) => assert.fail(`unexpected network request to ${url}`);

function signUpFetch(requests, userId) {
  return async (url, init) => {
    requests.push({ path: new URL(url).pathname, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ token: 'reset-token', user: { id: userId } }), {
      status: 200,
      headers: { 'content-type': 'application/json', 'set-auth-token': 'reset-token' },
    });
  };
}

test('projectsForMode runs the password reset journey alone or in the default Chromium lab', () => {
  assert.deepEqual(projectsForMode('password-reset'), ['local-password-reset-mobile-chromium']);
  assert.ok(projectsForMode('chromium').includes('local-password-reset-mobile-chromium'));
  assert.ok(projectsForMode('chromium').includes('local-account-mobile-chromium'));
  assert.ok(projectsForMode('all').includes('local-password-reset-mobile-chromium'));
  assert.ok(!projectsForMode('webkit').includes('local-password-reset-mobile-chromium'));
});

test('projectsForMode keeps the Mac-start password reset journey out of shared runs', () => {
  assert.deepEqual(projectsForMode('password-reset-mac'), ['local-password-reset-mac-mobile-chromium']);
  for (const mode of ['chromium', 'all', 'password-reset', 'webkit']) {
    assert.ok(!projectsForMode(mode).includes('local-password-reset-mac-mobile-chromium'), mode);
  }
});

test('projectsForMode runs the device-management journey alone and never in shared runs', () => {
  assert.equal(DEVICE_MANAGEMENT_PROJECT, 'local-device-management-mobile-chromium');
  assert.deepEqual(projectsForMode('device-management'), ['local-device-management-mobile-chromium']);
  for (const mode of ['chromium', 'all', 'webkit', 'revocation', 'password-reset', undefined]) {
    assert.ok(!projectsForMode(mode).includes(DEVICE_MANAGEMENT_PROJECT), String(mode));
  }
});

test('runE2E gives the device-management journey the lab account and the linked lab Mac', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];

  await runE2E({
    config,
    projects: projectsForMode('device-management'),
    fetchImpl: offlineFetch,
    reset: async () => calls.push('reset'),
    start: async (options) => {
      calls.push({ start: options.host });
      return { host: { linkCode: 'ABC234', label: 'Local test host' } };
    },
    execute: async (command, args, options) => {
      calls.push({ command, args, options });
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    stop: async () => calls.push('stop'),
    ...quietCleanup,
  });

  // A fresh database and a Swift host with a fresh link code, then teardown.
  assert.equal(calls[0], 'reset');
  assert.deepEqual(calls[1], { start: true });
  assert.equal(calls.at(-1), 'stop');
  const playwright = calls[2];
  assert.deepEqual(playwright.args, ['exec', 'playwright', 'test', '--project=local-device-management-mobile-chromium']);
  assert.equal(playwright.options.env.GT_LAB_EMAIL, 'lab@glasstunnel.test');
  assert.equal(playwright.options.env.GT_LAB_LINK_CODE, 'ABC234');
  assert.equal(playwright.options.env.GT_LAB_HOST_LABEL, 'Local test host');
});

test('runE2E refuses to run the device-management journey with others, since it removes the lab Mac', async (t) => {
  const config = fixtureConfig(t);
  let touched = false;
  const untouched = async () => {
    touched = true;
  };

  for (const other of ['local-account-mobile-chromium', 'fixture-mobile-chromium']) {
    await assert.rejects(
      runE2E({
        config,
        projects: [other, DEVICE_MANAGEMENT_PROJECT],
        reset: untouched,
        start: untouched,
        execute: untouched,
        stop: untouched,
        fetchImpl: offlineFetch,
        ...quietCleanup,
      }),
      /local-device-management-mobile-chromium runs alone \(node scripts\/lab\/e2e\.mjs device-management\)/,
    );
  }
  assert.equal(touched, false);
});

test('runE2E gives the Mac-start password reset journey the reset account and a fresh host link code', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];
  const requests = [];
  let startOptions = null;

  await runE2E({
    config,
    projects: ['local-password-reset-mac-mobile-chromium'],
    reset: async () => calls.push('reset'),
    start: async (options) => {
      startOptions = options;
      calls.push('start');
      return { host: { linkCode: 'ABC234', label: 'Local test host' } };
    },
    execute: async (command, args, options) => {
      calls.push({ command, args, env: options.env });
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    stop: async () => calls.push('stop'),
    fetchImpl: signUpFetch(requests, 'reset-user'),
    newPassword: () => 'Lab-Reset-generated-password',
    ...quietCleanup,
  });

  assert.equal(startOptions.host, true);
  assert.deepEqual(
    requests.map((request) => request.body.email),
    ['reset-journey@glasstunnel.test'],
  );
  const [resetStep, startStep, playwright, cleanup, stopStep] = calls;
  assert.equal(resetStep, 'reset');
  assert.equal(startStep, 'start');
  assert.equal(stopStep, 'stop');
  assert.deepEqual(playwright.args, [
    'exec',
    'playwright',
    'test',
    '--project=local-password-reset-mac-mobile-chromium',
  ]);
  assert.equal(playwright.env.GT_LAB_RESET_EMAIL, 'reset-journey@glasstunnel.test');
  assert.equal(playwright.env.GT_LAB_RESET_NEW_PASSWORD, 'Lab-Reset-generated-password');
  assert.equal(playwright.env.GT_LAB_PASSWORD, 'Glasstunnel-Lab-Only-2026');
  assert.equal(playwright.env.GT_LAB_LINK_CODE, 'ABC234');
  assert.equal(playwright.env.GT_LAB_HOST_LABEL, 'Local test host');
  assert.equal(playwright.env.GT_LAB_ROOT, config.root);
  assert.deepEqual(cleanup.args.slice(0, 3), [
    'run',
    'auth:deleteUserByLegacyId',
    '{"legacyUserId":"reset-user"}',
  ]);
});

test('runE2E refuses to share the host link code between the Mac-start reset and other projects', async (t) => {
  const config = fixtureConfig(t);
  let touched = false;
  const untouched = async () => {
    touched = true;
  };

  for (const other of ['local-account-mobile-chromium', 'local-password-reset-mobile-chromium']) {
    await assert.rejects(
      runE2E({
        config,
        projects: [other, 'local-password-reset-mac-mobile-chromium'],
        reset: untouched,
        start: untouched,
        execute: untouched,
        stop: untouched,
        fetchImpl: offlineFetch,
        ...quietCleanup,
      }),
      /local-password-reset-mac-mobile-chromium runs alone/,
    );
  }
  assert.equal(touched, false);
});

test('runE2E creates the password reset account, passes it to Playwright, and deletes it without a Mac host', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];
  const requests = [];
  let startOptions = null;

  await runE2E({
    config,
    projects: ['local-password-reset-mobile-chromium'],
    reset: async () => calls.push('reset'),
    start: async (options) => {
      startOptions = options;
      calls.push('start');
      return { host: null };
    },
    execute: async (command, args, options) => {
      calls.push({ command, args, env: options.env });
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    stop: async () => calls.push('stop'),
    fetchImpl: signUpFetch(requests, 'reset-user'),
    newPassword: () => 'Lab-Reset-generated-password',
    ...quietCleanup,
  });

  assert.equal(PASSWORD_RESET_EMAIL, 'reset-journey@glasstunnel.test');
  assert.equal(startOptions.host, false);
  assert.deepEqual(requests, [
    {
      path: '/api/auth/sign-up/email',
      body: {
        email: 'reset-journey@glasstunnel.test',
        password: 'Glasstunnel-Lab-Only-2026',
        name: 'Glasstunnel Reset Journey',
      },
    },
  ]);

  const [resetStep, startStep, playwright, cleanup, stopStep] = calls;
  assert.equal(resetStep, 'reset');
  assert.equal(startStep, 'start');
  assert.equal(stopStep, 'stop');
  assert.equal(calls.length, 5);
  assert.equal(playwright.command, 'pnpm');
  assert.deepEqual(playwright.args, [
    'exec',
    'playwright',
    'test',
    '--project=local-password-reset-mobile-chromium',
  ]);
  assert.equal(playwright.env.GT_LAB_RESET_EMAIL, 'reset-journey@glasstunnel.test');
  assert.equal(playwright.env.GT_LAB_RESET_NEW_PASSWORD, 'Lab-Reset-generated-password');
  assert.equal(playwright.env.GT_LAB_ROOT, config.root);
  assert.equal(playwright.env.GT_LAB_EMAIL, 'lab@glasstunnel.test');
  assert.equal(playwright.env.GT_LAB_PASSWORD, 'Glasstunnel-Lab-Only-2026');
  assert.equal(playwright.env.GT_LAB_BASE_URL, 'http://127.0.0.1:5173');
  assert.equal('GT_LAB_LINK_CODE' in playwright.env, false);
  assert.equal('GT_LAB_HOST_LABEL' in playwright.env, false);
  assert.equal('GT_LAB_SECOND_EMAIL' in playwright.env, false);

  // The account is deleted through the local admin CLI before teardown.
  assert.equal(cleanup.command, join(config.root, 'node_modules/.bin/convex'));
  assert.deepEqual(cleanup.args, [
    'run',
    'auth:deleteUserByLegacyId',
    '{"legacyUserId":"reset-user"}',
    '--env-file',
    config.files.convexEnv,
  ]);
});

test('runE2E generates a fresh replacement password for each password reset run', async (t) => {
  const config = fixtureConfig(t);
  const passwords = [];
  for (let run = 0; run < 2; run += 1) {
    await runE2E({
      config,
      projects: ['local-password-reset-mobile-chromium'],
      reset: async () => {},
      start: async () => ({ host: null }),
      execute: async (command, _args, options) => {
        if (command === 'pnpm') passwords.push(options.env.GT_LAB_RESET_NEW_PASSWORD);
        return { stdout: '', stderr: '', exitCode: 0 };
      },
      stop: async () => {},
      fetchImpl: signUpFetch([], 'reset-user'),
      ...quietCleanup,
    });
  }
  assert.equal(passwords.length, 2);
  for (const password of passwords) {
    assert.match(password, /^Lab-Reset-[A-Za-z0-9_-]{16}$/);
    assert.notEqual(password, config.identity.password);
  }
  assert.notEqual(passwords[0], passwords[1]);
});

test('runE2E deletes the password reset account and redacts it when Playwright fails', async (t) => {
  const config = fixtureConfig(t);
  const steps = [];

  await assert.rejects(
    runE2E({
      config,
      projects: ['local-password-reset-mobile-chromium'],
      reset: async () => {},
      start: async () => ({ host: null }),
      execute: async (command, args, options) => {
        if (command !== 'pnpm') {
          steps.push(args[1]);
          return { stdout: '', stderr: '', exitCode: 0 };
        }
        steps.push('playwright');
        const error = new Error('password reset journey failed');
        error.stdout = [
          `signed in as ${options.env.GT_LAB_RESET_EMAIL}`,
          `new password ${options.env.GT_LAB_RESET_NEW_PASSWORD}`,
          `old password ${options.env.GT_LAB_PASSWORD}`,
        ].join('\n');
        throw error;
      },
      stop: async () => steps.push('stop'),
      fetchImpl: signUpFetch([], 'reset-user'),
      newPassword: () => 'Lab-Reset-generated-password',
      ...quietCleanup,
    }),
    /password reset journey failed/,
  );

  assert.deepEqual(steps, ['playwright', 'auth:deleteUserByLegacyId', 'stop']);
  const log = readFileSync(join(config.paths.logs, 'playwright-last-command.log'), 'utf8');
  assert.doesNotMatch(log, /reset-journey@glasstunnel\.test/);
  assert.doesNotMatch(log, /Lab-Reset-generated-password/);
  assert.doesNotMatch(log, /Glasstunnel-Lab-Only-2026/);
  assert.match(log, /new password <redacted>/);
});

test('runE2E reports a failed password reset account cleanup after a passing run', async (t) => {
  const config = fixtureConfig(t);
  let stopped = false;

  await assert.rejects(
    runE2E({
      config,
      projects: ['local-password-reset-mobile-chromium'],
      reset: async () => {},
      start: async () => ({ host: null }),
      execute: async (command) => {
        if (command !== 'pnpm') throw new Error('convex run failed');
        return { stdout: '', stderr: '', exitCode: 0 };
      },
      stop: async () => {
        stopped = true;
      },
      fetchImpl: signUpFetch([], 'reset-user'),
      ...quietCleanup,
    }),
    /Local password reset account cleanup failed: convex run failed/,
  );
  assert.equal(stopped, true);
});

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
  assert.deepEqual(projectsForMode('codex-desktop-chromium'), ['local-codex-desktop-mobile-chromium']);
  assert.deepEqual(projectsForMode('codex-desktop-webkit'), ['local-codex-desktop-mobile-webkit']);
  assert.deepEqual(projectsForMode('codex-desktop-safari'), ['local-codex-desktop-mobile-webkit']);
});

test('runE2E passes only local account and host values to Playwright', async (t) => {
  const config = fixtureConfig(t);
  const calls = [];

  await runE2E({
    config,
    fetchImpl: offlineFetch,
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
    GT_LAB_REVOCATION_CONTROL: join(config.paths.state, 'revoke-device.json'),
  });
});

test('runE2E always stops services after Playwright fails', async (t) => {
  const config = fixtureConfig(t);
  let stopped = false;

  await assert.rejects(
    runE2E({
      config,
      fetchImpl: signUpFetch([], 'reset-user'),
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
      fetchImpl: signUpFetch([], 'reset-user'),
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
    fetchImpl: offlineFetch,
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
    fetchImpl: signUpFetch([], 'reset-user'),
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
    fetchImpl: signUpFetch([], 'reset-user'),
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
