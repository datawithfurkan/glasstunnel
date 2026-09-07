import { describe, expect, it } from 'vitest';
import { cacheRecord, validCacheRecord, CACHE_TTL_MS } from '../src/contentRetention';

describe('content retention envelope', () => {
  const now = 1_800_000_000_000;
  it('expires strictly at 24 hours without refreshing on reads', () => {
    const record = cacheRecord({ text: 'fixture' }, now);
    expect(validCacheRecord(record, now + CACHE_TTL_MS - 1)).toBe(true);
    expect(validCacheRecord(record, now + CACHE_TTL_MS)).toBe(false);
    expect(validCacheRecord(record, now + CACHE_TTL_MS + 1)).toBe(false);
    expect(record.receivedAt).toBe(now);
  });
  it.each([null, {}, { data: 'legacy' },
    { version: 1, receivedAt: 0, expiresAt: now, data: {} },
    { version: 1, receivedAt: now + 1, expiresAt: now + 100, data: {} },
    { version: 1, receivedAt: NaN, expiresAt: Infinity, data: {} },
    { version: 1, receivedAt: now, expiresAt: now + CACHE_TTL_MS + 1, data: {} },
    { version: 1, receivedAt: now, expiresAt: now + 1 },
  ])('rejects invalid or unverifiable records %#', (record) => {
    expect(validCacheRecord(record, now)).toBe(false);
  });
});
