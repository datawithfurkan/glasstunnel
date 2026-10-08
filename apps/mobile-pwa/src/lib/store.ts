import { create } from 'zustand';
import { del as idbDel, get as idbGet, set as idbSet, keys as idbKeys } from 'idb-keyval';
import { OfflineCache, type CacheTiming } from './offlineCache';
import {
  base64FromBytes,
  bytesFromBase64,
  generateDeviceKeypair,
  type DeviceKeypair,
} from '@glasstunnel/shared-crypto';
import {
  AdapterKind,
  AgentStatus,
  ChatRole,
  type AgentRuntimeControls,
  type AgentInputRequestResponse,
  type AgentRuntimeSettingsUpdate,
  type AgentStateSnapshot,
  type AgentTargetOption,
  type GridLayout,
  type Hello,
  type ImageAttachmentInput,
  type RemoteApp,
  type RemoteAppActionRequest,
  type ScreenShareQuality,
  type ScreenPointerInput,
} from '@glasstunnel/protocol';
import type { MessageDetail } from '@glasstunnel/protocol';
import {
  AccountApiError,
  HOST_MANAGEMENT_TIMEOUT_MS,
  claimHostCode,
  fetchAccountHosts,
  isAccountApiAuthFailure,
  registerBrowserDevice,
  removeAccountHost,
  renameAccountHost,
  type AccountHost,
} from './accountApi';
import {
  HOST_MANAGEMENT_COPY,
  HOST_REMOVED_RELAY_REASON,
  hostActionErrorCopy,
  isHostNotInAccount,
  isNetworkFailure,
  validateHostLabel,
  type HostAction,
} from './hostManagement';
import { createClientId } from './id';
import { platformConfig } from './platform';
import { registerPushSubscription } from '../notifications/push';
import { SignalingClient } from '../transport/SignalingClient';
import { PeerConnection } from '../transport/PeerConnection';
import type { FileAttachmentInput } from '../transport/PeerConnection';
import type { RelayConnection, RelayScreenFrame } from '../transport/RelayConnection';
import { PeerFlowAbortRegistry } from '../transport/PeerFlowAbortRegistry';
import {
  hasAccountAuth,
  authClient,
  clearPasswordResetToken,
  readPasswordResetToken,
  takeInvalidPasswordResetLink,
  takeSignInFromThisTab,
  type Session,
  type User,
} from './authClient';
import {
  PASSWORD_RESET_COPY,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  isInvalidResetTokenError,
  passwordResetErrorCopy,
  passwordResetRequestErrorCopy,
  type PasswordResetFlow,
} from './passwordReset';
import {
  bindPendingLinkCodeEmail,
  clearPendingLinkCode,
  moveLinkCodeFromUrl,
  restorePendingLinkCodeForSignIn,
} from './pendingLinkCode';
import {
  fallbackRemoteAppsFromLayout,
  isScreenSharingOn,
  isScreenStreamAvailable,
  remoteAppsForCachedWorkspace,
  remoteAppsWithScreenSharingOff,
  hasFreshRelayScreenFrameTimestamp,
  shouldCheckPendingScreenStop,
  shouldAcceptRelayScreenFrame,
  SCREEN_STOP_CONFIRMATION_TIMEOUT_MS,
} from './remoteApps';
import {
  SCREEN_STREAM_CONNECTING_MESSAGE,
  SCREEN_STREAM_DISCONNECTED_MESSAGE,
  isScreenStreamStatusMessage,
} from './screenStreamStatus';
import { connectionStatusCopy } from './connectionCopy';

export type Route =
  | 'loading'
  | 'auth'
  | 'hosts'
  | 'profile'
  | 'unlock'
  | 'grid'
  | 'workspace';

/**
 * Where the signed-in account's list of Macs stands. `loading` lasts until the
 * first list for the session arrives, so an empty list is never shown as "no
 * Macs" while it is still on its way. A refresh of a list already on screen
 * stays `loaded`, and so does its failure. A failed first list (`error`) goes
 * back to `loading` only for a refresh the person asked for; background
 * refreshes leave the failure on screen until one of them succeeds.
 */
export type HostListStatus = 'idle' | 'loading' | 'loaded' | 'error';

const LOCAL_MESSAGE_HISTORY_LIMIT = 250;
const LOCAL_OPTIMISTIC_MESSAGE_TTL_MS = 60_000;

export interface PairedHost {
  deviceId: string;
  publicKeyB64: string;
  label: string;
  signalingUrl: string;
  turnUrl?: string;
  turnUsername?: string;
  turnPassword?: string;
  pairedAtUnixMs: number;
}

export interface AuthenticatedUser {
  id: string;
  email: string;
  displayName: string;
  avatarUrl?: string;
}

interface RecoverConnectionOptions {
  reason?: string;
  forceRestart?: boolean;
  refreshHosts?: boolean;
  /**
   * Keep a live screen video peer while the relay reconnects. The video peer
   * does not depend on the relay socket, so relay blips and lifecycle events
   * should not restart a picture that is still rendering.
   */
  keepVideoPeer?: boolean;
}

interface StartPeerOptions {
  keepVideoPeer?: boolean;
}

export interface AppState {
  route: Route;
  locked: boolean;
  readOnlyMode: boolean;
  phoneKeypair: DeviceKeypair | null;
  pairedHost: PairedHost | null;
  availableHosts: AccountHost[];
  /** Whether `availableHosts` is the account's list yet; see HostListStatus. */
  hostsStatus: HostListStatus;
  accessRevocationNotice: string | null;
  user: AuthenticatedUser | null;
  authConfigured: boolean;
  layout: GridLayout | null;
  remoteApps: RemoteApp[];
  hostHello: Hello | null;
  workspaceHostDeviceId: string | null;
  agents: Record<string, AgentStateSnapshot>;
  /** Full text fetched on request, scoped to agent and message IDs. */
  messageDetails: Record<string, Record<string, MessageDetail>>;
  videoStreams: Record<string, MediaStream>;
  relayScreenFrames: Record<string, RelayScreenFrame>;
  screenShareQuality: ScreenShareQuality;
  peer: PeerConnection | null;
  signaling: SignalingClient | null;
  relay: RelayConnection | null;
  relayHostOnline: boolean | null;
  error: string | null;
  signOutError: string | null;
  signingOut: boolean;
  /**
   * The forgot-password or reset-password screen, when one is open. A reset
   * link shows its screen over everything else, even while signed in.
   */
  passwordResetFlow: PasswordResetFlow | null;

  bootstrap: () => Promise<void>;
  navigateTo: (route: Route) => void;
  setLocked: (locked: boolean) => void;
  setReadOnly: (readOnly: boolean) => void;
  forgetCurrentMac: () => Promise<void>;
  clearOfflineCopies: () => Promise<void>;
  expireOfflineCopies: () => void;
  disconnectPeer: () => void;
  startPeer: (options?: StartPeerOptions) => Promise<void>;
  startVideoPeer: () => Promise<void>;
  stopVideoPeer: (agentId?: string) => void;
  /** Restart screen video after the page was hidden or a flow failed, if it is still wanted. */
  resumeVideoPeerIfNeeded: () => void;
  clearVideoStream: (agentId: string) => void;
  clearRelayScreenFrame: (agentId: string) => void;
  setScreenShareQuality: (quality: ScreenShareQuality) => void;
  recoverConnection: (options?: RecoverConnectionOptions) => Promise<void>;
  signInWithGoogle: () => Promise<void>;
  signInWithGitHub: () => Promise<void>;
  signInWithPassword: (email: string, password: string) => Promise<void>;
  signUpWithPassword: (email: string, password: string, displayName?: string) => Promise<void>;
  signOut: () => Promise<void>;
  /** Shows the reset screen for a reset link this tab opened (token or invalid link). */
  loadPasswordResetLink: () => void;
  /**
   * Opens the forgot screen. A Mac linkCode in the address bar moves into
   * storage (10 minutes), bound to `email` (the address typed so far), for the
   * sign-in after the reset.
   */
  openForgotPassword: (email?: string) => void;
  /** Leaves the forgot/reset screens and forgets a pending reset token. */
  closePasswordReset: () => void;
  /**
   * Sends a reset email; resolves true when the server accepted the request.
   * A Mac linkCode this tab's forgot flow kept is then bound to that address.
   */
  requestPasswordReset: (email: string) => Promise<boolean>;
  /** Sets the new password; on success every session, including this one, is signed out. */
  completePasswordReset: (token: string, newPassword: string) => Promise<boolean>;
  /**
   * Loads the account's Macs again. `userInitiated` is for the person's own
   * Refresh or Try again: only that moves a failed list back to loading.
   */
  refreshHosts: (options?: { force?: boolean; userInitiated?: boolean }) => Promise<void>;
  claimHostLinkCode: (code: string) => Promise<AccountHost>;
  chooseHost: (hostDeviceId: string) => Promise<void>;
  /**
   * Renames a Mac in the account. The list shows the new name once the server
   * stored it; resolves with that name. Rejects with an AccountApiError whose
   * message is ready to show (invalid name, Mac not in this account, service
   * unavailable, no connection).
   */
  renameHost: (deviceId: string, label: string) => Promise<string>;
  /**
   * Removes a Mac from the account. The Mac leaves the list only once the
   * server removed it; when it was this browser's Mac, its workspace, saved
   * choice and offline copies go too. When no answer comes (a timeout or a
   * dropped connection), the account's list is loaded again: a Mac it no
   * longer has was removed, and this resolves as a removal does. Otherwise
   * rejects like renameHost.
   */
  removeHost: (deviceId: string) => Promise<void>;
  sendText: (agentId: string, text: string, submit: boolean) => boolean;
  sendScreenPointer: (
    agentId: string,
    x: number,
    y: number,
    action?: ScreenPointerInput['action'],
  ) => void;
  sendInputRequestResponse: (response: AgentInputRequestResponse) => void;
  sendImageAttachment: (
    agentId: string,
    input: Omit<ImageAttachmentInput, 'agentId'>,
  ) => Promise<boolean>;
  sendFileAttachmentBatch: (
    agentId: string,
    files: Omit<FileAttachmentInput, 'agentId'>[],
  ) => Promise<boolean>;
  sendQuickReply: (agentId: string, kind: number) => void;
  sendInterrupt: (agentId: string) => void;
  requestMessageDetail: (agentId: string, messageId: string) => boolean;
  selectTarget: (agentId: string, targetId: string) => boolean;
  renameTarget: (agentId: string, targetId: string, label: string) => boolean;
  updateRuntimeSettings: (
    agentId: string,
    update: Omit<AgentRuntimeSettingsUpdate, 'agentId'>,
  ) => boolean;
  requestRemoteAppAction: (
    remoteAppId: string,
    action: RemoteAppActionRequest['action'],
    options?: { screenQuality?: ScreenShareQuality },
  ) => boolean;
}

const PHONE_KEY_KEY = 'gt.phone.keypair';
const PAIRED_HOST_KEY = 'gt.pairedHost';
const offlineCache = new OfflineCache({ get: (key) => idbGet(key), set: (key, value) => idbSet(key, value), del: (key) => idbDel(key), keys: () => idbKeys() });
let cacheExpiryTimer: ReturnType<typeof setTimeout> | undefined;
const CACHE_EXPIRED_COPY = 'Offline copies expired. Reconnect your Mac to refresh this workspace.';
const SIGN_OUT_FAILURE_COPY = 'Sign-out cleanup is incomplete. Reconnect and retry, or clear this site\'s browser data.';
const SCREEN_SHARE_QUALITY_KEY = 'gt.screenShareQuality';
let authSubscriptionAttached = false;
let sessionSyncVersion = 0;
let pendingSignOutAccount: string | undefined;
let refreshHostsInFlight: Promise<void> | null = null;
let lastRefreshHostsCompletedAt = 0;

/**
 * A session sync, as far as this browser's registration with the account
 * goes. The registration answers with the account's Macs as this browser may
 * use them. A plain list fetch before it succeeded reads this browser as an
 * unknown device, so every Mac would show as untrusted ("Preparing"). While
 * the current sync runs, refreshHosts therefore waits for it instead of
 * fetching, and when the current sync did not register this browser,
 * refreshHosts registers it again.
 */
interface BrowserRegistration {
  syncVersion: number;
  /** Until the sync applied what it received, or gave up. */
  running: boolean;
  /** This browser's registration succeeded in this sync. */
  succeeded: boolean;
  /** Resolves (never rejects) when the sync stops running. */
  done: Promise<void>;
}
let browserRegistration: BrowserRegistration | null = null;

/**
 * Renames and removals this page made, in order. A host list requested before
 * one of them may answer after it with the old name or the removed Mac; the
 * edits made since that list was requested apply on top of it.
 */
interface HostListEdit {
  seq: number;
  deviceId: string;
  label?: string;
  removed?: boolean;
}
let hostListEditSeq = 0;
let hostListEdits: HostListEdit[] = [];
const HOST_LIST_EDIT_HISTORY = 32;
/**
 * Macs this page is removing, until when. The relay closes this browser's
 * socket to such a Mac as it goes; the page already says it was removed.
 */
const hostRemovalsByThisPage = new Map<string, number>();
/** Longer than a removal request may wait, plus the list check after a lost answer. */
const HOST_REMOVAL_ECHO_WINDOW_MS = HOST_MANAGEMENT_TIMEOUT_MS + 15_000;
const HOST_REVOKED_NOTICE = 'Access to this Mac was revoked.';
const HOST_REVOKED_CACHE_FAILED_NOTICE =
  'Access was revoked. Browser offline copies could not be cleared; retry in Profile.';
/**
 * The Mac whose offline copies this page could not clear, with the notice
 * that says so. A later rename or removal of that Mac must not hide the
 * notice: the copies stay in this browser until the user retries in Profile.
 */
let cacheFailureNotice: { deviceId: string; notice: string } | null = null;
const HOST_LIST_UNAVAILABLE_COPY = 'Signed in, but your Macs could not load. Refresh to try again.';
const HOST_CHOICE_NOT_SAVED_COPY =
  "Your Macs loaded, but this browser could not save your Mac choice. Check this site's storage settings.";

type SessionSyncOrigin = 'start-up' | 'auth-event';

interface SharedSessionSync {
  userId: string;
  accessToken: string;
  origin: SessionSyncOrigin;
  version: number;
  settled: boolean;
  done: Promise<void>;
}

/**
 * Start-up reads the session itself, and on the same load the auth listener
 * announces that session too (INITIAL_SESSION, or SIGNED_IN after a provider
 * return). Each would register this browser and load its Macs. The later one
 * joins the earlier synchronization of the same session (user and token)
 * instead. Auth events never join each other: a sign-in, account switch,
 * cross-tab change, or sign-out always synchronizes.
 */
let sharedSessionSync: SharedSessionSync | null = null;
let peerStartGeneration = 0;
let videoPeerStartGeneration = 0;
/** True between startVideoPeer and stopVideoPeer: the screen panel wants video. */
let videoPeerWanted = false;
let videoRetryTimer: number | null = null;
let videoRetryAttempt = 0;
const peerFlowAbortRegistry = new PeerFlowAbortRegistry();
let reconnectTimer: number | null = null;
let reconnectAttempt = 0;
let recoverConnectionInFlight: Promise<void> | null = null;
let lastRecoverHostRefreshAt = 0;
let pendingScreenStop = false;
let pendingScreenStopRequestedAt = 0;
let screenStopConfirmationTimer: number | null = null;

const REFRESH_HOSTS_MIN_INTERVAL_MS = 5_000;
const RECOVER_HOST_REFRESH_INTERVAL_MS = 30_000;
const RECONNECT_BACKOFF_MS = [1_500, 3_000, 5_000, 10_000, 20_000, 30_000];
export const VIDEO_RETRY_BACKOFF_MS = [2_000, 4_000, 8_000, 16_000, 30_000];
const USER_INITIATED_RECOVERY_REASONS = new Set([
  'workspace-retry',
  'remote-app-retry',
  'remote-app-start',
  'terminal-new-session',
  'terminal-close-session',
  'terminal-rename-session',
]);

type SetState = (
  partial: AppState | Partial<AppState> | ((state: AppState) => AppState | Partial<AppState>),
  replace?: boolean,
) => void;

export const useAppStore = create<AppState>((set, get) => ({
  route: 'loading',
  locked: true,
  readOnlyMode: false,
  phoneKeypair: null,
  pairedHost: null,
  availableHosts: [],
  hostsStatus: 'idle',
  accessRevocationNotice: null,
  user: null,
  authConfigured: hasAccountAuth(),
  layout: null,
  remoteApps: [],
  hostHello: null,
  workspaceHostDeviceId: null,
  agents: {},
  messageDetails: {},
  videoStreams: {},
  relayScreenFrames: {},
  screenShareQuality: loadScreenShareQuality(),
  peer: null,
  signaling: null,
  relay: null,
  relayHostOnline: null,
  error: null,
  signOutError: null,
  signingOut: false,
  passwordResetFlow: null,

  async bootstrap() {
    // Before anything async: the reset token leaves the address bar at once.
    // A malformed reset link must never block start-up.
    try {
      get().loadPasswordResetLink();
    } catch {
      // Without a readable reset link the app starts as usual.
    }
    try {
      let keypair = await loadKeypair();
      if (!keypair) {
        keypair = await generateDeviceKeypair();
        await saveKeypair(keypair);
      }

      const storedHost = ((await idbGet(PAIRED_HOST_KEY)) as PairedHost | undefined) ?? null;
      set({
        phoneKeypair: keypair,
        pairedHost: storedHost,
        authConfigured: hasAccountAuth(),
      });

      if (!authClient) {
        set({
          route: 'auth',
        });
        return;
      }

      if (!authSubscriptionAttached) {
        authSubscriptionAttached = true;
        authClient.auth.onAuthStateChange((event, session) => {
          if (event === 'TOKEN_REFRESHED') return;
          void synchronizeSessionOnce(set, get, session, 'auth-event');
        });
      }

      await authClient.auth.initialize();
      const {
        data: { session },
      } = await authClient.auth.getSession();
      // The listener usually announced this session already; that
      // synchronization registers this browser, not a second one.
      await synchronizeSessionOnce(set, get, session, 'start-up');
    } catch (err) {
      set({
        error: (err as Error).message,
        route: fallbackEntryRoute(),
      });
    }
  },

  navigateTo(route) {
    set({ route });
  },

  setLocked(locked) {
    const state = get();
    const route = locked
      ? 'unlock'
      : state.pairedHost
        ? 'workspace'
        : state.user
          ? 'hosts'
          : fallbackEntryRoute();
    set({ locked, route });
  },

  setReadOnly(readOnly) {
    const peer = get().peer;
    const relay = get().relay;
    set({ readOnlyMode: readOnly });
    if (get().hostHello?.hostReadOnly !== undefined) {
      relay?.sendReadOnlyUpdate(readOnly);
      peer?.sendReadOnlyUpdate(readOnly);
    }
  },

  async forgetCurrentMac() {
    const account = get().user?.id;
    const hostId = get().pairedHost?.deviceId;
    get().disconnectPeer();
    const pairedHost = get().pairedHost;
    if (pairedHost) {
      localStorage.removeItem(`gt.webauthn.enrolled.${pairedHost.deviceId}`);
    }
    await offlineCache.clear(account, hostId);
    await idbDel(PAIRED_HOST_KEY);
    get().peer?.close();
    get().signaling?.disconnect();
    get().relay?.disconnect();
    clearPendingScreenStop();
    const user = get().user;
    set({
      pairedHost: null,
      peer: null,
      signaling: null,
      relay: null,
      relayHostOnline: null,
      agents: {},
      messageDetails: {},
      videoStreams: {},
      relayScreenFrames: {},
      layout: null,
      remoteApps: [],
      hostHello: null,
      workspaceHostDeviceId: null,
      route: user ? 'hosts' : fallbackEntryRoute(),
    });
  },

  async clearOfflineCopies() {
    const pending = offlineCache.clear();
    dropOfflineItems(set, ['hello', 'layout', 'apps', ...Object.keys(get().agents).map((id) => `agent:${id}`)], false);
    await pending;
  },

  expireOfflineCopies() {
    dropOfflineItems(set, offlineCache.prune());
    scheduleCacheExpiry();
  },

  disconnectPeer() {
    offlineCache.reset();
    clearTimeout(cacheExpiryTimer);
    cacheExpiryTimer = undefined;
    peerStartGeneration += 1;
    videoPeerStartGeneration += 1;
    peerFlowAbortRegistry.cancelAll();
    clearReconnectTimer();
    forgetVideoPeer();
    get().peer?.close();
    get().signaling?.disconnect();
    get().relay?.disconnect();
    clearPendingScreenStop();
    set({
      peer: null,
      signaling: null,
      relay: null,
      relayHostOnline: null,
      hostHello: null,
      layout: null,
      remoteApps: [],
      agents: {},
      messageDetails: {},
      workspaceHostDeviceId: null,
      videoStreams: {},
      relayScreenFrames: {},
    });
  },

  async startPeer(options) {
    const { phoneKeypair, pairedHost } = get();
    if (!phoneKeypair || !pairedHost) return;
    const generation = ++peerStartGeneration;
    const isCurrent = () => generation === peerStartGeneration;
    // A rendering screen stream is independent of the relay socket: keep it
    // across relay reconnects and lifecycle recoveries unless the caller asks
    // for a full restart. A video flow that has not produced a stream yet is
    // restarted by the screen panel once the host is online again.
    const keepVideoPeer = options?.keepVideoPeer === true && hasScreenVideoStream(get());
    if (keepVideoPeer) {
      peerFlowAbortRegistry.cancel('primary');
    } else {
      videoPeerStartGeneration += 1;
      clearVideoRetryTimer();
      peerFlowAbortRegistry.cancelAll();
      get().peer?.close();
      get().signaling?.disconnect();
    }
    clearReconnectTimer();
    get().relay?.disconnect();
    get().expireOfflineCopies();
    const cached = await loadRelayCache(get().user?.id ?? '', pairedHost.deviceId);
    if (!isCurrent()) return;
    const current = get();
    const canReuseCurrentWorkspace = !!cached && current.workspaceHostDeviceId === pairedHost.deviceId;
    const liveScreenApps = keepVideoPeer && current.workspaceHostDeviceId === pairedHost.deviceId
      ? current.remoteApps.filter((app) => app.remoteAppId === 'screen') : [];
    set({
      ...(keepVideoPeer ? {} : { peer: null, signaling: null, videoStreams: {} }),
      relay: null,
      // While a kept video keeps rendering, the Mac's presence is merely unknown
      // until the relay answers; "offline" would hide a working picture.
      relayHostOnline: keepVideoPeer && canReuseCurrentWorkspace ? null : cached ? false : null,
      hostHello: cached?.hostHello ?? (canReuseCurrentWorkspace ? current.hostHello : null),
      layout: cached?.layout ?? (canReuseCurrentWorkspace ? current.layout : null),
      // The persisted cache marks screen sharing off for a cold start; a
      // reconnect to the same Mac keeps the list it was just showing.
      remoteApps: canReuseCurrentWorkspace ? current.remoteApps : (cached?.remoteApps ?? liveScreenApps),
      agents: cached?.agents ?? (canReuseCurrentWorkspace ? current.agents : {}),
      messageDetails: canReuseCurrentWorkspace ? current.messageDetails : {},
      workspaceHostDeviceId: cached || canReuseCurrentWorkspace || liveScreenApps.length ? pairedHost.deviceId : null,
      relayScreenFrames: {},
      error: cached
        ? connectionStatusCopy('cached-reconnecting')
        : connectionStatusCopy('connecting'),
    });
    try {
      const session = await currentSession();
      if (!isCurrent()) return;
      const { RelayConnection } = await import('../transport/RelayConnection');
      if (!isCurrent()) return;
      const relay = new RelayConnection({
        keypair: phoneKeypair,
        host: pairedHost,
        accessToken: session.access_token,
        getAccessToken: async () => (await currentSession()).access_token,
        onState: (state) => {
          if (!isCurrent()) return;
          if (state.online === true) {
            reconnectAttempt = 0;
            set({ relayHostOnline: true, error: null });
            return;
          }
          if (state.online === false) {
            set({
              relayHostOnline: false,
              error: state.error ?? connectionStatusCopy('offline-cached'),
            });
            return;
          }
          if (state.connected) return;
          if (state.error) {
            set({ error: state.error });
          }
        },
        onClose: (event, intentional) => {
          if (!isCurrent()) return;
          if (intentional) return;
          if (event.code === 4003) {
            // The same close code covers this browser's access being revoked
            // and the Mac leaving the account; the reason tells them apart.
            const removedFromAccount = event.reason === HOST_REMOVED_RELAY_REASON;
            // A removal this page made says so on its own; no second notice.
            const removedHere = removedFromAccount && hostRemovalByThisPage(pairedHost.deviceId);
            get().disconnectPeer();
            if (removedFromAccount) recordHostListEdit({ deviceId: pairedHost.deviceId, removed: true });
            set((state) => ({
              pairedHost: null,
              availableHosts: state.availableHosts.filter((host) => host.deviceId !== pairedHost.deviceId),
              route: state.user ? 'hosts' : fallbackEntryRoute(),
              error: null,
              accessRevocationNotice: removedHere
                ? state.accessRevocationNotice
                : removedFromAccount
                  ? HOST_MANAGEMENT_COPY.removedNotice
                  : HOST_REVOKED_NOTICE,
            }));
            void Promise.all([
              idbDel(PAIRED_HOST_KEY),
              offlineCache.clear(get().user?.id, pairedHost.deviceId),
            ]).catch(() => {
              showCacheFailureNotice(
                set,
                pairedHost.deviceId,
                removedFromAccount ? HOST_MANAGEMENT_COPY.removedNoticeCacheFailed : HOST_REVOKED_CACHE_FAILED_NOTICE,
              );
            });
            return;
          }
          if (event.code === 4001) {
            // The relay's authorization window ended without an in-place renewal
            // (an older relay, or a token refresh that failed): reconnect at once
            // instead of showing the Mac as offline while the socket returns.
            reconnectAttempt = 0;
            set({ signaling: null, relay: null });
            scheduleReconnect(set, get, connectionStatusCopy('reconnecting'), 0);
            return;
          }
          const error = connectionStatusCopy('reconnecting');
          set({
            signaling: null,
            relay: null,
            relayHostOnline: false,
            error,
          });
          scheduleReconnect(set, get, error);
        },
        onHello: (hello, cached, timing) => {
          if (!isCurrent()) return;
          if (!rememberHello(hello, cached, timing)) return;
          if (hello.hostReadOnly !== undefined) {
            get().relay?.sendReadOnlyUpdate(get().readOnlyMode);
          }
          if (!cached) {
            reconnectAttempt = 0;
          }
          const remoteApps = remoteAppsForScreenStopState(
            hello.remoteApps ?? fallbackRemoteAppsFromLayout(hello.currentLayout),
          );
          set((prev) => ({
            hostHello: hello,
            layout: hello.currentLayout,
            remoteApps,
            workspaceHostDeviceId: pairedHost.deviceId,
            relayHostOnline: cached ? (prev.relayHostOnline ?? false) : true,
            error: cached && prev.relayHostOnline !== true
              ? (prev.error ?? connectionStatusCopy('offline-cached'))
              : null,
          }));
          flushPendingScreenStop(set, get);
        },
        onAgent: (snap, cached, timing) => {
          if (!isCurrent()) return;
          if (!rememberOfflineItem(`agent:${snap.agentId}`, snap, cached, timing)) return;
          set((prev) => ({
            relayHostOnline: cached ? prev.relayHostOnline : true,
            error: cached ? prev.error : null,
            workspaceHostDeviceId: pairedHost.deviceId,
            agents: {
              ...prev.agents,
              [snap.agentId]: mergeLocalOptimisticMessages(prev.agents[snap.agentId], snap),
            },
          }));
        },
        onRemoteApps: (remoteApps, cached, timing) => {
          if (!isCurrent()) return;
          if (!rememberOfflineItem('apps', remoteAppsForCachedWorkspace(remoteApps), cached, timing)) return;
          const nextRemoteApps = remoteAppsForScreenStopState(remoteApps);
          set((prev) => ({
            remoteApps: nextRemoteApps,
            workspaceHostDeviceId: pairedHost.deviceId,
            relayHostOnline: cached ? (prev.relayHostOnline ?? false) : true,
            error: cached ? prev.error : null,
          }));
          if (!isScreenSharingOn(nextRemoteApps)) {
            if (remoteApps.some((app) => app.remoteAppId === 'screen' && app.enabled === false)) {
              clearPendingScreenStop();
            }
            get().stopVideoPeer('screen');
          }
          flushPendingScreenStop(set, get);
        },
        onCacheManifest: (manifest) => {
          if (!isCurrent() || get().relayHostOnline === true) return;
          const removed = Object.keys(offlineCache.items).filter((key) =>
            (key === 'hello' || key === 'layout') ? !manifest.hello :
              key === 'apps' ? !manifest.remoteApps && !manifest.hello :
                key.startsWith('agent:') && !manifest.agentIds.includes(key.slice(6)));
          offlineCache.remove(removed);
          dropOfflineItems(set, removed);
          if (!Object.keys(offlineCache.items).length) set({ error: CACHE_EXPIRED_COPY });
          scheduleCacheExpiry();
        },
        onMessageDetail: (detail) => {
          if (!isCurrent()) return;
          cacheMessageDetail(set, detail);
        },
        onScreenFrame: (frame) => {
          if (!isCurrent()) return;
          if (!shouldAcceptRelayScreenFrame(get().remoteApps, frame, pendingScreenStop)) {
            clearScreenMediaForCurrentState(set, get, frame.agentId);
            return;
          }
          set((prev) => ({
            relayHostOnline: true,
            error: isScreenStreamStatusMessage(prev.error) ? null : prev.error,
            workspaceHostDeviceId: pairedHost.deviceId,
            relayScreenFrames: {
              ...prev.relayScreenFrames,
              [frame.agentId]: frame,
            },
          }));
        },
      });
      await relay.connect();
      if (!isCurrent()) {
        relay.disconnect();
        return;
      }
      set({ relay });
      if (get().hostHello?.hostReadOnly !== undefined) {
        relay.sendReadOnlyUpdate(get().readOnlyMode);
      }
      const heartbeat = window.setInterval(() => {
        if (!isCurrent() || !relay.isConnected) {
          window.clearInterval(heartbeat);
          return;
        }
        relay.sendHeartbeat();
      }, 20_000);
      void registerPushSubscription({
        phoneDeviceId: phoneKeypair.deviceId,
        signalingHttpUrl: toHttp(pairedHost.signalingUrl),
      }).catch((error) => {
        console.warn('Failed to register push subscription', error);
      });
    } catch (err) {
      if (!isCurrent()) return;
      const message = connectionError(err);
      set({
        peer: null,
        signaling: null,
        relay: null,
        relayHostOnline: false,
        error: message,
      });
      if (import.meta.env.VITE_GLASSTUNNEL_ENABLE_WEBRTC_FALLBACK === 'true') {
        const signal = peerFlowAbortRegistry.begin('primary');
        await startWebRtcPeerFlow(set, get, generation, message, { signal });
      } else {
        scheduleReconnect(set, get, message);
      }
    }
  },

  async startVideoPeer() {
    const { phoneKeypair, pairedHost } = get();
    if (!phoneKeypair || !pairedHost) return;
    videoPeerWanted = true;
    clearVideoRetryTimer();
    // A hidden page cannot negotiate media; resumeVideoPeerIfNeeded starts the
    // flow when the page is visible again.
    if (isDocumentHidden()) return;

    const generation = ++videoPeerStartGeneration;
    peerFlowAbortRegistry.cancelAll();
    const signal = peerFlowAbortRegistry.begin('video');
    get().peer?.close();
    get().signaling?.disconnect();
    clearScreenVideoStream(set, get);
    set({
      peer: null,
      signaling: null,
      error: SCREEN_STREAM_CONNECTING_MESSAGE,
    });
    await startWebRtcPeerFlow(set, get, generation, SCREEN_STREAM_CONNECTING_MESSAGE, {
      videoOnly: true,
      signal,
    });
  },

  stopVideoPeer(agentId = 'screen') {
    forgetVideoPeer();
    videoPeerStartGeneration += 1;
    peerFlowAbortRegistry.cancelAll();
    get().peer?.close();
    get().signaling?.disconnect();
    clearVideoStreamForAgent(set, get, agentId);
    clearRelayScreenFrameForAgent(set, agentId);
    set((prev) => ({
      peer: null,
      signaling: null,
      error: isScreenStreamStatusMessage(prev.error) ? null : prev.error,
    }));
  },

  resumeVideoPeerIfNeeded() {
    if (!canResumeVideoPeer(get())) return;
    void get().startVideoPeer();
  },

  clearVideoStream(agentId) {
    clearVideoStreamForAgent(set, get, agentId);
  },

  clearRelayScreenFrame(agentId) {
    clearRelayScreenFrameForAgent(set, agentId);
  },

  setScreenShareQuality(quality) {
    saveScreenShareQuality(quality);
    set({ screenShareQuality: quality });
  },

  recoverConnection(options) {
    get().expireOfflineCopies();
    if (recoverConnectionInFlight) return recoverConnectionInFlight;
    const recovery = (async () => {
      const state = get();
      if (!isWorkspaceRoute(state.route) || !state.pairedHost || !state.phoneKeypair) return;
      if (isDocumentHidden()) return;
      if (
        !options?.forceRestart &&
        state.relayHostOnline === true &&
        state.hostHello &&
        (state.relay || state.peer) &&
        (!state.error || isScreenStreamStatusMessage(state.error))
      ) {
        return;
      }
      if (shouldDeferToPendingReconnect(options?.reason)) return;

      const now = Date.now();
      if (
        options?.refreshHosts ||
        now - lastRecoverHostRefreshAt > RECOVER_HOST_REFRESH_INTERVAL_MS
      ) {
        lastRecoverHostRefreshAt = now;
        try {
          await get().refreshHosts({ force: true });
          const latest = get();
          const selected = latest.pairedHost;
          const accountHost = selected
            ? latest.availableHosts.find((host) => host.deviceId === selected.deviceId)
            : null;
          if (accountHost && !accountHost.online) {
            set({
              relayHostOnline: false,
              error: connectionStatusCopy('offline-cached'),
            });
          }
        } catch (error) {
          const message = connectionError(error);
          set({ error: message });
          scheduleReconnect(set, get, message);
          return;
        }
      }

      await get().startPeer({ keepVideoPeer: options?.keepVideoPeer });
    })();
    const guardedRecovery = recovery.finally(() => {
      if (recoverConnectionInFlight === guardedRecovery) {
        recoverConnectionInFlight = null;
      }
    });
    recoverConnectionInFlight = guardedRecovery;
    return guardedRecovery;
  },

  async signInWithGoogle() {
    if (!authClient) {
      throw new Error('Hosted account login is not configured.');
    }
    const { error } = await authClient.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: authRedirectTo(),
      },
    });
    if (error) throw error;
  },

  async signInWithGitHub() {
    if (!authClient) {
      throw new Error('Hosted account login is not configured.');
    }
    const { error } = await authClient.auth.signInWithOAuth({
      provider: 'github',
      options: {
        redirectTo: authRedirectTo(),
      },
    });
    if (error) throw error;
  },

  async signInWithPassword(email, password) {
    if (!authClient) {
      throw new Error('Hosted account login is not configured.');
    }
    const trimmed = email.trim().toLowerCase();
    if (!trimmed) {
      throw new Error('Enter an email address.');
    }
    if (!password.trim()) {
      throw new Error('Enter your password.');
    }
    const { error } = await authClient.auth.signInWithPassword({
      email: trimmed,
      password,
    });
    if (error) throw error;
  },

  async signUpWithPassword(email, password, displayName) {
    if (!authClient) {
      throw new Error('Hosted account login is not configured.');
    }
    const trimmed = email.trim().toLowerCase();
    if (!trimmed) {
      throw new Error('Enter an email address.');
    }
    if (!password.trim()) {
      throw new Error('Create a password.');
    }
    const name = displayName?.trim() || trimmed.split('@')[0] || 'Glasstunnel user';
    const { error } = await authClient.auth.signUp({
      email: trimmed,
      password,
      options: {
        data: {
          name,
        },
      },
    });
    if (error) throw error;
  },

  async signOut() {
    if (get().signingOut) return;
    const account = get().user?.id ?? pendingSignOutAccount;
    pendingSignOutAccount = account;
    sessionSyncVersion += 1;
    // A Mac code kept through a password reset must not link to whoever signs in next.
    clearPendingLinkCode();
    // Local content and transports must disappear even if remote logout fails.
    get().disconnectPeer();
    set({
      user: null,
      signOutError: null,
      signingOut: true,
      accessRevocationNotice: null,
      availableHosts: [],
      hostsStatus: 'idle',
      pairedHost: null,
      peer: null,
      signaling: null,
      relay: null,
      relayHostOnline: null,
      layout: null,
      remoteApps: [],
      hostHello: null,
      agents: {},
      workspaceHostDeviceId: null,
      videoStreams: {},
      relayScreenFrames: {},
      locked: true,
      route: fallbackEntryRoute(),
    });
    const results = await Promise.allSettled([
      account ? offlineCache.clear(account) : offlineCache.clearLegacy(),
      idbDel(PAIRED_HOST_KEY),
      (async () => {
        if (!authClient) return;
        const { error } = await authClient.auth.signOut();
        if (error) throw error;
      })(),
    ]);
    set({ signingOut: false });
    const failed = results.find((result) => result.status === 'rejected');
    if (failed?.status === 'rejected') {
      set({ signOutError: SIGN_OUT_FAILURE_COPY });
      throw failed.reason;
    }
    pendingSignOutAccount = undefined;
  },

  loadPasswordResetLink() {
    const token = readPasswordResetToken();
    const invalidLink = takeInvalidPasswordResetLink();
    const flow = get().passwordResetFlow;
    if (token) {
      if (flow?.screen === 'reset' && flow.token === token) return;
      set({ passwordResetFlow: { screen: 'reset', token, status: 'idle', error: null } });
    } else if (invalidLink) {
      set({ passwordResetFlow: { screen: 'reset', token: null, status: 'invalid', error: null } });
    }
  },

  openForgotPassword(email = '') {
    clearPasswordResetToken();
    // A Mac that started this sign-in passed its linkCode in the address bar.
    // The reset email opens a new tab without it, so the code moves into
    // storage, bound to the address this flow is for. It comes back only for
    // a sign-in a tab of this browser makes itself to the account with that
    // email (synchronizeSession). Left in this tab too, it would be claimed twice:
    // once by the reset tab's sign-in, once here when that sign-in reaches
    // this tab.
    moveLinkCodeFromUrl(email);
    set({ passwordResetFlow: { screen: 'forgot', status: 'idle', error: null } });
  },

  closePasswordReset() {
    clearPasswordResetToken();
    set({ passwordResetFlow: null });
  },

  async requestPasswordReset(email) {
    const flow = get().passwordResetFlow;
    if (flow?.screen === 'forgot' && flow.status === 'sending') return false;
    const normalized = email.trim().toLowerCase();
    const failWith = (error: string) => {
      set({ passwordResetFlow: { screen: 'forgot', status: 'idle', error } });
      return false;
    };
    if (!normalized) return failWith(PASSWORD_RESET_COPY.emptyEmail);
    if (!authClient) return failWith(PASSWORD_RESET_COPY.notConfigured);
    const sending: PasswordResetFlow = { screen: 'forgot', status: 'sending', error: null };
    set({ passwordResetFlow: sending });
    const { error } = await authClient.auth.requestPasswordReset(normalized);
    // The reset is for this address now: a Mac code this tab's forgot flow
    // kept is linked by a sign-in to that account only.
    if (!error) bindPendingLinkCodeEmail(normalized);
    // The person left this screen while the request was in flight.
    if (get().passwordResetFlow !== sending) return !error;
    if (error) return failWith(passwordResetRequestErrorCopy(error));
    set({ passwordResetFlow: { screen: 'forgot', status: 'sent', error: null } });
    return true;
  },

  async completePasswordReset(token, newPassword) {
    const flow = get().passwordResetFlow;
    if (flow?.screen === 'reset' && flow.status === 'updating') return false;
    const failWith = (error: string) => {
      set({ passwordResetFlow: { screen: 'reset', token, status: 'idle', error } });
      return false;
    };
    const showInvalidLink = () => {
      clearPasswordResetToken();
      set({ passwordResetFlow: { screen: 'reset', token: null, status: 'invalid', error: null } });
      return false;
    };
    if (!token) return showInvalidLink();
    if (newPassword.length < PASSWORD_MIN_LENGTH) return failWith(PASSWORD_RESET_COPY.tooShort);
    if (newPassword.length > PASSWORD_MAX_LENGTH) return failWith(PASSWORD_RESET_COPY.tooLong);
    if (!authClient) return failWith(PASSWORD_RESET_COPY.notConfigured);
    const updating: PasswordResetFlow = { screen: 'reset', token, status: 'updating', error: null };
    set({ passwordResetFlow: updating });
    const { error } = await authClient.auth.resetPassword({ token, newPassword });
    if (error) {
      const invalidToken = isInvalidResetTokenError(error);
      if (invalidToken) clearPasswordResetToken();
      // The person left this screen while the request was in flight.
      if (get().passwordResetFlow !== updating) return false;
      return invalidToken ? showInvalidLink() : failWith(passwordResetErrorCopy(error));
    }
    clearPasswordResetToken();
    set({ passwordResetFlow: { screen: 'reset', token: null, status: 'done', error: null } });
    // The server ended every session of the account. The auth client already
    // announced the sign-out; this covers a session the store still shows.
    if (get().user) await synchronizeSession(set, get, null);
    return true;
  },

  async refreshHosts(options) {
    if (!authClient) return;
    const userInitiated = options?.userInitiated === true;
    if (refreshHostsInFlight) {
      if (!userInitiated) return refreshHostsInFlight;
      // The person asked while a background refresh runs: it finishes first,
      // and if the list still could not load, theirs runs, showing progress.
      return refreshHostsInFlight.then(() =>
        get().hostsStatus === 'error' ? get().refreshHosts({ ...options, force: true }) : undefined,
      );
    }
    if (
      !options?.force &&
      Date.now() - lastRefreshHostsCompletedAt < REFRESH_HOSTS_MIN_INTERVAL_MS
    ) {
      return;
    }
    // Only the person's own Refresh or Try again moves a failed list back to
    // loading and clears its message. Background refreshes (opening the
    // screen, the timer, focus) leave the failure on screen until they succeed.
    if (userInitiated && get().hostsStatus === 'error') set({ hostsStatus: 'loading', error: null });
    const resync = (session: Session | null) =>
      synchronizeSession(set, get, session, { preserveRoute: true, background: !userInitiated });

    refreshHostsInFlight = (async () => {
      // The running session sync registers this browser and brings the list
      // with it. A fetch now would read this browser as unknown (every Mac
      // untrusted) and could land after the registration's list.
      if (await waitForRunningSessionSync()) return;
      const session = await currentSession().catch(() => null);
      const keypair = get().phoneKeypair;

      if (!session?.user || !keypair) {
        await resync(session);
        return;
      }
      if (await waitForRunningSessionSync()) return;

      const registration = currentBrowserRegistration();
      if (!registration?.succeeded) {
        // This browser is not registered for this session (its registration
        // failed): register it again, which brings the list, not a bare fetch.
        await resync(session);
        return;
      }

      // Only a list read after this session's registration succeeded applies.
      // A newer sync (sign-in, account switch, sign-out) replaces this one.
      const isCurrentList = () =>
        registration.syncVersion === sessionSyncVersion && browserRegistration === registration;
      const editMark = hostListEditSeq;
      try {
        const { result: listed, session: accountSession } = await accountRequestWithSessionRetry(
          session,
          (accessToken) => fetchAccountHosts(accessToken, keypair.deviceId),
        );
        if (!isCurrentList()) return;
        const hosts = withHostListEditsSince(listed, editMark);

        const state = get();
        const selected = chooseHostSelection(hosts, state.pairedHost);
        let storageError: string | null = null;
        try {
          if (selected) {
            await idbSet(PAIRED_HOST_KEY, selected);
          } else if (state.pairedHost) {
            await idbDel(PAIRED_HOST_KEY);
          }
        } catch {
          // The list arrived; only remembering the chosen Mac failed.
          storageError = HOST_CHOICE_NOT_SAVED_COPY;
        }

        if (!isCurrentList()) return;
        const selectedOnline = selected
          ? (hosts.find((host) => host.deviceId === selected.deviceId)?.online ?? null)
          : null;
        set({
          user: state.user ?? mapUser(accountSession.user),
          availableHosts: hosts,
          hostsStatus: 'loaded',
          pairedHost: selected,
          relayHostOnline: selectedOnline,
          error: storageError,
          authConfigured: true,
        });
      } catch (err) {
        if (!isCurrentList()) return;
        set({
          error: friendlyAccountSyncError(err),
          hostsStatus: hostsStatusAfterFailure(get().hostsStatus),
        });
      }
    })().finally(() => {
      lastRefreshHostsCompletedAt = Date.now();
      refreshHostsInFlight = null;
    });

    return refreshHostsInFlight;
  },

  async claimHostLinkCode(code) {
    const session = await currentSession();
    const { result: host } = await accountRequestWithSessionRetry(session, (accessToken) =>
      claimHostCode(accessToken, {
        code,
        requesterDeviceId: get().phoneKeypair?.deviceId,
      }),
    );
    // A code kept through a password reset is used up now.
    clearPendingLinkCode(code);
    await get().refreshHosts({ force: true });
    // The Mac as the list now shows it (see mergeClaimedHost): the caller
    // opens it at once when it is online, or waits for it.
    let added = host;
    set((state) => {
      const availableHosts = mergeClaimedHost(state.availableHosts, host);
      added = availableHosts[0];
      return { availableHosts };
    });
    return added;
  },

  async chooseHost(hostDeviceId) {
    const host = get().availableHosts.find((entry) => entry.deviceId === hostDeviceId);
    if (!host) {
      throw new Error('Host not found.');
    }
    if (!host.trusted && !host.online) {
      throw new Error('This Mac is still being prepared for your account. Refresh and try again.');
    }

    const pairedHost = mapAccountHostToPairedHost(host);
    get().disconnectPeer();
    await savePairedHost(pairedHost);
    const cached = await loadRelayCache(get().user?.id ?? '', pairedHost.deviceId);
    clearPendingScreenStop();
    set({
      pairedHost,
      locked: false,
      route: 'workspace',
      accessRevocationNotice: null,
      hostHello: cached?.hostHello ?? null,
      layout: cached?.layout ?? null,
      remoteApps: cached?.remoteApps ?? [],
      agents: cached?.agents ?? {},
      workspaceHostDeviceId: pairedHost.deviceId,
      relayScreenFrames: {},
      relayHostOnline: host.online,
      error: host.online ? null : connectionStatusCopy('offline-cached'),
    });
    await get().startPeer();
  },

  async renameHost(deviceId, label) {
    const validation = validateHostLabel(label);
    if (!validation.ok) throw new AccountApiError(validation.error, 400);
    const account = get().user?.id;
    let stored: AccountHost | undefined;
    try {
      const session = await currentSession();
      ({ result: stored } = await accountRequestWithSessionRetry(session, (accessToken) =>
        renameAccountHost(accessToken, {
          deviceId,
          label: validation.label,
          requesterDeviceId: get().phoneKeypair?.deviceId,
        }),
      ));
    } catch (error) {
      throw hostActionFailure(get, 'rename', error);
    }
    const nextLabel = stored?.deviceId === deviceId && stored.label ? stored.label : validation.label;
    // Another account signed in while the request ran: its list is not this one.
    if (get().user?.id !== account) return nextLabel;
    recordHostListEdit({ deviceId, label: nextLabel });
    set((state) => ({
      // The screen now reports this change; an earlier access notice is stale,
      // unless it says this Mac's offline copies are still in this browser.
      accessRevocationNotice: cacheFailureNoticeFor(state, deviceId),
      availableHosts: state.availableHosts.map((host) =>
        host.deviceId === deviceId ? renamedAccountHost(host, nextLabel, stored) : host,
      ),
      pairedHost:
        state.pairedHost?.deviceId === deviceId ? { ...state.pairedHost, label: nextLabel } : state.pairedHost,
    }));
    const paired = get().pairedHost;
    if (paired?.deviceId === deviceId) {
      // The saved choice keeps its name; failing to save it changes nothing else.
      await idbSet(PAIRED_HOST_KEY, paired).catch(() => {});
    }
    return nextLabel;
  },

  async removeHost(deviceId) {
    const account = get().user?.id;
    // The relay may close this browser's socket to the Mac before the answer.
    hostRemovalsByThisPage.set(deviceId, Date.now() + HOST_REMOVAL_ECHO_WINDOW_MS);
    try {
      const session = await currentSession();
      await accountRequestWithSessionRetry(session, (accessToken) =>
        removeAccountHost(accessToken, { deviceId }),
      );
    } catch (error) {
      // No answer (the request timed out or the connection dropped): the
      // removal may have happened anyway. If the account's list, loaded
      // again, no longer has the Mac, it did, and it ends as a removal does.
      if (!isNetworkFailure(error) || !(await hostLeftAccountList(get, account, deviceId))) {
        hostRemovalsByThisPage.delete(deviceId);
        throw hostActionFailure(get, 'remove', error);
      }
    }
    if (get().user?.id !== account) return;
    recordHostListEdit({ deviceId, removed: true });
    const wasSelected = get().pairedHost?.deviceId === deviceId;
    if (wasSelected) {
      get().disconnectPeer();
      try {
        localStorage.removeItem(`gt.webauthn.enrolled.${deviceId}`);
      } catch {
        // Storage may be unavailable; nothing else depends on this flag.
      }
    }
    set((state) => ({
      // The relay may already have closed this browser's socket to the Mac and
      // failed to clear its offline copies; that notice stays.
      accessRevocationNotice: cacheFailureNoticeFor(state, deviceId),
      availableHosts: state.availableHosts.filter((host) => host.deviceId !== deviceId),
      ...(wasSelected
        ? {
            pairedHost: null,
            relayHostOnline: null,
            route: isWorkspaceRoute(state.route) ? ('hosts' as const) : state.route,
          }
        : {}),
    }));
    // This browser keeps nothing of a Mac that left the account. The removal
    // itself succeeded; copies that could not be cleared are reported instead.
    const cleared = await Promise.allSettled([
      wasSelected ? idbDel(PAIRED_HOST_KEY) : Promise.resolve(),
      account ? offlineCache.clear(account, deviceId) : Promise.resolve(),
    ]);
    if (cleared.some((result) => result.status === 'rejected') && get().user?.id === account) {
      showCacheFailureNotice(set, deviceId, HOST_MANAGEMENT_COPY.removedNoticeCacheFailed);
    }
  },

  sendText(agentId, text, submit) {
    if (!canSendControl(set, get(), agentId)) return false;
    const current = get().agents[agentId];
    if (targetPromptDeliveryUnavailable(current)) {
      appendTargetPromptBlockedMessage(set, agentId, current?.adapterKind);
      return false;
    }

    const relay = get().relay;
    const peer = get().peer;
    const trimmed = text.trim();
    if (!trimmed) return false;
    const delivered =
      relay?.sendUserInput({ agentId, text: trimmed, submitOnSend: submit }) ||
      peer?.sendUserInput({ agentId, text: trimmed, submitOnSend: submit }) ||
      false;
    if (!delivered) {
      appendSendFailureMessage(set, agentId);
      return false;
    }
    appendOptimisticUserMessage(set, agentId, trimmed);
    return true;
  },

  sendScreenPointer(agentId, x, y, action = 'click') {
    if (!canSendControl(set, get(), agentId)) return;
    const relay = get().relay;
    const peer = get().peer;
    const delivered =
      relay?.sendScreenPointer({ agentId, x, y, action }) ||
      peer?.sendScreenPointer({ agentId, x, y, action }) ||
      false;
    if (!delivered) {
      appendSendFailureMessage(set, agentId);
    }
  },

  sendInputRequestResponse(response) {
    if (!canSendControl(set, get(), response.agentId)) return;
    const relay = get().relay;
    const peer = get().peer;
    const delivered =
      relay?.sendInputRequestResponse(response) ||
      peer?.sendInputRequestResponse(response) ||
      false;
    if (!delivered) {
      appendSendFailureMessage(set, response.agentId);
      return;
    }
    appendOptimisticPlanningResponse(set, response);
  },

  async sendImageAttachment(agentId, input) {
    if (!canSendControl(set, get(), agentId)) return false;
    const current = get().agents[agentId];
    if (targetPromptDeliveryUnavailable(current)) {
      appendTargetPromptBlockedMessage(set, agentId, current?.adapterKind);
      return false;
    }

    const relay = get().relay;
    const peer = get().peer;
    const payload = {
      agentId,
      text: input.text,
      filename: input.filename,
      mimeType: input.mimeType,
      bytes: input.bytes,
      submitOnSend: input.submitOnSend,
    };
    const delivered =
      (await relay?.sendImageAttachment(payload)) ||
      (await peer?.sendImageAttachment(payload)) ||
      false;
    if (!delivered) {
      appendSendFailureMessage(set, agentId);
      return false;
    }
    appendOptimisticUserMessage(set, agentId, optimisticImageMessage(input));
    return true;
  },

  async sendFileAttachmentBatch(agentId, files) {
    if (!canSendControl(set, get(), agentId)) return false;
    const current = get().agents[agentId];
    if (targetPromptDeliveryUnavailable(current)) {
      appendTargetPromptBlockedMessage(set, agentId, current?.adapterKind);
      return false;
    }

    const relay = get().relay;
    const peer = get().peer;
    if ((!relay && !peer) || files.length === 0) {
      appendSendFailureMessage(set, agentId);
      return false;
    }

    for (const file of files) {
      if (!canSendControl(set, get(), agentId)) return false;
      const payload = {
        agentId,
        batchId: file.batchId,
        text: file.text,
        filename: file.filename,
        mimeType: file.mimeType,
        fileIndex: file.fileIndex,
        fileCount: file.fileCount,
        bytes: file.bytes,
        submitOnSend: file.submitOnSend,
      };
      const delivered =
        (await relay?.sendFileAttachment(payload)) ||
        (await peer?.sendFileAttachment(payload)) ||
        false;
      if (!delivered) {
        appendSendFailureMessage(set, agentId);
        return false;
      }
    }

    appendOptimisticUserMessage(set, agentId, optimisticFileBatchMessage(files));
    return true;
  },

  sendQuickReply(agentId, kind) {
    if (!canSendControl(set, get(), agentId)) return;
    const current = get().agents[agentId];
    if (targetPromptDeliveryUnavailable(current)) {
      appendTargetPromptBlockedMessage(set, agentId, current?.adapterKind);
      return;
    }

    const relay = get().relay;
    const peer = get().peer;
    const delivered =
      relay?.sendQuickReply({ agentId, kind }) || peer?.sendQuickReply({ agentId, kind }) || false;
    if (!delivered) {
      appendSendFailureMessage(set, agentId);
      return;
    }
    appendOptimisticUserMessage(set, agentId, quickReplyLabel(kind));
  },

  sendInterrupt(agentId) {
    if (!canSendControl(set, get(), agentId)) return;
    const relay = get().relay;
    const peer = get().peer;
    if (!(relay?.sendInterrupt({ agentId }) || peer?.sendInterrupt({ agentId }) || false)) {
      appendSendFailureMessage(set, agentId);
      return;
    }
    markInterruptRequested(set, agentId);
  },

  requestMessageDetail(agentId, messageId) {
    if (get().messageDetails[agentId]?.[messageId]) return true;
    const relay = get().relay;
    const peer = get().peer;
    return (
      relay?.sendMessageDetailRequest({ agentId, messageId }) ||
      peer?.sendMessageDetailRequest({ agentId, messageId }) ||
      false
    );
  },

  selectTarget(agentId, targetId) {
    if (!canSendControl(set, get(), agentId)) return false;
    const relay = get().relay;
    const peer = get().peer;
    if (
      !(
        relay?.sendTargetSelection({ agentId, targetId }) ||
        peer?.sendTargetSelection({ agentId, targetId }) ||
        false
      )
    ) {
      appendSendFailureMessage(set, agentId);
      return false;
    }

    set((prev) => {
      const current = prev.agents[agentId];
      if (!current) return prev;
      return {
        agents: {
          ...prev.agents,
          [agentId]: {
            ...current,
            status: AgentStatus.Working,
            statusDetail: targetSelectionStatusDetail(current, targetId),
            availableTargets: (current.availableTargets ?? []).map((target) => ({
              ...target,
              selected: target.targetId === targetId,
              isActive:
                [AdapterKind.Cursor, AdapterKind.Mirror].includes(current.adapterKind) &&
                target.targetId === targetId
                  ? false
                  : target.isActive,
            })),
          },
        },
      };
    });
    return true;
  },

  renameTarget(agentId, targetId, label) {
    if (!canSendControl(set, get(), agentId)) return false;
    const trimmed = label.trim().slice(0, 48);
    if (!trimmed) return false;
    const relay = get().relay;
    const peer = get().peer;
    const delivered =
      relay?.sendTargetRename({ agentId, targetId, label: trimmed }) ||
      peer?.sendTargetRename({ agentId, targetId, label: trimmed }) ||
      false;

    if (!delivered) {
      appendSendFailureMessage(set, agentId);
      return false;
    }

    set((prev) => {
      const current = prev.agents[agentId];
      if (!current) return prev;
      return {
        agents: {
          ...prev.agents,
          [agentId]: {
            ...current,
            availableTargets: (current.availableTargets ?? []).map((target) => {
              if (target.targetId !== targetId) return target;
              return {
                ...target,
                label: trimmed,
                threadLabel: trimmed,
              };
            }),
          },
        },
      };
    });
    return true;
  },

  updateRuntimeSettings(agentId, update) {
    if (!canSendControl(set, get(), agentId)) return false;
    const current = get().agents[agentId];
    if (!current?.runtimeControls) return false;
    if (!current.runtimeControls.editable) return false;
    if (runtimeSettingsUpdateUnavailable(current.status, current.statusDetail)) return false;

    const relay = get().relay;
    const peer = get().peer;
    const command = { agentId, ...update };
    const delivered =
      relay?.sendRuntimeSettingsUpdate(command) ||
      peer?.sendRuntimeSettingsUpdate(command) ||
      false;

    if (!delivered) {
      appendSendFailureMessage(set, agentId);
      return false;
    }

    set((prev) => {
      const current = prev.agents[agentId];
      if (!current?.runtimeControls) return prev;
      return {
        agents: {
          ...prev.agents,
          [agentId]: {
            ...current,
            status: AgentStatus.Working,
            statusDetail: 'updating settings',
            runtimeControls: applyRuntimeSettings(current.runtimeControls, update),
          },
        },
      };
    });
    return true;
  },

  requestRemoteAppAction(remoteAppId, action, options) {
    if (!canSendControl(set, get(), get().remoteApps.find((app) => app.remoteAppId === remoteAppId)?.agentId ?? remoteAppId)) return false;
    const state = get();
    const relay = state.relay;
    const isPendingScreenStop = isScreenStopAction(remoteAppId, action);
    if (isPendingScreenStop) {
      beginPendingScreenStop(set, get);
      markScreenSharingOffLocally(set);
      clearScreenMediaForCurrentState(set, get);
    } else if (isScreenStartAction(remoteAppId, action)) {
      clearPendingScreenStop();
    }
    if (state.relayHostOnline !== true) {
      set({
        relayHostOnline: false,
        error: isPendingScreenStop
          ? connectionStatusCopy('screen-stop-pending')
          : connectionStatusCopy('offline-retry'),
      });
      return false;
    }
    const delivered =
      relay?.sendRemoteAppAction({
        remoteAppId,
        action,
        screenQuality: options?.screenQuality,
      }) ?? false;
    if (!delivered) {
      set({
        relayHostOnline: relay?.isHostOnline ?? false,
        error: isPendingScreenStop
          ? connectionStatusCopy('screen-stop-delayed')
          : connectionStatusCopy('remote-start-failed'),
      });
      return false;
    }

    set({ error: null });
    return true;
  },
}));

export function effectiveReadOnly(state: Pick<AppState, 'readOnlyMode' | 'hostHello'>): boolean {
  return state.readOnlyMode || state.hostHello?.hostReadOnly === true;
}

function canSendControl(set: SetState, state: AppState, agentId: string): boolean {
  if (!effectiveReadOnly(state)) return true;
  appendLocalSystemMessage(set, agentId, state.hostHello?.hostReadOnly
    ? 'Action blocked: read-only mode is enabled on this Mac.'
    : 'Action blocked: this browser is in read-only mode.');
  return false;
}

function cacheMessageDetail(set: SetState, detail: MessageDetail): void {
  set((prev) => ({
    messageDetails: {
      ...prev.messageDetails,
      [detail.agentId]: {
        ...prev.messageDetails[detail.agentId],
        [detail.messageId]: detail,
      },
    },
  }));
}

interface SessionSyncOptions {
  /** Keep a workspace route on screen (a refresh, not a sign-in). */
  preserveRoute?: boolean;
  /**
   * A refresh the person did not ask for: a failed list and its message stay
   * on screen until this sync succeeds.
   */
  background?: boolean;
}

async function synchronizeSession(
  set: SetState,
  get: () => AppState,
  session: Session | null,
  options: SessionSyncOptions = {},
) {
  if (get().signingOut && session?.user) return;
  // A sign-in made in this tab (not a session adopted from another tab, a
  // reload, or a refresh) gets the Mac linkCode a forgot-password flow kept for
  // this account's email. In the address bar before the route is chosen
  // below, the hosts screen claims it as in the usual Mac flow.
  if (session?.user && takeSignInFromThisTab()) restorePendingLinkCodeForSignIn(session.user.email);
  const syncVersion = ++sessionSyncVersion;
  let finish!: () => void;
  const registration: BrowserRegistration = {
    syncVersion,
    running: true,
    succeeded: false,
    done: new Promise<void>((resolve) => {
      finish = resolve;
    }),
  };
  browserRegistration = registration;
  try {
    await runSessionSync(set, get, session, options, registration);
  } catch (err) {
    settleHostListLoading(set, get, syncVersion, friendlyAccountSyncError(err));
    throw err;
  } finally {
    // Every way out of the current sync leaves the list out of `loading`.
    settleHostListLoading(set, get, syncVersion, HOST_LIST_UNAVAILABLE_COPY);
    registration.running = false;
    finish();
  }
}

async function runSessionSync(
  set: SetState,
  get: () => AppState,
  session: Session | null,
  options: SessionSyncOptions,
  registration: BrowserRegistration,
) {
  const { syncVersion } = registration;
  const isCurrentSync = () => syncVersion === sessionSyncVersion;
  const previousUser = get().user;
  const accountChanged = !!previousUser && previousUser.id !== session?.user?.id;
  if (!session?.user || accountChanged) {
    get().disconnectPeer();
    set({
      user: null,
      availableHosts: [],
      // The new account's Macs load next; the old account's list is gone.
      hostsStatus: session?.user ? 'loading' : 'idle',
      pairedHost: null,
      locked: true,
      route: session?.user ? 'hosts' : fallbackEntryRoute(),
    });
    try {
      if (previousUser) await offlineCache.clear(previousUser.id);
      else await offlineCache.clearLegacy();
    } catch {
      if (!isCurrentSync()) return;
      pendingSignOutAccount = previousUser?.id ?? pendingSignOutAccount;
      set({ signOutError: SIGN_OUT_FAILURE_COPY, route: fallbackEntryRoute(), hostsStatus: 'idle' });
      return;
    }
    if (!isCurrentSync()) return;
  }
  const state = get();
  const storedHost = accountChanged || !session?.user
    ? null
    : ((await idbGet(PAIRED_HOST_KEY)) as PairedHost | undefined) ?? null;
  if (accountChanged || !session?.user) await idbDel(PAIRED_HOST_KEY);
  const pendingLinkCode = currentURLHasLinkCode();
  if (!isCurrentSync()) return;

  if (!session?.user || !authClient) {
    const route = state.authConfigured ? 'auth' : fallbackEntryRoute();
    set({
      user: null,
      availableHosts: [],
      hostsStatus: 'idle',
      pairedHost: storedHost,
      relayHostOnline: null,
      route,
      locked: state.locked,
    });
    return;
  }

  const user = mapUser(session.user);
  set({ signOutError: null });
  // Someone just signed in (a password sign-in that finished after "Forgot
  // password?" was opened, another tab, a provider return): the forgot screen
  // must not cover the signed-in app. A reset link's screen stays open. A Mac
  // code the forgot screen kept stays in storage for its own account's sign-in.
  if ((!previousUser || accountChanged) && get().passwordResetFlow?.screen === 'forgot') {
    set({ passwordResetFlow: null });
  }
  const keypair = state.phoneKeypair;
  if (!keypair) {
    // Without this browser's key no host list can load.
    set({
      user,
      route: 'hosts',
      locked: false,
      authConfigured: true,
      hostsStatus: get().hostsStatus === 'loaded' ? 'loaded' : 'idle',
    });
    return;
  }

  // A refresh (preserveRoute) never moves the person: whatever screen they
  // are on stays, including the hosts list, the profile and the workspace.
  // Only a sign-in chooses the first signed-in screen.
  const refreshKeepsRoute =
    options.preserveRoute === true && state.route !== 'loading' && state.route !== 'auth';
  const initialSignedInRoute: Route = refreshKeepsRoute
    ? state.route
    : pendingLinkCode
      ? 'hosts'
      : isWorkspaceRoute(state.route)
        ? 'workspace'
        : 'hosts';

  // The route and user change before the registration below answers; until
  // then the hosts screen shows the list as loading, never as "no Macs". A
  // list this account already shows stays while it refreshes, and a failed
  // one stays during a background refresh, with its message.
  const listStatus = get().hostsStatus;
  const keepFailedList = options.background === true && listStatus === 'error';
  set({
    user,
    authConfigured: true,
    route: initialSignedInRoute,
    locked: refreshKeepsRoute || isWorkspaceRoute(state.route) ? state.locked : false,
    ...(options.background ? {} : { error: null }),
    hostsStatus: listStatus === 'loaded' || keepFailedList ? listStatus : 'loading',
  });
  const errorBeforeRegistration = get().error;
  // The person may move on while the registration runs (open a Mac a claim
  // just added or one already listed, the profile, the lock screen). Their
  // newer route wins over the one this sync would choose.
  const movedOn = () => get().route !== initialSignedInRoute;

  let hosts: AccountHost[];
  let accountSession = session;
  const editMark = hostListEditSeq;
  try {
    const result = await accountRequestWithSessionRetry(session, (accessToken) =>
      registerBrowserDevice(accessToken, {
        deviceId: keypair.deviceId,
        publicKeyB64: base64FromBytes(keypair.publicKey),
        label: browserDeviceLabel(),
        kind: 'browser',
        platform: navigator.userAgent,
      }),
    );
    hosts = withHostListEditsSince(result.result, editMark);
    accountSession = result.session;
  } catch (err) {
    if (!isCurrentSync()) return;
    const latest = get();
    const fallbackRoute =
      latest.route === 'loading' || latest.route === 'auth' ? 'hosts' : latest.route;
    set({
      user,
      availableHosts: latest.availableHosts,
      hostsStatus: hostsStatusAfterFailure(latest.hostsStatus),
      pairedHost: latest.pairedHost ?? storedHost,
      route: fallbackRoute,
      locked: movedOn() ? latest.locked : false,
      authConfigured: true,
      error: friendlyAccountSyncError(err),
    });
    return;
  }
  registration.succeeded = true;

  if (!isCurrentSync()) return;

  // After the person moved on only the list updates: the screen they reached
  // stays as it is, and a Mac they opened was saved when they opened it.
  const updateListOnly = (storageError: string | null) => {
    set({
      user: mapUser(accountSession.user),
      availableHosts: hosts,
      hostsStatus: 'loaded',
      authConfigured: true,
      // The failure this sync replaces goes; a message from that screen stays.
      ...(get().error === errorBeforeRegistration ? { error: storageError } : {}),
    });
  };
  if (movedOn()) {
    updateListOnly(null);
    return;
  }

  const selected = chooseHostSelection(hosts, get().pairedHost ?? storedHost);
  let storageError: string | null = null;
  try {
    if (selected) {
      await idbSet(PAIRED_HOST_KEY, selected);
    } else {
      await idbDel(PAIRED_HOST_KEY);
    }
  } catch {
    // The list arrived; only remembering the chosen Mac failed. The list
    // shows, and the message says what did not work.
    storageError = HOST_CHOICE_NOT_SAVED_COPY;
  }

  if (!isCurrentSync()) return;

  if (movedOn()) {
    updateListOnly(storageError);
    return;
  }

  const shouldRestoreWorkspace =
    !!storedHost && !!selected && storedHost.deviceId === selected.deviceId;
  let nextRoute: Route = 'hosts';
  if (refreshKeepsRoute) {
    nextRoute = initialSignedInRoute;
  } else if (!pendingLinkCode && shouldRestoreWorkspace) {
    nextRoute = 'workspace';
  }

  const latest = get();
  const shouldKeepWorkspaceState =
    !!selected && latest.workspaceHostDeviceId === selected.deviceId;

  set({
    user: mapUser(accountSession.user),
    availableHosts: hosts,
    hostsStatus: 'loaded',
    pairedHost: selected,
    relayHostOnline: selected
      ? (hosts.find((host) => host.deviceId === selected.deviceId)?.online ?? null)
      : null,
    route: nextRoute,
    locked: refreshKeepsRoute || isWorkspaceRoute(state.route) ? state.locked : false,
    authConfigured: true,
    error: storageError,
    ...(shouldKeepWorkspaceState
      ? {}
      : {
          hostHello: null,
          layout: null,
          remoteApps: [],
          agents: {},
          messageDetails: {},
          workspaceHostDeviceId: null,
          relayScreenFrames: {},
        }),
  });
}

/**
 * Shares one synchronization between start-up and the auth listener when both
 * bring the same session (see `sharedSessionSync`). A start-up read joins any
 * current synchronization of that session; an auth event joins only one that
 * start-up began and that is still running.
 */
function synchronizeSessionOnce(
  set: SetState,
  get: () => AppState,
  session: Session | null,
  origin: SessionSyncOrigin,
): Promise<void> {
  const shared = sharedSessionSync;
  if (
    session?.user &&
    shared &&
    shared.version === sessionSyncVersion &&
    shared.userId === session.user.id &&
    shared.accessToken === session.access_token &&
    (origin === 'start-up'
      ? // A finished one still counts while its account is the one signed in.
        !shared.settled || get().user?.id === shared.userId
      : shared.origin === 'start-up' && !shared.settled)
  ) {
    return shared.done;
  }
  const versionBefore = sessionSyncVersion;
  const done = synchronizeSession(set, get, session);
  if (!session?.user || sessionSyncVersion === versionBefore) {
    // Signed out, or ignored while a sign-out finishes: nothing to share.
    sharedSessionSync = null;
    return done;
  }
  const started: SharedSessionSync = {
    userId: session.user.id,
    accessToken: session.access_token,
    origin,
    version: sessionSyncVersion,
    settled: false,
    done,
  };
  const settle = () => {
    started.settled = true;
  };
  void done.then(settle, settle);
  sharedSessionSync = started;
  return done;
}

/**
 * The status after a load of the host list failed. A list already on screen
 * stays; otherwise the failure shows. Only one load of a session's list runs
 * at a time: refreshHosts waits for a running registration and never fetches
 * alongside it.
 */
function hostsStatusAfterFailure(current: HostListStatus): HostListStatus {
  return current === 'loaded' ? 'loaded' : 'error';
}

/** The current session sync's registration record, if the current sync made one. */
function currentBrowserRegistration(): BrowserRegistration | null {
  return browserRegistration && browserRegistration.syncVersion === sessionSyncVersion
    ? browserRegistration
    : null;
}

/**
 * Waits while the current session sync runs, and any sync that replaces it
 * meanwhile. True when it waited: that sync brought the list, or reported
 * why it could not.
 */
async function waitForRunningSessionSync(): Promise<boolean> {
  let waited = false;
  for (
    let running = currentBrowserRegistration();
    running?.running;
    running = currentBrowserRegistration()
  ) {
    waited = true;
    await running.done;
  }
  return waited;
}

/**
 * A current sync that ends with the list still `loading` (it threw, or gave up
 * on a path that set no status) shows the failure instead of loading forever.
 */
function settleHostListLoading(
  set: SetState,
  get: () => AppState,
  syncVersion: number,
  error: string,
) {
  if (syncVersion !== sessionSyncVersion || get().hostsStatus !== 'loading') return;
  set({ hostsStatus: 'error', error: get().error ?? error });
}

async function currentSession(options: { forceRefresh?: boolean } = {}): Promise<Session> {
  if (!authClient) {
    throw new Error('Hosted account login is not configured.');
  }
  const {
    data: { session },
    error,
  } = await authClient.auth.getSession();
  if (error) throw error;
  const activeSession = session ?? failNoSession();
  if (!options.forceRefresh) {
    return activeSession;
  }
  const { data, error: refreshError } = await authClient.auth.refreshSession({
    refresh_token: activeSession.refresh_token,
  });
  if (refreshError) throw refreshError;
  return data.session ?? failNoSession();
}

async function accountRequestWithSessionRetry<T>(
  session: Session,
  request: (accessToken: string) => Promise<T>,
): Promise<{ result: T; session: Session }> {
  try {
    return {
      result: await request(session.access_token),
      session,
    };
  } catch (error) {
    if (!isAccountApiAuthFailure(error)) throw error;
    let refreshed: Session;
    try {
      refreshed = await currentSession({ forceRefresh: true });
    } catch {
      throw new AccountApiError('browser session expired', 401);
    }
    return {
      result: await request(refreshed.access_token),
      session: refreshed,
    };
  }
}

interface RelayCachedWorkspace {
  hostHello: Hello | null;
  layout: GridLayout | null;
  remoteApps: RemoteApp[];
  agents: Record<string, AgentStateSnapshot>;
}

async function loadRelayCache(account: string, hostDeviceId: string): Promise<RelayCachedWorkspace | null> {
  try {
    await offlineCache.open(account, hostDeviceId);
    scheduleCacheExpiry();
    const items = offlineCache.items;
    if (!Object.keys(items).length) return null;
    return sanitizeRelayCache({
      hostHello: items.hello?.data as Hello ?? null,
      layout: items.layout?.data as GridLayout ?? null,
      remoteApps: items.apps?.data as RemoteApp[] ?? [],
      agents: Object.fromEntries(Object.entries(items).filter(([key]) => key.startsWith('agent:')).map(([key, item]) => [key.slice(6), item.data as AgentStateSnapshot])),
    });
  } catch {
    return null;
  }
}

function rememberOfflineItem(key: string, data: unknown, cached = false, timing?: CacheTiming): boolean {
  const accepted = offlineCache.receive(key, data, cached, timing);
  scheduleCacheExpiry();
  return accepted;
}

function rememberHello(hello: Hello, cached = false, timing?: CacheTiming): boolean {
  const apps = remoteAppsForCachedWorkspace(hello.remoteApps ?? fallbackRemoteAppsFromLayout(hello.currentLayout));
  if (!rememberOfflineItem('hello', { ...hello, remoteApps: apps }, cached, timing)) return false;
  rememberOfflineItem('layout', hello.currentLayout, cached, timing);
  rememberOfflineItem('apps', apps, cached, timing);
  return true;
}

function scheduleCacheExpiry(): void {
  clearTimeout(cacheExpiryTimer);
  const deadline = Math.min(...Object.values(offlineCache.items).map((item) => item.expiresAt));
  cacheExpiryTimer = Number.isFinite(deadline) ? setTimeout(() => useAppStore.getState().expireOfflineCopies(), Math.max(0, deadline - Date.now())) : undefined;
}

function dropOfflineItems(set: SetState, keys: string[], expired = true): void {
  if (!keys.length) return;
  set((state) => ({
    ...(keys.includes('hello') ? { hostHello: null } : {}),
    ...(keys.includes('layout') ? { layout: null } : {}),
    ...(keys.includes('apps') ? { remoteApps: [] } : {}),
    agents: Object.fromEntries(Object.entries(state.agents).filter(([id]) => !keys.includes(`agent:${id}`))),
    messageDetails: {}, relayScreenFrames: {},
    error: state.relayHostOnline === true ? state.error : expired ? CACHE_EXPIRED_COPY : null,
  }));
}

function sanitizeRelayCache(cached: RelayCachedWorkspace): RelayCachedWorkspace {
  const remoteApps = remoteAppsForCachedWorkspace(cached.remoteApps ?? []);
  return {
    ...cached,
    remoteApps,
    hostHello: cached.hostHello
      ? {
          ...cached.hostHello,
          remoteApps: cached.hostHello.remoteApps
            ? remoteAppsForCachedWorkspace(cached.hostHello.remoteApps)
            : remoteApps,
        }
      : null,
  };
}

function screenAgentId(state: AppState): string | null {
  return (
    state.remoteApps.find((app) => app.remoteAppId === 'screen')?.agentId ??
    (state.videoStreams.screen ? 'screen' : null)
  );
}

function hasRecentRelayScreenFrame(state: AppState): boolean {
  const agentId = screenAgentId(state) ?? 'screen';
  const frame = state.relayScreenFrames[agentId] ?? state.relayScreenFrames.screen;
  return hasFreshRelayScreenFrameTimestamp(frame, Date.now());
}

function isScreenStopAction(
  remoteAppId: string,
  action: RemoteAppActionRequest['action'],
): boolean {
  return remoteAppId === 'screen' && (action === 'stop' || action === 'disable');
}

function isScreenStartAction(
  remoteAppId: string,
  action: RemoteAppActionRequest['action'],
): boolean {
  return (
    remoteAppId === 'screen' && (action === 'start' || action === 'enable' || action === 'launch')
  );
}

function markScreenSharingOffLocally(set: SetState): void {
  set((prev) => ({
    remoteApps: remoteAppsWithScreenSharingOff(prev.remoteApps),
  }));
}

function beginPendingScreenStop(set: SetState, get: () => AppState): void {
  pendingScreenStop = true;
  pendingScreenStopRequestedAt = Date.now();
  scheduleScreenStopConfirmationCheck(set, get);
}

function clearPendingScreenStop(): void {
  pendingScreenStop = false;
  pendingScreenStopRequestedAt = 0;
  if (screenStopConfirmationTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(screenStopConfirmationTimer);
  }
  screenStopConfirmationTimer = null;
}

function scheduleScreenStopConfirmationCheck(set: SetState, get: () => AppState): void {
  if (typeof window === 'undefined') return;
  if (screenStopConfirmationTimer !== null) {
    window.clearTimeout(screenStopConfirmationTimer);
  }
  screenStopConfirmationTimer = window.setTimeout(() => {
    screenStopConfirmationTimer = null;
    warnIfScreenStopUnconfirmed(set, get);
  }, SCREEN_STOP_CONFIRMATION_TIMEOUT_MS);
}

function warnIfScreenStopUnconfirmed(set: SetState, get: () => AppState): void {
  if (!pendingScreenStop) return;
  const state = get();
  const hostOnline = state.relayHostOnline === true || state.relay?.isHostOnline === true;
  if (!shouldCheckPendingScreenStop(pendingScreenStopRequestedAt, Date.now(), hostOnline)) {
    scheduleScreenStopConfirmationCheck(set, get);
    return;
  }

  const delivered =
    state.relay?.sendRemoteAppAction({
      remoteAppId: 'screen',
      action: 'stop',
    }) ?? false;

  markScreenSharingOffLocally(set);
  clearScreenMediaForCurrentState(set, get);
  set({
    error: delivered
      ? connectionStatusCopy('screen-stop-unconfirmed')
      : connectionStatusCopy('screen-stop-delayed'),
  });
  scheduleScreenStopConfirmationCheck(set, get);
}

function remoteAppsForScreenStopState(remoteApps: RemoteApp[]): RemoteApp[] {
  return pendingScreenStop ? remoteAppsWithScreenSharingOff(remoteApps) : remoteApps;
}

function flushPendingScreenStop(set: SetState, get: () => AppState): void {
  if (!pendingScreenStop) return;
  const state = get();
  if (state.relayHostOnline !== true && state.relay?.isHostOnline !== true) return;

  const delivered =
    state.relay?.sendRemoteAppAction({
      remoteAppId: 'screen',
      action: 'stop',
    }) ?? false;
  if (!delivered) return;

  markScreenSharingOffLocally(set);
  clearScreenMediaForCurrentState(set, get);
}

function loadScreenShareQuality(): ScreenShareQuality {
  if (typeof localStorage === 'undefined') return 'readable';
  try {
    const stored = localStorage.getItem(SCREEN_SHARE_QUALITY_KEY);
    return stored === 'fast' || stored === 'readable' ? stored : 'readable';
  } catch {
    return 'readable';
  }
}

function saveScreenShareQuality(quality: ScreenShareQuality): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(SCREEN_SHARE_QUALITY_KEY, quality);
  } catch {
    // Preference persistence is best effort.
  }
}

function clearScreenVideoStream(set: SetState, get: () => AppState): void {
  const agentId = screenAgentId(get());
  if (!agentId) return;
  clearVideoStreamForAgent(set, get, agentId);
}

function screenMediaAgentIds(state: AppState, extraAgentId?: string): string[] {
  const ids = new Set<string>(['screen']);
  const screenAppAgentId = state.remoteApps.find((app) => app.remoteAppId === 'screen')?.agentId;
  if (screenAppAgentId) ids.add(screenAppAgentId);
  if (extraAgentId) ids.add(extraAgentId);
  return [...ids];
}

function clearScreenMediaForCurrentState(
  set: SetState,
  get: () => AppState,
  extraAgentId?: string,
): void {
  for (const agentId of screenMediaAgentIds(get(), extraAgentId)) {
    clearVideoStreamForAgent(set, get, agentId);
    clearRelayScreenFrameForAgent(set, agentId);
  }
}

function replaceVideoStreamForAgent(
  set: SetState,
  get: () => AppState,
  agentId: string,
  stream: MediaStream,
): void {
  const existing = get().videoStreams[agentId];
  if (existing && existing !== stream) {
    stopStreamTracks(existing);
  }
  set((prev) => ({
    videoStreams: {
      ...prev.videoStreams,
      [agentId]: stream,
    },
  }));
}

function clearVideoStreamForAgent(set: SetState, get: () => AppState, agentId: string): void {
  const existing = get().videoStreams[agentId];
  if (existing) {
    stopStreamTracks(existing);
  }
  set((prev) => {
    if (!prev.videoStreams[agentId]) return {};
    const videoStreams = { ...prev.videoStreams };
    delete videoStreams[agentId];
    return { videoStreams };
  });
}

function clearRelayScreenFrameForAgent(set: SetState, agentId: string): void {
  set((prev) => {
    if (!prev.relayScreenFrames[agentId]) return {};
    const relayScreenFrames = { ...prev.relayScreenFrames };
    delete relayScreenFrames[agentId];
    return { relayScreenFrames };
  });
}

function stopStreamTracks(stream: MediaStream): void {
  for (const track of stream.getTracks()) {
    try {
      track.stop();
    } catch {
      // ignore
    }
  }
}

async function startWebRtcPeerFlow(
  set: SetState,
  get: () => AppState,
  generation: number,
  initialError: string,
  options: { videoOnly?: boolean; signal?: AbortSignal } = {},
): Promise<void> {
  const { phoneKeypair, pairedHost } = get();
  if (!phoneKeypair || !pairedHost) return;
  const isCurrent = () =>
    generation === (options.videoOnly ? videoPeerStartGeneration : peerStartGeneration);
  const relayStillOnline = () =>
    get().relayHostOnline === true || get().relay?.isHostOnline === true;
  const { startPeerFlow } = await import('../transport/startPeerFlow');
  try {
    await startPeerFlow({
      keypair: phoneKeypair,
      host: pairedHost,
      signal: options.signal,
      onState: (state) => {
        if (!isCurrent()) return;
        if (state.connected) {
          reconnectAttempt = 0;
          if (options.videoOnly) videoRetryAttempt = 0;
          set({ relayHostOnline: true, error: null });
          return;
        }
        if (state.error) {
          const hasRelayFrame = options.videoOnly && hasRecentRelayScreenFrame(get());
          // A video flow says nothing about the Mac's presence; only the
          // relay may mark it offline.
          set((prev) => ({
            relayHostOnline: options.videoOnly ? prev.relayHostOnline : false,
            error: hasRelayFrame ? null : state.error,
          }));
        }
      },
      onClosed: ({ error }) => {
        if (!isCurrent()) return;
        if (options.videoOnly) {
          // The relay owns its own reconnect; the video flow only retries
          // itself, with backoff, while the screen is still wanted.
          clearScreenVideoStream(set, get);
          const hasRelayFrame = hasRecentRelayScreenFrame(get());
          set((prev) => ({
            peer: null,
            signaling: null,
            error: hasRelayFrame
              ? null
              : relayStillOnline()
                ? SCREEN_STREAM_DISCONNECTED_MESSAGE
                : prev.error,
          }));
          scheduleVideoPeerRetry(get);
          return;
        }
        set({
          peer: null,
          signaling: null,
          relayHostOnline: false,
          error,
        });
        scheduleReconnect(set, get, error);
      },
      onSignaling: (signaling) => {
        if (isCurrent()) set({ signaling });
      },
      onPeer: (peer) => {
        if (isCurrent()) set({ peer });
      },
      onHello: (hello) => {
        if (!isCurrent()) return;
        rememberHello(hello);
        if (hello.hostReadOnly !== undefined) {
          get().peer?.sendReadOnlyUpdate(get().readOnlyMode);
        }
        reconnectAttempt = 0;
        set({
          hostHello: hello,
          layout: hello.currentLayout,
          remoteApps: remoteAppsForScreenStopState(
            hello.remoteApps ?? fallbackRemoteAppsFromLayout(hello.currentLayout),
          ),
          workspaceHostDeviceId: pairedHost.deviceId,
          relayHostOnline: true,
          error: null,
        });
        flushPendingScreenStop(set, get);
      },
      onAgent: (snap) => {
        if (!isCurrent()) return;
        rememberOfflineItem(`agent:${snap.agentId}`, snap);
        set((prev) => ({
          relayHostOnline: true,
          error: null,
          workspaceHostDeviceId: pairedHost.deviceId,
          agents: {
            ...prev.agents,
            [snap.agentId]: mergeLocalOptimisticMessages(prev.agents[snap.agentId], snap),
          },
        }));
      },
      onMessageDetail: (detail) => {
        if (!isCurrent()) return;
        cacheMessageDetail(set, detail);
      },
      onVideoTrack: (agentId, stream) => {
        if (!isCurrent()) return;
        videoRetryAttempt = 0;
        replaceVideoStreamForAgent(set, get, agentId, stream);
      },
      onLayout: (layout) => {
        if (isCurrent()) {
          rememberOfflineItem('layout', layout);
          set({ layout, workspaceHostDeviceId: pairedHost.deviceId });
        }
      },
      onRemoteApps: (remoteApps) => {
        if (!isCurrent()) return;
        rememberOfflineItem('apps', remoteAppsForCachedWorkspace(remoteApps));
        const nextRemoteApps = remoteAppsForScreenStopState(remoteApps);
        set({
          remoteApps: nextRemoteApps,
          workspaceHostDeviceId: pairedHost.deviceId,
          relayHostOnline: true,
          error: null,
        });
        if (!isScreenSharingOn(nextRemoteApps)) {
          if (remoteApps.some((app) => app.remoteAppId === 'screen' && app.enabled === false)) {
            clearPendingScreenStop();
          }
          get().stopVideoPeer('screen');
        }
        flushPendingScreenStop(set, get);
      },
    });
  } catch (error) {
    if (!isCurrent()) return;
    const message = connectionError(error) || initialError;
    if (options.videoOnly) {
      clearScreenVideoStream(set, get);
      const hasRelayFrame = hasRecentRelayScreenFrame(get());
      set((prev) => ({
        peer: null,
        signaling: null,
        error: hasRelayFrame ? null : relayStillOnline() ? message : prev.error,
      }));
      scheduleVideoPeerRetry(get);
      return;
    }
    set({ error: message });
    scheduleReconnect(set, get, message);
  }
}

function hasScreenVideoStream(state: AppState): boolean {
  return screenMediaAgentIds(state).some((agentId) => Boolean(state.videoStreams[agentId]));
}

function forgetVideoPeer(): void {
  videoPeerWanted = false;
  videoRetryAttempt = 0;
  clearVideoRetryTimer();
}

function clearVideoRetryTimer(): void {
  if (videoRetryTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(videoRetryTimer);
  }
  videoRetryTimer = null;
}

function canResumeVideoPeer(state: AppState): boolean {
  return (
    videoPeerWanted &&
    !isDocumentHidden() &&
    isWorkspaceRoute(state.route) &&
    state.relayHostOnline === true &&
    isScreenStreamAvailable(state.remoteApps) &&
    !hasScreenVideoStream(state)
  );
}

/**
 * Retries a screen video flow that ended without a rendering stream. The
 * screen panel only restarts on prop changes, so a flow that times out or
 * drops before its first frame would otherwise wait for a manual retry.
 */
function scheduleVideoPeerRetry(get: () => AppState): void {
  if (typeof window === 'undefined') return;
  if (!videoPeerWanted || videoRetryTimer !== null) return;
  const delay = VIDEO_RETRY_BACKOFF_MS[Math.min(videoRetryAttempt, VIDEO_RETRY_BACKOFF_MS.length - 1)];
  videoRetryAttempt += 1;
  videoRetryTimer = window.setTimeout(() => {
    videoRetryTimer = null;
    if (!canResumeVideoPeer(get())) return;
    void get().startVideoPeer();
  }, delay);
}

function failNoSession(): never {
  throw new Error('Sign in again to continue.');
}

export function hasLinkCodeParam(search: string): boolean {
  return !!new URLSearchParams(search).get('linkCode')?.trim();
}

export function shouldEnterHostLinkFlow(route: Route, search: string): boolean {
  return (
    hasLinkCodeParam(search) &&
    route !== 'hosts' &&
    route !== 'auth' &&
    route !== 'loading'
  );
}

/**
 * Puts the Mac a link code just added first. When the list read after the
 * claim already has that Mac, its entry wins: the claim can answer before this
 * browser's registration reached the account (the Mac then reads as untrusted,
 * "Preparing") and before the Mac's relay connection is up (offline).
 */
export function mergeClaimedHost(hosts: AccountHost[], claimedHost: AccountHost): AccountHost[] {
  const listed = hosts.find((host) => host.deviceId === claimedHost.deviceId);
  return [listed ?? claimedHost, ...hosts.filter((host) => host.deviceId !== claimedHost.deviceId)];
}

function currentURLHasLinkCode(): boolean {
  if (typeof window === 'undefined') return false;
  return hasLinkCodeParam(window.location.search);
}

function fallbackEntryRoute(): Route {
  return 'auth';
}

function isWorkspaceRoute(route: Route): boolean {
  return route === 'workspace' || route === 'grid';
}

function isDocumentHidden(): boolean {
  return typeof document !== 'undefined' && document.visibilityState === 'hidden';
}

function clearReconnectTimer() {
  if (reconnectTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(reconnectTimer);
  }
  reconnectTimer = null;
}

function shouldDeferToPendingReconnect(reason?: string): boolean {
  return reconnectTimer !== null && !USER_INITIATED_RECOVERY_REASONS.has(reason ?? '');
}

function scheduleReconnect(set: SetState, get: () => AppState, reason: string, delayOverrideMs?: number) {
  if (typeof window === 'undefined') return;
  if (reconnectTimer !== null || isDocumentHidden()) return;
  const state = get();
  if (!isWorkspaceRoute(state.route) || !state.pairedHost || !state.phoneKeypair) return;

  const delay = delayOverrideMs ?? RECONNECT_BACKOFF_MS[Math.min(reconnectAttempt, RECONNECT_BACKOFF_MS.length - 1)];
  reconnectAttempt += 1;
  reconnectTimer = window.setTimeout(() => {
    reconnectTimer = null;
    void get().recoverConnection({
      reason,
      forceRestart: true,
      refreshHosts: reconnectAttempt % 4 === 0,
      keepVideoPeer: true,
    });
  }, delay);
  set({ error: reason });
}

function connectionError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (/closed before authentication|failed to connect|websocket/i.test(message)) {
    return connectionStatusCopy('reconnecting');
  }
  return message;
}

function authRedirectTo(): string {
  if (typeof window === 'undefined') return platformConfig.publicAppUrl;
  const current = new URL(window.location.href);
  const redirect = new URL(platformConfig.publicAppUrl || window.location.origin);
  const linkCode = current.searchParams.get('linkCode');
  if (linkCode) redirect.searchParams.set('linkCode', linkCode);
  return redirect.toString();
}

function mapUser(user: User): AuthenticatedUser {
  const metadata = user.user_metadata ?? {};
  const displayName =
    (typeof metadata.full_name === 'string' && metadata.full_name.trim()) ||
    (typeof metadata.name === 'string' && metadata.name.trim()) ||
    user.email?.split('@')[0] ||
    'Glasstunnel user';
  return {
    id: user.id,
    email: user.email ?? '',
    displayName,
    avatarUrl: typeof metadata.avatar_url === 'string' ? metadata.avatar_url : undefined,
  };
}

function browserDeviceLabel(): string {
  if (typeof navigator === 'undefined') return 'Browser';
  const ua = navigator.userAgent;
  if (/iPhone/i.test(ua)) return 'iPhone browser';
  if (/iPad/i.test(ua)) return 'iPad browser';
  if (/Android/i.test(ua)) return 'Android browser';
  return 'Browser';
}

function friendlyAccountSyncError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (isAccountApiAuthFailure(error)) {
    return 'Signed in, but this browser session expired. Sign out and sign in again to reconnect your Macs.';
  }
  if (/too many subrequests|workers\/wrangler\/configuration\/#limits/i.test(message)) {
    return 'Signed in, but Mac sync is temporarily overloaded. Refresh in a moment.';
  }
  if (/duplicate key|devices_device_id_key|23505/i.test(message)) {
    return 'Signed in, but this browser was already registered. Refreshing should reconnect.';
  }
  if (/failed to fetch|network|load failed/i.test(message)) {
    return 'Signed in, but Mac sync could not reach Glasstunnel. Check your connection and refresh.';
  }
  return `Signed in, but Macs could not sync: ${message}`;
}

function recordHostListEdit(edit: Omit<HostListEdit, 'seq'>): void {
  hostListEditSeq += 1;
  hostListEdits = [...hostListEdits, { ...edit, seq: hostListEditSeq }].slice(-HOST_LIST_EDIT_HISTORY);
}

/** The list as it stands after the renames and removals this page made since `mark`. */
function withHostListEditsSince(hosts: AccountHost[], mark: number): AccountHost[] {
  let next = hosts;
  for (const edit of hostListEdits) {
    if (edit.seq <= mark) continue;
    if (edit.removed) {
      next = next.filter((host) => host.deviceId !== edit.deviceId);
    } else if (edit.label !== undefined) {
      const label = edit.label;
      next = next.map((host) => (host.deviceId === edit.deviceId ? { ...host, label } : host));
    }
  }
  return next;
}

function showCacheFailureNotice(set: SetState, deviceId: string, notice: string): void {
  cacheFailureNotice = { deviceId, notice };
  set({ accessRevocationNotice: notice });
}

/** The notice on screen when it still reports this Mac's offline copies left in this browser, else null. */
function cacheFailureNoticeFor(state: Pick<AppState, 'accessRevocationNotice'>, deviceId: string): string | null {
  return cacheFailureNotice?.deviceId === deviceId && state.accessRevocationNotice === cacheFailureNotice.notice
    ? cacheFailureNotice.notice
    : null;
}

/**
 * After a removal that got no answer: whether the account's list, loaded
 * again, no longer has the Mac. False when the list cannot load or another
 * account signed in meanwhile, so the failure is reported as it was.
 */
/**
 * How long the list check after an unanswered removal may take. It runs on
 * the same possibly stalled connection, and the Remove dialog cannot be
 * dismissed while it waits, so it gets its own limit; no answer in time means
 * "not confirmed" and the connection error shows.
 */
export const HOST_REMOVAL_RECHECK_TIMEOUT_MS = 15_000;

async function hostLeftAccountList(
  get: () => AppState,
  account: string | undefined,
  deviceId: string,
): Promise<boolean> {
  const keypair = get().phoneKeypair;
  if (!account || !keypair) return false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const recheck = (async () => {
      const session = await currentSession();
      if (session.user.id !== account) return null;
      const { result } = await accountRequestWithSessionRetry(session, (accessToken) =>
        fetchAccountHosts(accessToken, keypair.deviceId),
      );
      return result;
    })();
    const giveUp = new Promise<null>((resolve) => {
      timer = setTimeout(() => resolve(null), HOST_REMOVAL_RECHECK_TIMEOUT_MS);
    });
    const hosts = await Promise.race([recheck, giveUp]);
    if (!hosts) {
      // A late answer from the abandoned check is ignored.
      recheck.catch(() => {});
      return false;
    }
    return get().user?.id === account && !hosts.some((host) => host.deviceId === deviceId);
  } catch {
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function hostRemovalByThisPage(deviceId: string): boolean {
  const until = hostRemovalsByThisPage.get(deviceId);
  if (until === undefined) return false;
  if (until > Date.now()) return true;
  hostRemovalsByThisPage.delete(deviceId);
  return false;
}

/**
 * The Mac as the list shows it after a rename. Only fields that do not depend
 * on which browser asked come from the server's answer; presence and this
 * browser's trust stay as listed.
 */
function renamedAccountHost(host: AccountHost, label: string, stored: AccountHost | undefined): AccountHost {
  return {
    ...host,
    label,
    ...(stored?.appVersion ? { appVersion: stored.appVersion } : {}),
    ...(stored?.addedAtUnixMs ? { addedAtUnixMs: stored.addedAtUnixMs } : {}),
  };
}

/**
 * A failed rename or removal, with a message ready to show. When the server
 * said the Mac is not in the account (404 "Mac not found") or the answer never
 * came (the change may have happened), the list loads again so it shows what
 * the account holds. Any other 404 (an older Worker without the route) is a
 * plain failure: it says nothing about the Mac.
 */
function hostActionFailure(get: () => AppState, action: HostAction, error: unknown): AccountApiError {
  const status = error instanceof AccountApiError ? error.status : 0;
  if (isHostNotInAccount(error) || isNetworkFailure(error)) {
    void get().refreshHosts({ force: true }).catch(() => {});
  }
  return new AccountApiError(hostActionErrorCopy(action, error), isAccountApiAuthFailure(error) ? 401 : status);
}

function chooseHostSelection(hosts: AccountHost[], current: PairedHost | null): PairedHost | null {
  if (current) {
    const match = hosts.find((host) => host.deviceId === current.deviceId && host.trusted);
    if (match) return mapAccountHostToPairedHost(match);
  }
  return null;
}

function mapAccountHostToPairedHost(host: AccountHost): PairedHost {
  return {
    deviceId: host.deviceId,
    publicKeyB64: host.publicKeyB64,
    label: host.label,
    signalingUrl: host.signalingUrl || platformConfig.defaultSignalingUrl,
    turnUrl: host.turnUrl,
    turnUsername: host.turnUsername,
    turnPassword: host.turnPassword,
    pairedAtUnixMs: host.pairedAtUnixMs,
  };
}

async function loadKeypair(): Promise<DeviceKeypair | null> {
  const stored = (await idbGet(PHONE_KEY_KEY)) as
    | { pubKey: string; privKey: string; deviceId: string }
    | undefined;
  if (!stored) return null;
  return {
    publicKey: bytesFromBase64(stored.pubKey),
    privateKey: bytesFromBase64(stored.privKey),
    deviceId: stored.deviceId,
  };
}

async function saveKeypair(kp: DeviceKeypair) {
  await idbSet(PHONE_KEY_KEY, {
    pubKey: base64FromBytes(kp.publicKey),
    privKey: base64FromBytes(kp.privateKey),
    deviceId: kp.deviceId,
  });
}

export async function savePairedHost(host: PairedHost) {
  await idbSet(PAIRED_HOST_KEY, host);
  useAppStore.setState({ pairedHost: host });
}

function toHttp(wsUrl: string): string {
  return wsUrl.replace(/^ws/, 'http').replace(/\/signal\/?$/, '');
}

function appendOptimisticUserMessage(set: SetState, agentId: string, text: string) {
  set((prev) => {
    const current = prev.agents[agentId];
    const recentMessages = [
      ...(current?.recentMessages ?? []),
      {
        messageId: createClientId(),
        role: ChatRole.User,
        text,
        atUnixMs: Date.now(),
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ].slice(-LOCAL_MESSAGE_HISTORY_LIMIT);

    const appName = prev.remoteApps.find((a) => a.agentId === agentId)?.displayName;
    const nextSnapshot: AgentStateSnapshot = {
      agentId,
      agentLabel: current?.agentLabel ?? appName ?? 'Agent',
      adapterKind: current?.adapterKind ?? 1,
      status: AgentStatus.Working,
      statusDetail: 'input delivered',
      recentMessages,
      lastActivityUnixMs: Date.now(),
      position: current?.position ?? { row: 0, col: 0 },
      hasVideoTrack: current?.hasVideoTrack ?? false,
      availableTargets: current?.availableTargets,
      remoteAppId: current?.remoteAppId,
      pendingInputRequest: undefined,
      runtimeControls: current?.runtimeControls,
    };

    return {
      agents: {
        ...prev.agents,
        [agentId]: nextSnapshot,
      },
    };
  });
}

export function mergeLocalOptimisticMessages(
  current: AgentStateSnapshot | undefined,
  incoming: AgentStateSnapshot,
  nowUnixMs = Date.now(),
): AgentStateSnapshot {
  if (!current?.recentMessages?.length) return incoming;

  const incomingMessages = incoming.recentMessages ?? [];
  const incomingMessageKeys = new Set(incomingMessages.map(messageKey));
  const latestIncomingMessageAt = Math.max(0, ...incomingMessages.map((message) => message.atUnixMs ?? 0));
  const localOptimisticMessages = current.recentMessages.filter((message) => {
    if (!preservableOptimisticMessage(message)) return false;
    if (incomingMessageKeys.has(messageKey(message))) return false;
    const atUnixMs = message.atUnixMs ?? 0;
    if (atUnixMs > 0 && nowUnixMs - atUnixMs > LOCAL_OPTIMISTIC_MESSAGE_TTL_MS) return false;
    return latestIncomingMessageAt === 0 || atUnixMs >= latestIncomingMessageAt;
  });

  if (localOptimisticMessages.length === 0) return incoming;

  return {
    ...incoming,
    recentMessages: [...incomingMessages, ...localOptimisticMessages]
      .sort((a, b) => (a.atUnixMs ?? 0) - (b.atUnixMs ?? 0))
      .slice(-LOCAL_MESSAGE_HISTORY_LIMIT),
  };
}

function messageKey(message: { role: ChatRole; text: string }): string {
  return `${message.role}:${message.text}`;
}

function preservableOptimisticMessage(message: { role: ChatRole; text: string }): boolean {
  if (message.role === ChatRole.User) return true;
  if (message.role !== ChatRole.System) return false;
  return message.text.trim() === 'Stop requested.';
}

function appendOptimisticPlanningResponse(set: SetState, response: AgentInputRequestResponse) {
  set((prev) => {
    const current = prev.agents[response.agentId];
    const text = planningResponseSummary(current, response);
    const recentMessages = [
      ...(current?.recentMessages ?? []),
      {
        messageId: createClientId(),
        role: ChatRole.User,
        text,
        atUnixMs: Date.now(),
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ].slice(-LOCAL_MESSAGE_HISTORY_LIMIT);

    const appName = prev.remoteApps.find((a) => a.agentId === response.agentId)?.displayName;
    const nextSnapshot: AgentStateSnapshot = {
      agentId: response.agentId,
      agentLabel: current?.agentLabel ?? appName ?? 'Agent',
      adapterKind: current?.adapterKind ?? 1,
      status: AgentStatus.Working,
      statusDetail: 'choices submitted',
      recentMessages,
      lastActivityUnixMs: Date.now(),
      position: current?.position ?? { row: 0, col: 0 },
      hasVideoTrack: current?.hasVideoTrack ?? false,
      availableTargets: current?.availableTargets,
      remoteAppId: current?.remoteAppId,
      pendingInputRequest: undefined,
      runtimeControls: current?.runtimeControls,
    };

    return {
      agents: {
        ...prev.agents,
        [response.agentId]: nextSnapshot,
      },
    };
  });
}

function markInterruptRequested(set: SetState, agentId: string) {
  set((prev) => {
    const current = prev.agents[agentId];
    const appName = prev.remoteApps.find((a) => a.agentId === agentId)?.displayName;
    const recentMessages = [
      ...(current?.recentMessages ?? []),
      {
        messageId: createClientId(),
        role: ChatRole.System,
        text: 'Stop requested.',
        atUnixMs: Date.now(),
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ].slice(-LOCAL_MESSAGE_HISTORY_LIMIT);

    const nextSnapshot: AgentStateSnapshot = {
      agentId,
      agentLabel: current?.agentLabel ?? appName ?? 'Agent',
      adapterKind: current?.adapterKind ?? 1,
      status: AgentStatus.Working,
      statusDetail: 'stop requested',
      recentMessages,
      lastActivityUnixMs: Date.now(),
      position: current?.position ?? { row: 0, col: 0 },
      hasVideoTrack: current?.hasVideoTrack ?? false,
      availableTargets: current?.availableTargets,
      remoteAppId: current?.remoteAppId,
      pendingInputRequest: current?.pendingInputRequest,
      runtimeControls: current?.runtimeControls,
    };

    return {
      agents: {
        ...prev.agents,
        [agentId]: nextSnapshot,
      },
    };
  });
}

function appendSendFailureMessage(set: SetState, agentId: string) {
  set((prev) => {
    const current = prev.agents[agentId];
    const recentMessages = [
      ...(current?.recentMessages ?? []),
      {
        messageId: createClientId(),
        role: ChatRole.System,
        text: 'Not sent. Connection to your Mac is not open. Reconnect and try again.',
        atUnixMs: Date.now(),
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ].slice(-LOCAL_MESSAGE_HISTORY_LIMIT);

    const appName = prev.remoteApps.find((a) => a.agentId === agentId)?.displayName;
    const nextSnapshot: AgentStateSnapshot = {
      agentId,
      agentLabel: current?.agentLabel ?? appName ?? 'Agent',
      adapterKind: current?.adapterKind ?? 1,
      status: AgentStatus.WaitingInput,
      statusDetail: 'connection not open',
      recentMessages,
      lastActivityUnixMs: Date.now(),
      position: current?.position ?? { row: 0, col: 0 },
      hasVideoTrack: current?.hasVideoTrack ?? false,
      availableTargets: current?.availableTargets,
      remoteAppId: current?.remoteAppId,
      pendingInputRequest: current?.pendingInputRequest,
      runtimeControls: current?.runtimeControls,
    };

    return {
      error: 'Connection to your Mac is not open. Reconnect and try again.',
      agents: {
        ...prev.agents,
        [agentId]: nextSnapshot,
      },
    };
  });
}

function quickReplyLabel(kind: number): string {
  switch (kind) {
    case 1:
      return 'continue';
    case 2:
      return 'try again';
    case 3:
      return 'explain';
    case 4:
      return 'commit this change';
    case 5:
      return 'stop';
    case 6:
      return 'approve';
    case 7:
      return 'reject';
    default:
      return 'quick reply';
  }
}

function appendTargetPromptBlockedMessage(
  set: SetState,
  agentId: string,
  adapterKind?: AdapterKind,
) {
  appendLocalSystemMessage(
    set,
    agentId,
    adapterKind === AdapterKind.Mirror
      ? 'Not sent. Open this chat in Codex on your Mac to send.'
      : 'Not sent. Open this chat in Cursor on your Mac to send.',
  );
}

function appendLocalSystemMessage(set: SetState, agentId: string, text: string) {
  set((prev) => {
    const current = prev.agents[agentId];
    const recent = current?.recentMessages ?? [];
    if (recent.at(-1)?.role === ChatRole.System && recent.at(-1)?.text === text) {
      return prev;
    }

    const recentMessages = [
      ...recent,
      {
        messageId: createClientId(),
        role: ChatRole.System,
        text,
        atUnixMs: Date.now(),
        redacted: false,
        pendingToolCalls: [],
        redactionReasons: [],
      },
    ].slice(-LOCAL_MESSAGE_HISTORY_LIMIT);

    const appName = prev.remoteApps.find((a) => a.agentId === agentId)?.displayName;
    const nextSnapshot: AgentStateSnapshot = current ?? {
      agentId,
      agentLabel: appName ?? agentId,
      adapterKind: AdapterKind.Mirror,
      status: AgentStatus.Error,
      statusDetail: 'not connected',
      recentMessages: [],
      lastActivityUnixMs: Date.now(),
      position: { row: 0, col: 0, rowSpan: 1, colSpan: 1 },
      hasVideoTrack: false,
    };

    return {
      agents: {
        ...prev.agents,
        [agentId]: {
          ...nextSnapshot,
          recentMessages,
          lastActivityUnixMs: Date.now(),
        },
      },
    };
  });
}

export function cursorPromptDeliveryUnavailable(
  snapshot?: Pick<AgentStateSnapshot, 'adapterKind' | 'status' | 'statusDetail'> & {
    availableTargets?: Pick<AgentTargetOption, 'selected' | 'isActive'>[];
  } | null,
): boolean {
  const detail = (snapshot?.statusDetail ?? '').trim().toLowerCase();
  const locallySelectedCursorTarget =
    snapshot?.adapterKind === AdapterKind.Cursor &&
    (snapshot.availableTargets ?? []).some((target) => target.selected && target.isActive === false);
  return (
    snapshot?.adapterKind === AdapterKind.Cursor &&
    (locallySelectedCursorTarget ||
      (snapshot.status === AgentStatus.Working && /^syncing\s+\S/i.test(snapshot.statusDetail ?? '')) ||
      detail === 'open this chat in cursor to send')
  );
}

export function codexPromptDeliveryUnavailable(
  snapshot?: Pick<AgentStateSnapshot, 'adapterKind'> & {
    availableTargets?: Pick<AgentTargetOption, 'selected' | 'isActive'>[];
  } | null,
): boolean {
  return (
    snapshot?.adapterKind === AdapterKind.Mirror &&
    (snapshot.availableTargets ?? []).some((target) => target.selected && target.isActive === false)
  );
}

function targetPromptDeliveryUnavailable(
  snapshot?: Pick<AgentStateSnapshot, 'adapterKind' | 'status' | 'statusDetail'> & {
    availableTargets?: Pick<AgentTargetOption, 'selected' | 'isActive'>[];
  } | null,
): boolean {
  return cursorPromptDeliveryUnavailable(snapshot) || codexPromptDeliveryUnavailable(snapshot);
}

function planningResponseSummary(
  snapshot: AgentStateSnapshot | undefined,
  response: AgentInputRequestResponse,
): string {
  const request = snapshot?.pendingInputRequest;
  if (!request) return 'Submitted choices';

  const answerByQuestion = new Map(
    response.answers.map((answer) => [answer.questionId, answer.choiceIds]),
  );
  const lines = request.questions.flatMap((question) => {
    const selectedChoiceId = answerByQuestion.get(question.questionId)?.[0];
    const choice = question.choices.find((entry) => entry.choiceId === selectedChoiceId);
    if (!choice) return [];
    const label = question.header || question.question;
    return [`${label}: ${choice.label}`];
  });

  return lines.length === 0
    ? 'Submitted choices'
    : `Submitted choices:\n${lines.map((line) => `- ${line}`).join('\n')}`;
}

function projectLabelFor(snapshot: AgentStateSnapshot, targetId: string): string {
  const target = snapshot.availableTargets?.find((entry) => entry.targetId === targetId);
  return target?.threadLabel ?? target?.projectLabel ?? target?.label ?? 'project';
}

function targetSelectionStatusDetail(snapshot: AgentStateSnapshot, targetId: string): string {
  const label = projectLabelFor(snapshot, targetId);
  if (snapshot.adapterKind === AdapterKind.Cursor) {
    return `syncing ${label}`;
  }
  return `opening ${label}`;
}

function applyRuntimeSettings(
  controls: AgentRuntimeControls,
  update: Omit<AgentRuntimeSettingsUpdate, 'agentId'>,
): AgentRuntimeControls {
  const modelOption = update.modelId === undefined
    ? undefined
    : controls.modelOptions.find((option) => option.id === update.modelId);
  const effortOption = update.reasoningEffort === undefined
    ? undefined
    : controls.reasoningEffortOptions.find((option) => option.id === update.reasoningEffort);

  return {
    ...controls,
    modelId: update.modelId ?? controls.modelId,
    modelLabel: update.modelId === undefined
      ? controls.modelLabel
      : modelOption?.label ?? (update.modelId || 'Default'),
    reasoningEffort: update.reasoningEffort ?? controls.reasoningEffort,
    reasoningEffortLabel: update.reasoningEffort === undefined
      ? controls.reasoningEffortLabel
      : effortOption?.label ?? update.reasoningEffort,
    fastMode: update.fastMode ?? controls.fastMode,
  };
}

function runtimeSettingsUpdateUnavailable(status: AgentStatus, statusDetail?: string | null): boolean {
  if (status === AgentStatus.Disconnected || status === AgentStatus.Error) return true;
  if (status !== AgentStatus.Working) return false;

  const detail = (statusDetail ?? '').trim().toLowerCase();
  return detail !== 'settings updated';
}

function optimisticImageMessage(input: Omit<ImageAttachmentInput, 'agentId'>): string {
  const note = `Attached image: ${input.filename}`;
  const trimmed = input.text.trim();
  return trimmed ? `${trimmed}\n\n${note}` : note;
}

function optimisticFileBatchMessage(files: Omit<FileAttachmentInput, 'agentId'>[]): string {
  const first = files[0];
  const names = files.map((file) => file.filename).join(', ');
  const label = files.length === 1 ? 'Attached file' : `Attached ${files.length} files`;
  const note = `${label}: ${names}`;
  const trimmed = first?.text.trim() ?? '';
  return trimmed ? `${trimmed}\n\n${note}` : note;
}

export function statusColor(status: AgentStatus): string {
  switch (status) {
    case AgentStatus.Working:
      return 'bg-accent text-surface-0';
    case AgentStatus.WaitingInput:
      return 'bg-warn text-surface-0';
    case AgentStatus.AwaitingApproval:
      return 'bg-warn text-surface-0';
    case AgentStatus.Done:
      return 'bg-ok text-surface-0';
    case AgentStatus.Error:
      return 'bg-err text-surface-0';
    case AgentStatus.Disconnected:
      return 'bg-surface-3 text-white/60';
    default:
      return 'bg-surface-2 text-white/70';
  }
}
