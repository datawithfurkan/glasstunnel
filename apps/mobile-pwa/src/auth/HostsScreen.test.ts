import { describe, expect, it, vi } from 'vitest';
import type { AccountHost } from '../lib/accountApi';
import {
  claimCodeFromMac,
  claimLinkedHostAndOpen,
  HOST_LIST_COPY,
  hostActionAvailable,
  hostActionLabel,
  hostEmptyStateCopy,
  hostEmptyStateTitle,
  hostListAnnouncement,
  hostListView,
  hostRefreshButtonLabel,
} from './HostsScreen';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}

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

  it('never shows a list that is still loading, or failed, as an account without Macs', () => {
    const view = (hostCount: number, hostsStatus: 'idle' | 'loading' | 'loaded' | 'error', macClaimPending = false) =>
      hostListView({ hostCount, hostsStatus, macClaimPending });

    expect(view(0, 'loading')).toBe('loading');
    expect(view(0, 'error')).toBe('error');
    // Only a list that loaded empty offers the add-a-Mac form.
    expect(view(0, 'loaded')).toBe('empty');
    expect(view(0, 'idle')).toBe('empty');
    // Macs on hand are always listed, also while a refresh runs or after it failed.
    expect(view(3, 'loading')).toBe('hosts');
    expect(view(3, 'error')).toBe('hosts');
    expect(view(3, 'loaded')).toBe('hosts');
  });

  it('keeps the add flow a Mac started available while its claim is pending, as the list loads or fails', () => {
    expect(hostListView({ hostCount: 0, hostsStatus: 'loading', macClaimPending: true })).toBe('empty');
    expect(hostListView({ hostCount: 0, hostsStatus: 'error', macClaimPending: true })).toBe('empty');
    expect(hostListView({ hostCount: 1, hostsStatus: 'loading', macClaimPending: true })).toBe('hosts');
  });

  it.each([
    ['while loading', 'loading', 'loading'],
    ['with error', 'error', 'error'],
  ] as const)('shows the real list state once a Mac-started claim failed %s', async (_label, hostsStatus, expected) => {
    // The address bar had the code, so the add flow showed from the start.
    let macClaimPending = true;
    const claim = deferred<AccountHost>();
    const setError = vi.fn();
    const claiming = claimCodeFromMac('ABC234', {
      setMacClaimPending: (pending) => {
        macClaimPending = pending;
      },
      submitLinkCode: (code) =>
        claimLinkedHostAndOpen(code, {
          claimHostLinkCode: () => claim.promise,
          chooseHost: vi.fn(async () => {}),
          setLinkCode: vi.fn(),
          setStatus: vi.fn(),
          setError,
          setLinking: vi.fn(),
        }),
    });
    expect(hostListView({ hostCount: 0, hostsStatus, macClaimPending })).toBe('empty');

    claim.reject(new Error('This code expired. Show a new code on your Mac.'));
    await claiming;
    expect(setError).toHaveBeenCalledWith('This code expired. Show a new code on your Mac.');
    expect(macClaimPending).toBe(false);
    // Not the "Add this Mac" empty state: the list is still loading, or failed.
    expect(hostListView({ hostCount: 0, hostsStatus, macClaimPending })).toBe(expected);
  });

  it('drops the Mac-started add flow once its claim succeeded too', async () => {
    const pending: boolean[] = [];
    await claimCodeFromMac('ABC234', {
      setMacClaimPending: (value) => pending.push(value),
      submitLinkCode: async () => {},
    });
    expect(pending).toEqual([true, false]);
  });

  it('announces "Loading your Macs…" and then the outcome', () => {
    const say = (view: Parameters<typeof hostListAnnouncement>[0]['view'], hostCount: number, hostsStatus: 'idle' | 'loading' | 'loaded' | 'error') =>
      hostListAnnouncement({ view, hostCount, hostsStatus });
    expect(say('loading', 0, 'loading')).toBe('Loading your Macs…');
    expect(say('hosts', 1, 'loaded')).toBe('1 Mac listed.');
    expect(say('hosts', 3, 'loaded')).toBe('3 Macs listed.');
    expect(say('empty', 0, 'loaded')).toBe('No Macs on this account yet.');
    // The failure panel is an alert; a pending Mac claim reports its own progress.
    expect(say('error', 0, 'error')).toBe('');
    expect(say('empty', 0, 'loading')).toBe('');
    // While a Mac-started claim runs, a loaded empty list is not "no Macs".
    expect(hostListAnnouncement({ view: 'empty', hostCount: 0, hostsStatus: 'loaded', macClaimPending: true })).toBe('');
  });

  it('keeps the loading and failure copy short and product-facing', () => {
    const copy = Object.values(HOST_LIST_COPY).join(' ');
    expect(copy).not.toMatch(/relay|websocket|register|device|protocol|transport|cache|snapshot|adapter|sync/i);
    expect(HOST_LIST_COPY.loadingTitle).toBe('Loading your Macs…');
    for (const line of Object.values(HOST_LIST_COPY)) expect(line.length).toBeLessThanOrEqual(42);
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
