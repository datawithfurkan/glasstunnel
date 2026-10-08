import { FormEvent, ReactNode, Ref, useCallback, useEffect, useRef, useState } from 'react';
import {
  PASSWORD_RESET_COPY as COPY,
  validateNewPassword,
  type ForgotPasswordFlow,
  type PasswordResetFlow,
  type ResetPasswordFlow,
} from '../lib/passwordReset';

/** The heading and the one line under it for an open forgot/reset screen. */
export function passwordResetHeading(flow: PasswordResetFlow): { title: string; detail: string | null } {
  if (flow.screen === 'forgot') {
    return { title: COPY.forgotHeading, detail: flow.status === 'sent' ? null : COPY.forgotDetail };
  }
  const choosing = flow.status === 'idle' || flow.status === 'updating';
  return { title: COPY.resetHeading, detail: choosing ? COPY.resetDetail : null };
}

/**
 * Where focus goes when a forgot/reset screen changes to a message (sent,
 * updated, expired link). The focused message is read out, and focus does not
 * fall back to the page when the form it was in disappears. Forms focus their
 * first field instead, so they have no key.
 */
export function passwordResetFocusKey(flow: PasswordResetFlow): string | null {
  if (flow.screen === 'forgot') return flow.status === 'sent' ? 'forgot:sent' : null;
  if (flow.status === 'done') return 'reset:done';
  if (flow.status === 'invalid' || !flow.token) return 'reset:invalid';
  return null;
}

export function ForgotPasswordButton({
  mode,
  disabled = false,
  onClick,
}: {
  mode: 'signin' | 'signup';
  /** While a sign-in is in flight: it may still succeed, and the forgot screen must not cover the app. */
  disabled?: boolean;
  onClick: () => void;
}) {
  if (mode !== 'signin') return null;
  return (
    <div className="flex justify-end">
      <button type="button" onClick={onClick} disabled={disabled} className="gt-button gt-button-ghost -mr-2 px-2 py-1">
        {COPY.forgotButton}
      </button>
    </div>
  );
}

export function ForgotPasswordView({
  flow,
  email,
  onEmailChange,
  onSubmit,
  onBack,
}: {
  flow: ForgotPasswordFlow;
  email: string;
  onEmailChange: (email: string) => void;
  onSubmit: (email: string) => void;
  onBack: () => void;
}) {
  const emailField = useRefocusFieldAfterBusy(flow.status === 'sending');
  if (flow.status === 'sent') {
    return (
      <div className="space-y-4">
        <Notice tone="ok" focusKey={passwordResetFocusKey(flow)}>{COPY.sent}</Notice>
        <button type="button" onClick={onBack} className="gt-button gt-button-primary w-full py-3 text-base">
          {COPY.backToSignIn}
        </button>
      </div>
    );
  }

  const sending = flow.status === 'sending';
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!sending) onSubmit(email);
  };

  return (
    <form onSubmit={submit} className="space-y-4" aria-busy={sending}>
      <label className="block">
        <span className="gt-label mb-2 block">Email</span>
        <input
          ref={emailField}
          type="email"
          inputMode="email"
          autoComplete="email"
          autoFocus
          value={email}
          onChange={(event) => onEmailChange(event.target.value)}
          placeholder="you@example.com"
          className="gt-input"
        />
      </label>
      <button
        type="submit"
        disabled={sending || email.trim().length === 0}
        className="gt-button gt-button-primary w-full py-3 text-base"
      >
        {sending ? COPY.sendingButton : COPY.sendButton}
      </button>
      <button type="button" onClick={onBack} className="gt-button gt-button-ghost w-full">
        {COPY.backToSignIn}
      </button>
      {flow.error && <Notice tone="err">{flow.error}</Notice>}
    </form>
  );
}

export function ResetPasswordView({
  flow,
  onSubmit,
  onCancel,
  onRequestNewLink,
  onBackToSignIn,
}: {
  flow: ResetPasswordFlow;
  onSubmit: (token: string, newPassword: string) => void;
  onCancel: () => void;
  onRequestNewLink: () => void;
  onBackToSignIn: () => void;
}) {
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const newPasswordField = useRefocusFieldAfterBusy(flow.status === 'updating');

  if (flow.status === 'done') {
    return (
      <div className="space-y-4">
        <Notice tone="ok" focusKey={passwordResetFocusKey(flow)}>{COPY.updated}</Notice>
        <button type="button" onClick={onBackToSignIn} className="gt-button gt-button-primary w-full py-3 text-base">
          {COPY.backToSignIn}
        </button>
      </div>
    );
  }

  if (flow.status === 'invalid' || !flow.token) {
    return (
      <div className="space-y-4">
        <Notice tone="err" focusKey={passwordResetFocusKey(flow)}>{COPY.invalidToken}</Notice>
        <button type="button" onClick={onRequestNewLink} className="gt-button gt-button-primary w-full py-3 text-base">
          {COPY.requestNewLink}
        </button>
        <button type="button" onClick={onBackToSignIn} className="gt-button gt-button-ghost w-full">
          {COPY.backToSignIn}
        </button>
      </div>
    );
  }

  const token = flow.token;
  const updating = flow.status === 'updating';
  const message = problem ?? flow.error;
  const lengthProblem = message === COPY.tooShort || message === COPY.tooLong;
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (updating) return;
    const issue = validateNewPassword(newPassword, confirmPassword);
    setProblem(issue);
    if (!issue) onSubmit(token, newPassword);
  };
  const edit = (update: (value: string) => void) => (value: string) => {
    update(value);
    setProblem(null);
  };

  return (
    <form onSubmit={submit} className="space-y-4" aria-busy={updating}>
      <PasswordField
        label={COPY.newPasswordLabel}
        value={newPassword}
        onChange={edit(setNewPassword)}
        invalid={lengthProblem}
        autoFocus
        inputRef={newPasswordField}
      />
      <PasswordField
        label={COPY.confirmPasswordLabel}
        value={confirmPassword}
        onChange={edit(setConfirmPassword)}
        invalid={message === COPY.mismatch}
      />
      <button
        type="submit"
        disabled={updating || newPassword.length === 0 || confirmPassword.length === 0}
        className="gt-button gt-button-primary w-full py-3 text-base"
      >
        {updating ? COPY.updatingButton : COPY.updateButton}
      </button>
      <button type="button" onClick={onCancel} disabled={updating} className="gt-button gt-button-ghost w-full">
        {COPY.cancel}
      </button>
      {message && <Notice tone="err">{message}</Notice>}
    </form>
  );
}

function PasswordField({
  label,
  value,
  onChange,
  invalid,
  autoFocus,
  inputRef,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  invalid: boolean;
  autoFocus?: boolean;
  inputRef?: Ref<HTMLInputElement>;
}) {
  return (
    <label className="block">
      <span className="gt-label mb-2 block">{label}</span>
      <input
        ref={inputRef}
        type="password"
        autoComplete="new-password"
        autoFocus={autoFocus}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-invalid={invalid || undefined}
        className="gt-input"
      />
    </label>
  );
}

/**
 * Focuses the element each time `key` changes to a non-null value. A message
 * that replaces the focused form is created already holding its text, which a
 * live region alone may not announce; focus makes screen readers read it.
 */
function useFocusOnKey(key: string | null | undefined) {
  const node = useRef<HTMLElement | null>(null);
  useEffect(() => {
    if (key) node.current?.focus();
  }, [key]);
  return useCallback((element: HTMLElement | null) => {
    node.current = element;
  }, []);
}

/**
 * The submit button is disabled while a request runs, and a disabled button
 * loses keyboard focus to the page. When the form comes back (with an error to
 * fix), focus returns to its first field, unless the person already moved it.
 */
function useRefocusFieldAfterBusy(busy: boolean) {
  const field = useRef<HTMLInputElement>(null);
  const wasBusy = useRef(busy);
  useEffect(() => {
    if (wasBusy.current && !busy && focusIsLost()) field.current?.focus();
    wasBusy.current = busy;
  }, [busy]);
  return field;
}

function focusIsLost(): boolean {
  if (typeof document === 'undefined') return false;
  const active = document.activeElement;
  return !active || active === document.body;
}

function Notice({ tone, focusKey, children }: { tone: 'ok' | 'err'; focusKey?: string | null; children: ReactNode }) {
  const focusRef = useFocusOnKey(focusKey);
  // Focusable from script only (tabIndex -1), and only when it is the screen's message.
  const focusProps = focusKey ? { ref: focusRef, tabIndex: -1 } : {};
  const focusClass = focusKey ? ' focus:outline-none' : '';
  if (tone === 'ok') {
    return (
      <p
        role="status"
        aria-live="polite"
        {...focusProps}
        className={`rounded-[6px] border border-ok/30 bg-ok/10 px-4 py-3 text-sm leading-6 text-[color:var(--gt-text)]${focusClass}`}
      >
        {children}
      </p>
    );
  }
  return (
    <div role="alert" {...focusProps} className={`rounded-[6px] border border-err/30 bg-err/10 px-4 py-3 text-sm text-err${focusClass}`}>
      {children}
    </div>
  );
}
