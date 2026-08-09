import { createHash } from 'node:crypto';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { normalizeNodeId } from './branch-guard.mjs';
import { runProcess } from './process.mjs';

function normalized(value) {
  return value.trim().replace(/\s+/g, ' ');
}

function fingerprintFor({ nodeId, blocker, requestedAction }) {
  return createHash('sha256')
    .update([nodeId, normalized(blocker), normalized(requestedAction)].join('\n'))
    .digest('hex');
}

function statePath(paths, nodeId) {
  return join(paths.notifications, `${normalizeNodeId(nodeId)}.json`);
}

async function existingState(path) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function secretValues(env) {
  return Object.entries(env)
    .filter(
      ([key, value]) =>
        /(?:TOKEN|SECRET|PASSWORD|PASSCODE|PRIVATE_KEY|CREDENTIAL|AUTH)/i.test(key) &&
        typeof value === 'string' &&
        value.length >= 6,
    )
    .map(([, value]) => value);
}

function assertNoSecretValue(message, env) {
  if (secretValues(env).some((secret) => message.includes(secret))) {
    throw new Error('Blocker notification contains a configured secret value');
  }
}

export function formatBlockerMessage({
  nodeId,
  blocker,
  requestedAction,
  diagnostic = 'Automated diagnostics are exhausted or the remaining step is human-only.',
  safety,
  resume,
}) {
  return [
    `Title: Glasstunnel factory blocker (${nodeId})`,
    `Body: ${normalized(blocker)}`,
    `Diagnostic: ${normalized(diagnostic)}`,
    `Action: ${normalized(requestedAction)}`,
    `Safety: ${normalized(safety)}`,
    `Resume: ${normalized(resume)}`,
  ].join('\n');
}

export async function notifyBlocker({
  nodeId,
  blocker,
  requestedAction,
  diagnostic,
  safety,
  resume,
  paths,
  runner = runProcess,
  env = process.env,
  dryRun = env.GT_TELEGRAM_DRY_RUN === '1',
}) {
  const safeNode = normalizeNodeId(nodeId);
  for (const [name, value] of Object.entries({ blocker, requestedAction, safety, resume })) {
    if (!value?.trim()) throw new Error(`Blocker notification requires ${name}`);
  }
  const message = formatBlockerMessage({
    nodeId: safeNode,
    blocker,
    requestedAction,
    diagnostic,
    safety,
    resume,
  });
  assertNoSecretValue(message, env);
  if (dryRun) return { status: 'dry-run', message };

  await mkdir(paths.notifications, { recursive: true, mode: 0o700 });
  const path = statePath(paths, safeNode);
  const fingerprint = fingerprintFor({ nodeId: safeNode, blocker, requestedAction });
  const previous = await existingState(path);
  if (previous?.status === 'sent' && previous.fingerprint === fingerprint) {
    return { status: 'deduplicated', fingerprint };
  }

  const result = await runner(
    'bash',
    [join(paths.source, 'scripts', 'notify-telegram-blocker.sh')],
    {
      cwd: paths.source,
      env: {
        ...env,
        GT_BLOCKER_TITLE: `Agent factory blocker (${safeNode})`,
        GT_BLOCKER_BODY: normalized(blocker),
        GT_BLOCKER_ACTION: normalized(requestedAction),
        GT_BLOCKER_CONTEXT: [
          `Diagnostic: ${normalized(
            diagnostic ?? 'Automated diagnostics exhausted or human-only step',
          )}`,
          `Safety: ${normalized(safety)}`,
          `Resume: ${normalized(resume)}`,
        ].join(' | '),
        GT_BLOCKER_CWD: 'Glasstunnel agent factory',
        GT_BLOCKER_DEDUPE_KEY: fingerprint,
      },
      timeoutMs: 30_000,
    },
  );
  if (result.code !== 0) {
    throw new Error(
      `Telegram blocker notification failed: ${result.stderr.trim() || 'unknown error'}`,
    );
  }

  const state = {
    fingerprint,
    nodeId: safeNode,
    timestamp: new Date().toISOString(),
    status: 'sent',
  };
  await writeFile(path, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  return { status: 'sent', fingerprint };
}

export async function clearBlockerNotification({ nodeId, paths }) {
  await rm(statePath(paths, nodeId), { force: true });
  return { status: 'cleared', nodeId: normalizeNodeId(nodeId) };
}
