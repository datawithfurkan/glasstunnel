import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { factoryEnvironment, resolveFactoryPaths } from './config.mjs';

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
  assert.equal(paths.sourceRemote.endsWith('/home/test/.local/share/glasstunnel-factory/source.git'), true);
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

test('factory commands disable inherited Beads routing and automatic sync', () => {
  const paths = resolveFactoryPaths({
    repoRoot: '/repo/glasstunnel',
    env: { HOME: '/home/test' },
  });
  const env = factoryEnvironment(paths, {
    BD_ROUTING_MODE: 'auto',
    BEADS_ROUTING_MODE: 'auto',
    BD_BACKUP_ENABLED: 'true',
    BEADS_BACKUP_ENABLED: 'true',
    BD_DOLT_SYNC_CLI_REMOTES: 'true',
    BEADS_DOLT_SYNC_CLI_REMOTES: 'true',
    BD_EXPORT_AUTO: 'true',
  });

  assert.equal(env.BD_ROUTING_MODE, 'off');
  assert.equal(env.BEADS_ROUTING_MODE, 'off');
  assert.equal(env.BD_BACKUP_ENABLED, 'false');
  assert.equal(env.BEADS_BACKUP_ENABLED, 'false');
  assert.equal(env.BD_DOLT_SYNC_CLI_REMOTES, 'false');
  assert.equal(env.BEADS_DOLT_SYNC_CLI_REMOTES, 'false');
  assert.equal(env.BD_EXPORT_AUTO, 'false');
});
