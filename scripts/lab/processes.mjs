import { execFileSync, spawn } from 'node:child_process';
import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

import { ensureRuntimeDirectories } from './config.mjs';

const WRAPPER_PATH = fileURLToPath(new URL('./managed-service.mjs', import.meta.url));
const POLL_INTERVAL_MS = 50;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function safeName(value) {
  return String(value).replace(/[^a-zA-Z0-9._-]+/g, '-');
}

function processCommand(pid) {
  try {
    return execFileSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return '';
  }
}

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export function readManifest(config) {
  if (!existsSync(config.files.manifest)) return null;
  return JSON.parse(readFileSync(config.files.manifest, 'utf8'));
}

export function writeManifest(config, manifest) {
  ensureRuntimeDirectories(config);
  const temporaryPath = `${config.files.manifest}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o600,
  });
  renameSync(temporaryPath, config.files.manifest);
  return manifest;
}

export async function managedProcessStatus(service) {
  const alive = processIsAlive(service.pid);
  const commandLine = alive ? processCommand(service.pid) : '';
  const owned =
    alive &&
    commandLine.includes(WRAPPER_PATH) &&
    commandLine.includes(`--run-id ${service.runId}`);

  return {
    alive,
    owned,
    commandLine,
  };
}

export async function spawnManagedService(
  config,
  { name, runId, command, args = [], env = {}, cwd = config.root },
) {
  if (!name || !runId || !command) {
    throw new Error('Managed services require name, runId, and command.');
  }

  ensureRuntimeDirectories(config);
  const logPath = join(config.paths.logs, `${safeName(name)}-${safeName(runId)}.log`);
  const logFd = openSync(logPath, 'a', 0o600);
  const child = spawn(
    process.execPath,
    [WRAPPER_PATH, '--run-id', runId, '--', command, ...args],
    {
      cwd,
      detached: true,
      env: { ...process.env, ...env },
      stdio: ['ignore', logFd, logFd],
    },
  );
  closeSync(logFd);
  child.unref();

  const service = {
    name,
    pid: child.pid,
    runId,
    startedAt: new Date().toISOString(),
    command: [command, ...args],
    logPath,
    managed: true,
  };

  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const status = await managedProcessStatus(service);
    if (status.owned) return service;
    if (!status.alive) {
      throw new Error(`${name} exited before the lab could verify ownership.`);
    }
    await sleep(POLL_INTERVAL_MS);
  }

  throw new Error(`Timed out while verifying ownership of ${name}.`);
}

export async function stopManagedService(service, { timeoutMs = 5_000 } = {}) {
  const initial = await managedProcessStatus(service);
  if (!initial.alive) return { ...service, stopped: false, alreadyStopped: true };
  if (!initial.owned) {
    throw new Error(`Refusing to stop ${service.name}: process ownership mismatch.`);
  }

  try {
    process.kill(-service.pid, 'SIGTERM');
  } catch (error) {
    if (error.code === 'ESRCH') return { ...service, stopped: true };
    throw error;
  }

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!(await managedProcessStatus(service)).alive) {
      return { ...service, stopped: true };
    }
    await sleep(POLL_INTERVAL_MS);
  }

  const finalStatus = await managedProcessStatus(service);
  if (!finalStatus.alive) return { ...service, stopped: true };
  if (!finalStatus.owned) {
    throw new Error(`Refusing to force-stop ${service.name}: process ownership mismatch.`);
  }

  process.kill(-service.pid, 'SIGKILL');
  while ((await managedProcessStatus(service)).alive) {
    await sleep(POLL_INTERVAL_MS);
  }
  return { ...service, stopped: true, forced: true };
}

export async function stopManifestServices(config) {
  const manifest = readManifest(config);
  if (!manifest) return [];

  const results = [];
  for (const service of [...manifest.services].reverse()) {
    results.push(await stopManagedService(service));
  }

  rmSync(config.files.manifest, { force: true });
  return results;
}

export function managedServiceWrapperPath() {
  return WRAPPER_PATH;
}
