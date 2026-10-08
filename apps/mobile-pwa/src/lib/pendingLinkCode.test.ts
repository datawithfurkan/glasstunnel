import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  PENDING_LINK_CODE_MAX_AGE_MS,
  bindPendingLinkCodeEmail,
  clearPendingLinkCode,
  linkCodeFromUrl,
  moveLinkCodeFromUrl,
  pendingLinkCodeEmail,
  restorePendingLinkCodeForSignIn,
  savePendingLinkCode,
} from './pendingLinkCode';

const KEY = 'gt.pending-link-code';
const NOW = Date.parse('2026-10-08T10:00:00Z');
const EMAIL = 'person@example.test';

function memoryStorage(): Storage {
  const data = new Map<string, string>();
  return {
    get length() {
      return data.size;
    },
    clear: () => data.clear(),
    getItem: (key) => data.get(key) ?? null,
    key: (index) => [...data.keys()][index] ?? null,
    removeItem: (key) => void data.delete(key),
    setItem: (key, value) => void data.set(key, String(value)),
  };
}

let replaced: string[] = [];

function openApp(href: string) {
  const location = { href };
  vi.stubGlobal('window', {
    location,
    history: {
      state: { kept: true },
      replaceState: (_state: unknown, _title: string, url: string) => {
        replaced.push(url);
        location.href = new URL(url, location.href).toString();
      },
    },
  });
}

function stored() {
  return JSON.parse(localStorage.getItem(KEY) ?? 'null');
}

/** Another tab of the same browser: the same storage, its own module state. */
async function otherTab(): Promise<typeof import('./pendingLinkCode')> {
  vi.resetModules();
  return import('./pendingLinkCode');
}

beforeEach(() => {
  replaced = [];
  vi.stubGlobal('localStorage', memoryStorage());
  clearPendingLinkCode();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('Mac linkCode kept through a password reset', () => {
  it('lives exactly as long as the Mac link code (10 minutes)', () => {
    expect(PENDING_LINK_CODE_MAX_AGE_MS).toBe(10 * 60_000);
  });

  it('moves the linkCode out of the address bar with the email typed so far', () => {
    openApp('https://app.test/?linkCode=ABC234&authProvider=email#top');
    expect(linkCodeFromUrl()).toBe('ABC234');
    expect(moveLinkCodeFromUrl(' Person@Example.TEST ', NOW)).toBe(true);
    expect(replaced).toEqual(['/?authProvider=email#top']);
    expect(linkCodeFromUrl()).toBeNull();
    expect(stored()).toEqual({ code: 'ABC234', savedAt: NOW, email: EMAIL });
  });

  it('keeps an empty email until the reset request names one', () => {
    openApp('https://app.test/?linkCode=ABC234');
    expect(moveLinkCodeFromUrl('', NOW)).toBe(true);
    expect(stored()).toEqual({ code: 'ABC234', savedAt: NOW, email: '' });
    expect(pendingLinkCodeEmail(NOW)).toBeNull();
    // Nothing to match yet: no sign-in gets it.
    openApp('https://app.test/');
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + 1_000)).toBeNull();
    expect(replaced).toEqual(['/']);
  });

  it('binds the kept linkCode to the address the reset was sent for, keeping the time it was saved', () => {
    openApp('https://app.test/?linkCode=ABC234');
    moveLinkCodeFromUrl('first@example.test', NOW);
    expect(bindPendingLinkCodeEmail(' Second@Example.test ', NOW + 30_000)).toBe(true);
    expect(stored()).toEqual({ code: 'ABC234', savedAt: NOW, email: 'second@example.test' });
    expect(pendingLinkCodeEmail(NOW + 30_000)).toBe('second@example.test');
    expect(bindPendingLinkCodeEmail('   ', NOW + 30_000)).toBe(false);
    expect(stored().email).toBe('second@example.test');
  });

  it('lets only the tab whose forgot flow moved the code bind it to an address', async () => {
    openApp('https://app.test/?linkCode=ABC234');
    moveLinkCodeFromUrl('owner@example.test', NOW);

    // Another person's unrelated reset in another tab of this browser.
    const second = await otherTab();
    openApp('https://app.test/');
    expect(second.moveLinkCodeFromUrl('', NOW + 1_000)).toBe(false);
    expect(second.bindPendingLinkCodeEmail('someone-else@example.test', NOW + 2_000)).toBe(false);
    expect(stored()).toEqual({ code: 'ABC234', savedAt: NOW, email: 'owner@example.test' });
    expect(second.restorePendingLinkCodeForSignIn('someone-else@example.test', NOW + 3_000)).toBeNull();
    expect(stored()).not.toBeNull();
  });

  it('does not bind a code another Mac flow replaced meanwhile', async () => {
    openApp('https://app.test/?linkCode=ABC234');
    moveLinkCodeFromUrl('first@example.test', NOW);
    const second = await otherTab();
    openApp('https://app.test/?linkCode=XYZ789');
    second.moveLinkCodeFromUrl('second@example.test', NOW + 1_000);
    expect(bindPendingLinkCodeEmail('first@example.test', NOW + 2_000)).toBe(false);
    expect(stored()).toEqual({ code: 'XYZ789', savedAt: NOW + 1_000, email: 'second@example.test' });
  });

  it('restores the linkCode once for a sign-in to the same email, without a reload', () => {
    savePendingLinkCode('ABC234', EMAIL, NOW);
    openApp('https://app.test/?keep=1#top');
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + 60_000)).toBe('ABC234');
    expect(replaced).toEqual(['/?keep=1&linkCode=ABC234#top']);
    expect(window.location.href).toBe('https://app.test/?keep=1&linkCode=ABC234#top');
    expect(localStorage.getItem(KEY)).toBeNull();

    // Used up: a later sign-in restores nothing.
    openApp('https://app.test/');
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + 61_000)).toBeNull();
    expect(replaced).toEqual(['/?keep=1&linkCode=ABC234#top']);
  });

  it('matches the email in any case', () => {
    savePendingLinkCode('ABC234', 'Person@Example.test', NOW);
    expect(stored().email).toBe(EMAIL);
    openApp('https://app.test/');
    expect(restorePendingLinkCodeForSignIn(' PERSON@example.TEST ', NOW + 1_000)).toBe('ABC234');
    expect(replaced).toEqual(['/?linkCode=ABC234']);
  });

  it('never restores for a sign-in to another account, and keeps the entry for its own expiry', () => {
    savePendingLinkCode('ABC234', EMAIL, NOW);
    openApp('https://app.test/');
    for (const other of ['someone-else@example.test', 'person@example.tes', '', null, undefined]) {
      expect(restorePendingLinkCodeForSignIn(other, NOW + 1_000)).toBeNull();
    }
    expect(replaced).toEqual([]);
    expect(stored()).toEqual({ code: 'ABC234', savedAt: NOW, email: EMAIL });
  });

  it('lets only one of two tabs restore it', async () => {
    savePendingLinkCode('ABC234', EMAIL, NOW);
    openApp('https://app.test/');
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + 1_000)).toBe('ABC234');

    const second = await otherTab();
    openApp('https://app.test/');
    expect(second.restorePendingLinkCodeForSignIn(EMAIL, NOW + 2_000)).toBeNull();
    expect(replaced).toEqual(['/?linkCode=ABC234']);
  });

  it('ignores and removes a linkCode older than 10 minutes', () => {
    savePendingLinkCode('ABC234', EMAIL, NOW);
    openApp('https://app.test/');
    expect(pendingLinkCodeEmail(NOW + PENDING_LINK_CODE_MAX_AGE_MS)).toBe(EMAIL);

    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + PENDING_LINK_CODE_MAX_AGE_MS + 1)).toBeNull();
    expect(replaced).toEqual([]);
    expect(localStorage.getItem(KEY)).toBeNull();

    savePendingLinkCode('ABC234', EMAIL, NOW);
    expect(pendingLinkCodeEmail(NOW + PENDING_LINK_CODE_MAX_AGE_MS + 1)).toBeNull();
    expect(localStorage.getItem(KEY)).toBeNull();
  });

  it('keeps a linkCode already in the address bar and the kept one too', () => {
    savePendingLinkCode('OLD111', EMAIL, NOW);
    openApp('https://app.test/?linkCode=NEW222');
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + 1_000)).toBe('NEW222');
    expect(replaced).toEqual([]);
    expect(stored().code).toBe('OLD111');
  });

  it('keeps the stored copy when the address bar cannot be changed', () => {
    savePendingLinkCode('ABC234', EMAIL, NOW);
    vi.stubGlobal('window', {
      location: { href: 'https://app.test/' },
      history: {
        state: null,
        replaceState: () => {
          throw new Error('blocked');
        },
      },
    });
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW + 1_000)).toBeNull();
    expect(stored()).toEqual({ code: 'ABC234', savedAt: NOW, email: EMAIL });
  });

  it('leaves the address bar alone without a usable linkCode or storage', () => {
    savePendingLinkCode('OLD111', EMAIL, NOW);
    openApp('https://app.test/?authProvider=email');
    expect(moveLinkCodeFromUrl(EMAIL, NOW + 1_000)).toBe(false);
    openApp('https://app.test/?linkCode=%3Cscript%3E');
    expect(moveLinkCodeFromUrl(EMAIL, NOW + 1_000)).toBe(false);
    expect(replaced).toEqual([]);
    expect(stored()).toEqual({ code: 'OLD111', savedAt: NOW, email: EMAIL });

    vi.stubGlobal('localStorage', undefined);
    openApp('https://app.test/?linkCode=ABC234');
    expect(moveLinkCodeFromUrl(EMAIL, NOW)).toBe(false);
    expect(linkCodeFromUrl()).toBe('ABC234');
  });

  it('keeps a single copy when the address bar cannot be changed while moving', () => {
    vi.stubGlobal('window', {
      location: { href: 'https://app.test/?linkCode=ABC234' },
      history: {
        state: null,
        replaceState: () => {
          throw new Error('blocked');
        },
      },
    });
    expect(moveLinkCodeFromUrl(EMAIL, NOW)).toBe(false);
    expect(localStorage.getItem(KEY)).toBeNull();
    expect(linkCodeFromUrl()).toBe('ABC234');
    // Nothing moved here, so nothing can be bound.
    expect(bindPendingLinkCodeEmail(EMAIL, NOW)).toBe(false);
  });

  it('ignores and removes malformed entries', () => {
    openApp('https://app.test/');
    for (const raw of [
      '{not json',
      'null',
      '"ABC234"',
      JSON.stringify({ code: 'ABC234', email: EMAIL }),
      JSON.stringify({ code: 'ABC234', savedAt: NOW }),
      JSON.stringify({ code: 42, savedAt: NOW, email: EMAIL }),
      JSON.stringify({ code: '', savedAt: NOW, email: EMAIL }),
      JSON.stringify({ code: 'AB C2/34', savedAt: NOW, email: EMAIL }),
      JSON.stringify({ code: 'ABC234', savedAt: 'yesterday', email: EMAIL }),
      JSON.stringify({ code: 'ABC234', savedAt: NOW, email: 'Person@Example.test' }),
      JSON.stringify({ code: 'ABC234', savedAt: NOW, email: 7 }),
      // Saved "in the future": not something this browser wrote.
      JSON.stringify({ code: 'ABC234', savedAt: NOW + 10 * 60_000, email: EMAIL }),
    ]) {
      localStorage.setItem(KEY, raw);
      expect(restorePendingLinkCodeForSignIn(EMAIL, NOW)).toBeNull();
      expect(localStorage.getItem(KEY)).toBeNull();
    }
    expect(replaced).toEqual([]);
  });

  it('forgets the saved linkCode once that code is claimed, but not for another code', () => {
    savePendingLinkCode('abc234', EMAIL, NOW);
    clearPendingLinkCode('XYZ999');
    expect(localStorage.getItem(KEY)).not.toBeNull();
    clearPendingLinkCode('ABC234');
    expect(localStorage.getItem(KEY)).toBeNull();
  });

  it('forgets the saved linkCode on sign-out, and this tab no longer binds it', () => {
    openApp('https://app.test/?linkCode=ABC234');
    moveLinkCodeFromUrl(EMAIL, NOW);
    clearPendingLinkCode();
    expect(localStorage.getItem(KEY)).toBeNull();
    savePendingLinkCode('ABC234', 'first@example.test', NOW);
    expect(bindPendingLinkCodeEmail(EMAIL, NOW)).toBe(false);
  });

  it('works without storage', () => {
    vi.stubGlobal('localStorage', undefined);
    openApp('https://app.test/?linkCode=ABC234');
    expect(savePendingLinkCode('ABC234', EMAIL, NOW)).toBe(false);
    expect(pendingLinkCodeEmail(NOW)).toBeNull();
    expect(bindPendingLinkCodeEmail(EMAIL, NOW)).toBe(false);
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW)).toBe('ABC234');
    openApp('https://app.test/');
    expect(restorePendingLinkCodeForSignIn(EMAIL, NOW)).toBeNull();
    expect(() => clearPendingLinkCode()).not.toThrow();
  });
});
