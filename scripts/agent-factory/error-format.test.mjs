import assert from 'node:assert/strict';
import test from 'node:test';
import { formatError } from './error-format.mjs';

test('nested factory failures retain concise operation and cleanup causes', () => {
  const error = new AggregateError(
    [
      new Error('launching canary: worker failed'),
      new AggregateError(
        [new Error('closing lease: store is read-only')],
        'cleanup failed',
      ),
    ],
    'Canary failed and cleanup was incomplete',
  );

  assert.equal(
    formatError(error),
    [
      'Canary failed and cleanup was incomplete',
      '- launching canary: worker failed',
      '- cleanup failed',
      '  - closing lease: store is read-only',
    ].join('\n'),
  );
});
