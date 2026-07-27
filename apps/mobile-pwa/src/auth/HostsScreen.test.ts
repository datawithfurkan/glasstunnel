import { describe, expect, it, vi } from 'vitest';
import type { AccountHost } from '../lib/accountApi';
import {
  claimLinkedHostAndOpen,
  hostActionAvailable,
  hostActionLabel,
  hostEmptyStateCopy,
  hostEmptyStateTitle,
  hostRefreshButtonLabel,
} from './HostsScreen';

describe('HostsScreen host actions', () => {
  it('uses product-facing labels for host state', () => {
    expect(hostActionLabel({ online: true, trusted: true }, false)).toBe('Open');
    expect(hostActionLabel({ online: false, trusted: true }, false)).toBe('View only');
    expect(hostActionLabel({ online: true, trusted: false }, false)).toBe('Connect');
    expect(hostActionLabel({ online: false, trusted: false }, false)).toBe('Preparing');
    expect(hostActionLabel({ online: true, trusted: true }, true)).toBe('Opening…');
  });

  it('allows online same-account hosts to open even while trust catches up', () => {
    expect(hostActionAvailable({ online: true, trusted: true }, false)).toBe(true);
    expect(hostActionAvailable({ online: false, trusted: true }, false)).toBe(true);
    expect(hostActionAvailable({ online: true, trusted: true }, true)).toBe(false);
    expect(hostActionAvailable({ online: true, trusted: false }, false)).toBe(true);
    expect(hostActionAvailable({ online: false, trusted: false }, false)).toBe(false);
  });

  it('does not expose cache terminology in primary host actions', () => {
    const labels = [
      hostActionLabel({ online: true, trusted: true }, false),
      hostActionLabel({ online: false, trusted: true }, false),
      hostActionLabel({ online: true, trusted: false }, false),
      hostActionLabel({ online: false, trusted: false }, false),
    ];

    expect(labels.join(' ')).not.toMatch(/cache/i);
  });

  it('shows visible refresh progress copy', () => {
    expect(hostRefreshButtonLabel(false)).toBe('Refresh');
    expect(hostRefreshButtonLabel(true)).toBe('Refreshing…');
  });

  it('keeps the no-Mac empty state short, actionable, and product-facing', () => {
    expect(hostEmptyStateTitle()).toBe('Add this Mac');
    expect(hostEmptyStateCopy()).toBe('Enter the code shown on your Mac.');
    expect(`${hostEmptyStateTitle()} ${hostEmptyStateCopy()}`).not.toMatch(
      /relay|websocket|host device|protocol|transport|cache|snapshot|adapter/i,
    );
    expect(hostEmptyStateCopy().length).toBeLessThanOrEqual(42);
  });

  it('opens the claimed Mac directly after a link-code claim', async () => {
    const claimedHost: AccountHost = {
      deviceId: 'claimed-opencode-host',
      label: 'OpenCode iOS Safari',
      publicKeyB64: 'claimed-key',
      signalingUrl: 'wss://signal.example/signal',
      online: true,
      trusted: true,
      pairedAtUnixMs: 1_781_000_000_000,
    };
    const claimHostLinkCode = vi.fn(async () => claimedHost);
    const chooseHost = vi.fn(async () => undefined);
    const setLinkCode = vi.fn();
    const setStatus = vi.fn();
    const setError = vi.fn();
    const setLinking = vi.fn();

    await claimLinkedHostAndOpen('ABC123', {
      claimHostLinkCode,
      chooseHost,
      setLinkCode,
      setStatus,
      setError,
      setLinking,
    });

    expect(claimHostLinkCode).toHaveBeenCalledWith('ABC123');
    expect(chooseHost).toHaveBeenCalledWith('claimed-opencode-host');
    expect(setLinkCode).toHaveBeenCalledWith('');
    expect(setStatus).toHaveBeenCalledWith('Mac added. Opening…');
    expect(setError).toHaveBeenCalledWith(null);
    expect(setLinking).toHaveBeenNthCalledWith(1, true);
    expect(setLinking).toHaveBeenLastCalledWith(false);
  });

  it('does not auto-open a claimed Mac until the relay workspace is online', async () => {
    const claimedHost: AccountHost = {
      deviceId: 'claimed-opencode-host',
      label: 'OpenCode iOS Safari',
      publicKeyB64: 'claimed-key',
      signalingUrl: 'wss://signal.example/signal',
      online: false,
      trusted: true,
      pairedAtUnixMs: 1_781_000_000_000,
    };
    const claimHostLinkCode = vi.fn(async () => claimedHost);
    const chooseHost = vi.fn(async () => undefined);
    const setLinkCode = vi.fn();
    const setStatus = vi.fn();
    const setError = vi.fn();
    const setLinking = vi.fn();

    await claimLinkedHostAndOpen('ABC123', {
      claimHostLinkCode,
      chooseHost,
      setLinkCode,
      setStatus,
      setError,
      setLinking,
    });

    expect(claimHostLinkCode).toHaveBeenCalledWith('ABC123');
    expect(chooseHost).not.toHaveBeenCalled();
    expect(setLinkCode).toHaveBeenCalledWith('');
    expect(setStatus).toHaveBeenCalledWith('Mac added. Waiting for this Mac…');
    expect(setLinking).toHaveBeenNthCalledWith(1, true);
    expect(setLinking).toHaveBeenLastCalledWith(false);
  });
});
