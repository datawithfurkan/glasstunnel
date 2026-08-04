import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { parse } from 'smol-toml';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const PACK_ROOT = join(REPO_ROOT, 'ops', 'agent-factory', 'template', 'packs', 'glasstunnel');
const FORMULAS_ROOT = join(PACK_ROOT, 'formulas');
const EXPECTED_FORMULAS = [
  'bug-investigation.toml',
  'cross-surface-change.toml',
  'dependency-update.toml',
  'foundation-canary.toml',
  'product-change.toml',
  'release-evidence.toml',
];

function assertAcyclic(steps, file) {
  const byId = new Map(steps.map((step) => [step.id, step]));
  const visiting = new Set();
  const visited = new Set();

  function visit(id) {
    if (visited.has(id)) return;
    assert.equal(visiting.has(id), false, `${file}: cycle at ${id}`);
    visiting.add(id);
    for (const dependency of byId.get(id).needs ?? []) visit(dependency);
    visiting.delete(id);
    visited.add(id);
  }

  for (const id of byId.keys()) visit(id);
}

test('factory formulas are bounded, routed Formula v2 DAGs', async () => {
  const names = (await readdir(FORMULAS_ROOT)).sort();
  assert.deepEqual(names, EXPECTED_FORMULAS);

  for (const name of names) {
    const formula = parse(await readFile(join(FORMULAS_ROOT, name), 'utf8'));
    const steps = formula.steps ?? [];
    const ids = new Set(steps.map((step) => step.id));

    assert.equal(formula.requires.formula_compiler, '>=2.0.0', name);
    assert.ok(steps.length >= 3, `${name}: expected at least three stages`);
    assert.equal(ids.size, steps.length, `${name}: duplicate step id`);

    for (const step of steps) {
      for (const dependency of step.needs ?? []) {
        assert.ok(ids.has(dependency), `${name}: unknown dependency ${dependency}`);
      }
      if (!step.gate) {
        assert.match(step.metadata?.['gc.run_target'] ?? '', /^\{\{rig_name\}\}\//, name);
      }
      if (step.retry) {
        assert.ok(step.retry.max_attempts <= 2, `${name}: retry budget exceeds two`);
        assert.equal(step.retry.on_exhausted, 'hard_fail', name);
      }
    }
    assertAcyclic(steps, name);
  }
});

test('production formulas cannot reach integration-ready without validation and review', async () => {
  for (const name of EXPECTED_FORMULAS.filter(
    (entry) => !['foundation-canary.toml', 'release-evidence.toml'].includes(entry),
  )) {
    const formula = parse(await readFile(join(FORMULAS_ROOT, name), 'utf8'));
    const byId = new Map(formula.steps.map((step) => [step.id, step]));
    const integration = byId.get('integration-ready');
    assert.ok(integration, `${name}: missing integration-ready`);
    assert.ok(integration.needs.includes('validate'), `${name}: validation is not a blocker`);
    assert.ok(integration.needs.includes('review'), `${name}: review is not a blocker`);
    assert.match(byId.get('validate').metadata['gc.run_target'], /qa$/);
    assert.match(byId.get('review').metadata['gc.run_target'], /reviewer$/);
  }
});

test('foundation canary proves retry, independent review, and integration readiness', async () => {
  const formula = parse(await readFile(join(FORMULAS_ROOT, 'foundation-canary.toml'), 'utf8'));
  const byId = new Map(formula.steps.map((step) => [step.id, step]));
  assert.equal(byId.get('controlled-retry').retry.max_attempts, 2);
  assert.match(byId.get('controlled-retry').metadata['gc.run_target'], /canary-worker$/);
  assert.match(byId.get('review').metadata['gc.run_target'], /canary-reviewer$/);
  assert.deepEqual(byId.get('integration-ready').needs, ['controlled-retry', 'review']);
});
