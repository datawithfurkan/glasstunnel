import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountHost } from '../lib/accountApi';
import type { HostListStatus } from '../lib/store';

const state = vi.hoisted(() => ({
  user: { id: 'one', email: 'one@glasstunnel.test', displayName: 'One' },
  accessRevocationNotice: null as string | null,
  availableHosts: [] as AccountHost[],
  hostsStatus: 'idle' as HostListStatus,
  error: null as string | null,
  chooseHost: async () => {},
  refreshHosts: async () => {},
  claimHostLinkCode: async () => {
    throw new Error('not in this test');
  },
}));
vi.mock('../lib/store', () => ({
  useAppStore: Object.assign((select: (value: typeof state) => unknown) => select(state), {
    getState: () => state,
  }),
}));
import { HostsScreen } from './HostsScreen';

const host: AccountHost = {
  deviceId: 'test-mac', publicKeyB64: 'test-public-key', label: 'Test Mac',
  signalingUrl: 'wss://signal.example.test/signal', pairedAtUnixMs: 1,
  online: true, trusted: true,
};

function render(next: { hosts?: AccountHost[]; status: HostListStatus }) {
  state.availableHosts = next.hosts ?? [];
  state.hostsStatus = next.status;
  return renderToStaticMarkup(<HostsScreen />);
}

describe('Your Macs list states', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { location: { search: '' } });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('shows a busy loading state instead of the add-a-Mac form while the first list loads', () => {
    const html = render({ status: 'loading' });
    expect(html).toContain('Your Macs');
    expect(html).toContain('Loading your Macs…');
    // The list container is busy; the message is not a live region that comes and goes.
    expect(html).toMatch(/<div tabindex="-1" aria-busy="true"[^>]*><section class="gt-panel p-6">/);
    expect(html).not.toMatch(/role="status"[^>]*aria-busy/);
    expect(html).not.toContain('Add this Mac');
    expect(html).not.toContain('One-time code');
  });

  it('keeps one polite live region on screen in every list state', () => {
    for (const next of [
      { status: 'loading' as const },
      { status: 'error' as const },
      { status: 'loaded' as const },
      { hosts: [host], status: 'loaded' as const },
    ]) {
      const html = render(next);
      expect(html.match(/role="status"/g)).toHaveLength(1);
      // Empty on first paint, then filled, so the first message is announced too.
      expect(html).toContain('<p role="status" aria-live="polite" class="sr-only"></p>');
    }
  });

  it('lists the Macs once they arrive', () => {
    const html = render({ hosts: [host], status: 'loaded' });
    expect(html).toContain('Test Mac');
    expect(html).toContain('Add another Mac');
    expect(html).not.toContain('Loading your Macs');
    expect(html).toMatch(/<div tabindex="-1" aria-busy="false"/);
  });

  it('keeps the Macs on screen during a background refresh', () => {
    const html = render({ hosts: [host], status: 'loading' });
    expect(html).toContain('Test Mac');
    expect(html).not.toContain('Loading your Macs');
  });

  it('offers the add-a-Mac form for an account that loaded without Macs', () => {
    const html = render({ status: 'loaded' });
    expect(html).toContain('Add this Mac');
    expect(html).toContain('Enter the code shown on your Mac.');
    expect(html).not.toContain('Loading your Macs');
  });

  it('shows a failed first load with a way to try again, not the empty add-a-Mac state', () => {
    const html = render({ status: 'error' });
    expect(html).toContain('Could not load your Macs');
    expect(html).toContain('Try again');
    expect(html).toContain('>Refresh<');
    expect(html).not.toContain('Add this Mac');
    expect(html).not.toContain('Loading your Macs');
  });

  it('exposes a failed first load to assistive technology as an alert with its way out', () => {
    const html = render({ status: 'error' });
    expect(html).toMatch(
      /<section role="alert" class="gt-panel p-6"><div[^>]*>Could not load your Macs<\/div><button type="button"[^>]*>Try again<\/button><\/section>/,
    );
    expect(html).toMatch(/<div tabindex="-1" aria-busy="false"/);
    expect(html.match(/role="alert"/g)).toHaveLength(1);
  });

  it('shows the add flow at once when a Mac opened this page with its code, even while loading', () => {
    vi.stubGlobal('window', { location: { search: '?linkCode=abc234' } });
    const html = render({ status: 'loading' });
    expect(html).toContain('Add this Mac');
    expect(html).not.toContain('Loading your Macs');
  });
});
