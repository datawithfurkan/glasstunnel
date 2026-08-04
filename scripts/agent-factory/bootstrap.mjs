import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { factoryEnvironment, resolveFactoryPaths } from './config.mjs';
import { runDoctor } from './doctor.mjs';
import { listLeases } from './lease.mjs';
import { runProcess } from './process.mjs';

async function checked(runner, command, args, options, label) {
  const result = await runner(command, args, options);
  if (result.code !== 0) {
    const detail = result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
    throw new Error(`${label}: ${detail}`);
  }
  return result;
}

function rigListContains(stdout, name) {
  try {
    const parsed = JSON.parse(stdout);
    const queue = Array.isArray(parsed) ? [...parsed] : [parsed];
    while (queue.length > 0) {
      const value = queue.shift();
      if (!value || typeof value !== 'object') continue;
      if (value.name === name) return true;
      queue.push(...Object.values(value).filter((entry) => entry && typeof entry === 'object'));
    }
  } catch {
    return false;
  }
  return false;
}

const REQUIRED_FORMULAS = new Set([
  'bug-investigation',
  'cross-surface-change',
  'dependency-update',
  'foundation-canary',
  'product-change',
  'release-evidence',
]);

const MANAGED_MIRROR_TOPOLOGY_PATHS = [
  '.beads/identity.toml',
  '.beads/metadata.json',
  '.gitignore',
];

function assertRequiredFormulas(stdout) {
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new Error('Gas City returned invalid JSON while listing formulas');
  }
  const discovered = new Set(
    Array.isArray(parsed?.formulas) ? parsed.formulas.map((formula) => formula?.name) : [],
  );
  const missing = [...REQUIRED_FORMULAS].filter((name) => !discovered.has(name));
  if (missing.length > 0) {
    throw new Error(`Factory formulas were not installed: ${missing.join(', ')}`);
  }
}

function changedPaths(statusOutput) {
  return statusOutput
    .split('\n')
    .filter(Boolean)
    .map((line) => line.slice(3));
}

function assertOnlyManagedMirrorChanges(statusOutput) {
  const changed = changedPaths(statusOutput);
  const unexpected = changed.filter(
    (path) => path.includes(' -> ') || !MANAGED_MIRROR_TOPOLOGY_PATHS.includes(path),
  );
  if (unexpected.length > 0) {
    throw new Error(`Unexpected external mirror changes: ${unexpected.join(', ')}`);
  }
  return changed;
}

async function finalizeMirrorTopology({ runner, options, mirror }) {
  const status = await checked(
    runner,
    'git',
    ['status', '--porcelain=v1'],
    { ...options, cwd: mirror },
    'checking generated rig topology',
  );
  const changed = assertOnlyManagedMirrorChanges(status.stdout);
  if (changed.length === 0) return false;

  await checked(
    runner,
    'git',
    ['add', '--', ...MANAGED_MIRROR_TOPOLOGY_PATHS],
    { ...options, cwd: mirror },
    'staging generated rig topology',
  );
  await checked(
    runner,
    'git',
    ['commit', '-m', 'gc rig add: finalize external factory metadata'],
    { ...options, cwd: mirror },
    'committing generated rig topology',
  );
  const finalStatus = await checked(
    runner,
    'git',
    ['status', '--porcelain=v1'],
    { ...options, cwd: mirror },
    'verifying external rig mirror state',
  );
  if (finalStatus.stdout.trim()) {
    throw new Error('External rig mirror remained dirty after topology finalization');
  }
  return true;
}

export async function bootstrapFactory({
  repoRoot,
  env = process.env,
  runner = runProcess,
  doctor = runDoctor,
} = {}) {
  const paths = resolveFactoryPaths({ repoRoot, env });
  const processEnv = factoryEnvironment(paths, env);
  const options = { env: processEnv, timeoutMs: 120_000 };
  const report = await doctor({ repoRoot, env, runner });
  if (!report.ok) throw new Error('Factory doctor must pass before bootstrap');

  await mkdir(paths.root, { recursive: true, mode: 0o700 });
  for (const directory of [
    paths.gcHome,
    paths.backups,
    paths.leases,
    paths.rigs,
    paths.worktrees,
    paths.artifacts,
    paths.notifications,
  ]) {
    await mkdir(directory, { recursive: true, mode: 0o700 });
  }

  let cityCreated = false;
  if (!existsSync(join(paths.city, 'city.toml'))) {
    const template = join(repoRoot, 'ops', 'agent-factory', 'template');
    await checked(
      runner,
      'gc',
      [
        'init',
        '--from',
        template,
        '--name',
        'glasstunnel-factory',
        '--no-start',
        '--skip-provider-readiness',
        '--yes',
        paths.city,
      ],
      options,
      'initializing external city',
    );
    cityCreated = true;
  }

  await checked(
    runner,
    'gc',
    ['import', 'install'],
    { ...options, cwd: paths.city },
    'installing pinned city imports',
  );

  const mirror = join(paths.rigs, 'glasstunnel');
  const sourceOrigin = (
    await checked(
      runner,
      'git',
      ['remote', 'get-url', 'origin'],
      { ...options, cwd: repoRoot },
      'reading source origin',
    )
  ).stdout.trim();
  if (!sourceOrigin) throw new Error('The Glasstunnel source checkout has no origin URL');

  let mirrorCreated = false;
  if (!existsSync(mirror)) {
    await checked(
      runner,
      'git',
      ['clone', '--no-tags', '--branch', 'main', sourceOrigin, mirror],
      options,
      'cloning external rig mirror',
    );
    mirrorCreated = true;
  } else {
    const mirrorOrigin = (
      await checked(
        runner,
        'git',
        ['remote', 'get-url', 'origin'],
        { ...options, cwd: mirror },
        'reading mirror origin',
      )
    ).stdout.trim();
    if (mirrorOrigin !== sourceOrigin)
      throw new Error('External rig mirror origin does not match source');
    const status = await checked(
      runner,
      'git',
      ['status', '--porcelain'],
      { ...options, cwd: mirror },
      'checking mirror state',
    );
    assertOnlyManagedMirrorChanges(status.stdout);
    await checked(
      runner,
      'git',
      ['fetch', '--no-tags', 'origin', 'main'],
      { ...options, cwd: mirror },
      'fetching mirror main',
    );
  }

  const rigList = await checked(
    runner,
    'gc',
    ['rig', 'list', '--json'],
    { ...options, cwd: paths.city },
    'listing rigs',
  );
  let rigAdded = false;
  if (!rigListContains(rigList.stdout, 'glasstunnel')) {
    await checked(
      runner,
      'gc',
      [
        'rig',
        'add',
        mirror,
        '--name',
        'glasstunnel',
        '--default-branch',
        'main',
        '--start-suspended',
      ],
      { ...options, cwd: paths.city },
      'registering external rig mirror',
    );
    rigAdded = true;
  }

  await checked(runner, 'gc', ['doctor'], { ...options, cwd: paths.city }, 'running city doctor');
  await checked(
    runner,
    'gc',
    ['config', 'show', '--validate'],
    { ...options, cwd: paths.city },
    'validating city config',
  );
  const formulas = await checked(
    runner,
    'gc',
    ['formula', 'list', '--city', paths.city, '--rig', 'glasstunnel', '--json'],
    { ...options, cwd: paths.city },
    'listing formulas',
  );
  assertRequiredFormulas(formulas.stdout);

  const mirrorTopologyCommitted = await finalizeMirrorTopology({
    runner,
    options,
    mirror,
  });

  return { paths, cityCreated, mirrorCreated, rigAdded, mirrorTopologyCommitted };
}

export async function getFactoryStatus({ repoRoot, env = process.env, runner = runProcess } = {}) {
  const paths = resolveFactoryPaths({ repoRoot, env });
  const processEnv = factoryEnvironment(paths, env);
  const options = { env: processEnv, timeoutMs: 60_000 };
  const [city, rigs, repoStatus, disk, leases] = await Promise.all([
    runner('gc', ['status', paths.city, '--json'], options),
    runner('gc', ['rig', 'list', '--json'], { ...options, cwd: paths.city }),
    runner('git', ['status', '--porcelain'], { ...options, cwd: repoRoot }),
    runner('du', ['-sk', paths.root], options),
    listLeases(paths),
  ]);

  return {
    initialized: existsSync(join(paths.city, 'city.toml')),
    city: city.code === 0 ? city.stdout.trim() : null,
    rigs: rigs.code === 0 ? rigs.stdout.trim() : null,
    openLeases: leases,
    diskKiB: disk.code === 0 ? Number.parseInt(disk.stdout, 10) || null : null,
    primaryRepoClean: repoStatus.code === 0 && repoStatus.stdout.trim() === '',
  };
}

export async function stopFactory({ repoRoot, env = process.env, runner = runProcess } = {}) {
  const paths = resolveFactoryPaths({ repoRoot, env });
  if (!existsSync(paths.city)) return { stopped: false, reason: 'not-initialized' };
  const result = await runner('gc', ['stop', paths.city, '--timeout', '2m'], {
    env: factoryEnvironment(paths, env),
    timeoutMs: 150_000,
  });
  if (result.code !== 0) {
    throw new Error(`stopping external city: ${result.stderr.trim() || result.stdout.trim()}`);
  }
  return { stopped: true };
}
