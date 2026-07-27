import { create } from 'zustand';
import { del as idbDel, get as idbGet, set as idbSet } from 'idb-keyval';
import type { Session, User } from '@supabase/supabase-js';
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
import {
  AccountApiError,
  claimHostCode,
  fetchAccountHosts,
  isAccountApiAuthFailure,
  registerBrowserDevice,
  type AccountHost,
} from './accountApi';
import { createClientId } from './id';
import { platformConfig } from './platform';
import { registerPushSubscription } from '../notifications/push';
import { SignalingClient } from '../transport/SignalingClient';
import { PeerConnection } from '../transport/PeerConnection';
import type { FileAttachmentInput } from '../transport/PeerConnection';
import type { RelayConnection, RelayScreenFrame } from '../transport/RelayConnection';
import { PeerFlowAbortRegistry } from '../transport/PeerFlowAbortRegistry';
import { hasSupabaseAuth, supabase } from './supabase';
import {
  fallbackRemoteAppsFromLayout,
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

export interface AppState {
  route: Route;
  locked: boolean;
  readOnlyMode: boolean;
  phoneKeypair: DeviceKeypair | null;
  pairedHost: PairedHost | null;
  availableHosts: AccountHost[];
  user: AuthenticatedUser | null;
  authConfigured: boolean;
  layout: GridLayout | null;
  remoteApps: RemoteApp[];
  hostHello: Hello | null;
  workspaceHostDeviceId: string | null;
  agents: Record<string, AgentStateSnapshot>;
  videoStreams: Record<string, MediaStream>;
  relayScreenFrames: Record<string, RelayScreenFrame>;
  screenShareQuality: ScreenShareQuality;
  peer: PeerConnection | null;
  signaling: SignalingClient | null;
  relay: RelayConnection | null;
  relayHostOnline: boolean | null;
  error: string | null;

  bootstrap: () => Promise<void>;
  navigateTo: (route: Route) => void;
  setLocked: (locked: boolean) => void;
  setReadOnly: (readOnly: boolean) => void;
  forgetCurrentMac: () => Promise<void>;
  disconnectPeer: () => void;
  startPeer: () => Promise<void>;
  startVideoPeer: () => Promise<void>;
  stopVideoPeer: (agentId?: string) => void;
  clearVideoStream: (agentId: string) => void;
  clearRelayScreenFrame: (agentId: string) => void;
  setScreenShareQuality: (quality: ScreenShareQuality) => void;
  recoverConnection: (options?: {
    reason?: string;
    forceRestart?: boolean;
    refreshHosts?: boolean;
  }) => Promise<void>;
  signInWithGoogle: () => Promise<void>;
  signInWithGitHub: () => Promise<void>;
  signInWithPassword: (email: string, password: string) => Promise<void>;
  signUpWithPassword: (email: string, password: string, displayName?: string) => Promise<void>;
  signOut: () => Promise<void>;
  refreshHosts: (options?: { force?: boolean }) => Promise<void>;
  claimHostLinkCode: (code: string) => Promise<AccountHost>;
  chooseHost: (hostDeviceId: string) => Promise<void>;
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
const RELAY_CACHE_PREFIX = 'gt.relay.cache.';
const SCREEN_SHARE_QUALITY_KEY = 'gt.screenShareQuality';
let authSubscriptionAttached = false;
let sessionSyncVersion = 0;
let refreshHostsInFlight: Promise<void> | null = null;
let lastRefreshHostsCompletedAt = 0;
let peerStartGeneration = 0;
let videoPeerStartGeneration = 0;
const peerFlowAbortRegistry = new PeerFlowAbortRegistry();
let reconnectTimer: number | null = null;
let reconnectAttempt = 0;
let lastRecoverHostRefreshAt = 0;
let pendingScreenStop = false;
let pendingScreenStopRequestedAt = 0;
let screenStopConfirmationTimer: number | null = null;

const REFRESH_HOSTS_MIN_INTERVAL_MS = 5_000;
const RECOVER_HOST_REFRESH_INTERVAL_MS = 30_000;
const RECONNECT_BACKOFF_MS = [1_500, 3_000, 5_000, 10_000, 20_000, 30_000];

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
  user: null,
  authConfigured: hasSupabaseAuth(),
  layout: null,
  remoteApps: [],
  hostHello: null,
  workspaceHostDeviceId: null,
  agents: {},
  videoStreams: {},
  relayScreenFrames: {},
  screenShareQuality: loadScreenShareQuality(),
  peer: null,
  signaling: null,
  relay: null,
  relayHostOnline: null,
  error: null,

  async bootstrap() {
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
        authConfigured: hasSupabaseAuth(),
      });

      if (!supabase) {
        set({
          route: 'auth',
        });
        return;
      }

      if (!authSubscriptionAttached) {
        authSubscriptionAttached = true;
        supabase.auth.onAuthStateChange((event, session) => {
          if (event === 'TOKEN_REFRESHED') return;
          void synchronizeSession(set, get, session);
        });
      }

      await supabase.auth.initialize();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      await synchronizeSession(set, get, session);
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
    relay?.sendReadOnlyUpdate(readOnly);
    peer?.sendReadOnlyUpdate(readOnly);
  },

  async forgetCurrentMac() {
    peerStartGeneration += 1;
    videoPeerStartGeneration += 1;
    peerFlowAbortRegistry.cancelAll();
    clearReconnectTimer();
    const pairedHost = get().pairedHost;
    if (pairedHost) {
      localStorage.removeItem(`gt.webauthn.enrolled.${pairedHost.deviceId}`);
    }
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
      videoStreams: {},
      relayScreenFrames: {},
      layout: null,
      remoteApps: [],
      hostHello: null,
      workspaceHostDeviceId: null,
      route: user ? 'hosts' : fallbackEntryRoute(),
    });
  },

  disconnectPeer() {
    peerStartGeneration += 1;
    videoPeerStartGeneration += 1;
    peerFlowAbortRegistry.cancelAll();
    clearReconnectTimer();
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
      workspaceHostDeviceId: null,
      videoStreams: {},
      relayScreenFrames: {},
    });
  },

  async startPeer() {
    const { phoneKeypair, pairedHost } = get();
    if (!phoneKeypair || !pairedHost) return;
    const generation = ++peerStartGeneration;
    videoPeerStartGeneration += 1;
    peerFlowAbortRegistry.cancelAll();
    clearReconnectTimer();
    get().peer?.close();
    get().signaling?.disconnect();
    get().relay?.disconnect();
    const cached = await loadRelayCache(pairedHost.deviceId);
    const current = get();
    const canReuseCurrentWorkspace = current.workspaceHostDeviceId === pairedHost.deviceId;
    set({
      peer: null,
      signaling: null,
      relay: null,
      relayHostOnline: cached ? false : null,
      hostHello: cached?.hostHello ?? (canReuseCurrentWorkspace ? current.hostHello : null),
      layout: cached?.layout ?? (canReuseCurrentWorkspace ? current.layout : null),
      remoteApps: cached?.remoteApps ?? (canReuseCurrentWorkspace ? current.remoteApps : []),
      agents: cached?.agents ?? (canReuseCurrentWorkspace ? current.agents : {}),
      workspaceHostDeviceId: cached || canReuseCurrentWorkspace ? pairedHost.deviceId : null,
      videoStreams: {},
      relayScreenFrames: {},
      error: cached
        ? connectionStatusCopy('cached-reconnecting')
        : connectionStatusCopy('connecting'),
    });
    const isCurrent = () => generation === peerStartGeneration;
    try {
      const session = await currentSession();
      const { RelayConnection } = await import('../transport/RelayConnection');
      const relay = new RelayConnection({
        keypair: phoneKeypair,
        host: pairedHost,
        accessToken: session.access_token,
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
        onClose: (_event, intentional) => {
          if (!isCurrent()) return;
          if (intentional) return;
          const error = connectionStatusCopy('reconnecting');
          set({
            signaling: null,
            relay: null,
            relayHostOnline: false,
            error,
          });
          scheduleReconnect(set, get, error);
        },
        onHello: (hello, cached) => {
          if (!isCurrent()) return;
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
            error: cached
              ? (prev.error ?? connectionStatusCopy('offline-cached'))
              : null,
          }));
          flushPendingScreenStop(set, get);
          void persistRelayCache(get());
        },
        onAgent: (snap, cached) => {
          if (!isCurrent()) return;
          set((prev) => ({
            relayHostOnline: cached ? prev.relayHostOnline : true,
            error: cached ? prev.error : null,
            workspaceHostDeviceId: pairedHost.deviceId,
            agents: {
              ...prev.agents,
              [snap.agentId]: mergeLocalOptimisticMessages(prev.agents[snap.agentId], snap),
            },
          }));
          void persistRelayCache(get());
        },
        onRemoteApps: (remoteApps, cached) => {
          if (!isCurrent()) return;
          const nextRemoteApps = remoteAppsForScreenStopState(remoteApps);
          set((prev) => ({
            remoteApps: nextRemoteApps,
            workspaceHostDeviceId: pairedHost.deviceId,
            relayHostOnline: cached ? (prev.relayHostOnline ?? false) : true,
            error: cached ? prev.error : null,
          }));
          if (!isScreenStreamAvailable(nextRemoteApps)) {
            if (remoteApps.some((app) => app.remoteAppId === 'screen' && app.enabled === false)) {
              clearPendingScreenStop();
            }
            get().stopVideoPeer('screen');
          }
          flushPendingScreenStop(set, get);
          void persistRelayCache(get());
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
      if (!isCurrent()) return;
      set({ relay });
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

  async recoverConnection(options) {
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
      }
    }

    await get().startPeer();
  },

  async signInWithGoogle() {
    if (!supabase) {
      throw new Error('Hosted account login is not configured.');
    }
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: authRedirectTo(),
      },
    });
    if (error) throw error;
  },

  async signInWithGitHub() {
    if (!supabase) {
      throw new Error('Hosted account login is not configured.');
    }
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'github',
      options: {
        redirectTo: authRedirectTo(),
      },
    });
    if (error) throw error;
  },

  async signInWithPassword(email, password) {
    if (!supabase) {
      throw new Error('Hosted account login is not configured.');
    }
    const trimmed = email.trim().toLowerCase();
    if (!trimmed) {
      throw new Error('Enter an email address.');
    }
    if (!password.trim()) {
      throw new Error('Enter your password.');
    }
    const { error } = await supabase.auth.signInWithPassword({
      email: trimmed,
      password,
    });
    if (error) throw error;
  },

  async signUpWithPassword(email, password, displayName) {
    if (!supabase) {
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
    const { error } = await supabase.auth.signUp({
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
    sessionSyncVersion += 1;
    peerStartGeneration += 1;
    videoPeerStartGeneration += 1;
    peerFlowAbortRegistry.cancelAll();
    clearReconnectTimer();
    get().peer?.close();
    get().signaling?.disconnect();
    get().relay?.disconnect();
    await idbDel(PAIRED_HOST_KEY);
    if (supabase) {
      const { error } = await supabase.auth.signOut();
      if (error) throw error;
    }
    set({
      user: null,
      availableHosts: [],
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
  },

  async refreshHosts(options) {
    if (!supabase) return;
    if (refreshHostsInFlight) return refreshHostsInFlight;
    if (
      !options?.force &&
      Date.now() - lastRefreshHostsCompletedAt < REFRESH_HOSTS_MIN_INTERVAL_MS
    ) {
      return;
    }

    refreshHostsInFlight = (async () => {
      const syncVersion = sessionSyncVersion;
      const isCurrentSync = () => syncVersion === sessionSyncVersion;
      const session = await currentSession().catch(() => null);
      const keypair = get().phoneKeypair;

      if (!session?.user || !keypair) {
        await synchronizeSession(set, get, session, { preserveRoute: true });
        return;
      }

      try {
        const { result: hosts, session: accountSession } = await accountRequestWithSessionRetry(
          session,
          (accessToken) => fetchAccountHosts(accessToken, keypair.deviceId),
        );
        if (!isCurrentSync()) return;

        const state = get();
        const selected = chooseHostSelection(hosts, state.pairedHost);
        if (selected) {
          await idbSet(PAIRED_HOST_KEY, selected);
        } else if (state.pairedHost) {
          await idbDel(PAIRED_HOST_KEY);
        }

        if (!isCurrentSync()) return;
        const selectedOnline = selected
          ? (hosts.find((host) => host.deviceId === selected.deviceId)?.online ?? null)
          : null;
        set({
          user: state.user ?? mapUser(accountSession.user),
          availableHosts: hosts,
          pairedHost: selected,
          relayHostOnline: selectedOnline,
          error: null,
          authConfigured: true,
        });
      } catch (err) {
        if (!isCurrentSync()) return;
        set({ error: friendlyAccountSyncError(err) });
      } finally {
        lastRefreshHostsCompletedAt = Date.now();
      }
    })().finally(() => {
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
    await get().refreshHosts({ force: true });
    set((state) => ({
      availableHosts: mergeClaimedHost(state.availableHosts, host),
    }));
    return host;
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
    await savePairedHost(pairedHost);
    const cached = await loadRelayCache(pairedHost.deviceId);
    clearPendingScreenStop();
    set({
      pairedHost,
      locked: false,
      route: 'workspace',
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

  sendText(agentId, text, submit) {
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
    const relay = get().relay;
    const peer = get().peer;
    if (!(relay?.sendInterrupt({ agentId }) || peer?.sendInterrupt({ agentId }) || false)) {
      appendSendFailureMessage(set, agentId);
      return;
    }
    markInterruptRequested(set, agentId);
  },

  selectTarget(agentId, targetId) {
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

async function synchronizeSession(
  set: SetState,
  get: () => AppState,
  session: Session | null,
  options: { preserveRoute?: boolean } = {},
) {
  const syncVersion = ++sessionSyncVersion;
  const isCurrentSync = () => syncVersion === sessionSyncVersion;
  const state = get();
  const storedHost = ((await idbGet(PAIRED_HOST_KEY)) as PairedHost | undefined) ?? null;
  const pendingLinkCode = currentURLHasLinkCode();
  if (!isCurrentSync()) return;

  if (!session?.user || !supabase) {
    const route = state.authConfigured ? 'auth' : fallbackEntryRoute();
    set({
      user: null,
      availableHosts: [],
      pairedHost: storedHost,
      relayHostOnline: null,
      route,
      locked: state.locked,
    });
    return;
  }

  const user = mapUser(session.user);
  const keypair = state.phoneKeypair;
  if (!keypair) {
    set({
      user,
      route: 'hosts',
      locked: false,
      authConfigured: true,
    });
    return;
  }

  const initialSignedInRoute: Route = pendingLinkCode
    ? 'hosts'
    : isWorkspaceRoute(state.route)
      ? 'workspace'
      : 'hosts';

  set({
    user,
    authConfigured: true,
    route: initialSignedInRoute,
    locked: isWorkspaceRoute(state.route) ? state.locked : false,
    error: null,
  });

  let hosts: AccountHost[];
  let accountSession = session;
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
    hosts = result.result;
    accountSession = result.session;
  } catch (err) {
    if (!isCurrentSync()) return;
    const latest = get();
    const fallbackRoute =
      latest.route === 'loading' || latest.route === 'auth' ? 'hosts' : latest.route;
    set({
      user,
      availableHosts: latest.availableHosts,
      pairedHost: latest.pairedHost ?? storedHost,
      route: fallbackRoute,
      locked: false,
      authConfigured: true,
      error: friendlyAccountSyncError(err),
    });
    return;
  }

  if (!isCurrentSync()) return;

  const selected = chooseHostSelection(hosts, get().pairedHost ?? storedHost);
  if (selected) {
    await idbSet(PAIRED_HOST_KEY, selected);
  } else {
    await idbDel(PAIRED_HOST_KEY);
  }

  const shouldRestoreWorkspace =
    !!storedHost && !!selected && storedHost.deviceId === selected.deviceId;
  let nextRoute: Route = 'hosts';
  if (!pendingLinkCode && options.preserveRoute && isWorkspaceRoute(state.route)) {
    nextRoute = 'workspace';
  } else if (!pendingLinkCode && shouldRestoreWorkspace) {
    nextRoute = 'workspace';
  }

  const latest = get();
  const shouldKeepWorkspaceState =
    !!selected && latest.workspaceHostDeviceId === selected.deviceId;

  set({
    user: mapUser(accountSession.user),
    availableHosts: hosts,
    pairedHost: selected,
    relayHostOnline: selected
      ? (hosts.find((host) => host.deviceId === selected.deviceId)?.online ?? null)
      : null,
    route: nextRoute,
    locked: isWorkspaceRoute(state.route) ? state.locked : false,
    authConfigured: true,
    error: null,
    ...(shouldKeepWorkspaceState
      ? {}
      : {
          hostHello: null,
          layout: null,
          remoteApps: [],
          agents: {},
          workspaceHostDeviceId: null,
          relayScreenFrames: {},
        }),
  });
}

async function currentSession(options: { forceRefresh?: boolean } = {}): Promise<Session> {
  if (!supabase) {
    throw new Error('Hosted account login is not configured.');
  }
  const {
    data: { session },
    error,
  } = await supabase.auth.getSession();
  if (error) throw error;
  const activeSession = session ?? failNoSession();
  if (!options.forceRefresh) {
    return activeSession;
  }
  const { data, error: refreshError } = await supabase.auth.refreshSession({
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
  savedAtUnixMs: number;
}

async function loadRelayCache(hostDeviceId: string): Promise<RelayCachedWorkspace | null> {
  try {
    const cached =
      ((await idbGet(`${RELAY_CACHE_PREFIX}${hostDeviceId}`)) as
        | RelayCachedWorkspace
        | undefined) ?? null;
    return cached ? sanitizeRelayCache(cached) : null;
  } catch {
    return null;
  }
}

async function persistRelayCache(state: AppState): Promise<void> {
  if (!state.pairedHost) return;
  if (state.workspaceHostDeviceId !== state.pairedHost.deviceId) return;
  const remoteApps = remoteAppsForCachedWorkspace(state.remoteApps);
  await idbSet(`${RELAY_CACHE_PREFIX}${state.pairedHost.deviceId}`, {
    hostHello: state.hostHello
      ? {
          ...state.hostHello,
          remoteApps: state.hostHello.remoteApps
            ? remoteAppsForCachedWorkspace(state.hostHello.remoteApps)
            : remoteApps,
        }
      : null,
    layout: state.layout,
    remoteApps,
    agents: state.agents,
    savedAtUnixMs: Date.now(),
  } satisfies RelayCachedWorkspace);
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
          set({ relayHostOnline: true, error: null });
          return;
        }
        if (state.error) {
          const hasRelayFrame = options.videoOnly && hasRecentRelayScreenFrame(get());
          set({
            relayHostOnline: options.videoOnly && relayStillOnline() ? true : false,
            error: hasRelayFrame ? null : state.error,
          });
        }
      },
      onClosed: ({ error }) => {
        if (!isCurrent()) return;
        if (options.videoOnly) {
          clearScreenVideoStream(set, get);
        }
        if (options.videoOnly && relayStillOnline()) {
          const hasRelayFrame = hasRecentRelayScreenFrame(get());
          set({
            peer: null,
            signaling: null,
            relayHostOnline: true,
            error: hasRelayFrame ? null : SCREEN_STREAM_DISCONNECTED_MESSAGE,
          });
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
        void persistRelayCache(get());
      },
      onAgent: (snap) => {
        if (!isCurrent()) return;
        set((prev) => ({
          relayHostOnline: true,
          error: null,
          workspaceHostDeviceId: pairedHost.deviceId,
          agents: {
            ...prev.agents,
            [snap.agentId]: mergeLocalOptimisticMessages(prev.agents[snap.agentId], snap),
          },
        }));
        void persistRelayCache(get());
      },
      onVideoTrack: (agentId, stream) => {
        if (!isCurrent()) return;
        replaceVideoStreamForAgent(set, get, agentId, stream);
      },
      onLayout: (layout) => {
        if (isCurrent()) set({ layout, workspaceHostDeviceId: pairedHost.deviceId });
      },
      onRemoteApps: (remoteApps) => {
        if (!isCurrent()) return;
        const nextRemoteApps = remoteAppsForScreenStopState(remoteApps);
        set({
          remoteApps: nextRemoteApps,
          workspaceHostDeviceId: pairedHost.deviceId,
          relayHostOnline: true,
          error: null,
        });
        if (!isScreenStreamAvailable(nextRemoteApps)) {
          if (remoteApps.some((app) => app.remoteAppId === 'screen' && app.enabled === false)) {
            clearPendingScreenStop();
          }
          get().stopVideoPeer('screen');
        }
        flushPendingScreenStop(set, get);
        void persistRelayCache(get());
      },
    });
  } catch (error) {
    if (!isCurrent()) return;
    const message = connectionError(error) || initialError;
    if (options.videoOnly && relayStillOnline()) {
      clearScreenVideoStream(set, get);
      const hasRelayFrame = hasRecentRelayScreenFrame(get());
      set({
        peer: null,
        signaling: null,
        relayHostOnline: true,
        error: hasRelayFrame ? null : message,
      });
      return;
    }
    if (options.videoOnly) {
      clearScreenVideoStream(set, get);
    }
    set({ error: message });
    scheduleReconnect(set, get, message);
  }
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

export function mergeClaimedHost(hosts: AccountHost[], claimedHost: AccountHost): AccountHost[] {
  return [claimedHost, ...hosts.filter((host) => host.deviceId !== claimedHost.deviceId)];
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

function scheduleReconnect(set: SetState, get: () => AppState, reason: string) {
  if (typeof window === 'undefined') return;
  if (reconnectTimer !== null || isDocumentHidden()) return;
  const state = get();
  if (!isWorkspaceRoute(state.route) || !state.pairedHost || !state.phoneKeypair) return;

  const delay = RECONNECT_BACKOFF_MS[Math.min(reconnectAttempt, RECONNECT_BACKOFF_MS.length - 1)];
  reconnectAttempt += 1;
  reconnectTimer = window.setTimeout(() => {
    reconnectTimer = null;
    void get().recoverConnection({
      reason,
      forceRestart: true,
      refreshHosts: reconnectAttempt % 4 === 0,
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
