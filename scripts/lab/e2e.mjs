#!/usr/bin/env node

import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import { ensureRuntimeDirectories, labConfig } from './config.mjs';
import { resetLab, startCoreLab, stopLab } from './services.mjs';
import { defaultRunCommand } from './commands.mjs';
import { deleteLabUser, upsertLabUser } from './convex.mjs';

const PASSWORD_RESET_PROJECT = 'local-password-reset-mobile-chromium';
// The reset journey started from a Mac (`?linkCode=`): the reset account claims
// the Swift host's one link code. It runs alone: the account journey claims
// that same code for the lab user, and a second reset journey in the same run
// would hit the reset account's 2-minute email throttle.
const PASSWORD_RESET_MAC_PROJECT = 'local-password-reset-mac-mobile-chromium';
const PASSWORD_RESET_PROJECTS = [PASSWORD_RESET_PROJECT, PASSWORD_RESET_MAC_PROJECT];
// Renames and then removes the lab Mac from the lab account, which unlinks the
// Swift host; no other journey in the same run could use that Mac afterwards.
export const DEVICE_MANAGEMENT_PROJECT = 'local-device-management-mobile-chromium';
// Journeys that claim or consume the lab host on their own, so each runs alone.
const SOLO_PROJECTS = new Map([
  [
    PASSWORD_RESET_MAC_PROJECT,
    'node scripts/lab/e2e.mjs password-reset-mac): it claims the host\'s only link code with the reset account.',
  ],
  [
    DEVICE_MANAGEMENT_PROJECT,
    'node scripts/lab/e2e.mjs device-management): it removes the lab Mac from the account.',
  ],
]);
const CHROMIUM_PROJECTS = [
  'fixture-desktop-chromium',
  'fixture-mobile-chromium',
  'local-account-mobile-chromium',
  PASSWORD_RESET_PROJECT,
];
// Local account projects that need the backend and a fresh database but no
// linked Mac, so running them alone skips building the Swift host.
const HOSTLESS_ACCOUNT_PROJECTS = new Set([PASSWORD_RESET_PROJECT]);
// Disposable account for the password reset journey; removed after every run.
export const PASSWORD_RESET_EMAIL = 'reset-journey@glasstunnel.test';
const WEBKIT_PROJECTS = ['fixture-mobile-webkit'];
const SCREEN_CHROMIUM_PROJECTS = ['local-screen-mobile-chromium'];
const SCREEN_WEBKIT_PROJECTS = ['local-screen-mobile-webkit'];
const CODEX_CLI_CHROMIUM_PROJECTS = ['local-codex-cli-mobile-chromium'];
const CURSOR_AGENT_CHROMIUM_PROJECTS = ['local-cursor-agent-mobile-chromium'];
const CURSOR_AGENT_WEBKIT_PROJECTS = ['local-cursor-agent-mobile-webkit'];
const CURSOR_DESKTOP_CHROMIUM_PROJECTS = ['local-cursor-desktop-mobile-chromium'];
const CURSOR_DESKTOP_WEBKIT_PROJECTS = ['local-cursor-desktop-mobile-webkit'];
const CLAUDE_CODE_CHROMIUM_PROJECTS = ['local-claude-code-mobile-chromium'];
const CLAUDE_DESKTOP_CHROMIUM_PROJECTS = ['local-claude-desktop-mobile-chromium'];
const CLAUDE_CODE_WEBKIT_PROJECTS = ['local-claude-code-mobile-webkit'];
const CLAUDE_DESKTOP_WEBKIT_PROJECTS = ['local-claude-desktop-mobile-webkit'];
const CODEX_DESKTOP_CHROMIUM_PROJECTS = ['local-codex-desktop-mobile-chromium'];
const CODEX_DESKTOP_WEBKIT_PROJECTS = ['local-codex-desktop-mobile-webkit'];
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
  if (!failure) {
    // A cleanup step failing after a passing run still says which step it was.
    current.message = `${label}: ${current.message}`;
    return current;
  }
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
  fetchImpl = fetch,
  newPassword = () => `Lab-Reset-${randomBytes(12).toString('base64url')}`,
} = {}) {
  for (const [project, reason] of SOLO_PROJECTS) {
    if (projects.includes(project) && projects.length > 1) {
      throw new Error(`${project} runs alone (${reason}`);
    }
  }
  const sensitiveValues = [config.identity.email, config.identity.password];
  let baselineSessions = [];
  let baselinePtyProcesses = [];
  let result;
  let failure = null;
  // Extra lab accounts created for this run; each is deleted afterwards.
  const disposableAccounts = [];
  let retentionIdentity;
  let resetIdentity;

  try {
    baselineSessions = await listTerminalSessions();
    baselinePtyProcesses = await listPtyProcesses();
    const usesLocalAccounts = projects.some((project) => project.startsWith('local-'));
    const requiresAccountHost = projects.some(
      (project) => project.startsWith('local-') && !HOSTLESS_ACCOUNT_PROJECTS.has(project),
    );
    if (usesLocalAccounts) await reset({ config });
    const lab = await start({ config, host: requiresAccountHost });
    if (requiresAccountHost && (!lab.host?.linkCode || !lab.host?.label)) {
      throw new Error('The local host did not publish link metadata.');
    }
    if (lab.host?.linkCode) sensitiveValues.push(lab.host.linkCode);
    if (projects.includes('local-retention-mobile-chromium')) {
      const email = 'retention-secondary@glasstunnel.test';
      sensitiveValues.push(email);
      const user = await upsertLabUser({ config, email, password: config.identity.password, fetchImpl });
      if (!user.userId) throw new Error('The local backend did not return the secondary retention account id.');
      retentionIdentity = { email, id: user.userId };
      disposableAccounts.push({ label: 'retention', id: user.userId });
    }
    if (PASSWORD_RESET_PROJECTS.some((project) => projects.includes(project))) {
      const email = PASSWORD_RESET_EMAIL;
      // The journey replaces the lab password with this one; it is generated
      // per run and redacted from the saved Playwright log like the others.
      const replacement = newPassword();
      sensitiveValues.push(email, replacement);
      const user = await upsertLabUser({
        config,
        email,
        password: config.identity.password,
        name: 'Glasstunnel Reset Journey',
        fetchImpl,
      });
      if (!user.userId) throw new Error('The local backend did not return the password reset account id.');
      resetIdentity = { email, id: user.userId, newPassword: replacement };
      disposableAccounts.push({ label: 'password reset', id: user.userId });
    }

    const env = {
      ...process.env,
      GT_LAB_BASE_URL: config.urls.pwa,
      ...(retentionIdentity ? { GT_LAB_SECOND_EMAIL: retentionIdentity.email } : {}),
      ...(usesLocalAccounts
        ? {
            GT_LAB_EMAIL: config.identity.email,
            GT_LAB_PASSWORD: config.identity.password,
          }
        : {}),
      ...(requiresAccountHost
        ? {
            GT_LAB_LINK_CODE: lab.host.linkCode,
            GT_LAB_HOST_LABEL: lab.host.label,
            GT_LAB_REVOCATION_CONTROL: join(config.paths.state, 'revoke-device.json'),
          }
        : {}),
      ...(resetIdentity
        ? {
            // The reset account starts with GT_LAB_PASSWORD. GT_LAB_ROOT lets the
            // spec read the local email outbox through the lab's admin CLI.
            GT_LAB_RESET_EMAIL: resetIdentity.email,
            GT_LAB_RESET_NEW_PASSWORD: resetIdentity.newPassword,
            GT_LAB_ROOT: config.root,
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

  for (const account of disposableAccounts) {
    try {
      await deleteLabUser(config, account.id, { runCommand: execute });
    } catch (error) {
      failure = appendFailure(failure, error, `Local ${account.label} account cleanup failed`);
    }
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
  if (mode === 'retention') return ['local-retention-mobile-chromium'];
  if (mode === 'revocation') return ['local-revocation-mobile-chromium'];
  if (mode === 'device-management') return [DEVICE_MANAGEMENT_PROJECT];
  if (mode === 'password-reset') return [PASSWORD_RESET_PROJECT];
  if (mode === 'password-reset-mac') return [PASSWORD_RESET_MAC_PROJECT];
  if (mode === 'codex-cli-chromium') return CODEX_CLI_CHROMIUM_PROJECTS;
  if (mode === 'cursor-agent-chromium') return CURSOR_AGENT_CHROMIUM_PROJECTS;
  if (mode === 'cursor-agent-webkit' || mode === 'cursor-agent-safari') return CURSOR_AGENT_WEBKIT_PROJECTS;
  if (mode === 'cursor-desktop-chromium') return CURSOR_DESKTOP_CHROMIUM_PROJECTS;
  if (mode === 'cursor-desktop-webkit' || mode === 'cursor-desktop-safari') return CURSOR_DESKTOP_WEBKIT_PROJECTS;
  if (mode === 'claude-code-chromium') return CLAUDE_CODE_CHROMIUM_PROJECTS;
  if (mode === 'claude-desktop-chromium') return CLAUDE_DESKTOP_CHROMIUM_PROJECTS;
  if (mode === 'claude-code-webkit' || mode === 'claude-code-safari') return CLAUDE_CODE_WEBKIT_PROJECTS;
  if (mode === 'claude-desktop-webkit' || mode === 'claude-desktop-safari') return CLAUDE_DESKTOP_WEBKIT_PROJECTS;
  if (mode === 'codex-desktop-chromium') return CODEX_DESKTOP_CHROMIUM_PROJECTS;
  if (mode === 'codex-desktop-webkit' || mode === 'codex-desktop-safari') return CODEX_DESKTOP_WEBKIT_PROJECTS;
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
