import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { bootstrapFactory, getFactoryStatus, stopFactory } from './bootstrap.mjs';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'glasstunnel-bootstrap-'));
  const repoRoot = join(root, 'source');
  await mkdir(join(repoRoot, 'ops', 'agent-factory', 'template'), { recursive: true });
  await writeFile(join(repoRoot, 'ops', 'agent-factory', 'template', 'city.toml'), '[workspace]\n');
  await writeFile(join(repoRoot, 'ops', 'agent-factory', 'template', 'pack.toml'), '[pack]\n');
  return {
    repoRoot,
    env: { HOME: root, GT_FACTORY_HOME: join(root, 'state') },
  };
}

function bdRoutingResult(command, args) {
  if (command !== 'bd' || args[0] !== 'config') return null;
  if (args[1] === 'set' && args[2] === 'routing.mode' && args[3] === 'explicit') {
    return { code: 0, stdout: '', stderr: '' };
  }
  if (args[1] === 'get' && args[2] === 'routing.mode') {
    return { code: 0, stdout: 'explicit\n', stderr: '' };
  }
  return { code: 1, stdout: '', stderr: 'unexpected Beads config command' };
}

test('bootstrap initializes an external city and suspended mirror rig once', async () => {
  const { repoRoot, env } = await fixture();
  const calls = [];
  let rigRegistered = false;
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    const routing = bdRoutingResult(command, args);
    if (routing) return routing;
    if (
      command === 'git' &&
      args.slice(0, 2).join(' ') === 'remote get-url' &&
      args.at(-1) === 'origin' &&
      options?.cwd?.endsWith('/rigs/glasstunnel')
    ) {
      return {
        code: 0,
        stdout: `${resolve(options.cwd, '..', '..', 'source.git')}\n`,
        stderr: '',
      };
    }
    if (command === 'git' && args[0] === 'remote') {
      return { code: 0, stdout: 'https://github.com/datawithfurkan/glasstunnel.git\n', stderr: '' };
    }
    if (command === 'git' && args.slice(0, 2).join(' ') === 'init --bare') {
      await mkdir(args.at(-1), { recursive: true });
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'clone') {
      await mkdir(args.at(-1), { recursive: true });
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'status') return { code: 0, stdout: '', stderr: '' };
    if (command === 'gc' && args[0] === 'init') {
      await mkdir(args.at(-1), { recursive: true });
      await writeFile(join(args.at(-1), 'city.toml'), '[workspace]\n');
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig list') {
      return {
        code: 0,
        stdout: JSON.stringify(rigRegistered ? [{ name: 'glasstunnel' }] : []),
        stderr: '',
      };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig add') rigRegistered = true;
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'formula list') {
      return {
        code: 0,
        stdout: JSON.stringify({
          formulas: [
            'bug-investigation',
            'cross-surface-change',
            'dependency-update',
            'foundation-canary',
            'product-change',
            'release-evidence',
          ].map((name) => ({ name })),
        }),
        stderr: '',
      };
    }
    return { code: 0, stdout: '', stderr: '' };
  };
  const doctor = async () => ({ ok: true, checks: [] });

  const first = await bootstrapFactory({ repoRoot, env, runner, doctor });
  const second = await bootstrapFactory({ repoRoot, env, runner, doctor });

  assert.equal(first.cityCreated, true);
  assert.equal(first.mirrorCreated, true);
  assert.equal(first.rigAdded, true);
  assert.equal(second.cityCreated, false);
  assert.equal(second.mirrorCreated, false);
  assert.equal(second.rigAdded, false);
  assert.equal(
    calls.filter((entry) => entry.command === 'gc' && entry.args[0] === 'init').length,
    1,
  );
  assert.equal(
    calls.filter((entry) => entry.command === 'git' && entry.args[0] === 'clone').length,
    1,
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args.slice(0, 2).join(' ') === 'init --bare' &&
        entry.args.at(-1).endsWith('/source.git'),
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'bd' && entry.args.join(' ') === 'config set routing.mode explicit',
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'bd' &&
        entry.args.join(' ') === 'config get routing.mode' &&
        entry.options.env.BD_ROUTING_MODE === 'off',
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'clone' &&
        entry.args.some((arg) => arg.endsWith('/source.git')),
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args.join(' ') ===
          'remote set-url --push upstream DISABLED',
    ),
  );
  assert.equal(
    calls.filter(
      (entry) =>
        entry.command === 'gc' && entry.args.slice(0, 2).join(' ') === 'import install',
    ).length,
    2,
  );
  assert.equal(
    calls.filter(
      (entry) => entry.command === 'gc' && entry.args.slice(0, 2).join(' ') === 'rig add',
    ).length,
    1,
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'gc' &&
        entry.args.slice(0, 3).join(' ') === 'config show --validate',
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'gc' &&
        entry.args[0] === 'formula' &&
        entry.args[1] === 'list' &&
        entry.args.includes('--city') &&
        entry.args.includes('--rig') &&
        entry.args.includes('glasstunnel') &&
        entry.args.includes('--json'),
    ),
  );
  assert.equal(
    calls.some(
      (entry) => entry.command === 'git' && entry.args.slice(0, 2).join(' ') === 'merge --ff-only',
    ),
    false,
  );
  assert.ok(
    calls.every(
      (entry) =>
        entry.options?.env?.DO_NOT_TRACK === '1' &&
        entry.options?.env?.GC_DISABLE_USAGE_METRICS === '1',
    ),
  );
});

test('bootstrap commits only canonical Gas City topology changes in the external mirror', async () => {
  const { repoRoot, env } = await fixture();
  const mirror = join(env.GT_FACTORY_HOME, 'rigs', 'glasstunnel');
  const calls = [];
  let rigRegistered = false;
  let topologyCommitted = false;
  let identityTracked = false;
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    const routing = bdRoutingResult(command, args);
    if (routing) return routing;
    if (
      command === 'git' &&
      args.slice(0, 2).join(' ') === 'remote get-url' &&
      args.at(-1) === 'origin' &&
      options?.cwd?.endsWith('/rigs/glasstunnel')
    ) {
      return {
        code: 0,
        stdout: `${resolve(options.cwd, '..', '..', 'source.git')}\n`,
        stderr: '',
      };
    }
    if (command === 'git' && args[0] === 'remote') {
      return { code: 0, stdout: 'https://github.com/datawithfurkan/glasstunnel.git\n', stderr: '' };
    }
    if (command === 'git' && args[0] === 'clone') {
      await mkdir(mirror, { recursive: true });
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'status') {
      return {
        code: 0,
        stdout: rigRegistered && !topologyCommitted ? ' M .gitignore\n' : '',
        stderr: '',
      };
    }
    if (command === 'git' && args[0] === 'ls-files') {
      return { code: identityTracked ? 0 : 1, stdout: '', stderr: '' };
    }
    if (command === 'git' && args.join(' ') === 'add -f -- .beads/identity.toml') {
      identityTracked = true;
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'commit') {
      topologyCommitted = true;
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'gc' && args[0] === 'init') {
      await mkdir(args.at(-1), { recursive: true });
      await writeFile(join(args.at(-1), 'city.toml'), '[workspace]\n');
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig list') {
      return { code: 0, stdout: JSON.stringify(rigRegistered ? [{ name: 'glasstunnel' }] : []), stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig add') rigRegistered = true;
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'formula list') {
      return {
        code: 0,
        stdout: JSON.stringify({
          formulas: [
            'bug-investigation',
            'cross-surface-change',
            'dependency-update',
            'foundation-canary',
            'product-change',
            'release-evidence',
          ].map((name) => ({ name })),
        }),
        stderr: '',
      };
    }
    return { code: 0, stdout: '', stderr: '' };
  };

  await bootstrapFactory({
    repoRoot,
    env,
    runner,
    doctor: async () => ({ ok: true, checks: [] }),
  });

  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args.join(' ') === 'add -- .gitignore',
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args.join(' ') === 'add -f -- .beads/identity.toml',
    ),
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'commit' &&
        entry.options.cwd.endsWith('/rigs/glasstunnel'),
    ),
  );
  assert.equal(topologyCommitted, true);
});

test('bootstrap rejects unexpected external mirror changes instead of committing them', async () => {
  const { repoRoot, env } = await fixture();
  const mirror = join(env.GT_FACTORY_HOME, 'rigs', 'glasstunnel');
  let rigRegistered = false;
  const runner = async (command, args) => {
    const routing = bdRoutingResult(command, args);
    if (routing) return routing;
    if (command === 'git' && args[0] === 'remote') {
      return { code: 0, stdout: 'https://github.com/datawithfurkan/glasstunnel.git\n', stderr: '' };
    }
    if (command === 'git' && args[0] === 'clone') {
      await mkdir(mirror, { recursive: true });
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'status') {
      return {
        code: 0,
        stdout: rigRegistered ? ' M README.md\n' : '',
        stderr: '',
      };
    }
    if (command === 'gc' && args[0] === 'init') {
      await mkdir(args.at(-1), { recursive: true });
      await writeFile(join(args.at(-1), 'city.toml'), '[workspace]\n');
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig list') {
      return { code: 0, stdout: JSON.stringify(rigRegistered ? [{ name: 'glasstunnel' }] : []), stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig add') rigRegistered = true;
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'formula list') {
      return {
        code: 0,
        stdout: JSON.stringify({
          formulas: [
            'bug-investigation',
            'cross-surface-change',
            'dependency-update',
            'foundation-canary',
            'product-change',
            'release-evidence',
          ].map((name) => ({ name })),
        }),
        stderr: '',
      };
    }
    return { code: 0, stdout: '', stderr: '' };
  };

  await assert.rejects(
    () =>
      bootstrapFactory({
        repoRoot,
        env,
        runner,
        doctor: async () => ({ ok: true, checks: [] }),
      }),
    /unexpected external mirror changes.*README\.md/i,
  );
});

test('bootstrap recovers canonical topology changes from an interrupted existing rig setup', async () => {
  const { repoRoot, env } = await fixture();
  const city = join(env.GT_FACTORY_HOME, 'city');
  const mirror = join(env.GT_FACTORY_HOME, 'rigs', 'glasstunnel');
  await mkdir(city, { recursive: true });
  await mkdir(mirror, { recursive: true });
  await writeFile(join(city, 'city.toml'), '[workspace]\n');
  let topologyCommitted = false;
  let identityTracked = false;
  const calls = [];
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    const routing = bdRoutingResult(command, args);
    if (routing) return routing;
    if (
      command === 'git' &&
      args.slice(0, 2).join(' ') === 'remote get-url' &&
      args.at(-1) === 'origin' &&
      options?.cwd?.endsWith('/rigs/glasstunnel')
    ) {
      return {
        code: 0,
        stdout: `${resolve(options.cwd, '..', '..', 'source.git')}\n`,
        stderr: '',
      };
    }
    if (command === 'git' && args[0] === 'remote') {
      return { code: 0, stdout: 'https://github.com/datawithfurkan/glasstunnel.git\n', stderr: '' };
    }
    if (command === 'git' && args[0] === 'status') {
      return {
        code: 0,
        stdout: topologyCommitted ? '' : ' M .gitignore\n',
        stderr: '',
      };
    }
    if (command === 'git' && args[0] === 'ls-files') {
      return { code: identityTracked ? 0 : 1, stdout: '', stderr: '' };
    }
    if (command === 'git' && args.join(' ') === 'add -f -- .beads/identity.toml') {
      identityTracked = true;
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'git' && args[0] === 'commit') {
      topologyCommitted = true;
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'rig list') {
      return { code: 0, stdout: JSON.stringify([{ name: 'glasstunnel' }]), stderr: '' };
    }
    if (command === 'gc' && args.slice(0, 2).join(' ') === 'formula list') {
      return {
        code: 0,
        stdout: JSON.stringify({
          formulas: [
            'bug-investigation',
            'cross-surface-change',
            'dependency-update',
            'foundation-canary',
            'product-change',
            'release-evidence',
          ].map((name) => ({ name })),
        }),
        stderr: '',
      };
    }
    return { code: 0, stdout: '', stderr: '' };
  };

  const result = await bootstrapFactory({
    repoRoot,
    env,
    runner,
    doctor: async () => ({ ok: true, checks: [] }),
  });

  assert.equal(result.mirrorTopologyCommitted, true);
  assert.ok(
    calls.some(
      (entry) => entry.command === 'git' && entry.args.join(' ') === 'fetch --no-tags origin main',
    ),
  );
  assert.equal(topologyCommitted, true);
});

test('bootstrap fails closed when doctor or mirror origin is wrong', async () => {
  const { repoRoot, env } = await fixture();
  await assert.rejects(
    () =>
      bootstrapFactory({
        repoRoot,
        env,
        runner: async () => ({ code: 0, stdout: '', stderr: '' }),
        doctor: async () => ({ ok: false, checks: [{ id: 'gc-version', status: 'fail' }] }),
      }),
    /doctor/i,
  );
});

test('status is read-only and down stops only the external city', async () => {
  const { repoRoot, env } = await fixture();
  await mkdir(join(env.GT_FACTORY_HOME, 'city'), { recursive: true });
  const calls = [];
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    if (command === 'git') return { code: 0, stdout: '', stderr: '' };
    if (command === 'du') return { code: 0, stdout: '12\tstate\n', stderr: '' };
    return { code: 0, stdout: '{}\n', stderr: '' };
  };

  const status = await getFactoryStatus({ repoRoot, env, runner });
  const stopped = await stopFactory({ repoRoot, env, runner });

  assert.equal(status.primaryRepoClean, true);
  assert.equal(stopped.stopped, true);
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'gc' && entry.args[0] === 'stop' && entry.args[1].endsWith('/city'),
    ),
  );
  assert.equal(
    calls.some((entry) => entry.args.includes('--force')),
    false,
  );
});
