import { FormEvent, useEffect, useRef, useState } from 'react';
import { useAppStore } from '../lib/store';
import { BrandMark } from '../ui/Brand';

type EmailAuthMode = 'signin' | 'signup';
type HostedAuthProvider = 'google' | 'github' | 'email';

export function AuthScreen() {
  const signInWithGoogle = useAppStore((s) => s.signInWithGoogle);
  const signInWithGitHub = useAppStore((s) => s.signInWithGitHub);
  const signInWithPassword = useAppStore((s) => s.signInWithPassword);
  const signUpWithPassword = useAppStore((s) => s.signUpWithPassword);
  const authConfigured = useAppStore((s) => s.authConfigured);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [emailMode, setEmailMode] = useState<EmailAuthMode>('signin');
  const [emailVisible, setEmailVisible] = useState(false);
  const [emailStepComplete, setEmailStepComplete] = useState(false);
  const [busy, setBusy] = useState(false);
  const [googleBusy, setGoogleBusy] = useState(false);
  const [githubBusy, setGithubBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestedProvider = useRef<HostedAuthProvider | null>(readRequestedProvider());
  const providerRequestHandled = useRef(false);

  const submitGoogle = async () => {
    setGoogleBusy(true);
    setError(null);
    try {
      await signInWithGoogle();
    } catch (err) {
      setError((err as Error).message);
      setGoogleBusy(false);
    }
  };

  const submitGitHub = async () => {
    setGithubBusy(true);
    setError(null);
    try {
      await signInWithGitHub();
    } catch (err) {
      setError((err as Error).message);
      setGithubBusy(false);
    }
  };

  useEffect(() => {
    const provider = requestedProvider.current;
    if (!provider || providerRequestHandled.current) return;
    if (provider === 'email') {
      providerRequestHandled.current = true;
      clearRequestedProvider();
      setEmailVisible(true);
      return;
    }
    if (!authConfigured) return;

    providerRequestHandled.current = true;
    clearRequestedProvider();
    setError(null);

    if (provider === 'google') {
      setGoogleBusy(true);
      void signInWithGoogle().catch((err) => {
        setError((err as Error).message);
        setGoogleBusy(false);
      });
      return;
    }

    setGithubBusy(true);
    void signInWithGitHub().catch((err) => {
      setError((err as Error).message);
      setGithubBusy(false);
    });
  }, [authConfigured, signInWithGitHub, signInWithGoogle]);

  const continueWithEmail = (event: FormEvent) => {
    event.preventDefault();
    setError(null);
    const normalized = email.trim().toLowerCase();
    if (!normalized) {
      setError('Enter an email address.');
      return;
    }
    setEmail(normalized);
    setEmailStepComplete(true);
  };

  const submitEmailPassword = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const normalized = email.trim().toLowerCase();
      if (emailMode === 'signin') {
        await signInWithPassword(normalized, password);
      } else {
        await signUpWithPassword(normalized, password, displayName);
      }
    } catch (err) {
      const message = (err as Error).message;
      if (emailMode === 'signup' && /already registered/i.test(message)) {
        setEmailMode('signin');
        setPassword('');
        setError('That email already has an account. Sign in instead.');
      } else if (emailMode === 'signin' && /invalid login credentials/i.test(message)) {
        setError('Wrong email or password. If you are new here, switch to Create account.');
      } else {
        setError(message);
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={authScreenShellClassName()}>
      <div className="flex min-h-full w-full items-center justify-center py-6 min-[480px]:py-8">
        <div className="w-full max-w-[420px]">
          <div className="mb-8 flex flex-col items-center text-center">
            <BrandMark className="h-16 w-16 object-contain" alt="Glasstunnel" />
            <h1 className="mt-5 text-4xl font-semibold">Open your agents</h1>
            <p className="gt-muted mt-3 max-w-sm text-base leading-6">
              Sign in once. Your linked Macs and coding agents appear automatically.
            </p>
          </div>

          <div className="gt-panel p-5">

        {authConfigured ? (
          <div className="space-y-4">
            <div className="space-y-3">
              <button
                type="button"
                onClick={submitGoogle}
                disabled={googleBusy || githubBusy}
                className="gt-button gt-button-google w-full py-3 text-base"
              >
                <GoogleMark />
                <span>{googleBusy ? 'Redirecting to Google…' : 'Continue with Google'}</span>
              </button>

              <button
                type="button"
                onClick={submitGitHub}
                disabled={githubBusy || googleBusy}
                className="gt-button gt-button-github w-full py-3 text-base"
              >
                <GitHubMark />
                <span>{githubBusy ? 'Redirecting to GitHub…' : 'Continue with GitHub'}</span>
              </button>
            </div>

            {!emailVisible && (
              <button
                type="button"
                onClick={() => setEmailVisible(true)}
                className="gt-button gt-button-ghost w-full"
              >
                Continue with email instead
              </button>
            )}

            {emailVisible && !emailStepComplete ? (
              <form onSubmit={continueWithEmail} className="space-y-4">
                <label className="block">
                  <span className="gt-label mb-2 block">Email</span>
                  <input
                    type="email"
                    inputMode="email"
                    autoComplete="email"
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                    placeholder="you@example.com"
                    className="gt-input"
                  />
                </label>
                <button
                  type="submit"
                  disabled={email.trim().length === 0}
                  className="gt-button gt-button-secondary w-full py-3 text-base"
                >
                  Continue with email
                </button>
              </form>
            ) : emailVisible ? (
              <form onSubmit={submitEmailPassword} className="space-y-4">
                <div className="flex items-center justify-between gap-3">
                  <button
                    type="button"
                    onClick={() => {
                      setEmailStepComplete(false);
                      setPassword('');
                      setDisplayName('');
                      setError(null);
                    }}
                    className="gt-button gt-button-ghost px-3 py-2"
                  >
                    ←
                  </button>
                  <div className="gt-badge min-w-0 flex-1 justify-center truncate">{email}</div>
                </div>

                <div className="gt-segment">
                  <button
                    type="button"
                    onClick={() => setEmailMode('signin')}
                    className={`gt-segment-button ${emailMode === 'signin' ? 'is-active' : ''}`}
                  >
                    Sign in
                  </button>
                  <button
                    type="button"
                    onClick={() => setEmailMode('signup')}
                    className={`gt-segment-button ${emailMode === 'signup' ? 'is-active' : ''}`}
                  >
                    Create account
                  </button>
                </div>

                {emailMode === 'signup' && (
                  <label className="block">
                    <span className="gt-label mb-2 block">Name</span>
                    <input
                      type="text"
                      autoComplete="name"
                      value={displayName}
                      onChange={(event) => setDisplayName(event.target.value)}
                      placeholder="Your name"
                      className="gt-input"
                    />
                  </label>
                )}

                <label className="block">
                  <span className="gt-label mb-2 block">Password</span>
                  <input
                    type="password"
                    autoComplete={emailMode === 'signin' ? 'current-password' : 'new-password'}
                    value={password}
                    onChange={(event) => setPassword(event.target.value)}
                    placeholder={emailMode === 'signin' ? 'Enter your password' : 'Create a password'}
                    className="gt-input"
                  />
                </label>

                <button
                  type="submit"
                  disabled={busy || password.trim().length === 0}
                  className="gt-button gt-button-primary w-full py-3 text-base"
                >
                  {busy
                    ? emailMode === 'signin'
                      ? 'Signing in…'
                      : 'Creating account…'
                    : emailMode === 'signin'
                      ? 'Sign in'
                      : 'Create account'}
                </button>
              </form>
            ) : null}
          </div>
        ) : (
          <div className="mt-6 rounded-[6px] border border-warn/30 bg-warn/10 px-4 py-3 text-sm text-warn">
            Hosted auth is not configured yet in this build.
          </div>
        )}

        {error && (
          <div className="mt-4 rounded-[6px] border border-err/30 bg-err/10 px-4 py-3 text-sm text-err">
            {error}
          </div>
        )}

          </div>
        </div>
      </div>
    </div>
  );
}

export function authScreenShellClassName() {
  return 'h-full overflow-y-auto safe-pad-x safe-pad-top safe-pad-bottom';
}

function readRequestedProvider(): HostedAuthProvider | null {
  if (typeof window === 'undefined') return null;
  const provider = new URL(window.location.href).searchParams.get('authProvider')?.toLowerCase();
  if (provider === 'google' || provider === 'github' || provider === 'email') return provider;
  return null;
}

function clearRequestedProvider() {
  if (typeof window === 'undefined') return;
  const url = new URL(window.location.href);
  url.searchParams.delete('authProvider');
  window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
}

function GoogleMark() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 18 18"
      className="h-[18px] w-[18px] shrink-0"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        fill="#4285F4"
        d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.9c1.7-1.56 2.7-3.86 2.7-6.62Z"
      />
      <path
        fill="#34A853"
        d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.9-2.26c-.8.54-1.84.86-3.06.86-2.35 0-4.33-1.58-5.04-3.7H.96v2.34A9 9 0 0 0 9 18Z"
      />
      <path
        fill="#FBBC05"
        d="M3.96 10.72A5.41 5.41 0 0 1 3.68 9c0-.6.1-1.18.28-1.72V4.94H.96A9 9 0 0 0 0 9c0 1.45.35 2.82.96 4.06l3-2.34Z"
      />
      <path
        fill="#EA4335"
        d="M9 3.58c1.32 0 2.5.46 3.44 1.36l2.58-2.58C13.46.92 11.43 0 9 0A9 9 0 0 0 .96 4.94l3 2.34C4.67 5.16 6.65 3.58 9 3.58Z"
      />
    </svg>
  );
}

function GitHubMark() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 16 16"
      className="h-[18px] w-[18px] shrink-0"
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 0 0 5.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82A7.6 7.6 0 0 1 8 4.57c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8 8 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  );
}
