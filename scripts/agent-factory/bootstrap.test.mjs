import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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

test('bootstrap initializes an external city and suspended mirror rig once', async () => {
  const { repoRoot, env } = await fixture();
  const calls = [];
  let rigRegistered = false;
  const runner = async (command, args, options) => {
    calls.push({ command, args, options });
    if (command === 'git' && args[0] === 'remote') {
      return { code: 0, stdout: 'https://github.com/datawithfurkan/glasstunnel.git\n', stderr: '' };
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
        entry.command === 'gc' && entry.args.slice(0, 3).join(' ') === 'config show --validate',
    ),
  );
  assert.ok(
    calls.every(
      (entry) =>
        entry.options?.env?.DO_NOT_TRACK === '1' &&
        entry.options?.env?.GC_DISABLE_USAGE_METRICS === '1',
    ),
  );
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
