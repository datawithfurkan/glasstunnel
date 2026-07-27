import { describe, expect, it } from 'vitest';
import { formatMessageTimestamp } from './messageTimestamp';

describe('formatMessageTimestamp', () => {
  it('uses compact time for messages created today', () => {
    const timestamp = formatMessageTimestamp(Date.UTC(2026, 4, 17, 9, 48), {
      locale: 'en-GB',
      now: new Date(Date.UTC(2026, 4, 17, 13, 0)),
      timeZone: 'UTC',
    });

    expect(timestamp?.label).toBe('09:48');
    expect(timestamp?.iso).toBe('2026-05-17T09:48:00.000Z');
  });

  it('uses 24-hour time even in locales that normally use AM/PM', () => {
    const timestamp = formatMessageTimestamp(Date.UTC(2026, 4, 17, 22, 33), {
      locale: 'en-US',
      now: new Date(Date.UTC(2026, 4, 17, 23, 0)),
      timeZone: 'UTC',
    });

    expect(timestamp?.label).toBe('22:33');
    expect(timestamp?.full).not.toMatch(/AM|PM/i);
  });

  it('adds date context for older messages', () => {
    const timestamp = formatMessageTimestamp(Date.UTC(2026, 4, 16, 15, 2), {
      locale: 'en-GB',
      now: new Date(Date.UTC(2026, 4, 17, 13, 0)),
      timeZone: 'UTC',
    });

    expect(timestamp?.label).toBe('16 May, 15:02');
  });

  it('adds the year for messages outside the current year', () => {
    const timestamp = formatMessageTimestamp(Date.UTC(2025, 11, 31, 23, 59), {
      locale: 'en-GB',
      now: new Date(Date.UTC(2026, 4, 17, 13, 0)),
      timeZone: 'UTC',
    });

    expect(timestamp?.label).toBe('31 Dec 2025, 23:59');
  });

  it('hides invalid timestamps', () => {
    expect(formatMessageTimestamp(0)).toBeNull();
    expect(formatMessageTimestamp(Number.NaN)).toBeNull();
  });
});
