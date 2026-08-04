import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function canonicalPath(path) {
  const absolute = resolve(path);
  if (existsSync(absolute)) return realpathSync(absolute);

  let ancestor = dirname(absolute);
  while (!existsSync(ancestor)) {
    const parent = dirname(ancestor);
    if (parent === ancestor) return absolute;
    ancestor = parent;
  }
  return resolve(realpathSync(ancestor), relative(ancestor, absolute));
}

export function isPathInside(parent, candidate) {
  const rel = relative(canonicalPath(parent), canonicalPath(candidate));
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

export function loadVersionPolicy(repoRoot = MODULE_ROOT) {
  const file = join(repoRoot, 'ops', 'agent-factory', 'versions.env');
  const values = {};

  for (const rawLine of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^([A-Z][A-Z0-9_]*)=(.+)$/.exec(line);
    if (!match) throw new Error(`Invalid version policy line in ${file}`);
    values[match[1]] = match[2];
  }

  return {
    gasCity: values.GC_VERSION,
    gasCityCommit: values.GC_RELEASE_COMMIT,
    beads: values.BD_VERSION,
    doltMinimum: values.DOLT_MIN_VERSION,
    nodeMinimumMajor: Number(values.NODE_MIN_MAJOR),
    schemaVersion: Number(values.FACTORY_SCHEMA_VERSION),
  };
}

export function resolveFactoryPaths({ repoRoot = MODULE_ROOT, env = process.env } = {}) {
  const source = canonicalPath(repoRoot);
  const root = canonicalPath(
    env.GT_FACTORY_HOME ??
      join(env.HOME ?? homedir(), '.local', 'share', 'glasstunnel-factory'),
  );

  if (isPathInside(source, root)) {
    throw new Error('GT_FACTORY_HOME must be outside the Glasstunnel source checkout');
  }
  if (/\s/.test(root)) {
    throw new Error('GT_FACTORY_HOME cannot contain whitespace with Gas City 1.4.0');
  }

  return {
    source,
    root,
    city: join(root, 'city'),
    gcHome: join(root, 'gc-home'),
    backups: join(root, 'backups'),
    leases: join(root, 'leases'),
    rigs: join(root, 'rigs'),
    worktrees: join(root, 'worktrees'),
    artifacts: join(root, 'artifacts'),
    notifications: join(root, 'notifications'),
  };
}

export function factoryEnvironment(paths, env = process.env) {
  return {
    ...env,
    GC_HOME: paths.gcHome,
    DO_NOT_TRACK: '1',
    GC_DISABLE_USAGE_METRICS: '1',
  };
}
