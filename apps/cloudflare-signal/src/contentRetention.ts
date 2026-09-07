export const CACHE_TTL_MS = 24 * 60 * 60_000;

export interface CacheRecord<T = unknown> {
  version: 1;
  receivedAt: number;
  expiresAt: number;
  data: T;
}

export function cacheRecord<T>(data: T, now = Date.now()): CacheRecord<T> {
  return { version: 1, receivedAt: now, expiresAt: now + CACHE_TTL_MS, data };
}

export function validCacheRecord(value: unknown, now = Date.now()): value is CacheRecord {
  if (!value || typeof value !== 'object') return false;
  const record = value as CacheRecord;
  return record.version === 1 && Object.hasOwn(record, 'data') &&
    Number.isSafeInteger(record.receivedAt) && record.receivedAt > 0 && record.receivedAt <= now &&
    Number.isSafeInteger(record.expiresAt) && record.expiresAt > now &&
    record.expiresAt > record.receivedAt && record.expiresAt - record.receivedAt <= CACHE_TTL_MS;
}
