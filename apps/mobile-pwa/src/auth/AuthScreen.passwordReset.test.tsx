import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import type { PasswordResetFlow } from '../lib/passwordReset';

const state = vi.hoisted(() => ({
  authConfigured: true,
  signingOut: false,
  signOutError: null as string | null,
  passwordResetFlow: null as PasswordResetFlow | null,
}));
vi.mock('../lib/store', () => ({ useAppStore: (select: (value: typeof state) => unknown) => select(state) }));
import { AuthScreen, signInEmailAfterReset, signInFieldAfterReset } from './AuthScreen';
import { ForgotPasswordButton, ForgotPasswordView, ResetPasswordView, passwordResetFocusKey } from './PasswordResetViews';

const noop = () => {};

function renderScreen(flow: PasswordResetFlow | null, overrides: Partial<typeof state> = {}) {
  Object.assign(state, { authConfigured: true, signingOut: false, signOutError: null, passwordResetFlow: flow }, overrides);
  return renderToStaticMarkup(<AuthScreen />);
}

function buttonMarkup(html: string, label: string) {
  return html.match(new RegExp(`<button[^>]*>(?:(?!</button>).)*${label}(?:(?!</button>).)*</button>`))?.[0] ?? '';
}

describe('forgot password screen', () => {
  it('offers "Forgot password?" on the email sign-in step only', () => {
    expect(renderToStaticMarkup(<ForgotPasswordButton mode="signin" onClick={noop} />)).toContain('Forgot password?');
    expect(renderToStaticMarkup(<ForgotPasswordButton mode="signup" onClick={noop} />)).toBe('');
  });

  it('turns "Forgot password?" off while a sign-in is in flight', () => {
    const idle = renderToStaticMarkup(<ForgotPasswordButton mode="signin" onClick={noop} />);
    expect(buttonMarkup(idle, 'Forgot password\\?')).toContain('Forgot password?');
    expect(buttonMarkup(idle, 'Forgot password\\?')).not.toContain('disabled');
    const busy = renderToStaticMarkup(<ForgotPasswordButton mode="signin" disabled onClick={noop} />);
    expect(buttonMarkup(busy, 'Forgot password\\?')).toContain('disabled=""');
  });

  it('asks for the email with a send action and a way back', () => {
    const html = renderScreen({ screen: 'forgot', status: 'idle', error: null });
    expect(html).toContain('<h1');
    expect(html).toContain('Reset your password</h1>');
    expect(html).toContain('placeholder="you@example.com"');
    expect(html).toContain('Send reset link');
    expect(html).toContain('Back to sign in');
    expect(html).not.toContain('Continue with Google');
  });

  it('keeps the typed email and disables sending while a request is in flight', () => {
    const idle = renderToStaticMarkup(
      <ForgotPasswordView flow={{ screen: 'forgot', status: 'idle', error: null }} email="person@example.test" onEmailChange={noop} onSubmit={noop} onBack={noop} />,
    );
    expect(idle).toContain('value="person@example.test"');
    expect(buttonMarkup(idle, 'Send reset link')).not.toContain('disabled');

    const sending = renderToStaticMarkup(
      <ForgotPasswordView flow={{ screen: 'forgot', status: 'sending', error: null }} email="person@example.test" onEmailChange={noop} onSubmit={noop} onBack={noop} />,
    );
    expect(buttonMarkup(sending, 'Sending…')).toContain('disabled');
    expect(sending).not.toContain('Send reset link');
  });

  it('confirms a sent request without saying whether the account exists', () => {
    const html = renderScreen({ screen: 'forgot', status: 'sent', error: null });
    expect(html).toContain('If an account exists for that email, we sent a link to reset your password. It expires in 1 hour.');
    expect(html).toContain('role="status"');
    expect(html).toContain('Back to sign in');
    expect(html).not.toContain('Send reset link');
    expect(html).not.toContain('you@example.com');
  });

  it('shows why a request could not be sent', () => {
    for (const message of [
      "Password reset isn't available yet. Sign in with Google or GitHub instead.",
      'Too many reset requests. Wait a minute and try again.',
    ]) {
      const html = renderScreen({ screen: 'forgot', status: 'idle', error: message });
      expect(html).toContain('role="alert"');
      expect(html).toContain(message.replace(/'/g, '&#x27;'));
      expect(html).toContain('Send reset link');
    }
  });
});

describe('choose a new password screen', () => {
  it('asks for the new password twice and says every device signs out', () => {
    const html = renderScreen({ screen: 'reset', token: 'link-token', status: 'idle', error: null });
    expect(html).toContain('Choose a new password</h1>');
    expect(html).toContain('Updating your password signs you out on every device.');
    expect(html).toMatch(/<label[^>]*><span[^>]*>New password<\/span><input type="password" autoComplete="new-password"/);
    expect(html).toMatch(/<label[^>]*><span[^>]*>Confirm new password<\/span><input type="password" autoComplete="new-password"/);
    expect(html).toContain('Update password');
    expect(html).toContain('Cancel');
    expect(html).not.toContain('link-token');
  });

  it('shows progress while updating and the server error after it', () => {
    const updating = renderToStaticMarkup(
      <ResetPasswordView flow={{ screen: 'reset', token: 't', status: 'updating', error: null }} onSubmit={noop} onCancel={noop} onRequestNewLink={noop} onBackToSignIn={noop} />,
    );
    expect(buttonMarkup(updating, 'Updating…')).toContain('disabled');
    expect(buttonMarkup(updating, 'Cancel')).toContain('disabled');

    const failed = renderScreen({ screen: 'reset', token: 't', status: 'idle', error: 'Use at least 8 characters.' });
    expect(failed).toContain('role="alert"');
    expect(failed).toContain('Use at least 8 characters.');
    expect(failed).toContain('aria-invalid="true"');
  });

  it('confirms the update and leads back to sign-in', () => {
    const html = renderScreen({ screen: 'reset', token: null, status: 'done', error: null });
    expect(html).toContain('Password updated. Sign in with your new password.');
    expect(html).toContain('Back to sign in');
    expect(html).not.toContain('type="password"');
    expect(html).not.toContain('Updating your password signs you out on every device.');
  });

  it('explains an expired or used link and offers a new one', () => {
    const html = renderScreen({ screen: 'reset', token: null, status: 'invalid', error: null });
    expect(html).toContain('role="alert"');
    expect(html).toContain('This reset link has expired or was already used. Request a new one.');
    expect(html).toContain('Request a new link');
    expect(html).not.toContain('type="password"');
  });

  it('never shows a reset screen while signing out or without hosted sign-in', () => {
    const flow: PasswordResetFlow = { screen: 'reset', token: 't', status: 'idle', error: null };
    const signingOut = renderScreen(flow, { signingOut: true });
    expect(signingOut).toContain('Signing out...');
    expect(signingOut).not.toContain('Choose a new password');

    const unconfigured = renderScreen(flow, { authConfigured: false });
    expect(unconfigured).toContain('Hosted auth is not configured yet in this build.');
    expect(unconfigured).toContain('Open your agents');
  });

  it('keeps the normal sign-in screen when no reset is open', () => {
    const html = renderScreen(null);
    expect(html).toContain('Open your agents</h1>');
    expect(html).toContain('Continue with Google');
    expect(html).not.toContain('Reset your password');
  });
});

describe('focus when a reset screen changes', () => {
  const forms: PasswordResetFlow[] = [
    { screen: 'forgot', status: 'idle', error: null },
    { screen: 'forgot', status: 'sending', error: null },
    { screen: 'forgot', status: 'idle', error: 'Too many reset requests. Wait a minute and try again.' },
    { screen: 'reset', token: 't', status: 'idle', error: null },
    { screen: 'reset', token: 't', status: 'updating', error: null },
    { screen: 'reset', token: 't', status: 'idle', error: 'Use at least 8 characters.' },
  ];

  it('moves focus to the message that replaces a form: sent, updated, expired link', () => {
    const messages: [PasswordResetFlow, string, string][] = [
      [{ screen: 'forgot', status: 'sent', error: null }, 'forgot:sent', 'role="status"'],
      [{ screen: 'reset', token: null, status: 'done', error: null }, 'reset:done', 'role="status"'],
      [{ screen: 'reset', token: null, status: 'invalid', error: null }, 'reset:invalid', 'role="alert"'],
      [{ screen: 'reset', token: null, status: 'idle', error: null }, 'reset:invalid', 'role="alert"'],
    ];
    for (const [flow, key, role] of messages) {
      expect(passwordResetFocusKey(flow)).toBe(key);
      const html = renderScreen(flow);
      // The message itself takes focus (from script only), with its status or alert role.
      expect(html).toMatch(new RegExp(`<(p|div) ${role}[^>]*tabindex="-1"`));
      expect(html.match(/tabindex="-1"/g)).toHaveLength(1);
    }
    const keys = messages.slice(0, 3).map(([flow]) => passwordResetFocusKey(flow));
    expect(new Set(keys).size).toBe(3);
  });

  it('leaves forms to focus their first field, and their errors out of the tab order', () => {
    for (const flow of forms) {
      expect(passwordResetFocusKey(flow)).toBeNull();
      const html = renderScreen(flow);
      expect(html).not.toContain('tabindex="-1"');
      expect(html).toContain('autofocus=""');
    }
  });

  it('returns focus to the password after "Back to sign in" when the email step was done, else to the email', () => {
    expect(signInFieldAfterReset('person@example.test', true)).toBe('password');
    expect(signInFieldAfterReset('person@example.test', false)).toBe('email');
    expect(signInFieldAfterReset('   ', true)).toBe('email');
    expect(signInFieldAfterReset('', false)).toBe('email');
  });

  it('fills the sign-in email after "Back to sign in" from a Mac code kept through the reset only when none was typed', () => {
    expect(signInEmailAfterReset('typed@example.test', 'kept@example.test')).toBe('typed@example.test');
    expect(signInEmailAfterReset('', 'kept@example.test')).toBe('kept@example.test');
    expect(signInEmailAfterReset('  ', 'kept@example.test')).toBe('kept@example.test');
    expect(signInEmailAfterReset('', null)).toBe('');
  });
});
