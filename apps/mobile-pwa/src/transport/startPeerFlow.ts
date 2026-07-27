import type { DeviceKeypair } from '@glasstunnel/shared-crypto';
import type {
  AgentStateSnapshot,
  GridLayout,
  Hello,
  Envelope,
  DataChannelMessage,
  RemoteApp,
} from '@glasstunnel/protocol';
import { DEFAULT_STUN_URLS, CURRENT_PROTOCOL_VERSION } from '@glasstunnel/protocol';
import { SignalingClient } from './SignalingClient';
import { PeerConnection } from './PeerConnection';
import type { PairedHost } from '../lib/store';
import { createClientId } from '../lib/id';
import { connectionStatusCopy } from '../lib/connectionCopy';

export interface StartPeerFlowParams {
  keypair: DeviceKeypair;
  host: PairedHost;
  signal?: AbortSignal;
  onState: (s: { error?: string; connected?: boolean }) => void;
  onClosed?: (s: { reason: 'timeout' | 'signaling' | 'peer'; error: string }) => void;
  onSignaling: (s: SignalingClient) => void;
  onPeer: (p: PeerConnection) => void;
  onHello: (hello: Hello) => void;
  onAgent: (snap: AgentStateSnapshot) => void;
  onVideoTrack: (agentId: string, stream: MediaStream) => void;
  onLayout: (layout: GridLayout) => void;
  onRemoteApps: (remoteApps: RemoteApp[]) => void;
}

/**
 * Spin up signaling + WebRTC after the user selects an account-linked Mac.
 *
 * Mac is the offerer. Phone waits for an SDP offer envelope, answers, and
 * exchanges ICE candidates over the same signaling connection.
 */
export async function startPeerFlow(params: StartPeerFlowParams) {
  const {
    keypair,
    host,
    signal,
    onSignaling,
    onPeer,
    onState,
    onClosed,
    onHello,
    onAgent,
    onVideoTrack,
    onLayout,
    onRemoteApps,
  } = params;

  let sessionID = 'default';
  let peerConnected = false;
  let closed = false;
  let connectionTimeout: number | null = null;
  let disconnectedTimeout: number | null = null;
  let heartbeatId: number | null = null;
  let abortHandler: (() => void) | null = null;
  const refs: {
    peer?: PeerConnection;
    signaling?: SignalingClient;
  } = {};

  const timeoutError = connectionStatusCopy('reconnecting');
  const droppedError = connectionStatusCopy('reconnecting');

  const clearConnectionTimeout = () => {
    if (connectionTimeout !== null) {
      window.clearTimeout(connectionTimeout);
      connectionTimeout = null;
    }
  };

  const clearDisconnectedTimeout = () => {
    if (disconnectedTimeout !== null) {
      window.clearTimeout(disconnectedTimeout);
      disconnectedTimeout = null;
    }
  };

  const stopHeartbeat = () => {
    if (heartbeatId !== null) {
      window.clearInterval(heartbeatId);
      heartbeatId = null;
    }
  };

  const disposeFlow = (): boolean => {
    if (closed) return false;
    closed = true;
    clearConnectionTimeout();
    clearDisconnectedTimeout();
    stopHeartbeat();
    if (signal && abortHandler) {
      signal.removeEventListener('abort', abortHandler);
      abortHandler = null;
    }
    try {
      refs.signaling?.disconnect();
    } catch {
      // ignore
    }
    refs.peer?.close();
    return true;
  };

  const closeFlow = (reason: 'timeout' | 'signaling' | 'peer', error: string) => {
    if (!disposeFlow()) return;
    onState({ connected: false, error });
    onClosed?.({ reason, error });
  };

  const peer = new PeerConnection({
    iceServers: buildIceServers(host),
    onState: (state) => {
      if (closed) return;
      if (state === 'connected') {
        peerConnected = true;
        clearConnectionTimeout();
        clearDisconnectedTimeout();
        onState({ connected: true });
        return;
      }

      if (state === 'failed' || state === 'closed') {
        closeFlow('peer', droppedError);
        return;
      }

      if (state === 'disconnected') {
        onState({ connected: false, error: droppedError });
        clearDisconnectedTimeout();
        disconnectedTimeout = window.setTimeout(() => {
          closeFlow('peer', droppedError);
        }, 8_000);
        return;
      }

      onState({ connected: false });
    },
    onLocalIce: async (candidate) => {
      if (closed) return;
      try {
        const activeSignaling = refs.signaling;
        if (!activeSignaling) throw new Error('Signaling is not ready yet.');
        await activeSignaling.sendEnvelope({
          envelopeId: createClientId(),
          fromDeviceId: keypair.deviceId,
          toDeviceId: host.deviceId,
          sentAtUnixMs: Date.now(),
          signature: new Uint8Array(),
          payload: {
            kind: 'iceCandidate',
            iceCandidate: {
              candidate: candidate.candidate,
              sdpMid: candidate.sdpMid ?? '',
              sdpMlineIndex: candidate.sdpMLineIndex ?? 0,
              sessionId: sessionID,
            },
          },
        });
      } catch (error) {
        onState({ error: (error as Error).message });
      }
    },
    onTrack: (stream, trackId) => {
      if (closed) return;
      const agentId = trackId.replace(/^gt-/, '');
      onVideoTrack(agentId, stream);
    },
    onMessage: (msg) => {
      if (closed) return;
      const activeSignaling = refs.signaling;
      if (!activeSignaling) {
        onState({ error: 'Signaling is not ready yet.' });
        return;
      }
      handleDataChannel(
        msg,
        peer,
        activeSignaling,
        disposeFlow,
        onState,
        onHello,
        onAgent,
        onLayout,
        onRemoteApps,
      );
    },
  });
  refs.peer = peer;

  const signaling = new SignalingClient({
    url: host.signalingUrl,
    keypair,
    role: 'phone',
    deviceInfo: navigator.userAgent,
    onEnvelope: async (env: Envelope) => {
      if (closed) return;
      if (env.fromDeviceId !== host.deviceId) return;
      switch (env.payload.kind) {
        case 'sdpOffer': {
          const offer = env.payload.sdpOffer;
          sessionID = offer.sessionId;
          const answer = await peer.acceptOffer(offer.sdp);
          if (closed) return;
          await signaling.sendEnvelope({
            envelopeId: createClientId(),
            fromDeviceId: keypair.deviceId,
            toDeviceId: host.deviceId,
            sentAtUnixMs: Date.now(),
            signature: new Uint8Array(),
            payload: {
              kind: 'sdpAnswer',
              sdpAnswer: {
                sdp: answer.sdp ?? '',
                sessionId: offer.sessionId,
              },
            },
          });
          break;
        }
        case 'iceCandidate': {
          await peer.addRemoteIce({
            candidate: env.payload.iceCandidate.candidate,
            sdpMid: env.payload.iceCandidate.sdpMid,
            sdpMLineIndex: env.payload.iceCandidate.sdpMlineIndex,
          });
          break;
        }
        default:
          break;
      }
    },
    onError: (error) => {
      if (!closed) onState({ error: error.message });
    },
    onClose: (_event, intentional) => {
      if (closed || intentional) return;
      closeFlow('signaling', peerConnected ? droppedError : timeoutError);
    },
    trustedPublicKeyForDevice: (deviceId) =>
      deviceId === host.deviceId ? host.publicKeyB64 : undefined,
  });
  refs.signaling = signaling;

  abortHandler = () => {
    disposeFlow();
  };
  signal?.addEventListener('abort', abortHandler, { once: true });
  if (signal?.aborted) {
    disposeFlow();
    return;
  }

  try {
    await signaling.connect();
  } catch (error) {
    if (closed || signal?.aborted) {
      disposeFlow();
      return;
    }
    throw error;
  }
  if (closed || signal?.aborted) {
    disposeFlow();
    return;
  }
  onSignaling(signaling);
  onPeer(peer);

  await signaling.sendEnvelope({
    envelopeId: createClientId(),
    fromDeviceId: keypair.deviceId,
    toDeviceId: host.deviceId,
    sentAtUnixMs: Date.now(),
    signature: new Uint8Array(),
    payload: { kind: 'ping', ping: { atUnixMs: Date.now() } },
  });
  if (closed || signal?.aborted) {
    disposeFlow();
    return;
  }

  heartbeatId = window.setInterval(() => peer.sendHeartbeat(), 20_000);
  connectionTimeout = window.setTimeout(() => {
    if (peerConnected || closed) return;
    closeFlow('timeout', timeoutError);
  }, 25_000);
}

function handleDataChannel(
  msg: DataChannelMessage,
  peer: PeerConnection,
  signaling: SignalingClient,
  onFatalClose: () => void,
  onState: (s: { error?: string; connected?: boolean }) => void,
  onHello: (hello: Hello) => void,
  onAgent: (snap: AgentStateSnapshot) => void,
  onLayout: (layout: GridLayout) => void,
  onRemoteApps: (remoteApps: RemoteApp[]) => void,
) {
  switch (msg.body.kind) {
    case 'hello': {
      const hello = msg.body.hello;
      const hostVersion = hello.protocolVersion ?? 1;
      const diff = Math.abs(hostVersion - CURRENT_PROTOCOL_VERSION);
      if (diff > 1) {
        const err =
          hostVersion < CURRENT_PROTOCOL_VERSION
            ? 'Your Mac app is out of date. Please update Glasstunnel on your Mac and try again.'
            : 'Your phone app is out of date. Please refresh the page and try again.';
        onState({ error: err });
        onFatalClose();
        peer.close();
        signaling.disconnect();
        return;
      }
      onHello(hello);
      break;
    }
    case 'agentState':
      onAgent(msg.body.agentState);
      break;
    case 'gridLayoutUpdate':
      onLayout(msg.body.gridLayoutUpdate.layout);
      break;
    case 'remoteAppsUpdate':
      onRemoteApps(msg.body.remoteAppsUpdate.remoteApps);
      break;
    default:
      break;
  }
}

function buildIceServers(host: PairedHost): RTCIceServer[] {
  const servers: RTCIceServer[] = DEFAULT_STUN_URLS.map((url) => ({ urls: [url] }));
  const turnUrl = host.turnUrl?.trim();
  const turnUsername = host.turnUsername?.trim();
  const turnPassword = host.turnPassword?.trim();
  if (turnUrl && turnUsername && turnPassword) {
    servers.push({
      urls: [turnUrl],
      username: turnUsername,
      credential: turnPassword,
    });
  }
  return servers;
}
