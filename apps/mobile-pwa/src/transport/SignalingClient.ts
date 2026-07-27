import {
  canonicalizeForSigning,
  sign,
  verify,
  base64FromBytes,
  bytesFromBase64,
  type DeviceKeypair,
} from '@glasstunnel/shared-crypto';
import { type Envelope, encodeEnvelopeJson, decodeEnvelopeJson } from '@glasstunnel/protocol';

export interface SignalingClientOptions {
  url: string;
  keypair: DeviceKeypair;
  role?: string;
  deviceInfo?: string;
  onAuthOk?: (deviceId: string) => void;
  onEnvelope?: (env: Envelope) => void;
  onControl?: (msg: Record<string, unknown>) => void;
  onError?: (err: Error) => void;
  onClose?: (event: CloseEvent, intentional: boolean) => void;
  trustedPublicKeyForDevice?: (deviceId: string) => string | undefined;
}

/**
 * WebSocket client for the glasstunnel signaling server.
 *
 * Handshake:
 * 1. server sends `{type: "server_hello", nonce, ttl_ms}`
 * 2. client signs `nonce` with ed25519, replies `{type: "client_auth", public_key, signature, device_id, role}`
 * 3. server replies `{type: "auth_ok", device_id}`
 *
 * After that, Envelopes flow in both directions and JSON control messages
 * are available for account linking and keepalive.
 */
export class SignalingClient {
  private ws: WebSocket | null = null;
  private opts: SignalingClientOptions;
  private authResolver: ((deviceId: string) => void) | null = null;
  private authedDeviceId: string | null = null;
  private intentionalClose = false;

  constructor(opts: SignalingClientOptions) {
    this.opts = opts;
  }

  async connect(): Promise<string> {
    const ws = new WebSocket(this.opts.url);
    this.ws = ws;
    this.intentionalClose = false;
    return new Promise<string>((resolve, reject) => {
      let settled = false;
      this.authResolver = (deviceId) => {
        settled = true;
        resolve(deviceId);
      };
      ws.onopen = () => {};
      ws.onerror = () => {
        const error = new Error('signaling WebSocket failed to connect');
        this.opts.onError?.(error);
        if (!settled) {
          settled = true;
          reject(error);
        }
      };
      ws.onclose = (event) => {
        if (!settled) {
          settled = true;
          reject(new Error('signaling WebSocket closed before authentication'));
        }
        this.opts.onClose?.(event, this.intentionalClose);
      };
      ws.onmessage = (ev) => this.handleMessage(String(ev.data));
    });
  }

  disconnect() {
    this.intentionalClose = true;
    this.ws?.close();
    this.ws = null;
  }

  get isAuthenticated() {
    return this.authedDeviceId !== null;
  }

  async sendEnvelope(env: Envelope) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('signaling not connected');
    }
    const canonical = canonicalizeForSigning({
      envelopeId: env.envelopeId,
      fromDeviceId: env.fromDeviceId,
      toDeviceId: env.toDeviceId,
      sentAtUnixMs: env.sentAtUnixMs,
      payload: env.payload,
    });
    const sig = await sign(canonical, this.opts.keypair.privateKey);
    env.signature = sig;
    this.ws.send(encodeEnvelopeJson(env));
  }

  sendControl(message: Record<string, unknown>) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify(message));
  }

  private async handleMessage(raw: string) {
    let obj: Record<string, unknown> | null = null;
    try {
      obj = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }

    if (obj && typeof obj.type === 'string') {
      switch (obj.type) {
        case 'server_hello':
          await this.handleServerHello(obj as { nonce: string; ttl_ms: number });
          return;
        case 'auth_ok':
          this.authedDeviceId = (obj.device_id as string) ?? null;
          this.opts.onAuthOk?.(this.authedDeviceId ?? '');
          this.authResolver?.(this.authedDeviceId ?? '');
          return;
        default:
          this.opts.onControl?.(obj);
          return;
      }
    }

    try {
      const env = decodeEnvelopeJson(raw);
      if (!(await this.verifyEnvelope(env))) return;
      this.opts.onEnvelope?.(env);
    } catch {
      // ignore
    }
  }

  private async handleServerHello(hello: { nonce: string; ttl_ms: number }) {
    if (!this.ws) return;
    const nonce = bytesFromBase64(hello.nonce);
    const sig = await sign(nonce, this.opts.keypair.privateKey);
    const auth = {
      type: 'client_auth',
      device_id: this.opts.keypair.deviceId,
      public_key: base64FromBytes(this.opts.keypair.publicKey),
      signature: base64FromBytes(sig),
      role: this.opts.role ?? 'phone',
      device_info: this.opts.deviceInfo ?? navigator.userAgent,
    };
    this.ws.send(JSON.stringify(auth));
  }

  private async verifyEnvelope(env: Envelope): Promise<boolean> {
    const trustedPublicKeyB64 = this.opts.trustedPublicKeyForDevice?.(env.fromDeviceId);
    if (!trustedPublicKeyB64) return true;

    const signature = bytesLike(env.signature);
    if (signature.byteLength === 0) {
      this.opts.onError?.(new Error(`unsigned envelope from ${env.fromDeviceId}`));
      return false;
    }

    const canonical = canonicalizeForSigning({
      envelopeId: env.envelopeId,
      fromDeviceId: env.fromDeviceId,
      toDeviceId: env.toDeviceId,
      sentAtUnixMs: env.sentAtUnixMs,
      payload: env.payload,
    });
    const ok = await verify(signature, canonical, bytesFromBase64(trustedPublicKeyB64));
    if (!ok) {
      this.opts.onError?.(new Error(`invalid envelope signature from ${env.fromDeviceId}`));
    }
    return ok;
  }
}

function bytesLike(value: Uint8Array | string): Uint8Array {
  return typeof value === 'string' ? bytesFromBase64(value) : value;
}
