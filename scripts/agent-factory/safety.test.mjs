import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { resolveFactoryPaths } from './config.mjs';

test('git ignores accidental Gas City and Beads runtime roots', async () => {
  const gitignore = await readFile(new URL('../../.gitignore', import.meta.url), 'utf8');
  assert.match(gitignore, /^\.gc\/$/m);
  assert.match(gitignore, /^\.beads\/$/m);
  assert.match(gitignore, /^\.factory-state\/$/m);
});

test('factory state defaults to a private external path without whitespace', () => {
  const paths = resolveFactoryPaths({
    repoRoot: '/repo/glasstunnel',
    env: { HOME: '/home/test' },
  });
  assert.equal(paths.root.endsWith('/home/test/.local/share/glasstunnel-factory'), true);
  assert.equal(/\s/.test(paths.root), false);
});

test('factory state rejects whitespace that Gas City cannot safely launch through', () => {
  assert.throws(
    () =>
      resolveFactoryPaths({
        repoRoot: '/repo/glasstunnel',
        env: { HOME: '/home/test', GT_FACTORY_HOME: '/tmp/factory state' },
      }),
    /whitespace/i,
  );
});
