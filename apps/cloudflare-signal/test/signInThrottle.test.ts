import { describe, expect, it } from 'vitest';
import {
  FORGET_AFTER_MS,
  FREE_FAILURES,
  MAX_DELAY_MS,
  delayAfterFailures,
  recordAfterFailure,
  retryAfterMessage,
  retryAfterMs,
  signInEmailKey,
  type SignInThrottleRecord,
} from '../../../convex/signInThrottle';

const MINUTE = 60_000;

describe('sign-in throttle', () => {
  it('lets the first five wrong passwords through, then doubles the wait up to 15 minutes', () => {
    expect([1, 2, 3, 4, 5].map(delayAfterFailures)).toEqual([0, 0, 0, 0, 0]);
    expect(delayAfterFailures(FREE_FAILURES + 1)).toBe(30_000);
    expect(delayAfterFailures(FREE_FAILURES + 2)).toBe(60_000);
    expect(delayAfterFailures(FREE_FAILURES + 5)).toBe(8 * MINUTE);
    expect(delayAfterFailures(FREE_FAILURES + 6)).toBe(MAX_DELAY_MS);
    expect(delayAfterFailures(1_000)).toBe(MAX_DELAY_MS);
  });

  it('counts failures in a row and makes the next try wait', () => {
    let record: SignInThrottleRecord | null = null;
    const now = 1_800_000_000_000;
    for (let i = 0; i < FREE_FAILURES; i++) record = recordAfterFailure(record, now);
    expect(record).toEqual({ failures: 5, lastFailureAt: now, lockedUntil: now });
    expect(retryAfterMs(record, now)).toBe(0);

    record = recordAfterFailure(record, now);
    expect(retryAfterMs(record, now)).toBe(30_000);
    expect(retryAfterMs(record, now + 10_000)).toBe(20_000);
    expect(retryAfterMs(record, now + 30_000)).toBe(0);
  });

  it('forgets an address a day after its last wrong password', () => {
    const now = 1_800_000_000_000;
    const stale: SignInThrottleRecord = { failures: 40, lastFailureAt: now, lockedUntil: now + MAX_DELAY_MS };
    expect(retryAfterMs(stale, now + FORGET_AFTER_MS + 1)).toBe(0);
    expect(recordAfterFailure(stale, now + FORGET_AFTER_MS + 1).failures).toBe(1);
    expect(retryAfterMs(null, now)).toBe(0);
  });

  it('says how long to wait in whole minutes', () => {
    expect(retryAfterMessage(30_000)).toBe(
      'Too many sign-in attempts for this email. Try again in 1 minute, or reset your password.',
    );
    expect(retryAfterMessage(14 * MINUTE + 1)).toContain('Try again in 15 minutes');
  });

  it('keys on a hash of the address, the same for any case or spacing', async () => {
    const key = await signInEmailKey('  Alice@Example.COM ');
    expect(key).toBe(await signInEmailKey('alice@example.com'));
    expect(key).toMatch(/^[0-9a-f]{64}$/);
    expect(key).not.toContain('alice');
  });
});
