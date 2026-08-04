import { dirname } from 'node:path';
import { loadVersionPolicy, resolveFactoryPaths } from './config.mjs';
import { runProcess } from './process.mjs';

const GIB = 1024 * 1024 * 1024;

function versionFrom(text) {
  return String(text).match(/\bv?(\d+\.\d+\.\d+)\b/)?.[1] ?? null;
}

function compareVersions(left, right) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

function check(id, status, detail) {
  return { id, status, detail };
}

async function commandVersion({ id, command, args, expected, minimum, runner }) {
  const result = await runner(command, args, { timeoutMs: 15_000 });
  if (result.code !== 0) return check(id, 'fail', `${command} is unavailable`);
  const found = versionFrom(`${result.stdout}\n${result.stderr}`);
  if (!expected && !minimum) return check(id, 'pass', found ?? 'available');
  if (!found) return check(id, 'fail', `could not parse ${command} version`);
  if (expected && found !== expected) {
    return check(id, 'fail', `found ${found}; expected ${expected}`);
  }
  if (minimum && compareVersions(found, minimum) < 0) {
    return check(id, 'fail', `found ${found}; requires ${minimum} or newer`);
  }
  return check(id, 'pass', found);
}

export async function runDoctor({ repoRoot, env = process.env, runner = runProcess } = {}) {
  const checks = [];
  let paths;
  let policy;

  try {
    policy = loadVersionPolicy(repoRoot);
    paths = resolveFactoryPaths({ repoRoot, env });
    checks.push(check('external-state', 'pass', 'factory state is outside the source checkout'));
  } catch (error) {
    checks.push(check('external-state', 'fail', error.message));
    return { ok: false, checks };
  }

  const commands = [
    ['gc-version', 'gc', ['version'], policy.gasCity, null],
    ['bd-version', 'bd', ['version'], policy.beads, null],
    ['dolt-version', 'dolt', ['version'], null, policy.doltMinimum],
    ['tmux-version', 'tmux', ['-V'], null, null],
    ['git-version', 'git', ['--version'], null, null],
    ['jq-version', 'jq', ['--version'], null, null],
    ['flock-version', 'flock', ['--version'], null, null],
    ['gh-version', 'gh', ['--version'], null, null],
    ['codex-version', 'codex', ['--version'], null, null],
  ];

  for (const [id, command, args, expected, minimum] of commands) {
    checks.push(await commandVersion({ id, command, args, expected, minimum, runner }));
  }

  const [doltName, doltEmail] = await Promise.all([
    runner('dolt', ['config', '--global', '--get', 'user.name'], { timeoutMs: 15_000 }),
    runner('dolt', ['config', '--global', '--get', 'user.email'], { timeoutMs: 15_000 }),
  ]);
  const doltIdentityConfigured =
    doltName.code === 0 &&
    doltName.stdout.trim() !== '' &&
    doltEmail.code === 0 &&
    doltEmail.stdout.trim() !== '';
  checks.push(
    check(
      'dolt-identity',
      doltIdentityConfigured ? 'pass' : 'fail',
      doltIdentityConfigured
        ? 'configured'
        : 'configure global Dolt user.name and user.email before bootstrap',
    ),
  );

  const nodeMajor = Number(process.versions.node.split('.')[0]);
  checks.push(
    check(
      'node-version',
      nodeMajor >= policy.nodeMinimumMajor ? 'pass' : 'fail',
      nodeMajor >= policy.nodeMinimumMajor
        ? process.versions.node
        : `found ${process.versions.node}; requires major ${policy.nodeMinimumMajor} or newer`,
    ),
  );

  const auth = await runner('gh', ['auth', 'status'], { cwd: repoRoot, timeoutMs: 15_000 });
  checks.push(
    check(
      'github-auth',
      auth.code === 0 ? 'pass' : 'fail',
      auth.code === 0 ? 'authenticated' : 'GitHub CLI authentication is unavailable',
    ),
  );

  const gitState = await runner('git', ['status', '--porcelain'], {
    cwd: repoRoot,
    timeoutMs: 15_000,
  });
  const clean = gitState.code === 0 && gitState.stdout.trim() === '';
  checks.push(
    check(
      'clean-worktree',
      clean ? 'pass' : 'fail',
      clean ? 'source checkout is clean' : 'source checkout has uncommitted changes',
    ),
  );

  const disk = await runner('df', ['-Pk', dirname(paths.root)], { timeoutMs: 15_000 });
  const availableKb = Number(disk.stdout.trim().split(/\s+/).at(-3));
  const availableBytes = Number.isFinite(availableKb) ? availableKb * 1024 : 0;
  checks.push(
    check(
      'disk-space',
      disk.code === 0 && availableBytes >= 20 * GIB ? 'pass' : 'fail',
      disk.code === 0 && availableBytes > 0
        ? `${(availableBytes / GIB).toFixed(1)} GiB available`
        : 'could not determine available disk space',
    ),
  );

  return { ok: checks.every((entry) => entry.status === 'pass'), checks, paths, policy };
}
