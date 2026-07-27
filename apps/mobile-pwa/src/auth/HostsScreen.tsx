import { useCallback, useEffect, useRef, useState } from 'react';
import type { AccountHost } from '../lib/accountApi';
import { useAppStore } from '../lib/store';

export function HostsScreen() {
  const user = useAppStore((s) => s.user);
  const availableHosts = useAppStore((s) => s.availableHosts);
  const chooseHost = useAppStore((s) => s.chooseHost);
  const refreshHosts = useAppStore((s) => s.refreshHosts);
  const claimHostLinkCode = useAppStore((s) => s.claimHostLinkCode);
  const [linkCode, setLinkCode] = useState('');
  const [busyHostId, setBusyHostId] = useState<string | null>(null);
  const [linking, setLinking] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const autoClaimedCodeRef = useRef<string | null>(null);
  const lastAutoRefreshAtRef = useRef(0);

  const refreshHostsVisible = useCallback(
    async (options?: { force?: boolean }) => {
      if (document.visibilityState !== 'visible') return;
      if (!options?.force && Date.now() - lastAutoRefreshAtRef.current < 10_000) return;
      lastAutoRefreshAtRef.current = Date.now();
      await refreshHosts(options);
    },
    [refreshHosts],
  );

  const openHost = async (host: AccountHost) => {
    setBusyHostId(host.deviceId);
    setError(null);
    setStatus(null);
    try {
      await chooseHost(host.deviceId);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusyHostId(null);
    }
  };

  const refreshHostsFromButton = useCallback(async () => {
    if (refreshing) return;
    setRefreshing(true);
    setError(null);
    setStatus('Refreshing Macs…');
    try {
      await refreshHosts({ force: true });
      const latestError = useAppStore.getState().error;
      if (latestError) {
        setError(latestError);
        setStatus(null);
      } else {
        setStatus('Macs updated.');
      }
    } catch (err) {
      setError((err as Error).message);
      setStatus(null);
    } finally {
      setRefreshing(false);
    }
  }, [refreshHosts, refreshing]);

  const submitLinkCode = useCallback(
    async (code: string) => {
      const normalized = normalizeCode(code);
      if (!normalized) {
        setError('Enter the 6-character code shown on your Mac.');
        return;
      }

      await claimLinkedHostAndOpen(normalized, {
        claimHostLinkCode,
        chooseHost,
        setLinkCode,
        setStatus,
        setError,
        setLinking,
      });
    },
    [chooseHost, claimHostLinkCode],
  );

  useEffect(() => {
    if (!user) return;
    const params = new URLSearchParams(window.location.search);
    const code = normalizeCode(params.get('linkCode') ?? '');
    if (!code || autoClaimedCodeRef.current === code) return;

    autoClaimedCodeRef.current = code;
    setLinkCode(code);
    params.delete('linkCode');
    const nextQuery = params.toString();
    const nextURL = `${window.location.pathname}${nextQuery ? `?${nextQuery}` : ''}${window.location.hash}`;
    window.history.replaceState({}, '', nextURL);

    void submitLinkCode(code);
  }, [submitLinkCode, user]);

  useEffect(() => {
    if (!user) return;

    const refreshVisibleHosts = () => {
      void refreshHostsVisible();
    };

    void refreshHostsVisible({ force: true });
    const intervalId = window.setInterval(() => void refreshHostsVisible(), 60_000);
    window.addEventListener('focus', refreshVisibleHosts);
    document.addEventListener('visibilitychange', refreshVisibleHosts);

    return () => {
      window.clearInterval(intervalId);
      window.removeEventListener('focus', refreshVisibleHosts);
      document.removeEventListener('visibilitychange', refreshVisibleHosts);
    };
  }, [refreshHostsVisible, user]);

  const hasHosts = availableHosts.length > 0;

  return (
    <div className="h-full overflow-y-auto safe-pad-x safe-pad-bottom">
      <div className="mx-auto flex w-full max-w-4xl flex-col gap-5 py-6">
        <section className="flex items-end justify-between gap-4">
          <div>
            <div className="gt-kicker">Account</div>
            <h1 className="mt-2 text-4xl font-semibold">Your Macs</h1>
            <p className="gt-muted mt-2 text-sm">
              {user?.email ?? 'Signed in'}
            </p>
          </div>
          <button
            type="button"
            onClick={() => void refreshHostsFromButton()}
            disabled={refreshing}
            aria-busy={refreshing}
            className="gt-button gt-button-ghost"
          >
            {hostRefreshButtonLabel(refreshing)}
          </button>
        </section>

        {(status || error) && (
          <section
            aria-live="polite"
            className={`rounded-[6px] border px-5 py-4 text-sm ${
              error
                ? 'border-err/30 bg-err/10 text-err'
                : 'border-accent/30 bg-accent/10 text-accent'
            }`}
          >
            {error ?? status}
          </section>
        )}

        {!hasHosts ? (
          <LinkCodePanel
            title={hostEmptyStateTitle()}
            subtitle={hostEmptyStateCopy()}
            linkCode={linkCode}
            linking={linking}
            onLinkCodeChange={setLinkCode}
            onSubmit={() => void submitLinkCode(linkCode)}
          />
        ) : (
          <>
            <section className="space-y-3">
              <div className="grid gap-3">
                {availableHosts.map((host) => {
                  const busy = busyHostId === host.deviceId;
                  const available = hostActionAvailable(host, busy);
                  return (
                    <article key={host.deviceId} className="gt-panel px-5 py-5">
                      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
                        <div className="min-w-0">
                          <div className="flex flex-wrap items-center gap-2">
                            <h2 className="truncate text-xl font-semibold">{host.label}</h2>
                            <HostStatusBadge host={host} />
                          </div>
                          {host.lastSeenAtUnixMs && (
                            <div className="gt-dim mt-2 text-sm">
                              Last seen {formatTimestamp(host.lastSeenAtUnixMs)}
                            </div>
                          )}
                        </div>
                        <div className="flex gap-2">
                          <button
                            type="button"
                            onClick={() => void openHost(host)}
                            disabled={!available}
                            className="gt-button gt-button-primary"
                          >
                            {hostActionLabel(host, busy)}
                          </button>
                        </div>
                      </div>
                    </article>
                  );
                })}
              </div>
            </section>

            <LinkCodePanel
              title="Add another Mac"
              subtitle="Enter a new code from the Mac app."
              linkCode={linkCode}
              linking={linking}
              onLinkCodeChange={setLinkCode}
              onSubmit={() => void submitLinkCode(linkCode)}
              compact
            />
          </>
        )}
      </div>
    </div>
  );
}

function LinkCodePanel({
  title,
  subtitle,
  linkCode,
  linking,
  onLinkCodeChange,
  onSubmit,
  compact = false,
}: {
  title: string;
  subtitle: string;
  linkCode: string;
  linking: boolean;
  onLinkCodeChange: (value: string) => void;
  onSubmit: () => void;
  compact?: boolean;
}) {
  const panelContent = (
    <>
      {!compact && (
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="gt-kicker">{title}</div>
            <div className="gt-muted mt-2 text-sm">{subtitle}</div>
          </div>
          <div className="gt-badge">One-time code</div>
        </div>
      )}
      <div className={compact ? 'mt-4 flex flex-col gap-3 md:flex-row' : 'mt-4 flex flex-col gap-3 md:flex-row'}>
        <input
          value={linkCode}
          onChange={(event) => onLinkCodeChange(normalizeCode(event.target.value))}
          placeholder="ABC123"
          maxLength={6}
          className="gt-input flex-1 text-center font-mono text-lg font-semibold uppercase tracking-[0.28em]"
        />
        <button
          type="button"
          onClick={onSubmit}
          disabled={linking || linkCode.trim().length < 6}
          className="gt-button gt-button-primary px-5 py-3 text-base"
        >
          {linking ? 'Adding…' : compact ? 'Add Mac' : 'Add this Mac'}
        </button>
      </div>
      {!compact && (
        <p className="gt-dim mt-3 text-sm">
          This code is only used once.
        </p>
      )}
    </>
  );

  if (compact) {
    return (
      <details className="gt-panel p-5">
        <summary className="cursor-pointer list-none">
          <div className="flex items-center justify-between gap-4">
            <div>
              <div className="text-sm font-semibold">{title}</div>
              <div className="gt-muted mt-1 text-sm">{subtitle}</div>
            </div>
            <span className="gt-badge">Add</span>
          </div>
        </summary>
        {panelContent}
      </details>
    );
  }

  return (
    <section className="gt-panel p-6">
      {panelContent}
    </section>
  );
}

function HostStatusBadge({ host }: { host: AccountHost }) {
  if (!host.trusted) {
    return (
      <span className="inline-flex items-center gap-2 rounded-[4px] bg-warn/15 px-2.5 py-1 text-[11px] font-medium uppercase tracking-[0.18em] text-warn">
        <span className="gt-status-dot bg-warn" />
        Preparing
      </span>
    );
  }

  if (!host.online) {
    return (
      <span className="inline-flex items-center gap-2 rounded-[4px] bg-surface-3 px-2.5 py-1 text-[11px] font-medium uppercase tracking-[0.18em] text-white/75">
        <span className="gt-status-dot bg-white/50" />
        Offline
      </span>
    );
  }

  return (
    <span className="inline-flex items-center gap-2 rounded-[4px] bg-ok px-2.5 py-1 text-[11px] font-medium uppercase tracking-[0.18em] text-surface-0">
      <span className="gt-status-dot bg-surface-0/60" />
      Online
    </span>
  );
}

export function hostActionLabel(host: Pick<AccountHost, 'online' | 'trusted'>, busy: boolean): string {
  if (busy) return 'Opening…';
  if (!host.trusted) return host.online ? 'Connect' : 'Preparing';
  if (!host.online) return 'View only';
  return 'Open';
}

export function hostActionAvailable(host: Pick<AccountHost, 'online' | 'trusted'>, busy: boolean): boolean {
  return !busy && (host.trusted || host.online);
}

export function hostRefreshButtonLabel(refreshing: boolean): string {
  return refreshing ? 'Refreshing…' : 'Refresh';
}

export function hostEmptyStateTitle(): string {
  return 'Add this Mac';
}

export function hostEmptyStateCopy(): string {
  return 'Enter the code shown on your Mac.';
}

export async function claimLinkedHostAndOpen(
  normalizedCode: string,
  actions: {
    claimHostLinkCode: (code: string) => Promise<AccountHost>;
    chooseHost: (hostDeviceId: string) => Promise<void>;
    setLinkCode: (value: string) => void;
    setStatus: (value: string | null) => void;
    setError: (value: string | null) => void;
    setLinking: (value: boolean) => void;
  },
): Promise<void> {
  actions.setLinking(true);
  actions.setError(null);
  actions.setStatus('Adding this Mac…');
  try {
    const host = await actions.claimHostLinkCode(normalizedCode);
    actions.setLinkCode('');
    if (!host.online) {
      actions.setStatus('Mac added. Waiting for this Mac…');
      return;
    }
    actions.setStatus('Mac added. Opening…');
    try {
      await actions.chooseHost(host.deviceId);
    } catch {
      actions.setStatus('Mac added. Open it below.');
    }
  } catch (err) {
    actions.setError((err as Error).message);
    actions.setStatus(null);
  } finally {
    actions.setLinking(false);
  }
}

function normalizeCode(value: string): string {
  return value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
}

function formatTimestamp(unixMs: number): string {
  try {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    }).format(new Date(unixMs));
  } catch {
    return new Date(unixMs).toLocaleString();
  }
}
