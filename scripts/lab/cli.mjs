#!/usr/bin/env node

import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { redact } from './config.mjs';
import {
  labStatus,
  launchSignedMacApp,
  resetLab,
  runDoctor,
  startCoreLab,
  stopLab,
} from './services.mjs';

const HELP = 'Commands: doctor, up, up-host, status, reset --yes, down, mac';

const defaultDependencies = {
  doctor: runDoctor,
  up: startCoreLab,
  status: labStatus,
  reset: resetLab,
  down: stopLab,
  mac: launchSignedMacApp,
};

export async function runCli(
  args,
  {
    dependencies = defaultDependencies,
    stdout = (value) => console.log(value),
    isTTY = Boolean(process.stdin.isTTY),
  } = {},
) {
  const [command = 'status', ...flags] = args;
  let result;

  switch (command) {
    case 'doctor':
      result = await dependencies.doctor();
      break;
    case 'up':
      result = await dependencies.up({ host: false });
      break;
    case 'up-host':
      result = await dependencies.up({ host: true });
      break;
    case 'status':
      result = await dependencies.status();
      break;
    case 'reset':
      if (!isTTY && !flags.includes('--yes')) {
        throw new Error('Non-interactive reset requires --yes.');
      }
      result = await dependencies.reset();
      break;
    case 'down':
      result = await dependencies.down();
      break;
    case 'mac':
      result = await dependencies.mac();
      break;
    default:
      throw new Error(`Unknown lab command: ${command}. ${HELP}`);
  }

  stdout(JSON.stringify(redact(result), null, 2));
  return result;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  runCli(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
