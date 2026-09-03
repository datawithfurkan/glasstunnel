import { useEffect, useState } from 'react';
import { shouldEnterHostLinkFlow, useAppStore } from '../lib/store';
import { AuthScreen } from '../auth/AuthScreen';
import { HostsScreen } from '../auth/HostsScreen';
import { ProfileScreen } from '../auth/ProfileScreen';
import { UnlockScreen } from '../lib/UnlockScreen';
import { AgentCarousel } from '../agents/AgentCarousel';
import { TopBar } from '../ui/TopBar';
import { applyWorkspaceFixture, isWorkspaceFixtureEnabled } from '../dev/workspaceFixture';
import { APP_UPDATE_REQUIRED_COPY, APP_UPDATE_REQUIRED_EVENT } from './appUpdateRecovery';
import {
  LIFECYCLE_RECOVERY_DEBOUNCE_MS,
  focusRecoveryRequest,
  mergeLifecycleRecoveryRequest,
  networkOnlineRecoveryRequest,
  pageResumeRecoveryRequest,
  pageShowRecoveryRequest,
  type LifecycleRecoveryRequest,
} from './lifecycleRecovery';

export function App() {
  const [updateRequired, setUpdateRequired] = useState(false);
  const route = useAppStore((s) => s.route);
  const bootstrap = useAppStore((s) => s.bootstrap);
  const pairedHost = useAppStore((s) => s.pairedHost);
  const peer = useAppStore((s) => s.peer);
  const relay = useAppStore((s) => s.relay);
  const navigateTo = useAppStore((s) => s.navigateTo);
  const disconnectPeer = useAppStore((s) => s.disconnectPeer);
  const recoverConnection = useAppStore((s) => s.recoverConnection);
  const resumeVideoPeerIfNeeded = useAppStore((s) => s.resumeVideoPeerIfNeeded);
  const workspaceFixtureEnabled = isWorkspaceFixtureEnabled();

  useEffect(() => {
    const showUpdateRequired = () => setUpdateRequired(true);
    window.addEventListener(APP_UPDATE_REQUIRED_EVENT, showUpdateRequired);
    return () => window.removeEventListener(APP_UPDATE_REQUIRED_EVENT, showUpdateRequired);
  }, []);

  useEffect(() => {
    if (applyWorkspaceFixture()) return;
    void bootstrap();
  }, [bootstrap]);

  useEffect(() => {
    if (workspaceFixtureEnabled) return;
    if ((route === 'workspace' || route === 'grid') && pairedHost && !relay && !peer) {
      void recoverConnection({ reason: 'workspace-open' });
    }
  }, [pairedHost, peer, recoverConnection, relay, route, workspaceFixtureEnabled]);

  useEffect(() => {
    if (workspaceFixtureEnabled) return;

    const enterHostLinkFlow = () => {
      if (!shouldEnterHostLinkFlow(useAppStore.getState().route, window.location.search)) return;
      disconnectPeer();
      navigateTo('hosts');
    };

    enterHostLinkFlow();
    window.addEventListener('focus', enterHostLinkFlow);
    window.addEventListener('pageshow', enterHostLinkFlow);
    window.addEventListener('popstate', enterHostLinkFlow);
    return () => {
      window.removeEventListener('focus', enterHostLinkFlow);
      window.removeEventListener('pageshow', enterHostLinkFlow);
      window.removeEventListener('popstate', enterHostLinkFlow);
    };
  }, [disconnectPeer, navigateTo, route, workspaceFixtureEnabled]);

  useEffect(() => {
    let hiddenAt = 0;
    let pendingRecover: LifecycleRecoveryRequest | null = null;
    let recoverTimer: number | null = null;
    const recover = (request: LifecycleRecoveryRequest) => {
      if (document.visibilityState === 'hidden') return;
      pendingRecover = mergeLifecycleRecoveryRequest(pendingRecover, request);
      if (recoverTimer !== null) return;
      recoverTimer = window.setTimeout(() => {
        recoverTimer = null;
        const request = pendingRecover;
        pendingRecover = null;
        if (!request || document.visibilityState === 'hidden') return;
        // Screen video is independent of the relay: a rendering stream is kept,
        // and one that stopped while the page was hidden is restarted here.
        resumeVideoPeerIfNeeded();
        void recoverConnection({ ...request, keepVideoPeer: true });
      }, LIFECYCLE_RECOVERY_DEBOUNCE_MS);
    };
    const onVisibilityChange = () => {
      if (document.visibilityState === 'hidden') {
        hiddenAt = Date.now();
        return;
      }
      recover(pageResumeRecoveryRequest(Date.now() - hiddenAt));
    };
    const onPageShow = (event: PageTransitionEvent) => {
      recover(pageShowRecoveryRequest(event.persisted));
    };
    const onFocus = () => recover(focusRecoveryRequest());
    const onOnline = () => recover(networkOnlineRecoveryRequest());

    document.addEventListener('visibilitychange', onVisibilityChange);
    window.addEventListener('pageshow', onPageShow);
    window.addEventListener('focus', onFocus);
    window.addEventListener('online', onOnline);
    return () => {
      if (recoverTimer !== null) {
        window.clearTimeout(recoverTimer);
      }
      document.removeEventListener('visibilitychange', onVisibilityChange);
      window.removeEventListener('pageshow', onPageShow);
      window.removeEventListener('focus', onFocus);
      window.removeEventListener('online', onOnline);
    };
  }, [recoverConnection, resumeVideoPeerIfNeeded]);

  if (updateRequired) return <AppUpdateRequiredScreen />;

  return (
    <div className="h-full w-full flex flex-col bg-surface-0 text-[color:var(--gt-text)]">
      {route !== 'auth' && <TopBar />}
      <main className="flex-1 overflow-hidden">
        {route === 'loading' && <LoadingScreen />}
        {route === 'auth' && <AuthScreen />}
        {route === 'hosts' && <HostsScreen />}
        {route === 'profile' && <ProfileScreen />}
        {route === 'unlock' && <UnlockScreen />}
        {(route === 'workspace' || route === 'grid') && <AgentCarousel />}
      </main>
    </div>
  );
}

function AppUpdateRequiredScreen() {
  return (
    <div className="h-full w-full safe-pad-x safe-pad-bottom flex items-center justify-center bg-surface-0 text-[color:var(--gt-text)]">
      <div className="gt-panel w-full max-w-sm p-6 text-center">
        <h1 className="text-xl font-semibold">{APP_UPDATE_REQUIRED_COPY.title}</h1>
        <p className="gt-muted mt-2 text-sm">{APP_UPDATE_REQUIRED_COPY.detail}</p>
        <button
          type="button"
          className="gt-button gt-button-primary mt-6 w-full"
          onClick={() => window.location.reload()}
        >
          {APP_UPDATE_REQUIRED_COPY.action}
        </button>
      </div>
    </div>
  );
}

function LoadingScreen() {
  return (
    <div className="h-full safe-pad-x safe-pad-bottom flex items-center justify-center">
      <div className="gt-panel w-full max-w-sm p-6 text-center">
        <div className="mx-auto h-8 w-8 rounded-full border-2 border-[color:var(--gt-border)] border-t-[color:var(--gt-text)] animate-spin" />
        <div className="mt-4 text-lg font-semibold">Loading Glasstunnel</div>
        <div className="gt-muted mt-2 text-sm">Checking your account and linked Macs.</div>
      </div>
    </div>
  );
}
