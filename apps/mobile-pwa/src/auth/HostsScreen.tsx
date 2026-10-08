import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import type { AccountHost } from '../lib/accountApi';
import { currentHostsFixtureDialog } from '../dev/workspaceFixture';
import {
  deviceFingerprint,
  duplicateHostLabels,
  hostLabelKey,
  removedStatus,
  renamedStatus,
} from '../lib/hostManagement';
import { useAppStore, type HostListStatus } from '../lib/store';
import {
  HostActionsMenu,
  MacDetailsDialog,
  RemoveMacDialog,
  RenameMacDialog,
  formatHostTimestamp,
  hostMenuButtonSelector,
  type HostMenuAction,
} from './HostManagement';

/** A dialog opened from a Mac's "⋯" menu. `snapshot` keeps it whole if the Mac leaves the list meanwhile. */
interface HostDialogState {
  kind: HostMenuAction;
  deviceId: string;
  snapshot?: AccountHost;
}

export function HostsScreen() {
  const user = useAppStore((s) => s.user);
  const accessRevocationNotice = useAppStore((s) => s.accessRevocationNotice);
  const availableHosts = useAppStore((s) => s.availableHosts);
  const hostsStatus = useAppStore((s) => s.hostsStatus);
  const chooseHost = useAppStore((s) => s.chooseHost);
  const refreshHosts = useAppStore((s) => s.refreshHosts);
  const claimHostLinkCode = useAppStore((s) => s.claimHostLinkCode);
  const renameHost = useAppStore((s) => s.renameHost);
  const removeHost = useAppStore((s) => s.removeHost);
  const [linkCode, setLinkCode] = useState('');
  // A Mac opened this page with its one-time code: the add flow shows at once,
  // as it always has, even while the account's Macs are still loading, and
  // only until that claim settles (see claimCodeFromMac).
  const [macClaimPending, setMacClaimPending] = useState(() => linkCodeInAddressBar() !== '');
  const macClaimUserIdRef = useRef(user?.id ?? null);
  // The live region starts empty and fills once on screen, so its first
  // message ("Loading your Macs…") is announced too.
  const [announcing, setAnnouncing] = useState(false);
  const [busyHostId, setBusyHostId] = useState<string | null>(null);
  const [linking, setLinking] = useState(false);
  const [pendingClaimedHostId, setPendingClaimedHostId] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const retryButtonRef = useRef<HTMLButtonElement>(null);
  const retryFocusPending = useRef(false);
  const autoClaimedCodeRef = useRef<string | null>(null);
  const lastAutoRefreshAtRef = useRef(0);
  // A device-management fixture may open the menu or a dialog at once.
  const [menuHostId, setMenuHostId] = useState<string | null>(() => {
    const fixture = currentHostsFixtureDialog();
    return fixture?.kind === 'menu' ? fixture.deviceId : null;
  });
  const [hostDialog, setHostDialog] = useState<HostDialogState | null>(() => {
    const fixture = currentHostsFixtureDialog();
    return fixture && fixture.kind !== 'menu' ? { kind: fixture.kind, deviceId: fixture.deviceId } : null;
  });

  const openHostDialog = (host: AccountHost, kind: HostMenuAction) => {
    setMenuHostId(null);
    setHostDialog({ kind, deviceId: host.deviceId, snapshot: host });
  };

  // Focus goes back to the Mac's "⋯" button, or to the list when the Mac is gone.
  const returnFocusFor = (deviceId: string) => () =>
    document.querySelector<HTMLElement>(hostMenuButtonSelector(deviceId)) ?? listRef.current;

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
      await refreshHosts({ force: true, userInitiated: true });
      // A failed list refresh is already on screen: the top bar shows the
      // store's message, and an empty list shows the "Could not load" alert.
      // A local copy would outlive a later background refresh that succeeds.
      setStatus(useAppStore.getState().error ? null : 'Macs updated.');
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
        claimHostLinkCode: async (code) => {
          const host = await claimHostLinkCode(code);
          setPendingClaimedHostId(host.online ? null : host.deviceId);
          return host;
        },
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
    setAnnouncing(true);
  }, []);

  // Declared before the auto-claim below: when another account signs in, a
  // claim this page started belongs to the account that left.
  useEffect(() => {
    const userId = user?.id ?? null;
    if (macClaimUserIdRef.current === userId) return;
    macClaimUserIdRef.current = userId;
    setMacClaimPending(false);
  }, [user?.id]);

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

    void claimCodeFromMac(code, { submitLinkCode, setMacClaimPending });
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

  useEffect(() => {
    if (!pendingClaimedHostId) return;
    const host = availableHosts.find((entry) => entry.deviceId === pendingClaimedHostId);
    if (host?.online) {
      setPendingClaimedHostId(null);
      void chooseHost(host.deviceId).catch(() => setStatus('Mac added. Open it below.'));
      return;
    }
    const interval = window.setInterval(() => void refreshHostsVisible(), 10_000);
    return () => window.clearInterval(interval);
  }, [pendingClaimedHostId, availableHosts, chooseHost, refreshHostsVisible]);

  const listView = hostListView({
    hostCount: availableHosts.length,
    hostsStatus,
    macClaimPending,
  });

  // "Try again" unmounts itself when the list starts loading. Keep keyboard
  // and screen reader focus in the list: on the list while it loads, back on
  // "Try again" if the retry failed, on the list once it shows.
  useEffect(() => {
    if (!retryFocusPending.current) return;
    if (listView === 'error') {
      // The button is disabled until the retry has fully settled.
      if (refreshing) return;
      retryButtonRef.current?.focus();
      retryFocusPending.current = false;
    } else {
      listRef.current?.focus();
      if (listView !== 'loading') retryFocusPending.current = false;
    }
  }, [listView, refreshing]);
  const announcement = announcing
    ? hostListAnnouncement({ view: listView, hostCount: availableHosts.length, hostsStatus, macClaimPending })
    : '';
  const duplicateLabels = duplicateHostLabels(availableHosts);
  const dialogHost = hostDialog
    ? (availableHosts.find((host) => host.deviceId === hostDialog.deviceId) ?? hostDialog.snapshot ?? null)
    : null;
  const banner = error ?? accessRevocationNotice ?? status;

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

        {/* Always in the page (taking no room while empty), so a message that appears later is announced. */}
        <section aria-live="polite" className={banner ? undefined : '-mt-5'}>
          {banner && (
            <div
              className={`rounded-[6px] border px-5 py-4 text-sm [overflow-wrap:anywhere] ${
                error || accessRevocationNotice
                  ? 'border-err/30 bg-err/10 text-err'
                  : 'border-accent/30 bg-accent/10 text-accent'
              }`}
            >
              {banner}
            </div>
          )}
        </section>

        {/* Persistent, so "Loading your Macs…" and then the outcome are announced. */}
        <p role="status" aria-live="polite" className="sr-only">
          {announcement}
        </p>

        <div
          ref={listRef}
          tabIndex={-1}
          aria-busy={listView === 'loading'}
          className="flex flex-col gap-5 focus:outline-none"
        >
          {listView === 'loading' ? (
            <HostListLoadingPanel />
          ) : listView === 'error' ? (
            <HostListErrorPanel
              retryRef={retryButtonRef}
              refreshing={refreshing}
              onRefresh={() => {
                retryFocusPending.current = true;
                void refreshHostsFromButton();
              }}
            />
          ) : listView === 'empty' ? (
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
                {/* One column that never grows past the screen: a long name truncates. */}
                <div className="grid grid-cols-1 gap-3">
                  {availableHosts.map((host) => {
                    const busy = busyHostId === host.deviceId;
                    const available = hostActionAvailable(host, busy);
                    return (
                      <article key={host.deviceId} className="gt-panel min-w-0 py-4 pl-5 pr-3 md:py-5">
                        <div className="flex items-start gap-2 md:items-center">
                          <div className="flex min-w-0 flex-1 flex-col gap-4 pt-2 md:flex-row md:items-center md:justify-between md:pt-0">
                            <div className="min-w-0">
                              <div className="flex flex-wrap items-center gap-2">
                                <h2 className="max-w-full truncate text-xl font-semibold">{host.label}</h2>
                                <HostStatusBadge host={host} />
                              </div>
                              {host.lastSeenAtUnixMs && (
                                <div className="gt-dim mt-2 text-sm">
                                  Last seen {formatHostTimestamp(host.lastSeenAtUnixMs)}
                                </div>
                              )}
                              {duplicateLabels.has(hostLabelKey(host.label)) && (
                                // Two Macs with one name: the device ID tells them apart.
                                <div className="gt-dim mt-1 text-sm">
                                  Device ID <span className="font-mono">{deviceFingerprint(host.deviceId)}</span>
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
                          <HostActionsMenu
                            host={host}
                            open={menuHostId === host.deviceId}
                            onOpenChange={(open) => setMenuHostId(open ? host.deviceId : null)}
                            onSelect={(action) => openHostDialog(host, action)}
                          />
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

      {hostDialog && dialogHost && hostDialog.kind === 'rename' && (
        <RenameMacDialog
          host={dialogHost}
          rename={renameHost}
          onRenamed={(label) => {
            setHostDialog(null);
            setError(null);
            setStatus(renamedStatus(label));
          }}
          onClose={() => setHostDialog(null)}
          returnFocus={returnFocusFor(dialogHost.deviceId)}
        />
      )}
      {hostDialog && dialogHost && hostDialog.kind === 'details' && (
        <MacDetailsDialog
          host={dialogHost}
          onClose={() => setHostDialog(null)}
          returnFocus={returnFocusFor(dialogHost.deviceId)}
        />
      )}
      {hostDialog && dialogHost && hostDialog.kind === 'remove' && (
        <RemoveMacDialog
          host={dialogHost}
          remove={removeHost}
          onRemoved={() => {
            setHostDialog(null);
            setError(null);
            setStatus(removedStatus(dialogHost.label));
          }}
          onClose={() => setHostDialog(null)}
          returnFocus={returnFocusFor(dialogHost.deviceId)}
        />
      )}
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

function HostListLoadingPanel() {
  // The list container around it is aria-busy; the live region above speaks.
  return (
    <section className="gt-panel p-6">
      <div className="flex items-center gap-4">
        <div
          aria-hidden="true"
          className="h-8 w-8 shrink-0 rounded-full border-2 border-[color:var(--gt-border)] border-t-[color:var(--gt-text)] animate-spin"
        />
        <div className="min-w-0">
          <div className="text-lg font-semibold">{HOST_LIST_COPY.loadingTitle}</div>
          <div className="gt-muted mt-1 text-sm">{HOST_LIST_COPY.loadingDetail}</div>
        </div>
      </div>
    </section>
  );
}

function HostListErrorPanel({
  retryRef,
  refreshing,
  onRefresh,
}: {
  retryRef: RefObject<HTMLButtonElement>;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  return (
    <section role="alert" className="gt-panel p-6">
      {/* The top bar already says why; this offers the way out. */}
      <div className="text-lg font-semibold">{HOST_LIST_COPY.errorTitle}</div>
      <button
        ref={retryRef}
        type="button"
        onClick={onRefresh}
        disabled={refreshing}
        aria-busy={refreshing}
        className="gt-button gt-button-primary mt-4 px-5 py-3 text-base"
      >
        {HOST_LIST_COPY.errorAction}
      </button>
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

export const HOST_LIST_COPY = {
  loadingTitle: 'Loading your Macs…',
  loadingDetail: 'Checking your account for linked Macs.',
  errorTitle: 'Could not load your Macs',
  errorAction: 'Try again',
  emptyAnnouncement: 'No Macs on this account yet.',
} as const;

export type HostListView = 'hosts' | 'loading' | 'error' | 'empty';

/**
 * What the list area shows. Macs on hand are always listed. Without any, the
 * add-a-Mac form shows for a list that loaded empty, and at once while a
 * claim a Mac started (with its code in this page's address) is pending. A
 * list still on its way, or one that could not load, never looks like "no
 * Macs".
 */
export function hostListView(input: {
  hostCount: number;
  hostsStatus: HostListStatus;
  macClaimPending: boolean;
}): HostListView {
  if (input.hostCount > 0) return 'hosts';
  if (input.macClaimPending) return 'empty';
  if (input.hostsStatus === 'loading') return 'loading';
  if (input.hostsStatus === 'error') return 'error';
  return 'empty';
}

/**
 * What the list's live region says: "Loading your Macs…", then the outcome.
 * A failed list announces itself (its panel is an alert), and a claim a Mac
 * started reports its own progress, so neither repeats here.
 */
export function hostListAnnouncement(input: {
  view: HostListView;
  hostCount: number;
  hostsStatus: HostListStatus;
  macClaimPending?: boolean;
}): string {
  // A claim the Mac started reports its own progress ("Adding this Mac…");
  // the list must not announce "no Macs" in the middle of it.
  if (input.macClaimPending) return '';
  if (input.view === 'loading') return HOST_LIST_COPY.loadingTitle;
  if (input.view === 'hosts') return input.hostCount === 1 ? '1 Mac listed.' : `${input.hostCount} Macs listed.`;
  if (input.view === 'empty' && input.hostsStatus === 'loaded') return HOST_LIST_COPY.emptyAnnouncement;
  return '';
}

/**
 * Claims the code a Mac put in this page's address. Its add flow shows while
 * the claim is pending and goes once the claim settles, either way: then the
 * list shows what the account holds (loading, failed, empty, or the Macs).
 */
export async function claimCodeFromMac(
  code: string,
  actions: {
    submitLinkCode: (code: string) => Promise<void>;
    setMacClaimPending: (pending: boolean) => void;
  },
): Promise<void> {
  actions.setMacClaimPending(true);
  try {
    await actions.submitLinkCode(code);
  } finally {
    actions.setMacClaimPending(false);
  }
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

/** The one-time code a Mac put in this page's address, as the auto-claim reads it. */
function linkCodeInAddressBar(): string {
  if (typeof window === 'undefined') return '';
  return normalizeCode(new URLSearchParams(window.location.search).get('linkCode') ?? '');
}
