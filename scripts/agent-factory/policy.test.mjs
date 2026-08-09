import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const POLICIES = join(REPO_ROOT, 'ops', 'agent-factory', 'policies');

async function json(name) {
  return JSON.parse(await readFile(join(POLICIES, name), 'utf8'));
}

const validNode = {
  schema: 'glasstunnel.factory.node.v1',
  objective: 'Prove the deterministic canary lifecycle',
  nonGoals: ['Modify product source'],
  surfaces: ['factory'],
  fileOwnership: ['ops/agent-factory/**'],
  risk: 'low',
  budgets: { wallClockMinutes: 10, modelTokens: 0, githubRuns: 0 },
  resources: ['canary-exclusive'],
  validation: ['pnpm factory:test'],
  maxEvidenceFreeAttempts: 1,
  humanGates: [],
  evidence: [],
};

test('node contract accepts a complete bounded node', async () => {
  const validate = new Ajv2020({ allErrors: true }).compile(
    await json('node-contract.schema.json'),
  );
  assert.equal(validate(validNode), true, JSON.stringify(validate.errors));
});

test('node contract rejects every missing required contract field', async () => {
  const schema = await json('node-contract.schema.json');
  const validate = new Ajv2020({ allErrors: true }).compile(schema);
  for (const field of schema.required) {
    const candidate = structuredClone(validNode);
    delete candidate[field];
    assert.equal(validate(candidate), false, field);
  }
});

test('foundation retry and GitHub budgets are bounded', async () => {
  const validate = new Ajv2020({ allErrors: true }).compile(
    await json('node-contract.schema.json'),
  );
  assert.equal(validate({ ...validNode, maxEvidenceFreeAttempts: 2 }), false);
  assert.equal(validate({ ...validNode, budgets: { ...validNode.budgets, githubRuns: 2 } }), false);
});

test('exclusive resources have complete recovery policy', async () => {
  const policy = await json('resources.json');
  const expected = [
    'canary-exclusive',
    'ios-simulator',
    'keychain-signing',
    'local-lab',
    'mac-ui',
    'notarization',
    'production-deploy',
    'tcc-accessibility',
    'tcc-screen-recording',
  ];
  assert.deepEqual(Object.keys(policy.resources).sort(), expected);
  for (const [name, resource] of Object.entries(policy.resources)) {
    assert.equal(typeof resource.humanGate, 'boolean', name);
    assert.ok(resource.defaultTtlSeconds > resource.heartbeatSeconds, name);
    assert.match(resource.recoveryCommand, /^pnpm (factory:status|lab:down)$/);
  }
});
