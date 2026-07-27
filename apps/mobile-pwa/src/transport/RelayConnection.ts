import {
  base64FromBytes,
  bytesFromBase64,
  sign,
  type DeviceKeypair,
} from '@glasstunnel/shared-crypto';
import {
  type AgentInputRequestResponse,
  type AgentRuntimeSettingsUpdate,
  type AgentStateSnapshot,
  type DataChannelMessage,
  encodeDataChannelMessageJson,
  type FileAttachmentChunk,
  type Hello,
  type ImageAttachmentInput,
  type InterruptRequest,
  type QuickReply,
  type ReadOnlyModeUpdate,
  type RemoteAppActionRequest,
  type RemoteApp,
  type ScreenPointerInput,
  type TargetSelectionRequest,
  type TargetRenameRequest,
  type UserInput,
} from '@glasstunnel/protocol';
import { createClientId } from '../lib/id';
import type { PairedHost } from '../lib/store';
import { connectionStatusCopy } from '../lib/connectionCopy';

export type RelayFileAttachmentInput = Omit<
  FileAttachmentChunk,
  'transferId' | 'totalBytes' | 'chunkIndex' | 'chunkCount'
> & {
  bytes: Uint8Array;
};

export interface RelayScreenFrame {
  type: 'relay_screen_frame';
  agentId: string;
  mimeType: string;
  width: number;
  height: number;
  bytes: string;
  sequence: number;
  atUnixMs: number;
}

export interface RelayConnectionOptions {
  keypair: DeviceKeypair;
  host: PairedHost;
  accessToken: string;
  onState?: (state: { connected?: boolean; online?: boolean; error?: string }) => void;
  onHello?: (hello: Hello, cached: boolean) => void;
  onRemoteApps?: (remoteApps: RemoteApp[], cached: boolean) => void;
  onAgent?: (snapshot: AgentStateSnapshot, cached: boolean) => void;
  onScreenFrame?: (frame: RelayScreenFrame) => void;
  onClose?: (event: CloseEvent, intentional: boolean) => void;
}

export class RelayConnection {
  private ws: WebSocket | null = null;
  private readonly opts: RelayConnectionOptions;
  private intentionalClose = false;
  private authenticated = false;
  private hostOnline: boolean | null = null;
  private static readonly attachmentChunkBytes = 32 * 1024;
  private static readonly maxBufferedBytes = 2 * 1024 * 1024;

  constructor(opts: RelayConnectionOptions) {
    this.opts = opts;
  }

  async connect(): Promise<string> {
    const ws = new WebSocket(relayUrlFor(this.opts.host));
    this.ws = ws;
    this.intentionalClose = false;
    this.authenticated = false;
    this.hostOnline = null;

    return new Promise<string>((resolve, reject) => {
      let settled = false;
      ws.onerror = () => {
        const error = new Error('relay WebSocket failed to connect');
        this.opts.onState?.({ connected: false, error: error.message });
        if (!settled) {
          settled = true;
          reject(error);
        }
      };
      ws.onclose = (event) => {
        this.authenticated = false;
        if (!settled) {
          settled = true;
          reject(new Error('relay WebSocket closed before authentication'));
        }
        this.opts.onState?.({ connected: false });
        this.opts.onClose?.(event, this.intentionalClose);
      };
      ws.onmessage = (event) => {
        void this.handleMessage(String(event.data), (deviceId) => {
          if (!settled) {
            settled = true;
            resolve(deviceId);
          }
        });
      };
    });
  }

  disconnect() {
    this.intentionalClose = true;
    this.authenticated = false;
    this.hostOnline = null;
    this.ws?.close();
    this.ws = null;
  }

  get isConnected() {
    return this.authenticated && this.ws?.readyState === WebSocket.OPEN;
  }

  get isHostOnline() {
    return this.hostOnline === true;
  }

  sendUserInput(input: UserInput): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'userInput', userInput: input },
    });
  }

  sendScreenPointer(input: ScreenPointerInput): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'screenPointerInput', screenPointerInput: input },
    });
  }

  async sendImageAttachment(input: ImageAttachmentInput): Promise<boolean> {
    if (!this.isConnected) return false;

    const transferId = createClientId();
    const chunkCount = Math.ceil(input.bytes.byteLength / RelayConnection.attachmentChunkBytes);
    if (chunkCount <= 0) return false;

    for (let chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      const socketReady = await this.waitForBufferedAmount();
      if (!socketReady) return false;

      const start = chunkIndex * RelayConnection.attachmentChunkBytes;
      const end = Math.min(input.bytes.byteLength, start + RelayConnection.attachmentChunkBytes);
      const sent = this.sendCommand({
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
            bytes: input.bytes.slice(start, end),
            submitOnSend: input.submitOnSend,
          },
        },
      });
      if (!sent) return false;
    }

    return true;
  }

  async sendFileAttachment(input: RelayFileAttachmentInput): Promise<boolean> {
    if (!this.isConnected) return false;

    const transferId = createClientId();
    const chunkCount = Math.ceil(input.bytes.byteLength / RelayConnection.attachmentChunkBytes);
    if (chunkCount <= 0) return false;

    for (let chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      const socketReady = await this.waitForBufferedAmount();
      if (!socketReady) return false;

      const start = chunkIndex * RelayConnection.attachmentChunkBytes;
      const end = Math.min(input.bytes.byteLength, start + RelayConnection.attachmentChunkBytes);
      const sent = this.sendCommand({
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
            bytes: input.bytes.slice(start, end),
            submitOnSend: input.submitOnSend,
          },
        },
      });
      if (!sent) return false;
    }

    return true;
  }

  sendInputRequestResponse(response: AgentInputRequestResponse): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'inputRequestResponse', inputRequestResponse: response },
    });
  }

  sendQuickReply(reply: QuickReply): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'quickReply', quickReply: reply },
    });
  }

  sendInterrupt(req: InterruptRequest): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'interruptRequest', interruptRequest: req },
    });
  }

  sendTargetSelection(req: TargetSelectionRequest): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'targetSelectionRequest', targetSelectionRequest: req },
    });
  }

  sendTargetRename(req: TargetRenameRequest): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'targetRenameRequest', targetRenameRequest: req },
    });
  }

  sendRuntimeSettingsUpdate(update: AgentRuntimeSettingsUpdate): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'agentRuntimeSettingsUpdate', agentRuntimeSettingsUpdate: update },
    });
  }

  sendRemoteAppAction(req: RemoteAppActionRequest): boolean {
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'remoteAppActionRequest', remoteAppActionRequest: req },
    });
  }

  sendReadOnlyUpdate(readOnly: boolean): boolean {
    const update: ReadOnlyModeUpdate = { readOnly };
    return this.sendCommand({
      messageId: createClientId(),
      atUnixMs: Date.now(),
      body: { kind: 'readOnlyModeUpdate', readOnlyModeUpdate: update },
    });
  }

  sendHeartbeat(): boolean {
    return this.send({ type: 'relay_ping', at: Date.now() });
  }

  private sendCommand(command: DataChannelMessage): boolean {
    if (!this.isConnected || this.hostOnline !== true) return false;
    const encoded = encodeDataChannelMessageJson(command);
    return this.send({
      type: 'relay_command',
      command: JSON.parse(encoded) as Record<string, unknown>,
      at: Date.now(),
    });
  }

  private send(message: Record<string, unknown>): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    try {
      this.ws.send(JSON.stringify(message));
      return true;
    } catch {
      return false;
    }
  }

  private async handleMessage(raw: string, resolveAuth: (deviceId: string) => void) {
    let obj: Record<string, unknown>;
    try {
      obj = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }

    switch (obj.type) {
      case 'server_hello':
        await this.handleServerHello(obj as { nonce: string });
        return;
      case 'auth_ok': {
        this.authenticated = true;
        const deviceId = String(obj.device_id ?? this.opts.keypair.deviceId);
        this.opts.onState?.({ connected: true });
        resolveAuth(deviceId);
        return;
      }
      case 'relay_presence':
        this.hostOnline = obj.online === true;
        this.opts.onState?.({
          connected: true,
          online: this.hostOnline,
          error: this.hostOnline ? undefined : connectionStatusCopy('offline-cached'),
        });
        return;
      case 'relay_hello': {
        if (obj.cached !== true) {
          this.hostOnline = true;
          this.opts.onState?.({ connected: true, online: true });
        }
        this.opts.onHello?.(obj.hello as Hello, obj.cached === true);
        return;
      }
      case 'relay_remote_apps':
        if (obj.cached !== true) {
          this.hostOnline = true;
          this.opts.onState?.({ connected: true, online: true });
        }
        this.opts.onRemoteApps?.((obj.remoteApps as RemoteApp[]) ?? [], obj.cached === true);
        return;
      case 'relay_agent_state':
        if (obj.cached !== true) {
          this.hostOnline = true;
          this.opts.onState?.({ connected: true, online: true });
        }
        this.opts.onAgent?.(obj.snapshot as AgentStateSnapshot, obj.cached === true);
        return;
      case 'relay_screen_frame':
        if (this.hostOnline !== true) {
          this.opts.onState?.({ connected: true, online: true });
        }
        this.hostOnline = true;
        this.opts.onScreenFrame?.(obj as unknown as RelayScreenFrame);
        return;
      case 'relay_error': {
        const hostOffline = obj.code === 'host_offline';
        if (hostOffline) {
          this.hostOnline = false;
        }
        this.opts.onState?.({
          connected: !hostOffline,
          online: hostOffline ? false : undefined,
          error: typeof obj.message === 'string' ? obj.message : 'Relay command failed.',
        });
        return;
      }
      default:
        return;
    }
  }

  private async handleServerHello(hello: { nonce: string }) {
    if (!this.ws) return;
    const nonce = bytesFromBase64(hello.nonce);
    const signature = await sign(nonce, this.opts.keypair.privateKey);
    this.ws.send(
      JSON.stringify({
        type: 'client_auth',
        device_id: this.opts.keypair.deviceId,
        public_key: base64FromBytes(this.opts.keypair.publicKey),
        signature: base64FromBytes(signature),
        role: 'client',
        device_info: navigator.userAgent,
        access_token: this.opts.accessToken,
      }),
    );
  }

  private waitForBufferedAmount(): Promise<boolean> {
    const socket = this.ws;
    if (!socket || socket.readyState !== WebSocket.OPEN) return Promise.resolve(false);
    if (socket.bufferedAmount <= RelayConnection.maxBufferedBytes) {
      return Promise.resolve(true);
    }

    return new Promise((resolve) => {
      const deadline = Date.now() + 3000;
      const check = () => {
        if (!socket || socket.readyState !== WebSocket.OPEN) {
          resolve(false);
          return;
        }
        if (socket.bufferedAmount <= RelayConnection.maxBufferedBytes) {
          resolve(true);
          return;
        }
        if (Date.now() >= deadline) {
          resolve(socket.bufferedAmount <= RelayConnection.maxBufferedBytes * 2);
          return;
        }
        window.setTimeout(check, 50);
      };
      check();
    });
  }
}

function relayUrlFor(host: PairedHost): string {
  const url = new URL(host.signalingUrl);
  url.pathname = '/relay';
  url.searchParams.set('host_device_id', host.deviceId);
  return url.toString();
}
