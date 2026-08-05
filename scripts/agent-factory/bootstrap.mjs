import { existsSync } from 'node:fs';
import { cp, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { factoryEnvironment, resolveFactoryPaths } from './config.mjs';
import { isFactoryManagedDoltRunning, stopFactoryManagedDoltWatchdog } from './backup.mjs';
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

const MANAGED_MIRROR_TOPOLOGY_PATHS = ['.beads/identity.toml', '.gitignore'];

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

async function verifyCityDoctor({ runner, options, city }) {
  const result = await runner('gc', ['doctor', '--json'], { ...options, cwd: city });
  if (result.code === 0) return;

  let report;
  try {
    report = JSON.parse(result.stdout);
  } catch {
    const detail = result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
    throw new Error(`running city doctor: ${detail}`);
  }
  const failures = (report.results ?? []).filter((entry) => entry.status === 'error');
  const onlyDormantOrders = failures.length === 1 && failures[0].name === 'order-firing-current';
  if (onlyDormantOrders) {
    const status = await checked(
      runner,
      'gc',
      ['status', city, '--json'],
      { ...options, cwd: city },
      'checking dormant city state',
    );
    const parsed = JSON.parse(status.stdout);
    const rig = (parsed.rigs ?? []).find((entry) => entry.name === 'glasstunnel');
    if (parsed.running === false && rig?.suspended === true) return;
  }

  const names = failures.map((entry) => entry.name).filter(Boolean);
  throw new Error(`running city doctor: ${names.join(', ') || 'unknown failure'}`);
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
  const identity = await runner('git', ['ls-files', '--error-unmatch', '.beads/identity.toml'], {
    ...options,
    cwd: mirror,
  });
  if (identity.code !== 0 && identity.code !== 1) {
    throw new Error('Could not inspect external rig identity tracking');
  }
  const identityTracked = identity.code === 0;
  if (changed.length === 0 && identityTracked) return false;

  if (changed.includes('.gitignore')) {
    await checked(
      runner,
      'git',
      ['add', '--', '.gitignore'],
      { ...options, cwd: mirror },
      'staging generated rig ignore policy',
    );
  }
  if (!identityTracked) {
    await checked(
      runner,
      'git',
      ['add', '-f', '--', '.beads/identity.toml'],
      { ...options, cwd: mirror },
      'staging canonical rig identity',
    );
  }
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

async function preserveManagedDoltState({
  paths,
  env,
  runner,
  providerProbe,
  providerStopper,
  operation,
}) {
  const wasRunning = await providerProbe({ paths, env, runner });
  let value;
  let operationError;
  try {
    value = await operation();
  } catch (error) {
    operationError = error;
  }

  let cleanupError;
  try {
    if (!wasRunning && (await providerProbe({ paths, env, runner }))) {
      await providerStopper({ paths, env, runner });
    }
  } catch (error) {
    cleanupError = error;
  }

  if (operationError && cleanupError) {
    throw new AggregateError(
      [operationError, cleanupError],
      'Factory operation failed and managed Dolt state could not be restored',
    );
  }
  if (operationError) throw operationError;
  if (cleanupError) throw cleanupError;
  return value;
}

export async function bootstrapFactory({
  repoRoot,
  env = process.env,
  runner = runProcess,
  doctor = runDoctor,
  providerProbe = isFactoryManagedDoltRunning,
  providerStopper = stopFactoryManagedDoltWatchdog,
} = {}) {
  const paths = resolveFactoryPaths({ repoRoot, env });
  const processEnv = factoryEnvironment(paths, env);
  const options = { env: processEnv, timeoutMs: 120_000 };
  return preserveManagedDoltState({
    paths,
    env: processEnv,
    runner,
    providerProbe,
    providerStopper,
    operation: async () => {
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

      const managedPack = join(paths.city, 'packs', 'glasstunnel');
      await rm(managedPack, { recursive: true, force: true });
      await cp(
        join(repoRoot, 'ops', 'agent-factory', 'template', 'packs', 'glasstunnel'),
        managedPack,
        {
          recursive: true,
        },
      );

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

      if (!existsSync(paths.sourceRemote)) {
        await checked(
          runner,
          'git',
          ['init', '--bare', paths.sourceRemote],
          options,
          'initializing private source remote',
        );
        await checked(
          runner,
          'git',
          ['remote', 'add', 'upstream', sourceOrigin],
          { ...options, cwd: paths.sourceRemote },
          'adding public fetch source',
        );
      } else {
        const sourceUpstream = (
          await checked(
            runner,
            'git',
            ['remote', 'get-url', 'upstream'],
            { ...options, cwd: paths.sourceRemote },
            'reading private source upstream',
          )
        ).stdout.trim();
        if (sourceUpstream !== sourceOrigin) {
          throw new Error('Private source remote upstream does not match source');
        }
      }
      await checked(
        runner,
        'git',
        ['remote', 'set-url', '--push', 'upstream', 'DISABLED'],
        { ...options, cwd: paths.sourceRemote },
        'disabling public source pushes',
      );
      await checked(
        runner,
        'git',
        ['fetch', '--no-tags', 'upstream', 'refs/heads/main:refs/heads/main'],
        { ...options, cwd: paths.sourceRemote },
        'refreshing private source main',
      );

      let mirrorCreated = false;
      if (!existsSync(mirror)) {
        await checked(
          runner,
          'git',
          ['clone', '--no-tags', '--branch', 'main', paths.sourceRemote, mirror],
          options,
          'cloning external rig mirror',
        );
        await checked(
          runner,
          'git',
          ['remote', 'add', 'upstream', sourceOrigin],
          { ...options, cwd: mirror },
          'adding public mirror upstream',
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
        if (mirrorOrigin !== paths.sourceRemote)
          throw new Error('External rig mirror origin is not the private source remote');
        const mirrorUpstream = (
          await checked(
            runner,
            'git',
            ['remote', 'get-url', 'upstream'],
            { ...options, cwd: mirror },
            'reading mirror upstream',
          )
        ).stdout.trim();
        if (mirrorUpstream !== sourceOrigin)
          throw new Error('External rig mirror upstream does not match source');
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
      await checked(
        runner,
        'git',
        ['remote', 'set-url', '--push', 'upstream', 'DISABLED'],
        { ...options, cwd: mirror },
        'disabling public mirror pushes',
      );

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

      await checked(
        runner,
        'bd',
        ['config', 'set', 'routing.mode', 'explicit'],
        { ...options, cwd: mirror },
        'setting explicit factory routing',
      );
      const persistedConfigEnv = { ...processEnv };
      delete persistedConfigEnv.BD_ROUTING_MODE;
      delete persistedConfigEnv.BEADS_ROUTING_MODE;
      const routingMode = (
        await checked(
          runner,
          'bd',
          ['config', 'get', 'routing.mode'],
          { ...options, cwd: mirror, env: persistedConfigEnv },
          'verifying explicit factory routing',
        )
      ).stdout.trim();
      if (routingMode !== 'explicit') {
        throw new Error('Factory rig routing mode is not explicit');
      }

      await verifyCityDoctor({ runner, options, city: paths.city });
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
    },
  });
}

export async function getFactoryStatus({
  repoRoot,
  env = process.env,
  runner = runProcess,
  providerProbe = isFactoryManagedDoltRunning,
  providerStopper = stopFactoryManagedDoltWatchdog,
} = {}) {
  const paths = resolveFactoryPaths({ repoRoot, env });
  const processEnv = factoryEnvironment(paths, env);
  const options = { env: processEnv, timeoutMs: 60_000 };
  return preserveManagedDoltState({
    paths,
    env: processEnv,
    runner,
    providerProbe,
    providerStopper,
    operation: async () => {
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
    },
  });
}

export async function stopFactory({
  repoRoot,
  env = process.env,
  runner = runProcess,
  providerStopper = stopFactoryManagedDoltWatchdog,
} = {}) {
  const paths = resolveFactoryPaths({ repoRoot, env });
  if (!existsSync(paths.city)) return { stopped: false, reason: 'not-initialized' };
  const processEnv = factoryEnvironment(paths, env);
  const result = await runner('gc', ['stop', paths.city, '--timeout', '2m'], {
    env: processEnv,
    timeoutMs: 150_000,
  });
  let operationError;
  if (result.code !== 0) {
    operationError = new Error(
      `stopping external city: ${result.stderr.trim() || result.stdout.trim()}`,
    );
  }
  let cleanupError;
  try {
    await providerStopper({ paths, env: processEnv, runner });
  } catch (error) {
    cleanupError = error;
  }
  if (operationError && cleanupError) {
    throw new AggregateError(
      [operationError, cleanupError],
      'Factory shutdown failed and managed Dolt cleanup was incomplete',
    );
  }
  if (operationError) throw operationError;
  if (cleanupError) throw cleanupError;
  return { stopped: true };
}
