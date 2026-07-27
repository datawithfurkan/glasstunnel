#!/usr/bin/env node

import { spawn } from 'node:child_process';

const separator = process.argv.indexOf('--');
const runIdIndex = process.argv.indexOf('--run-id');

if (runIdIndex === -1 || !process.argv[runIdIndex + 1] || separator === -1) {
  console.error('Usage: managed-service.mjs --run-id <id> -- <command> [args...]');
  process.exit(64);
}

const [command, ...args] = process.argv.slice(separator + 1);
if (!command) {
  console.error('A managed service command is required.');
  process.exit(64);
}

const child = spawn(command, args, {
  cwd: process.cwd(),
  env: process.env,
  stdio: 'inherit',
});

let forwardingSignal = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    if (forwardingSignal) return;
    forwardingSignal = true;
    child.kill(signal);
  });
}

child.once('error', (error) => {
  console.error(`Unable to start managed service: ${error.message}`);
  process.exit(127);
});

child.once('exit', (code) => {
  process.exit(code ?? 1);
});
