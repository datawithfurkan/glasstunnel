import { useEffect, useRef, useState } from 'react';
import { useAppStore } from '../lib/store';
import { BrandMark } from './Brand';

export function TopBar() {
  const paired = useAppStore((s) => s.pairedHost);
  const user = useAppStore((s) => s.user);
  const route = useAppStore((s) => s.route);
  const navigateTo = useAppStore((s) => s.navigateTo);
  const signOut = useAppStore((s) => s.signOut);
  const error = useAppStore((s) => s.error);
  const relayHostOnline = useAppStore((s) => s.relayHostOnline);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement | null>(null);

  let title = paired?.label ?? 'Workspace';
  if (route === 'loading') title = 'Loading';
  if (route === 'auth') title = 'Sign in';
  if (route === 'hosts') title = 'Your Macs';
  if (route === 'profile') title = 'Profile';
  if (route === 'unlock') title = 'Locked';
  const inWorkspace = route === 'workspace' || route === 'grid';
  const homeRoute = user ? 'hosts' : 'auth';
  const canGoHome = route !== homeRoute && route !== 'loading';
  const goHome = () => {
    if (!canGoHome) return;
    navigateTo(homeRoute);
  };
  const workspaceStatus =
    relayHostOnline === true
      ? 'Connected'
      : relayHostOnline === false || error
        ? 'Connection issue'
        : 'Connecting';
  const workspaceDot =
    relayHostOnline === true
      ? 'bg-ok'
      : relayHostOnline === false || error
        ? 'bg-err'
        : 'bg-warn';
  const errorDetail = topBarErrorDetail(error, inWorkspace);

  useEffect(() => {
    if (!menuOpen) return;

    const closeOnOutsideClick = (event: MouseEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) {
        setMenuOpen(false);
      }
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setMenuOpen(false);
      }
    };

    document.addEventListener('mousedown', closeOnOutsideClick);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      document.removeEventListener('mousedown', closeOnOutsideClick);
      document.removeEventListener('keydown', closeOnEscape);
    };
  }, [menuOpen]);

  const goTo = (nextRoute: 'hosts' | 'profile' | 'workspace') => {
    setMenuOpen(false);
    navigateTo(nextRoute);
  };

  const menuInitials = initialsFor(user?.displayName || user?.email || paired?.label || 'GT');

  return (
    <header className="safe-pad-top safe-pad-x border-b border-[color:var(--gt-border)] bg-surface-0">
      <div className="flex items-center justify-between gap-3 py-3">
        <div className="flex min-w-0 items-center gap-3">
          <button
            type="button"
            onClick={goHome}
            disabled={!canGoHome}
            aria-label="Go to home"
            title="Go to home"
            className={`flex min-w-0 items-center gap-3 rounded-[10px] text-left transition ${
              canGoHome ? 'cursor-pointer hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-accent/35' : 'cursor-default'
            }`}
          >
            <BrandMark className="h-9 w-9 shrink-0 object-contain" alt="Glasstunnel" />
            <div className="min-w-0">
              <div className="truncate text-base font-semibold">{title}</div>
              {inWorkspace && (
                <div className="gt-dim mt-0.5 flex items-center gap-2 text-xs">
                  <span className={`gt-status-dot ${workspaceDot}`} />
                  <span>{workspaceStatus}</span>
                </div>
              )}
            </div>
          </button>
          {user && !inWorkspace && (
            <div className="gt-dim mt-1 truncate text-xs">{user.email}</div>
          )}
        </div>
        <div className="flex items-center gap-2" ref={menuRef}>
          {user && route !== 'auth' && (
            <div className="relative">
              <button
                type="button"
                onClick={() => setMenuOpen((open) => !open)}
                aria-label="Open menu"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                title="Menu"
                className="gt-button gt-button-secondary h-10 w-10 px-0"
              >
                <span className="flex flex-col items-center gap-1.5" aria-hidden="true">
                  <span className="block h-0.5 w-4 rounded-full bg-current" />
                  <span className="block h-0.5 w-4 rounded-full bg-current" />
                  <span className="block h-0.5 w-4 rounded-full bg-current" />
                </span>
              </button>

              {menuOpen && (
                <div
                  role="menu"
                  className="absolute right-0 top-12 z-50 w-72 overflow-hidden rounded-[18px] border border-[color:var(--gt-border)] bg-surface-1 p-2 shadow-2xl"
                >
                  <div className="flex items-center gap-3 px-3 py-3">
                    <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-accent/45 bg-accent/15 text-sm font-semibold text-accent">
                      {menuInitials}
                    </div>
                    <div className="min-w-0">
                      <div className="truncate text-sm font-semibold">
                        {user.displayName || 'Glasstunnel account'}
                      </div>
                      <div className="gt-muted truncate text-xs">{user.email}</div>
                    </div>
                  </div>

                  <div className="my-1 h-px bg-[color:var(--gt-border)]" />

                  {paired && route !== 'workspace' && route !== 'grid' && (
                    <MenuItem label="Workspace" detail={paired.label} onClick={() => goTo('workspace')} />
                  )}
                  <MenuItem label="Your Macs" detail="Choose a linked Mac" onClick={() => goTo('hosts')} />
                  <MenuItem label="Profile" detail="Account details" onClick={() => goTo('profile')} />

                  <div className="my-1 h-px bg-[color:var(--gt-border)]" />

                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setMenuOpen(false);
                      void signOut();
                    }}
                    className="w-full rounded-[12px] px-3 py-2 text-left text-sm font-medium text-err transition hover:bg-err/10 focus:bg-err/10 focus:outline-none"
                  >
                    Sign out
                  </button>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
      {errorDetail && (
        <div className="pb-2 text-xs text-err" title={errorDetail}>
          ! {errorDetail}
        </div>
      )}
    </header>
  );
}

export function topBarErrorDetail(error: string | null, inWorkspace: boolean): string | null {
  if (!error) return null;
  if (inWorkspace) return null;
  return error;
}

function MenuItem({
  label,
  detail,
  onClick,
}: {
  label: string;
  detail: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className="w-full rounded-[12px] px-3 py-2 text-left transition hover:bg-surface-2 focus:bg-surface-2 focus:outline-none"
    >
      <span className="block text-sm font-medium">{label}</span>
      <span className="gt-muted mt-0.5 block truncate text-xs">{detail}</span>
    </button>
  );
}

function initialsFor(value: string) {
  const words = value
    .replace(/@.*/, '')
    .split(/[\s._-]+/)
    .filter(Boolean);
  const initials = words.slice(0, 2).map((word) => word[0]?.toUpperCase()).join('');
  return initials || 'GT';
}
