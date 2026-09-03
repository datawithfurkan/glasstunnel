import {
  type DataChannelMessage,
  type UserInput,
  type ImageAttachmentInput,
  type FileAttachmentChunk,
  type AgentRuntimeSettingsUpdate,
  type QuickReply,
  type InterruptRequest,
  type TargetSelectionRequest,
  type TargetRenameRequest,
  type AgentInputRequestResponse,
  type ScreenPointerInput,
  encodeDataChannelMessageJson,
  decodeDataChannelMessageJson,
  DEFAULT_STUN_URLS,
} from '@glasstunnel/protocol';
import type { MessageDetailRequest } from '@glasstunnel/protocol';
import { createClientId } from '../lib/id';
import { preferH264InAnswerSdp } from './sdpCodecs';

export interface PeerConnectionOptions {
  iceServers: RTCIceServer[];
  onMessage?: (msg: DataChannelMessage) => void;
  onTrack?: (stream: MediaStream, trackId: string) => void;
  onState?: (state: RTCPeerConnectionState) => void;
  onLocalIce?: (candidate: RTCIceCandidate) => void;
  onLocalOffer?: (offer: RTCSessionDescriptionInit) => void;
}

export type FileAttachmentInput = Omit<
  FileAttachmentChunk,
  'transferId' | 'totalBytes' | 'chunkIndex' | 'chunkCount'
> & {
  bytes: Uint8Array;
};

/**
 * Thin wrapper over RTCPeerConnection for the phone side.
 *
 * The phone is the *answerer* — the Mac creates the offer, we create the
 * answer. We do not add any video senders; we only consume incoming video
 * tracks from the Mac.
 */
export class PeerConnection {
  public readonly pc: RTCPeerConnection;
  private dataChannel: RTCDataChannel | null = null;
  private opts: PeerConnectionOptions;
  private static readonly attachmentChunkBytes = 32 * 1024;
  private static readonly maxBufferedBytes = 512 * 1024;

  constructor(opts: PeerConnectionOptions) {
    this.opts = opts;
    const config: RTCConfiguration = {
      iceServers: opts.iceServers.length
        ? opts.iceServers
        : DEFAULT_STUN_URLS.map((url) => ({ urls: [url] })),
      bundlePolicy: 'max-bundle',
      rtcpMuxPolicy: 'require',
    };
    this.pc = new RTCPeerConnection(config);

    this.pc.onconnectionstatechange = () => {
      this.opts.onState?.(this.pc.connectionState);
    };

    this.pc.onicecandidate = (ev) => {
      if (ev.candidate) this.opts.onLocalIce?.(ev.candidate);
    };

    this.pc.ontrack = (ev) => {
      const [stream] = ev.streams;
      if (stream) {
        this.opts.onTrack?.(stream, ev.track.id);
      }
    };

    this.pc.ondatachannel = (ev) => {
      this.attachDataChannel(ev.channel);
    };
  }

  async acceptOffer(sdp: string): Promise<RTCSessionDescriptionInit> {
    await this.pc.setRemoteDescription({ type: 'offer', sdp });
    this.preferMobileVideoCodecs();
    const answer = await this.pc.createAnswer();
    if (shouldPreferH264ForVideo() && answer.sdp) {
      answer.sdp = preferH264InAnswerSdp(answer.sdp);
    }
    await this.pc.setLocalDescription(answer);
    this.opts.onLocalOffer?.(answer);
    return answer;
  }

  async addRemoteIce(candidate: RTCIceCandidateInit): Promise<void> {
    try {
      await this.pc.addIceCandidate(candidate);
    } catch {
      // Ignore; candidates can arrive before SRD sometimes.
    }
  }

  close() {
    try {
      this.dataChannel?.close();
    } catch {
      // ignore
    }
    try {
      this.pc.close();
    } catch {
      // ignore
    }
  }

  send(msg: DataChannelMessage): boolean {
    if (!this.dataChannel || this.dataChannel.readyState !== 'open') return false;
    try {
      this.dataChannel.send(encodeDataChannelMessageJson(msg));
      return true;
    } catch {
      return false;
    }
  }

  sendUserInput(input: UserInput): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'userInput', userInput: input },
    });
  }

  sendScreenPointer(input: ScreenPointerInput): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'screenPointerInput', screenPointerInput: input },
    });
  }

  async sendImageAttachment(input: ImageAttachmentInput): Promise<boolean> {
    if (!this.dataChannel || this.dataChannel.readyState !== 'open') return false;

    const transferId = createClientId();
    const chunkCount = Math.ceil(input.bytes.byteLength / PeerConnection.attachmentChunkBytes);
    if (chunkCount <= 0) return false;

    for (let chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      const channelReady = await this.waitForBufferedAmount();
      if (!channelReady) return false;

      const start = chunkIndex * PeerConnection.attachmentChunkBytes;
      const end = Math.min(input.bytes.byteLength, start + PeerConnection.attachmentChunkBytes);
      const bytes = input.bytes.slice(start, end);
      const sent = this.send({
        messageId: createClientId(),
        atUnixMs: Date.now(),
        body: {
          kind: 'imageAttachmentChunk',
          imageAttachmentChunk: {
            transferId,
            agentId: input.agentId,
            text: input.text,
            filename: input.filename,
            mimeType: input.mimeType,
            totalBytes: input.bytes.byteLength,
            chunkIndex,
            chunkCount,
            bytes,
            submitOnSend: input.submitOnSend,
          },
        },
      });
      if (!sent) return false;
    }

    return true;
  }

  async sendFileAttachment(input: FileAttachmentInput): Promise<boolean> {
    if (!this.dataChannel || this.dataChannel.readyState !== 'open') return false;

    const transferId = createClientId();
    const chunkCount = Math.ceil(input.bytes.byteLength / PeerConnection.attachmentChunkBytes);
    if (chunkCount <= 0) return false;

    for (let chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      const channelReady = await this.waitForBufferedAmount();
      if (!channelReady) return false;

      const start = chunkIndex * PeerConnection.attachmentChunkBytes;
      const end = Math.min(input.bytes.byteLength, start + PeerConnection.attachmentChunkBytes);
      const bytes = input.bytes.slice(start, end);
      const sent = this.send({
        messageId: createClientId(),
        atUnixMs: Date.now(),
        body: {
          kind: 'fileAttachmentChunk',
          fileAttachmentChunk: {
            batchId: input.batchId,
            transferId,
            agentId: input.agentId,
            text: input.text,
            filename: input.filename,
            mimeType: input.mimeType,
            totalBytes: input.bytes.byteLength,
            fileIndex: input.fileIndex,
            fileCount: input.fileCount,
            chunkIndex,
            chunkCount,
            bytes,
            submitOnSend: input.submitOnSend,
          },
        },
      });
      if (!sent) return false;
    }

    return true;
  }

  sendQuickReply(reply: QuickReply): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'quickReply', quickReply: reply },
    });
  }

  sendInterrupt(req: InterruptRequest): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'interruptRequest', interruptRequest: req },
    });
  }

  sendMessageDetailRequest(req: MessageDetailRequest): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'messageDetailRequest', messageDetailRequest: req },
    });
  }

  sendTargetSelection(req: TargetSelectionRequest): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'targetSelectionRequest', targetSelectionRequest: req },
    });
  }

  sendTargetRename(req: TargetRenameRequest): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'targetRenameRequest', targetRenameRequest: req },
    });
  }

  sendRuntimeSettingsUpdate(update: AgentRuntimeSettingsUpdate): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'agentRuntimeSettingsUpdate', agentRuntimeSettingsUpdate: update },
    });
  }

  sendInputRequestResponse(req: AgentInputRequestResponse): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'inputRequestResponse', inputRequestResponse: req },
    });
  }

  sendReadOnlyUpdate(readOnly: boolean): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'readOnlyModeUpdate', readOnlyModeUpdate: { readOnly } },
    });
  }

  sendHeartbeat(): boolean {
    return this.send({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'heartbeatPing', heartbeatPing: { atUnixMs: Date.now() } },
    });
  }

  private attachDataChannel(channel: RTCDataChannel) {
    this.dataChannel = channel;
    channel.bufferedAmountLowThreshold = PeerConnection.maxBufferedBytes;
    channel.onmessage = (ev) => {
      if (typeof ev.data !== 'string') return;
      try {
        const msg = decodeDataChannelMessageJson(ev.data);
        this.opts.onMessage?.(msg);
      } catch {
        // ignore
      }
    };
  }

  private preferMobileVideoCodecs() {
    if (!shouldPreferH264ForVideo()) return;
    if (typeof RTCRtpReceiver === 'undefined' || !RTCRtpReceiver.getCapabilities) return;
    const capabilities = RTCRtpReceiver.getCapabilities('video');
    if (!capabilities?.codecs?.length) return;

    const h264 = capabilities.codecs.filter((codec) => codec.mimeType.toLowerCase() === 'video/h264');
    if (h264.length === 0) return;

    const rest = capabilities.codecs.filter((codec) => codec.mimeType.toLowerCase() !== 'video/h264');
    const preferred = [...h264, ...rest];
    for (const transceiver of this.pc.getTransceivers()) {
      if (transceiver.receiver.track?.kind !== 'video') continue;
      try {
        transceiver.setCodecPreferences(preferred);
      } catch {
        // Some browsers expose the API but reject codec preference changes.
      }
    }
  }

  private waitForBufferedAmount(): Promise<boolean> {
    const channel = this.dataChannel;
    if (!channel || channel.readyState !== 'open') return Promise.resolve(false);
    if (channel.bufferedAmount <= PeerConnection.maxBufferedBytes) {
      return Promise.resolve(true);
    }

    channel.bufferedAmountLowThreshold = PeerConnection.maxBufferedBytes;
    return new Promise((resolve) => {
      const timeout = window.setTimeout(() => {
        channel.onbufferedamountlow = null;
        resolve(channel.readyState === 'open' && channel.bufferedAmount <= PeerConnection.maxBufferedBytes * 2);
      }, 3000);
      channel.onbufferedamountlow = () => {
        window.clearTimeout(timeout);
        channel.onbufferedamountlow = null;
        resolve(channel.readyState === 'open');
      };
    });
  }
}

function shouldPreferH264ForVideo(): boolean {
  if (typeof navigator === 'undefined') return false;
  const ua = navigator.userAgent;
  if (/iPhone|iPad|iPod/i.test(ua)) return true;

  // iPadOS desktop mode reports as Macintosh but keeps touch points.
  return /Macintosh/i.test(ua) && navigator.maxTouchPoints > 1;
}
