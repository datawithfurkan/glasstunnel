import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import { labConfig } from './config.mjs';

const root = labConfig().root;

function read(path) {
  return readFileSync(`${root}/${path}`, 'utf8');
}

test('root scripts expose the complete local lab command surface', () => {
  const { engines, scripts, workspaces } = JSON.parse(read('package.json'));
  const required = [
    'lab:doctor',
    'lab:up',
    'lab:up:host',
    'lab:status',
    'lab:reset',
    'lab:down',
    'lab:mac',
    'lab:test',
    'lab:test:unit',
    'lab:e2e',
    'lab:e2e:safari',
    'worker:typecheck',
    'worker:test',
    'worker:build',
  ];

  for (const name of required) {
    assert.equal(typeof scripts[name], 'string', `missing package script ${name}`);
  }
  assert.ok(workspaces.includes('apps/cloudflare-signal'));
  assert.equal(engines.node, '>=22');
});

test('CI uses the Node baseline required by the Worker toolchain', () => {
  const ci = read('.github/workflows/ci.yml');

  assert.match(ci, /node-version:\s*(?:["']?22["']?)/);
  assert.doesNotMatch(ci, /node-version:\s*(?:["']?20["']?)/);
});

test('validation selects local lab and Worker checks without pnpm dlx', () => {
  const validation = read('scripts/agent-validate.sh');

  assert.match(validation, /pnpm lab:test:unit/);
  assert.match(validation, /pnpm worker:typecheck/);
  assert.match(validation, /pnpm worker:test/);
  assert.match(validation, /pnpm worker:build/);
  assert.doesNotMatch(validation, /pnpm dlx wrangler/);
});

test('developer guidance keeps the account-first lab on the fast local path', () => {
  const makefile = read('Makefile');
  const runbook = read('docs/dev-runbook.md');
  const mobileQa = read('docs/mobile-qa.md');
  const workflows = read('docs/agentic-workflows.md');
  const loopState = read('docs/current-loop-state.md');
  const workerReadme = read('apps/cloudflare-signal/README.md');
  const devApp = read('scripts/dev-app.sh');

  assert.match(makefile, /account-first local lab/);
  assert.match(makefile, /lab-e2e:/);
  assert.match(runbook, /Node\.js 22\+/);
  assert.doesNotMatch(runbook, /Node\.js 20\+/);
  assert.match(runbook, /pnpm lab:up:host/);
  assert.match(runbook, /pnpm lab:e2e/);
  assert.match(runbook, /pnpm lab:mac/);
  assert.match(runbook, /one consolidated push/i);
  assert.doesNotMatch(runbook, /Starts signaling on `:18080`/);
  assert.match(mobileQa, /Playwright WebKit is not Mobile Safari/i);
  assert.match(workflows, /local-first inner loop/i);
  assert.match(loopState, /Last updated: \d{4}-\d{2}-\d{2}\./);
  assert.match(loopState, /Local Test Lab/);
  assert.match(workerReadme, /pnpm worker:test/);
  assert.match(devApp, /GLASSTUNNEL_DEV_APP_PATH/);
  assert.match(devApp, /GLASSTUNNEL_DEV_BUNDLE_ID/);
  assert.doesNotMatch(devApp, /pkill -x GlassTunnel/);
});

test('the default Chromium lab proves the authenticated account journey on mobile', () => {
  const e2eController = read('scripts/lab/e2e.mjs');
  const playwrightConfig = read('playwright.config.ts');

  assert.match(e2eController, /'local-account-mobile-chromium'/);
  assert.match(playwrightConfig, /name:\s*'local-account-mobile-chromium'/);
  assert.match(playwrightConfig, /\.\.\.devices\['Pixel 7'\]/);
});

test('Mac release audits read the development bundle identity from the launcher contract', () => {
  const devAppPath = `${root}/scripts/dev-app.sh`;
  const preflight = read('scripts/mac-release-preflight.sh');
  const distributionDocsAudit = read('scripts/mac-distribution-docs-audit.sh');
  const cleanEnvironment = { ...process.env };
  delete cleanEnvironment.GLASSTUNNEL_DEV_BUNDLE_ID;

  const defaultBundleID = execFileSync('bash', [devAppPath, '--print-bundle-id'], {
    encoding: 'utf8',
    env: cleanEnvironment,
    timeout: 1_000,
  }).trim();
  const overriddenBundleID = execFileSync('bash', [devAppPath, '--print-bundle-id'], {
    encoding: 'utf8',
    env: {
      ...cleanEnvironment,
      GLASSTUNNEL_DEV_BUNDLE_ID: 'io.glasstunnel.host.lab',
    },
    timeout: 1_000,
  }).trim();

  assert.equal(defaultBundleID, 'io.glasstunnel.host.dev');
  assert.equal(overriddenBundleID, 'io.glasstunnel.host.lab');
  assert.match(preflight, /bash "\$DEV_APP_SCRIPT" --print-bundle-id/);
  assert.match(distributionDocsAudit, /bash "\$DEV_SCRIPT" --print-bundle-id/);
});
