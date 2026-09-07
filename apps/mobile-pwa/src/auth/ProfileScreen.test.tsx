import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
vi.mock('../lib/store', () => ({ useAppStore: (select: (state: unknown) => unknown) => select({
  user: { displayName: 'Fixture' }, availableHosts: [], pairedHost: null,
  signOut: () => {}, clearOfflineCopies: () => {}, navigateTo: () => {},
}) }));
import { ProfileScreen } from './ProfileScreen';

describe('Profile offline-copy controls', () => {
  it('offers a browser-only clear action without promising source deletion', () => {
    const html = renderToStaticMarkup(<ProfileScreen />);
    expect(html).toContain('Clear offline copies');
    expect(html).toContain('24 hours');
    expect(html).toContain('Original chats and files stay on your Mac.');
  });
});
