import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../', import.meta.url).pathname;
const script = join(root, 'scripts/public-remote-ref-audit.mjs');

function runAudit(fixture) {
  const dir = mkdtempSync(join(tmpdir(), 'gt-remote-ref-audit-'));
  const fixturePath = join(dir, 'refs.txt');
  writeFileSync(fixturePath, fixture);

  return execFileSync(process.execPath, [script], {
    cwd: root,
    env: {
      ...process.env,
      GT_PUBLIC_REMOTE_REF_AUDIT_FIXTURE: fixturePath,
    },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

test('accepts normal public GitHub refs', () => {
  const output = runAudit(`
7027b836c33c7b95b0380effcca8cb8bcdec6d30\tHEAD
7027b836c33c7b95b0380effcca8cb8bcdec6d30\trefs/heads/main
5571d2768164d7a48324ba33ce7a98564dcf2ed5\trefs/heads/codex/agent-factory-foundation
5571d2768164d7a48324ba33ce7a98564dcf2ed5\trefs/pull/1/head
23a358ee608248052a85a3e438eec77b965e358f\trefs/tags/v0.1.4
`);

  assert.match(output, /Public remote ref audit passed/u);
});

test('rejects exposed Dolt data refs', () => {
  assert.throws(
    () =>
      runAudit(`
dfa2d9dfe3af06be7ea5a82a0f93e01cbd9765d1\trefs/dolt/data
7027b836c33c7b95b0380effcca8cb8bcdec6d30\trefs/heads/main
`),
    /Public remote ref audit failed/u,
  );
});

test('rejects Dolt metadata branches', () => {
  assert.throws(
    () =>
      runAudit(`
e795cf4c417a05b1860c09f02267940ef55c3b21\trefs/heads/__dolt_remote_info__
7027b836c33c7b95b0380effcca8cb8bcdec6d30\trefs/heads/main
`),
    /Public remote ref audit failed/u,
  );
});
