/**
 * Slows password guessing on email sign-in, per email address. The auth
 * endpoints are served by Convex directly (not through the Worker) and see no
 * trusted client IP, so the throttle keys on the address instead: the first
 * FREE_FAILURES wrong passwords cost nothing, then every further failure
 * doubles the wait before the next try, up to MAX_DELAY_MS. A correct password
 * clears the record, and a record with no failure for a day is forgotten.
 *
 * Someone who knows an address can keep it waiting too; Google, GitHub, and
 * password reset still sign the owner in. Records hold a SHA-256 of the
 * address, never the address.
 */

export const FREE_FAILURES = 5;
export const FIRST_DELAY_MS = 30_000;
export const MAX_DELAY_MS = 15 * 60_000;
export const FORGET_AFTER_MS = 24 * 60 * 60_000;

export type SignInThrottleRecord = {
  failures: number;
  lastFailureAt: number;
  lockedUntil: number;
};

/** The wait after the `failures`-th wrong password in a row. */
export function delayAfterFailures(failures: number): number {
  if (failures <= FREE_FAILURES) return 0;
  return Math.min(FIRST_DELAY_MS * 2 ** (failures - FREE_FAILURES - 1), MAX_DELAY_MS);
}

/** The record after one more wrong password at `now`. */
export function recordAfterFailure(previous: SignInThrottleRecord | null, now: number): SignInThrottleRecord {
  const forgotten = !previous || now - previous.lastFailureAt > FORGET_AFTER_MS;
  const failures = (forgotten ? 0 : previous.failures) + 1;
  return { failures, lastFailureAt: now, lockedUntil: now + delayAfterFailures(failures) };
}

/** How long a sign-in for this address must still wait, 0 when it may try. */
export function retryAfterMs(record: SignInThrottleRecord | null, now: number): number {
  if (!record || now - record.lastFailureAt > FORGET_AFTER_MS) return 0;
  return Math.max(0, record.lockedUntil - now);
}

export function retryAfterMessage(ms: number): string {
  const minutes = Math.max(1, Math.ceil(ms / 60_000));
  const wait = minutes === 1 ? "1 minute" : `${minutes} minutes`;
  return `Too many sign-in attempts for this email. Try again in ${wait}, or reset your password.`;
}

/** The throttle key for an address: hex SHA-256 of the trimmed, lowercased address. */
export async function signInEmailKey(email: string): Promise<string> {
  const bytes = new TextEncoder().encode(email.trim().toLowerCase());
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
