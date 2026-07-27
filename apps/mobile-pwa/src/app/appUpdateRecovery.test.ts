import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import {
  APP_UPDATE_REQUIRED_COPY,
  APP_UPDATE_REQUIRED_EVENT,
  installAppUpdateRecovery,
} from './appUpdateRecovery';

class MemoryStorage {
  private readonly values = new Map<string, string>();

  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }
}

describe('app update recovery', () => {
  it('provides a concise manual recovery state when reloading cannot recover', () => {
    expect(APP_UPDATE_REQUIRED_COPY).toEqual({
      title: 'Refresh Glasstunnel',
      detail: 'A new version is ready. Refresh to continue.',
      action: 'Refresh',
    });
  });

  it('ships revalidation headers for the app shell and service worker', () => {
    const headers = readFileSync(new URL('../../public/_headers', import.meta.url), 'utf8');

    expect(headers).toContain('/index.html');
    expect(headers).toContain('/sw.js');
    expect(headers.match(/Cache-Control: public, no-cache, must-revalidate/g)).toHaveLength(3);
  });

  it('reloads once when Vite reports a missing deployment chunk', () => {
    const target = new EventTarget();
    const storage = new MemoryStorage();
    const reload = vi.fn();
    const cleanup = installAppUpdateRecovery({
      target,
      storage,
      reload,
      now: () => 10_000,
      scheduleStableReset: () => 1,
      cancelStableReset: () => undefined,
    });
    const event = new Event('vite:preloadError', { cancelable: true });

    target.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(reload).toHaveBeenCalledTimes(1);
    cleanup();
  });

  it('shows a refresh action instead of entering an automatic reload loop', () => {
    const target = new EventTarget();
    const storage = new MemoryStorage();
    const reload = vi.fn();
    const updateRequired = vi.fn();
    target.addEventListener(APP_UPDATE_REQUIRED_EVENT, updateRequired);
    const cleanup = installAppUpdateRecovery({
      target,
      storage,
      reload,
      now: () => 10_000,
      scheduleStableReset: () => 1,
      cancelStableReset: () => undefined,
    });

    target.dispatchEvent(new Event('vite:preloadError', { cancelable: true }));
    target.dispatchEvent(new Event('vite:preloadError', { cancelable: true }));

    expect(reload).toHaveBeenCalledTimes(1);
    expect(updateRequired).toHaveBeenCalledTimes(1);
    cleanup();
  });

  it('allows a later recovery after the refreshed app stays stable', () => {
    const storage = new MemoryStorage();
    const reload = vi.fn();
    const firstTarget = new EventTarget();
    const firstCleanup = installAppUpdateRecovery({
      target: firstTarget,
      storage,
      reload,
      now: () => 10_000,
      scheduleStableReset: () => 1,
      cancelStableReset: () => undefined,
    });
    firstTarget.dispatchEvent(new Event('vite:preloadError', { cancelable: true }));
    firstCleanup();

    const refreshedTarget = new EventTarget();
    let reset: (() => void) | undefined;
    const cleanup = installAppUpdateRecovery({
      target: refreshedTarget,
      storage,
      reload,
      now: () => 10_000,
      scheduleStableReset: (callback) => {
        reset = callback;
        return 1;
      },
      cancelStableReset: () => undefined,
    });

    reset?.();
    refreshedTarget.dispatchEvent(new Event('vite:preloadError', { cancelable: true }));

    expect(reload).toHaveBeenCalledTimes(2);
    cleanup();
  });
});
