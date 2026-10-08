import { AccountApiError, isAccountApiAuthFailure } from './accountApi';

/** The longest name a Mac can have in an account (the server enforces the same). */
export const HOST_LABEL_MAX_LENGTH = 40;

/** How many characters of a device ID identify a Mac in the details view. */
export const DEVICE_FINGERPRINT_LENGTH = 12;

/**
 * The reason the relay gives when it closes a browser's socket (code 4003)
 * because the Mac was removed from the account, as opposed to a revocation of
 * this browser's access.
 */
export const HOST_REMOVED_RELAY_REASON = 'mac removed from account';

export const HOST_MANAGEMENT_COPY = {
  emptyLabel: 'Enter a name.',
  labelTooLong: `Use ${HOST_LABEL_MAX_LENGTH} characters or fewer.`,
  labelHiddenCharacters: 'Remove hidden characters from the name.',
  removedNotice: 'This Mac was removed from your account.',
  removedNoticeCacheFailed:
    'This Mac was removed from your account. Browser offline copies could not be cleared; retry in Profile.',
  notFound: 'This Mac is no longer in your account.',
  sessionExpired: 'Your session expired. Sign out and sign in again to manage your Macs.',
  unavailable: "Glasstunnel can't update your account right now. Try again in a moment.",
  busy: 'Too many changes at once. Try again in a moment.',
  offline: "Couldn't reach Glasstunnel. Check your connection and try again.",
  renameFailed: "Couldn't rename this Mac. Try again.",
  removeFailed: "Couldn't remove this Mac. Try again.",
  invalidLabelFallback: "That name can't be used. Try a different one.",
} as const;

export function renamedStatus(label: string): string {
  return `Renamed to ${label}.`;
}

export function removedStatus(label: string): string {
  return `Removed ${label} from your account.`;
}

export type HostLabelValidation = { ok: true; label: string } | { ok: false; error: string };

/**
 * Characters a Mac's name cannot hold: control characters (C0, DEL and C1:
 * tabs, line breaks, escapes), the Unicode line and paragraph separators,
 * the bidirectional controls (U+202A-U+202E, U+2066-U+2069, U+200E, U+200F)
 * and the invisible U+200B, U+2060 and U+FEFF. The zero-width joiner and
 * non-joiner (U+200D, U+200C) stay allowed: emoji sequences and Persian names
 * need them. The Worker and Convex refuse the same set, and the Mac app drops
 * it when it shows the name.
 */
const HOST_LABEL_FORBIDDEN = /[\p{Cc}\u2028\u2029\u202A-\u202E\u2066-\u2069\u200E\u200F\u200B\u2060\uFEFF]/u;
const HOST_LABEL_FORBIDDEN_ALL = new RegExp(HOST_LABEL_FORBIDDEN.source, 'gu');

/**
 * A Mac's name as the account stores it: NFC-normalized, trimmed, 1 to 40
 * Unicode code points (an emoji made of two UTF-16 units counts once), and
 * none of the forbidden characters above. The Worker and Convex apply the
 * same rule, in the same order, with the same messages.
 */
export function validateHostLabel(input: string): HostLabelValidation {
  const label = input.normalize('NFC').trim();
  if (!label) return { ok: false, error: HOST_MANAGEMENT_COPY.emptyLabel };
  if (HOST_LABEL_FORBIDDEN.test(label)) return { ok: false, error: HOST_MANAGEMENT_COPY.labelHiddenCharacters };
  if (Array.from(label).length > HOST_LABEL_MAX_LENGTH) return { ok: false, error: HOST_MANAGEMENT_COPY.labelTooLong };
  return { ok: true, label };
}

/**
 * What the name field keeps of typed or pasted text: the characters a name
 * cannot hold (a pasted line break or tab, an invisible zero-width space, a
 * direction override) never reach the field. The text is not normalized here,
 * so an input method's composition stays as typed; validateHostLabel
 * normalizes it on save.
 */
export function sanitizeHostLabelInput(value: string): string {
  return value.replace(HOST_LABEL_FORBIDDEN_ALL, '');
}

/** A short, stable way to tell two Macs with the same name apart. */
export function deviceFingerprint(deviceId: string): string {
  return deviceId.slice(0, DEVICE_FINGERPRINT_LENGTH);
}

/**
 * Labels shared by more than one Mac in the list, compared as hostLabelKey
 * does, so two names that look the same on screen count as one.
 */
export function duplicateHostLabels(hosts: ReadonlyArray<{ label: string }>): Set<string> {
  const seen = new Set<string>();
  const duplicates = new Set<string>();
  for (const host of hosts) {
    const key = hostLabelKey(host.label);
    if (seen.has(key)) duplicates.add(key);
    seen.add(key);
  }
  return duplicates;
}

/**
 * A name as it looks on screen: NFC-normalized, without the invisible and
 * direction-control characters a name cannot hold (an older name may still
 * have them), without outer spaces, and without case.
 */
export function hostLabelKey(label: string): string {
  return label.normalize('NFC').replace(HOST_LABEL_FORBIDDEN_ALL, '').trim().toLocaleLowerCase();
}

const SERVER_LABEL_ERRORS = new Set<string>([
  HOST_MANAGEMENT_COPY.emptyLabel,
  HOST_MANAGEMENT_COPY.labelTooLong,
  HOST_MANAGEMENT_COPY.labelHiddenCharacters,
]);

export type HostAction = 'rename' | 'remove';

/**
 * The server's one answer for a Mac outside the caller's account: a missing
 * device, another account's Mac, a revoked row, a phone or a browser.
 */
export const HOST_NOT_FOUND_SERVER_MESSAGE = 'Mac not found';

/**
 * Whether the server said this Mac is not in the account. Only the exact 404
 * "Mac not found" counts: any other 404 (an older Worker without the rename
 * and remove routes answers "not found") says nothing about the Mac.
 */
export function isHostNotInAccount(error: unknown): boolean {
  return error instanceof AccountApiError && error.status === 404 && error.message === HOST_NOT_FOUND_SERVER_MESSAGE;
}

/**
 * Friendly copy for a failed rename or removal. The server answers 404 "Mac
 * not found" for a Mac that is not in this account (whatever the reason), 400
 * for a name it will not store, and 503 when the account service is
 * unavailable. Anything else gets the general line for the action.
 */
export function hostActionErrorCopy(action: HostAction, error: unknown): string {
  if (isAccountApiAuthFailure(error)) return HOST_MANAGEMENT_COPY.sessionExpired;
  // No session at all (signed out in another tab, or the session store is gone).
  if (!(error instanceof AccountApiError) && /sign in again/i.test(errorMessage(error))) {
    return HOST_MANAGEMENT_COPY.sessionExpired;
  }
  if (isHostNotInAccount(error)) return HOST_MANAGEMENT_COPY.notFound;
  if (error instanceof AccountApiError) {
    if (error.status === 400 && action === 'rename') {
      return SERVER_LABEL_ERRORS.has(error.message) ? error.message : HOST_MANAGEMENT_COPY.invalidLabelFallback;
    }
    if (error.status === 429) return HOST_MANAGEMENT_COPY.busy;
    if (error.status >= 500) return HOST_MANAGEMENT_COPY.unavailable;
  }
  if (isNetworkFailure(error)) return HOST_MANAGEMENT_COPY.offline;
  return action === 'rename' ? HOST_MANAGEMENT_COPY.renameFailed : HOST_MANAGEMENT_COPY.removeFailed;
}

/** A request that never got an answer: the change may or may not have happened. */
export function isNetworkFailure(error: unknown): boolean {
  if (error instanceof AccountApiError) return false;
  // A timed-out request aborts with a DOMException, which older engines do not make an Error.
  const name = error && typeof error === 'object' ? (error as { name?: unknown }).name : undefined;
  if (name === 'AbortError' || name === 'TimeoutError') return true;
  return error instanceof TypeError || /failed to fetch|network|load failed|timed out/i.test(errorMessage(error));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
