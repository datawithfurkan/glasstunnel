export const CACHE_PREFIX = 'gt.relay.cache.';
export const CACHE_TTL_MS = 24 * 60 * 60_000;
const VERSION_PREFIX = `${CACHE_PREFIX}v2.`;
const REVISION_KEY = 'gt.relay.cacheRevision';

export interface CacheTiming { version: 1; receivedAt: number; expiresAt: number }
export interface OfflineItem extends CacheTiming { data: unknown }
interface Copy { version: 2; accountId: string; hostId: string; items: Record<string, OfflineItem> }
interface Storage {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<unknown>;
  del(key: string): Promise<unknown>;
  keys(): Promise<IDBValidKey[]>;
}

export function cacheKey(account: string, host: string): string {
  return `${VERSION_PREFIX}${JSON.stringify([account, host])}`;
}

export function validCacheTiming(value: unknown, now = Date.now()): value is CacheTiming {
  if (!value || typeof value !== 'object') return false;
  const item = value as CacheTiming;
  return item.version === 1 && Number.isSafeInteger(item.receivedAt) && item.receivedAt > 0 &&
    item.receivedAt <= now && Number.isSafeInteger(item.expiresAt) && item.expiresAt > now &&
    item.expiresAt > item.receivedAt && item.expiresAt - item.receivedAt <= CACHE_TTL_MS;
}

// One serialized lane plus Web Locks across tabs. A durable revision prevents a
// previously opened tab from rewriting copies erased by another tab's logout.
export class OfflineCache {
  items: Record<string, OfflineItem> = {};
  private account = '';
  private host = '';
  private generation = 0;
  private revision = 0;
  private tail: Promise<unknown> = Promise.resolve();
  constructor(private readonly db: Storage) {}

  private enqueue<T>(action: () => Promise<T>): Promise<T> {
    const result = this.tail.then(async (): Promise<T> => {
      if (typeof navigator !== 'undefined' && navigator.locks) {
        return await navigator.locks.request('gt-offline-cache', action);
      }
      return action();
    });
    this.tail = result.catch(() => {});
    return result;
  }

  reset(): void { this.generation++; this.items = {}; this.account = ''; this.host = ''; }

  async clearLegacy(): Promise<void> {
    await this.enqueue(async () => {
      for (const key of await this.db.keys()) {
        if (typeof key === 'string' && key.startsWith(CACHE_PREFIX) && !key.startsWith(VERSION_PREFIX)) await this.db.del(key);
      }
    });
  }

  async open(account: string, host: string): Promise<void> {
    if (account && account === this.account && host === this.host) {
      const generation = this.generation;
      await this.flush();
      const revision = Number(await this.db.get(REVISION_KEY)) || 0;
      if (generation !== this.generation) return;
      if (revision === this.revision) { this.prune(); return; }
    }
    this.reset();
    this.account = account;
    this.host = host;
    const generation = this.generation;
    await this.enqueue(async () => {
      if (generation !== this.generation || !account || !host) return;
      this.revision = Number(await this.db.get(REVISION_KEY)) || 0;
      for (const key of await this.db.keys()) {
        if (typeof key === 'string' && key.startsWith(CACHE_PREFIX) && !key.startsWith(VERSION_PREFIX)) await this.db.del(key);
      }
      const key = cacheKey(account, host);
      const value = await this.db.get(key) as Copy | undefined;
      if (generation !== this.generation) return;
      if (!value) return;
      if (value.version !== 2 || value.accountId !== account || value.hostId !== host ||
          !value.items || typeof value.items !== 'object' || Array.isArray(value.items)) {
        await this.db.del(key);
        return;
      }
      this.items = Object.fromEntries(Object.entries(value.items).filter(([name, item]) =>
        this.allowedItem(name) && validCacheTiming(item) && Object.hasOwn(item, 'data')));
      if (Object.keys(this.items).length) await this.db.set(key, { ...value, items: this.items });
      else await this.db.del(key);
    });
  }

  private allowedItem(key: string): boolean {
    return ['hello', 'apps', 'layout'].includes(key) || key.startsWith('agent:');
  }

  receive(key: string, data: unknown, cached: boolean, timing?: CacheTiming): boolean {
    const now = Date.now();
    if (!this.allowedItem(key) || (cached && !validCacheTiming(timing, now))) return false;
    // A supplied but invalid deadline must not silently become a fresh copy.
    if (timing !== undefined && !validCacheTiming(timing, now)) return false;
    const receipt = timing ?? { version: 1 as const, receivedAt: now, expiresAt: now + CACHE_TTL_MS };
    this.items = { ...this.items, [key]: { ...receipt, data } };
    this.save();
    return true;
  }

  prune(): string[] {
    const expired = Object.keys(this.items).filter((key) => !validCacheTiming(this.items[key]));
    this.remove(expired);
    return expired;
  }

  remove(keys: string[]): void {
    if (!keys.length) return;
    this.items = Object.fromEntries(Object.entries(this.items).filter(([key]) => !keys.includes(key)));
    this.save();
  }

  private save(): void {
    if (!this.account || !this.host) return;
    const generation = this.generation;
    const revision = this.revision;
    const key = cacheKey(this.account, this.host);
    const value: Copy = { version: 2, accountId: this.account, hostId: this.host, items: this.items };
    void this.enqueue(async () => {
      if (generation !== this.generation || (Number(await this.db.get(REVISION_KEY)) || 0) !== revision) return;
      if (Object.keys(value.items).length) await this.db.set(key, value);
      else await this.db.del(key);
      if (generation !== this.generation) await this.db.del(key);
    }).catch(() => { /* Storage failure must not break a live session. */ });
  }

  async clear(account?: string, host?: string): Promise<void> {
    this.generation++;
    const generation = this.generation;
    if ((!account || account === this.account) && (!host || host === this.host)) this.items = {};
    await this.enqueue(async () => {
      const revision = (Number(await this.db.get(REVISION_KEY)) || 0) + 1;
      await this.db.set(REVISION_KEY, revision);
      if (generation === this.generation) this.revision = revision;
      for (const key of await this.db.keys()) {
        if (typeof key !== 'string' || !key.startsWith(CACHE_PREFIX)) continue;
        let scope: unknown;
        try { scope = JSON.parse(key.slice(VERSION_PREFIX.length)); } catch { /* legacy */ }
        if (!key.startsWith(VERSION_PREFIX) || !Array.isArray(scope) ||
          ((!account || scope[0] === account) && (!host || scope[1] === host))) await this.db.del(key);
      }
    });
  }

  async flush(): Promise<void> { await this.tail; }
}
