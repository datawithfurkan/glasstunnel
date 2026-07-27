import assert from 'node:assert/strict';
import test from 'node:test';

import { runCli } from './cli.mjs';

function dependencies(calls) {
  return {
    doctor: async () => calls.push('doctor'),
    up: async (options) => calls.push(['up', options]),
    status: async () => calls.push('status'),
    reset: async () => calls.push('reset'),
    down: async () => calls.push('down'),
    mac: async () => calls.push('mac'),
  };
}

test('runCli routes every public lab command', async () => {
  const calls = [];
  const deps = dependencies(calls);

  await runCli(['doctor'], { dependencies: deps, stdout: () => {} });
  await runCli(['up'], { dependencies: deps, stdout: () => {} });
  await runCli(['up-host'], { dependencies: deps, stdout: () => {} });
  await runCli(['status'], { dependencies: deps, stdout: () => {} });
  await runCli(['reset', '--yes'], { dependencies: deps, stdout: () => {}, isTTY: false });
  await runCli(['down'], { dependencies: deps, stdout: () => {} });
  await runCli(['mac'], { dependencies: deps, stdout: () => {} });

  assert.deepEqual(calls, [
    'doctor',
    ['up', { host: false }],
    ['up', { host: true }],
    'status',
    'reset',
    'down',
    'mac',
  ]);
});

test('runCli requires --yes for a non-interactive reset', async () => {
  await assert.rejects(
    runCli(['reset'], {
      dependencies: dependencies([]),
      stdout: () => {},
      isTTY: false,
    }),
    /--yes/,
  );
});

test('runCli rejects unknown commands with concise help', async () => {
  await assert.rejects(
    runCli(['explode'], { dependencies: dependencies([]), stdout: () => {} }),
    /doctor.*up.*status.*reset.*down/s,
  );
});
