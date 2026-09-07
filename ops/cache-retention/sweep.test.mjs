import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inspectObject, listObjects } from './sweep.mjs';

test('namespace enumeration follows a final cursor to an empty page', async () => {
  const calls = [];
  const objects = await listObjects(async (path) => {
    calls.push(path);
    return calls.length === 1 ? { result: [{ id: 'a'.repeat(64), hasStoredData: true }], result_info: { cursor: 'next' } } : { result: [] };
  }, 'account', 'namespace');
  assert.equal(objects.length, 1);
  assert.match(calls[1], /cursor=next/);
});
test('scoped inspection never turns an inventory into a mutation', async () => {
  const calls = [];
  const pages = await inspectObject(async (body) => {
    calls.push(body);
    return { scanned: 1, invalid: 1, fresh: 0, deleted: 0, cursor: calls.length === 1 ? 'next' : null };
  }, { namespace: 'relay', id: 'a'.repeat(64) }, true);
  assert.equal(pages.length, 2);
  assert.ok(calls.every((body) => body.dryRun === true));
  assert.equal(calls[1].cursor, 'next');
});
test('repeating namespace pages fail closed', async () => {
  await assert.rejects(listObjects(async () => ({ result: [{ id: 'a'.repeat(64) }], result_info: { cursor: 'next' } }), 'a', 'b'), /repeated/);
});
