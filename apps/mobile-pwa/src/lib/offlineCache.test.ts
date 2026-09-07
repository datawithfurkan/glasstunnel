import { describe, expect, it, vi } from 'vitest';
import { OfflineCache, CACHE_PREFIX, CACHE_TTL_MS, cacheKey } from './offlineCache';

function fixture() {
  const data = new Map<string, unknown>();
  const db = { get: async (key: string) => data.get(key),
    set: vi.fn(async (key: string, value: unknown) => { data.set(key, value); }),
    del: async (key: string) => { data.delete(key); }, keys: async () => [...data.keys()] };
  return { data, db, cache: new OfflineCache(db) };
}

describe('account scoped offline copies', () => {
  it('prevents an already open tab from rewriting a cleared copy', async () => {
    const { cache, data, db } = fixture();
    const other = new OfflineCache(db);
    await cache.open('a', 'host');
    await other.open('a', 'host');
    await cache.clear('a');
    other.receive('hello', { stale: true }, false);
    await other.flush();
    expect(data.has(cacheKey('a', 'host'))).toBe(false);
  });
  it('expires per item and neither replay nor reload renews it', async () => {
    vi.useFakeTimers();
    try {
      const { cache, db } = fixture();
      await cache.open('a', 'host');
      expect(cache.receive('agent:old', { text: 'old' }, false)).toBe(true);
      const first = cache.items['agent:old'];
      await vi.advanceTimersByTimeAsync(1000);
      cache.receive('agent:new', { text: 'new' }, false);
      cache.receive('agent:old', { text: 'old' }, true, first);
      await cache.flush();
      const restored = new OfflineCache(db);
      await restored.open('a', 'host');
      expect(restored.items['agent:old'].expiresAt).toBe(first.expiresAt);
      await vi.advanceTimersByTimeAsync(CACHE_TTL_MS - 1000);
      expect(restored.prune()).toEqual(['agent:old']);
      expect(Object.keys(restored.items)).toEqual(['agent:new']);
    } finally { vi.useRealTimers(); }
  });

  it('discards legacy and wrong-owner records but preserves unrelated credentials', async () => {
    const { cache, data } = fixture();
    data.set(`${CACHE_PREFIX}old-host`, { agents: { secret: 'legacy' } });
    data.set('gt.phoneKeypair', { private: 'fixture' });
    await cache.open('a', 'host');
    cache.receive('agent:a', { text: 'account a' }, false);
    await cache.flush();
    data.set(cacheKey('b', 'host'), data.get(cacheKey('a', 'host')));
    await cache.open('b', 'host');
    expect(cache.items).toEqual({});
    expect(data.has(`${CACHE_PREFIX}old-host`)).toBe(false);
    expect(data.has(cacheKey('b', 'host'))).toBe(false);
    expect(data.has(cacheKey('a', 'host'))).toBe(true);
    expect(data.get('gt.phoneKeypair')).toEqual({ private: 'fixture' });
  });

  it('rejects cached replays without a valid deadline and caps live retention', async () => {
    const { cache } = fixture();
    await cache.open('a', 'host');
    expect(cache.receive('hello', {}, true)).toBe(false);
    expect(cache.receive('hello', {}, true, { version: 1, receivedAt: 0, expiresAt: Infinity })).toBe(false);
    const now = Date.now();
    expect(cache.receive('hello', {}, false, { version: 1, receivedAt: now - 100, expiresAt: now + 100 })).toBe(true);
    expect(cache.items.hello.expiresAt).toBe(now + 100);
  });

  it.each(['clear', 'reset'] as const)('does not resurrect a delayed write after %s', async (operation) => {
    const { cache, data, db } = fixture();
    await cache.open('a', 'host');
    let finish!: () => void;
    let started!: () => void;
    const writing = new Promise<void>((resolve) => { started = resolve; });
    db.set.mockImplementationOnce(async (key, value) => {
      started();
      await new Promise<void>((resolve) => { finish = resolve; });
      data.set(key, value);
    });
    cache.receive('hello', { text: 'private' }, false);
    await writing;
    const clear = operation === 'clear' ? cache.clear('a') : (cache.reset(), cache.clear('a'));
    finish();
    await clear;
    await cache.flush();
    expect(data.has(cacheKey('a', 'host'))).toBe(false);
    expect(cache.items).toEqual({});
  });

  it('reports a failed clear rather than claiming deletion', async () => {
    const { cache, db } = fixture();
    await cache.open('a', 'host');
    cache.receive('hello', {}, false);
    await cache.flush();
    db.del = async () => { throw new Error('storage unavailable'); };
    await expect(cache.clear('a')).rejects.toThrow('storage unavailable');
  });
});
