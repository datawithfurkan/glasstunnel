import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ authConfigured: true, signingOut: false, signOutError: null as string | null }));
vi.mock('../lib/store', () => ({ useAppStore: (select: (value: typeof state) => unknown) => select(state) }));
import { AuthScreen } from './AuthScreen';

describe('sign-out presentation', () => {
  it('does not offer a new login while saved-session cleanup is pending', () => {
    state.signingOut = true;
    state.signOutError = null;
    const html = renderToStaticMarkup(<AuthScreen />);
    expect(html).toContain('Signing out...');
    expect(html).not.toContain('Continue with Google');
  });
  it('shows a retry action after cleanup fails', () => {
    state.signingOut = false;
    state.signOutError = 'Sign-out cleanup is incomplete.';
    const html = renderToStaticMarkup(<AuthScreen />);
    expect(html).toContain('role="alert"');
    expect(html).toContain('Retry sign out');
  });
});
