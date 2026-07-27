#!/usr/bin/env node

import { execFile } from 'node:child_process';
import { readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import { resetLab, startCoreLab, stopLab } from './services.mjs';
import { defaultRunCommand } from './supabase.mjs';

const CHROMIUM_PROJECTS = [
  'fixture-desktop-chromium',
  'fixture-mobile-chromium',
  'local-account-mobile-chromium',
];
const WEBKIT_PROJECTS = ['fixture-mobile-webkit'];
const SCREEN_CHROMIUM_PROJECTS = ['local-screen-mobile-chromium'];
const SCREEN_WEBKIT_PROJECTS = ['local-screen-mobile-webkit'];
const CODEX_CLI_CHROMIUM_PROJECTS = ['local-codex-cli-mobile-chromium'];
const execFileAsync = promisify(execFile);
const DEFAULT_PTY_PROCESS_REGISTRY = join(
  homedir(),
  'Library',
  'Application Support',
  'Glasstunnel',
  'pty-processes',
);

export function parseTerminalScreenSessions(output) {
  const sessions = [];
  for (const line of String(output).split(/\r?\n/)) {
    const match = /^\s*((\d+)\.([^\s(]+))\s+\(([^)]+)\)/.exec(line);
    if (!match) continue;
    sessions.push({ id: match[1], name: match[3], state: match[4] });
  }
  return sessions;
}

function isManagedTerminalSessionName(name) {
  return (
    name === 'glasstunnel-terminal' ||
    /^glasstunnel-terminal-\d{10,}(?:-[A-Fa-f0-9]{4,12})?$/.test(name)
  );
}

export function newManagedTerminalSessions(before, after) {
  const existing = new Set(before.map((session) => session.id));
  return after.filter(
    (session) => !existing.has(session.id) && isManagedTerminalSessionName(session.name),
  );
}

export async function listTerminalScreenSessions() {
  try {
    const { stdout } = await execFileAsync('/usr/bin/screen', ['-ls'], { encoding: 'utf8' });
    return parseTerminalScreenSessions(stdout);
  } catch (error) {
    const output = `${error.stdout ?? ''}\n${error.stderr ?? ''}`;
    if (/No Sockets found|No screen session found/i.test(output)) return [];
    if (output.trim()) return parseTerminalScreenSessions(output);
    throw error;
  }
}

export async function cleanupTerminalScreenSessions(sessions) {
  for (const session of sessions) {
    await execFileAsync('/usr/bin/screen', ['-S', session.id, '-X', 'quit'], {
      encoding: 'utf8',
    });
  }
}

export function listPtyProcessRecords(directory = DEFAULT_PTY_PROCESS_REGISTRY) {
  let files;
  try {
    files = readdirSync(directory, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }

  return files.flatMap((file) => {
    if (!file.isFile() || !file.name.endsWith('.json')) return [];
    const path = join(directory, file.name);
    try {
      const record = JSON.parse(readFileSync(path, 'utf8'));
      if (!Number.isInteger(record.childPid) || record.childPid <= 0) return [];
      return [{ ...record, id: file.name, path }];
    } catch {
      return [];
    }
  });
}

export function newPtyProcessRecords(before, after) {
  const existing = new Set(before.map((record) => record.id));
  return after.filter((record) => !existing.has(record.id));
}

function defaultProcessIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === 'ESRCH') return false;
    if (error.code === 'EPERM') return true;
    throw error;
  }
}

function defaultSignalProcessGroup(pid, signal) {
  try {
    process.kill(-pid, signal);
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
    try {
      process.kill(pid, signal);
    } catch (fallbackError) {
      if (fallbackError.code !== 'ESRCH') throw fallbackError;
    }
  }
}

export async function cleanupPtyProcessRecords(
  records,
  {
    processIsAlive = defaultProcessIsAlive,
    signalProcessGroup = defaultSignalProcessGroup,
    removeRecord = (path) => unlinkSync(path),
    settle = defaultSettle,
  } = {},
) {
  for (const record of records) {
    if (record.preserveOnOwnerExit) continue;

    if (processIsAlive(record.childPid)) {
      signalProcessGroup(record.childPid, 'SIGTERM');
      for (let attempt = 0; attempt < 10 && processIsAlive(record.childPid); attempt += 1) {
        await settle(100);
      }
    }

    if (processIsAlive(record.childPid)) {
      signalProcessGroup(record.childPid, 'SIGKILL');
      for (let attempt = 0; attempt < 10 && processIsAlive(record.childPid); attempt += 1) {
        await settle(100);
      }
    }

    if (processIsAlive(record.childPid)) {
      throw new Error(`PTY process ${record.childPid} remained alive after cleanup.`);
    }

    try {
      removeRecord(record.path);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

function appendFailure(failure, error, label) {
  const current = error instanceof Error ? error : new Error(String(error));
  if (!failure) return current;
  failure.message = `${failure.message}\n${label}: ${current.message}`;
  return failure;
}

function defaultSettle(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function runE2E({
  config = ensureRuntimeDirectories(labConfig()),
  projects = CHROMIUM_PROJECTS,
  reset = (options) => resetLab(options),
  start = (options) => startCoreLab(options),
  execute = defaultRunCommand,
  stop = (options) => stopLab(options),
  listTerminalSessions = listTerminalScreenSessions,
  cleanupTerminalSessions = cleanupTerminalScreenSessions,
  listPtyProcesses = listPtyProcessRecords,
  cleanupPtyProcesses = cleanupPtyProcessRecords,
  settle = defaultSettle,
} = {}) {
  const sensitiveValues = [config.identity.email, config.identity.password];
  let baselineSessions = [];
  let baselinePtyProcesses = [];
  let result;
  let failure = null;

  try {
    baselineSessions = await listTerminalSessions();
    baselinePtyProcesses = await listPtyProcesses();
    const requiresAccountHost = projects.some((project) => project.startsWith('local-'));
    if (requiresAccountHost) await reset({ config });
    const lab = await start({ config, host: requiresAccountHost });
    if (requiresAccountHost && (!lab.host?.linkCode || !lab.host?.label)) {
      throw new Error('The local host did not publish link metadata.');
    }
    if (lab.host?.linkCode) sensitiveValues.push(lab.host.linkCode);

    const env = {
      ...process.env,
      GT_LAB_BASE_URL: config.urls.pwa,
      ...(requiresAccountHost
        ? {
            GT_LAB_EMAIL: config.identity.email,
            GT_LAB_PASSWORD: config.identity.password,
            GT_LAB_LINK_CODE: lab.host.linkCode,
            GT_LAB_HOST_LABEL: lab.host.label,
          }
        : {}),
    };
    const args = [
      'exec',
      'playwright',
      'test',
      ...projects.map((project) => `--project=${project}`),
    ];
    result = await execute('pnpm', args, { cwd: config.root, env });
  } catch (error) {
    const commandOutput = [error.stdout, error.stderr].filter(Boolean).join('\n');
    let logPath = null;
    if (commandOutput) {
      const redactedOutput = sensitiveValues.reduce(
        (output, value) => output.replaceAll(value, '<redacted>'),
        commandOutput,
      );
      logPath = `${config.paths.logs}/playwright-last-command.log`;
      writeFileSync(logPath, redactedOutput, { encoding: 'utf8', mode: 0o600 });
    }
    const normalized = error instanceof Error ? error : new Error(String(error));
    normalized.message = [
      normalized.message,
      `Playwright artifacts: ${config.paths.playwright}`,
      logPath ? `Playwright command log: ${logPath}` : null,
    ]
      .filter(Boolean)
      .join('\n');
    failure = normalized;
  }

  try {
    await stop({ config });
  } catch (error) {
    failure = appendFailure(failure, error, 'Lab teardown failed');
  }

  try {
    await settle(1_500);
    let consecutiveCleanChecks = 0;
    for (let attempt = 0; attempt < 6 && consecutiveCleanChecks < 2; attempt += 1) {
      await settle(300);
      const remainingSessions = await listTerminalSessions();
      const createdSessions = newManagedTerminalSessions(baselineSessions, remainingSessions);
      if (createdSessions.length > 0) {
        consecutiveCleanChecks = 0;
        await cleanupTerminalSessions(createdSessions);
      } else {
        consecutiveCleanChecks += 1;
      }
    }
    if (consecutiveCleanChecks < 2) {
      throw new Error('New Glasstunnel Terminal sessions did not settle after cleanup.');
    }
  } catch (error) {
    failure = appendFailure(failure, error, 'Terminal session cleanup failed');
  }

  try {
    let consecutiveCleanChecks = 0;
    for (let attempt = 0; attempt < 6 && consecutiveCleanChecks < 2; attempt += 1) {
      await settle(300);
      const remainingProcesses = await listPtyProcesses();
      const createdProcesses = newPtyProcessRecords(baselinePtyProcesses, remainingProcesses);
      if (createdProcesses.length > 0) {
        consecutiveCleanChecks = 0;
        await cleanupPtyProcesses(createdProcesses);
      } else {
        consecutiveCleanChecks += 1;
      }
    }
    if (consecutiveCleanChecks < 2) {
      throw new Error('New Glasstunnel PTY processes did not settle after cleanup.');
    }
  } catch (error) {
    failure = appendFailure(failure, error, 'PTY process cleanup failed');
  }

  if (failure) throw failure;
  return result;
}

export function projectsForMode(mode) {
  if (mode === 'codex-cli-chromium') return CODEX_CLI_CHROMIUM_PROJECTS;
  if (mode === 'screen-chromium') return SCREEN_CHROMIUM_PROJECTS;
  if (mode === 'screen-webkit' || mode === 'screen-safari') return SCREEN_WEBKIT_PROJECTS;
  if (mode === 'webkit' || mode === 'safari') return WEBKIT_PROJECTS;
  if (mode === 'all') return [...CHROMIUM_PROJECTS, ...WEBKIT_PROJECTS];
  return CHROMIUM_PROJECTS;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const projects = projectsForMode(process.argv[2]);
  runE2E({ projects })
    .then(() => console.log(`Local Playwright passed: ${projects.join(', ')}`))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
}
