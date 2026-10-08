import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  route: 'workspace' as string,
  passwordResetFlow: null as unknown,
}));
vi.mock('../lib/store', () => ({
  useAppStore: Object.assign((select: (value: typeof state) => unknown) => select(state), {
    getState: () => state,
  }),
  shouldEnterHostLinkFlow: () => false,
}));
vi.mock('../auth/AuthScreen', () => ({ AuthScreen: () => <div>auth-screen</div> }));
vi.mock('../auth/HostsScreen', () => ({ HostsScreen: () => <div>hosts-screen</div> }));
vi.mock('../auth/ProfileScreen', () => ({ ProfileScreen: () => <div>profile-screen</div> }));
vi.mock('../lib/UnlockScreen', () => ({ UnlockScreen: () => <div>unlock-screen</div> }));
vi.mock('../agents/AgentCarousel', () => ({ AgentCarousel: () => <div>workspace-screen</div> }));
vi.mock('../ui/TopBar', () => ({ TopBar: () => <div>top-bar</div> }));
vi.mock('../dev/workspaceFixture', () => ({ applyWorkspaceFixture: () => false, isWorkspaceFixtureEnabled: () => false }));
import { App } from './App';

describe('password reset routing', () => {
  it('shows an open reset screen over a signed-in workspace, without the top bar', () => {
    state.route = 'workspace';
    state.passwordResetFlow = { screen: 'reset', token: 't', status: 'idle', error: null };
    const html = renderToStaticMarkup(<App />);
    expect(html).toContain('auth-screen');
    expect(html).not.toContain('workspace-screen');
    expect(html).not.toContain('top-bar');
  });

  it('shows the reset screen instead of the start-up spinner', () => {
    state.route = 'loading';
    state.passwordResetFlow = { screen: 'reset', token: 't', status: 'idle', error: null };
    const html = renderToStaticMarkup(<App />);
    expect(html).toContain('auth-screen');
    expect(html).not.toContain('Loading Glasstunnel');
  });

  it('routes normally when no reset is open', () => {
    state.route = 'hosts';
    state.passwordResetFlow = null;
    const html = renderToStaticMarkup(<App />);
    expect(html).toContain('hosts-screen');
    expect(html).toContain('top-bar');
    expect(html).not.toContain('auth-screen');
  });
});
