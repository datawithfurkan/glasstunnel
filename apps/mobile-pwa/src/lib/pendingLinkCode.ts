// A Mac that starts sign-in opens the browser at `?linkCode=<code>&authProvider=email`.
// When the person then uses "Forgot password?", the reset email opens a new tab
// without that linkCode, so signing in there would never link the Mac. The
// code moves out of the address bar into storage while the forgot flow runs,
// together with the email address the flow is for.
//
// The kept code is bound to that address. It goes back into an address bar
// only when a sign-in made in that same tab (email and password, sign-up, or a
// Google/GitHub return) signs in to an account with exactly that email. Then
// the hosts screen claims it as in the usual Mac flow. A shared browser's
// next, unrelated sign-in (another person, another account) never gets it, and
// a tab that only follows a sign-in made in another tab never does either.
//
// Only one tab holds the code at a time: every signed-in tab with a linkCode
// in its address bar claims it, so the forgot flow's tab gives it up and the
// first restoring sign-in removes the stored copy.

const PENDING_LINK_CODE_KEY = 'gt.pending-link-code';
/**
 * As long as the Mac's link code lives (HOST_LINK_CODE_TTL_MS in
 * apps/cloudflare-signal); a kept code never outlives it.
 */
export const PENDING_LINK_CODE_MAX_AGE_MS = 10 * 60_000;
/** A saved time further ahead than this is not one this browser wrote. */
const CLOCK_SKEW_MS = 60_000;
const LINK_CODE_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const MAX_EMAIL_LENGTH = 320;

interface PendingLinkCode {
  code: string;
  savedAt: number;
  /** The address the forgot flow is for (trimmed, lowercase); empty until known. */
  email: string;
}

/**
 * The code this tab's forgot flow moved out of its own address bar. Only that
 * tab may later bind the kept code to the address a reset was requested for.
 */
let movedHere: string | null = null;

function storage(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

function normalizeLinkCode(value: string | null | undefined): string | null {
  const code = value?.trim() ?? '';
  return LINK_CODE_PATTERN.test(code) ? code : null;
}

function normalizeEmail(value: string | null | undefined): string {
  const email = value?.trim().toLowerCase() ?? '';
  return email.length <= MAX_EMAIL_LENGTH ? email : '';
}

function currentUrl(): URL | null {
  if (typeof window === 'undefined' || !window.location?.href) return null;
  try {
    return new URL(window.location.href);
  } catch {
    return null;
  }
}

function replaceUrl(url: URL): boolean {
  try {
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
    return true;
  } catch {
    return false;
  }
}

/** How the hosts screen compares codes: letters and digits, any case. */
function sameLinkCode(a: string, b: string): boolean {
  const canonical = (value: string) => value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return canonical(a) === canonical(b);
}

function writeEntry(store: Storage, entry: PendingLinkCode): boolean {
  try {
    store.setItem(PENDING_LINK_CODE_KEY, JSON.stringify(entry));
    return true;
  } catch {
    // Storage full or blocked: the Mac can still be linked by typing its code.
    return false;
  }
}

function parseEntry(raw: string): PendingLinkCode | null {
  try {
    const parsed = JSON.parse(raw) as Partial<PendingLinkCode> | null;
    const code = normalizeLinkCode(typeof parsed?.code === 'string' ? parsed.code : null);
    const savedAt = parsed?.savedAt;
    const email = parsed?.email;
    if (!code || typeof savedAt !== 'number' || !Number.isFinite(savedAt) || typeof email !== 'string') return null;
    if (email !== normalizeEmail(email)) return null;
    return { code, savedAt, email };
  } catch {
    return null;
  }
}

/** The kept entry while it is fresh. An expired or malformed entry is removed. */
function readFreshEntry(store: Storage, now: number): PendingLinkCode | null {
  const raw = store.getItem(PENDING_LINK_CODE_KEY);
  if (!raw) return null;
  const entry = parseEntry(raw);
  const age = entry ? now - entry.savedAt : Number.NaN;
  if (!entry || age > PENDING_LINK_CODE_MAX_AGE_MS || age < -CLOCK_SKEW_MS) {
    store.removeItem(PENDING_LINK_CODE_KEY);
    return null;
  }
  return entry;
}

/** The Mac linkCode in the address bar, if any. */
export function linkCodeFromUrl(): string | null {
  return normalizeLinkCode(currentUrl()?.searchParams.get('linkCode'));
}

/**
 * Keeps a Mac linkCode for 10 minutes, bound to `email` (may be empty until
 * the reset request names an address). Without a usable code nothing changes.
 */
export function savePendingLinkCode(code: string | null | undefined, email: string | null | undefined, now = Date.now()): boolean {
  const normalized = normalizeLinkCode(code);
  const store = storage();
  if (!normalized || !store) return false;
  return writeEntry(store, { code: normalized, savedAt: now, email: normalizeEmail(email) });
}

/**
 * Starts the forgot flow's hold on a Mac linkCode: moves it from the address
 * bar into storage (10 minutes) with the email typed so far, so this tab no
 * longer holds it. When it cannot be stored, it stays in the address bar.
 * Returns whether it moved.
 */
export function moveLinkCodeFromUrl(email: string | null | undefined, now = Date.now()): boolean {
  const url = currentUrl();
  const code = normalizeLinkCode(url?.searchParams.get('linkCode'));
  if (!url || !code || !savePendingLinkCode(code, email, now)) return false;
  url.searchParams.delete('linkCode');
  if (!replaceUrl(url)) {
    // The address bar still holds it: keep only that copy.
    clearPendingLinkCode(code);
    return false;
  }
  movedHere = code;
  return true;
}

/**
 * Binds the kept linkCode to the address a reset email was just requested
 * for. Only the tab whose forgot flow moved that code may do this, so another
 * person's reset in another tab of a shared browser cannot claim it. Keeps the
 * time it was saved: the Mac's code does not live longer either.
 */
export function bindPendingLinkCodeEmail(email: string | null | undefined, now = Date.now()): boolean {
  const normalized = normalizeEmail(email);
  if (!movedHere || !normalized) return false;
  try {
    const store = storage();
    if (!store) return false;
    const entry = readFreshEntry(store, now);
    if (!entry || !sameLinkCode(entry.code, movedHere)) return false;
    return writeEntry(store, { ...entry, email: normalized });
  } catch {
    return false;
  }
}

/** The address the kept linkCode is bound to while it is fresh, for prefilling sign-in. */
export function pendingLinkCodeEmail(now = Date.now()): string | null {
  try {
    const store = storage();
    if (!store) return null;
    return readFreshEntry(store, now)?.email || null;
  } catch {
    return null;
  }
}

/**
 * Forgets the kept linkCode; with `code`, only when it is that one (say, once
 * it was claimed). Sign-out forgets it whatever it is.
 */
export function clearPendingLinkCode(code?: string): void {
  if (code === undefined || (movedHere && sameLinkCode(movedHere, code))) movedHere = null;
  try {
    const store = storage();
    if (!store) return;
    if (code !== undefined) {
      const raw = store.getItem(PENDING_LINK_CODE_KEY);
      const entry = raw ? parseEntry(raw) : null;
      if (entry && !sameLinkCode(entry.code, code)) return;
    }
    store.removeItem(PENDING_LINK_CODE_KEY);
  } catch {
    // Nothing stored.
  }
}

/**
 * Called for a sign-in made in this tab. When the kept linkCode is fresh and
 * bound to exactly the signed-in account's email (any case), puts it into this
 * tab's address bar (history.replaceState, no reload, other parameters kept)
 * so the hosts screen claims it, and removes the stored copy, so no other tab
 * can restore it too. For another account it stays untouched until it expires.
 * A linkCode already in the address bar wins. Returns the code now in the
 * address bar, or null.
 */
export function restorePendingLinkCodeForSignIn(signedInEmail: string | null | undefined, now = Date.now()): string | null {
  const url = currentUrl();
  if (!url) return null;
  const present = normalizeLinkCode(url.searchParams.get('linkCode'));
  if (present) return present;
  const email = normalizeEmail(signedInEmail);
  try {
    const store = storage();
    if (!store || !email) return null;
    const entry = readFreshEntry(store, now);
    if (!entry || !entry.email || entry.email !== email) return null;
    // Taken out of storage first, so a second tab finds nothing to restore.
    store.removeItem(PENDING_LINK_CODE_KEY);
    url.searchParams.set('linkCode', entry.code);
    if (!replaceUrl(url)) {
      writeEntry(store, entry);
      return null;
    }
    movedHere = null;
    return entry.code;
  } catch {
    return null;
  }
}
