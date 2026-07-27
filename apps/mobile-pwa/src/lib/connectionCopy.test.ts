import { describe, expect, it } from 'vitest';
import { connectionStatusCopy, type ConnectionCopyState } from './connectionCopy';

describe('connectionStatusCopy', () => {
  it('keeps mobile connection states short and product-facing', () => {
    const states: ConnectionCopyState[] = [
      'connecting',
      'reconnecting',
      'cached-reconnecting',
      'offline-cached',
      'offline-retry',
      'screen-stop-pending',
      'screen-stop-delayed',
      'screen-stop-unconfirmed',
      'remote-start-failed',
    ];

    for (const state of states) {
      const copy = connectionStatusCopy(state);
      expect(copy.length).toBeLessThanOrEqual(72);
      expect(copy).not.toMatch(
        /relay|websocket|automatically|cached workspace|latest cached|retry the relay/i,
      );
    }
  });

  it('uses distinct copy for loading, reconnecting, and offline states', () => {
    expect(connectionStatusCopy('connecting')).toBe('Connecting to your Mac.');
    expect(connectionStatusCopy('reconnecting')).toBe('Connection lost. Reconnecting.');
    expect(connectionStatusCopy('offline-cached')).toBe('Mac offline. Showing recent workspace.');
  });

  it('uses actionable copy when screen stop is not confirmed', () => {
    expect(connectionStatusCopy('screen-stop-unconfirmed')).toBe(
      'Screen sharing is still stopping. Keep Glasstunnel open on the Mac.',
    );
  });
});
