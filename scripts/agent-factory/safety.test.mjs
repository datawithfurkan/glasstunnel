import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('git ignores accidental Gas City and Beads runtime roots', async () => {
  const gitignore = await readFile(new URL('../../.gitignore', import.meta.url), 'utf8');
  assert.match(gitignore, /^\.gc\/$/m);
  assert.match(gitignore, /^\.beads\/$/m);
  assert.match(gitignore, /^\.factory-state\/$/m);
});
