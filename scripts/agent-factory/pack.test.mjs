import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { parse } from 'smol-toml';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const TEMPLATE = join(REPO_ROOT, 'ops', 'agent-factory', 'template');
const PIN = 'sha:a7297c511d637a3609947386f3389d76ddb2f23b';
const EXPECTED_ROLES = [
  'adapter-engineer',
  'architect',
  'integrator',
  'mac-engineer',
  'planner',
  'protocol-engineer',
  'qa',
  'release-operator',
  'reviewer',
  'security-reviewer',
  'web-engineer',
];
const UTILITY_AGENTS = ['canary-reviewer', 'canary-worker'];

async function toml(path) {
  return parse(await readFile(path, 'utf8'));
}

test('root pack pins reviewed Pack V2 dependencies', async () => {
  const pack = await toml(join(TEMPLATE, 'pack.toml'));
  assert.equal(pack.pack.schema, 2);
  assert.equal(pack.imports.core.version, PIN);
  assert.equal(pack.imports.bd.version, PIN);
});

test('city defaults to Codex and imports the Glasstunnel rig pack', async () => {
  const city = await toml(join(TEMPLATE, 'city.toml'));
  assert.equal(city.workspace.provider, 'codex');
  assert.equal(city.providers.codex.base, 'builtin:codex');
  assert.equal(city.defaults.rig.imports.glasstunnel.source, 'packs/glasstunnel');
  assert.equal(city.convergence.max_total, 2);
});

test('every reviewed role is rig-scoped and dormant by default', async () => {
  const agentsRoot = join(TEMPLATE, 'packs', 'glasstunnel', 'agents');
  const agents = (await readdir(agentsRoot)).sort();
  assert.deepEqual(agents, [...EXPECTED_ROLES, ...UTILITY_AGENTS].sort());

  for (const role of EXPECTED_ROLES) {
    const config = await toml(join(agentsRoot, role, 'agent.toml'));
    const prompt = await readFile(join(agentsRoot, role, 'prompt.template.md'), 'utf8');
    assert.equal(config.scope, 'rig', role);
    assert.equal(config.provider, 'codex', role);
    assert.equal(config.min_active_sessions, 0, role);
    assert.equal(config.max_active_sessions, 1, role);
    assert.match(prompt, /Never push|never push|read-only/, role);
    assert.match(prompt, /evidence/i, role);
  }
});

test('deterministic canary agents use reviewed local scripts', async () => {
  const agentsRoot = join(TEMPLATE, 'packs', 'glasstunnel', 'agents');
  for (const role of UTILITY_AGENTS) {
    const config = await toml(join(agentsRoot, role, 'agent.toml'));
    assert.equal(config.scope, 'rig', role);
    assert.equal(config.lifecycle, 'one_shot', role);
    assert.equal(config.min_active_sessions, 0, role);
    assert.equal(config.max_active_sessions, 1, role);
    assert.match(config.start_command, /^gc agent-script --script /, role);
  }

  const worker = await readFile(
    join(TEMPLATE, 'packs', 'glasstunnel', 'assets', 'scripts', 'canary-worker.yaml'),
    'utf8',
  );
  assert.match(worker, /gc\.failure_class=transient/);
  assert.match(worker, /gc\.outcome=pass/);
  assert.doesNotMatch(worker, /git (push|merge)|notary|codesign/);
});
