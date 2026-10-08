import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AccountHost } from '../lib/accountApi';
import type { HostsFixtureDialog } from '../dev/workspaceFixture';
import type { HostListStatus } from '../lib/store';

const state = vi.hoisted(() => ({
  user: { id: 'one', email: 'one@glasstunnel.test', displayName: 'One' },
  accessRevocationNotice: null as string | null,
  availableHosts: [] as AccountHost[],
  hostsStatus: 'loaded' as HostListStatus,
  error: null as string | null,
  chooseHost: async () => {},
  refreshHosts: async () => {},
  claimHostLinkCode: async () => {
    throw new Error('not in this test');
  },
  renameHost: async (_deviceId: string, label: string) => label,
  removeHost: async () => {},
}));
const fixture = vi.hoisted(() => ({ dialog: null as HostsFixtureDialog | null }));

vi.mock('../lib/store', () => ({
  useAppStore: Object.assign((select: (value: typeof state) => unknown) => select(state), {
    getState: () => state,
  }),
}));
vi.mock('../dev/workspaceFixture', () => ({
  currentHostsFixtureDialog: () => fixture.dialog,
}));

import { HostsScreen } from './HostsScreen';
import {
  HOST_DIALOG_COPY,
  HOST_MENU_ITEMS,
  MacDetailsDialog,
  RemoveMacDialog,
  RenameMacDialog,
  hostDetailsRows,
  hostMenuButtonLabel,
  removeMacTitle,
} from './HostManagement';

const onlineMac: AccountHost = {
  deviceId: 'gt-4a1b7e3ac0d2f915', publicKeyB64: 'key-1', label: 'Studio Mac mini',
  signalingUrl: 'wss://signal.example.test/signal', pairedAtUnixMs: 1_781_000_000_000,
  addedAtUnixMs: 1_780_000_000_000, lastSeenAtUnixMs: 1_781_312_200_000, appVersion: '0.1.10',
  online: true, trusted: true,
};
const offlineMac: AccountHost = {
  ...onlineMac, deviceId: 'gt-9c03d5e81b7a4f20', publicKeyB64: 'key-2', online: false,
  appVersion: undefined, addedAtUnixMs: undefined, lastSeenAtUnixMs: 1_778_400_000_000,
};
const laptop: AccountHost = { ...offlineMac, deviceId: 'gt-17e2b9f04c6a3d58', label: 'MacBook Pro' };

function render(hosts: AccountHost[], dialog: HostsFixtureDialog | null = null) {
  state.availableHosts = hosts;
  fixture.dialog = dialog;
  return renderToStaticMarkup(<HostsScreen />);
}

const decode = (html: string) => html.replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&');

describe('Your Macs device actions', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { location: { search: '' } });
    state.accessRevocationNotice = null;
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('gives every Mac a closed "⋯" menu button named after it', () => {
    const html = render([onlineMac, laptop]);
    for (const host of [onlineMac, laptop]) {
      expect(html).toMatch(new RegExp(
        `<button[^>]*aria-label="${hostMenuButtonLabel(host.label)}" aria-haspopup="menu" aria-expanded="false"[^>]*data-host-menu-button="${host.deviceId}"[^>]*class="gt-button gt-button-ghost h-11 w-11 px-0"`,
      ));
    }
    expect(html).not.toContain('role="menu"');
    expect(html).not.toContain('role="dialog"');
  });

  it('opens the menu with Rename, Details and Remove from account, in that order', () => {
    const html = render([onlineMac, laptop], { kind: 'menu', deviceId: onlineMac.deviceId });
    expect(HOST_MENU_ITEMS.map((item) => item.label)).toEqual(['Rename', 'Details', 'Remove from account']);
    const items = [...html.matchAll(/<button[^>]*role="menuitem"[^>]*>([^<]+)<\/button>/g)].map((match) => match[1]);
    expect(items).toEqual(['Rename', 'Details', 'Remove from account']);
    expect(html.match(/role="menu"/g)).toHaveLength(1);
    expect(html).toMatch(/aria-expanded="true" aria-controls="[^"]+"/);
    // Items take arrow-key focus, not a Tab stop each.
    expect(html.match(/role="menuitem" tabindex="-1"/g)).toHaveLength(3);
  });

  it('shows a short device ID on Macs that share a name, and only on those', () => {
    const shown = (html: string) =>
      [...html.matchAll(/Device ID <span class="font-mono">([^<]+)<\/span>/g)].map((match) => match[1]);
    expect(shown(render([onlineMac, offlineMac, laptop]))).toEqual(['gt-4a1b7e3ac', 'gt-9c03d5e81']);
    expect(shown(render([onlineMac, laptop]))).toEqual([]);
  });

  it('treats names that look the same as shared: composed alike, case and invisible characters aside', () => {
    const shown = (html: string) =>
      [...html.matchAll(/Device ID <span class="font-mono">([^<]+)<\/span>/g)].map((match) => match[1]);
    // "Zoé" composed and decomposed, and a copy with a zero-width space and a direction mark.
    const html = render([
      { ...onlineMac, label: 'Zo\u00E9 Mac' },
      { ...offlineMac, label: 'zoe\u0301 mac' },
      { ...laptop, label: 'Zo\u00E9 Mac\u200B\u200E' },
    ]);
    expect(shown(html)).toEqual(['gt-4a1b7e3ac', 'gt-9c03d5e81', 'gt-17e2b9f04']);
  });

  it('truncates a long name inside a one-column list instead of widening the page', () => {
    const html = render([{ ...onlineMac, label: 'W'.repeat(40) }]);
    expect(html).toContain('<div class="grid grid-cols-1 gap-3">');
    expect(html).toMatch(/<h2 class="max-w-full truncate text-xl font-semibold">W{40}<\/h2>/);
  });

  it('opens Rename as a modal dialog with the current name in a labelled field', () => {
    const html = decode(render([onlineMac], { kind: 'rename', deviceId: onlineMac.deviceId }));
    expect(html).toMatch(/role="dialog" aria-modal="true" aria-labelledby="([^"]+)"[^>]*>.*<h2 id="\1"[^>]*>Rename Mac<\/h2>/);
    const label = html.match(/<label for="([^"]+)"[^>]*>Mac name<\/label>/);
    expect(label).not.toBeNull();
    expect(html).toMatch(new RegExp(`<input id="${label![1]}"[^>]*value="Studio Mac mini"`));
    expect(html).toContain('>Save</button>');
    expect(html).toContain('>Cancel</button>');
    expect(html).toContain(HOST_DIALOG_COPY.renameHint);
  });

  it('starts Rename without hidden characters an older name may hold', () => {
    const html = renderToStaticMarkup(
      <RenameMacDialog host={{ ...onlineMac, label: 'Studio\u200B Mac\u202E mini' }} rename={async (_id, label) => label}
        onRenamed={() => {}} onClose={() => {}} />,
    );
    expect(html).toMatch(/<input [^>]*value="Studio Mac mini"/);
  });

  it('shows a rename error as an alert tied to the field', () => {
    const html = renderToStaticMarkup(
      <RenameMacDialog host={onlineMac} rename={async (_id, label) => label} onRenamed={() => {}} onClose={() => {}}
        initialError="Use 40 characters or fewer." />,
    );
    const described = html.match(/aria-invalid="true" aria-describedby="([^"]+)"/);
    expect(described).not.toBeNull();
    expect(html).toContain(`<p id="${described![1]}" role="alert" class="mt-2 text-sm text-err">Use 40 characters or fewer.</p>`);
  });

  it('opens Details with status, last seen, added date, app version and the short device ID', () => {
    const html = decode(render([onlineMac], { kind: 'details', deviceId: onlineMac.deviceId }));
    expect(html).toMatch(/role="dialog" aria-modal="true"[^>]*>.*<h2[^>]*>Studio Mac mini<\/h2>/);
    for (const label of ['Status', 'Last seen', 'Added', 'Mac app version', 'Device ID']) {
      expect(html).toContain(`>${label}</dt>`);
    }
    expect(html).toContain('>Online</dd>');
    expect(html).toContain('>0.1.10</dd>');
    expect(html).toContain(`title="${onlineMac.deviceId}">gt-4a1b7e3ac</code>`);
    expect(html).toContain('aria-label="Copy device ID"');
    expect(html).toContain('>Done</button>');
  });

  it('leaves out the app version row when the server does not know it', () => {
    const html = renderToStaticMarkup(<MacDetailsDialog host={offlineMac} onClose={() => {}} />);
    expect(html).toContain('>Offline</dd>');
    expect(html).not.toContain('Mac app version');
  });

  it('lists details in order, with added falling back to the pairing date', () => {
    const format = (unixMs: number, style: string) => `${style}:${unixMs}`;
    expect(hostDetailsRows(onlineMac, format)).toEqual([
      { label: 'Status', value: 'Online' },
      { label: 'Last seen', value: 'date-time:1781312200000' },
      { label: 'Added', value: 'date:1780000000000' },
      { label: 'Mac app version', value: '0.1.10' },
    ]);
    expect(hostDetailsRows({ ...offlineMac, lastSeenAtUnixMs: undefined }, format)).toEqual([
      { label: 'Status', value: 'Offline' },
      { label: 'Last seen', value: 'Not available' },
      { label: 'Added', value: 'date:1781000000000' },
    ]);
    expect(hostDetailsRows({ ...onlineMac, lastSeenAtUnixMs: undefined, appVersion: '  ' }, format)[1]).toEqual({
      label: 'Last seen', value: 'Now',
    });
  });

  it('asks before removing, naming the Mac and what removal does', () => {
    const html = decode(render([onlineMac], { kind: 'remove', deviceId: onlineMac.deviceId }));
    expect(html).toMatch(/role="alertdialog" aria-modal="true" aria-labelledby="[^"]+" aria-describedby="([^"]+)"/);
    expect(html).toContain(`>${removeMacTitle('Studio Mac mini')}</h2>`);
    expect(removeMacTitle('Studio Mac mini')).toBe('Remove Studio Mac mini?');
    expect(html).toContain(
      'Phones and browsers signed in to this account lose access to this Mac right away. The Mac is signed out of your account. To use it again, link it from the Mac.',
    );
    expect(html).toMatch(/class="gt-button gt-button-destructive">Remove Mac<\/button>/);
    expect(html).toContain('>Cancel</button>');
  });

  it('shows a failed removal in the dialog', () => {
    const html = renderToStaticMarkup(
      <RemoveMacDialog host={onlineMac} remove={async () => {}} onRemoved={() => {}} onClose={() => {}}
        initialError="This Mac is no longer in your account." />,
    );
    expect(html).toContain('<p role="alert" class="mt-3 text-sm text-err">This Mac is no longer in your account.</p>');
  });

  it('does not open a dialog for a Mac that is not listed', () => {
    const html = render([laptop], { kind: 'rename', deviceId: 'gt-unknown' });
    expect(html).not.toContain('role="dialog"');
  });

  it('tells a browser whose Mac was removed elsewhere what happened', () => {
    state.accessRevocationNotice = 'This Mac was removed from your account.';
    const html = render([laptop]);
    expect(html).toMatch(/<section aria-live="polite"><div class="[^"]*text-err">This Mac was removed from your account.<\/div><\/section>/);
  });

  it('keeps the message area in the page while empty, so later messages are announced', () => {
    const html = render([laptop]);
    expect(html).toContain('<section aria-live="polite" class="-mt-5"></section>');
  });
});
