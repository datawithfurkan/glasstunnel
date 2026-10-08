import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RelayHub, SignalingHub } from "../src/index";

// The hubs keep their socket registries private; these views let the tests assert
// that a socket which closed mid-auth never stays registered.
interface RelayHubInternals {
  hostSocket: WebSocket | null;
  clientSockets: Map<string, WebSocket>;
  sessions: Map<WebSocket, unknown>;
}

interface SignalingHubInternals {
  peers: Map<string, WebSocket>;
  sessions: Map<WebSocket, unknown>;
}

interface DeviceIdentity {
  keys: CryptoKeyPair;
  deviceId: string;
  publicKeyB64: string;
}

interface HubSocket {
  client: WebSocket;
  nonce: string;
  nextMessage: () => Promise<Record<string, unknown>>;
  closed: Promise<{ code: number; reason: string }>;
  messages: Record<string, unknown>[];
}

type AccountGatePoint = 'device-lookup' | 'last-seen-touch' | 'auth-user' | 'device-update';

const relayInternals = (hub: RelayHub) => hub as unknown as RelayHubInternals;
const signalingInternals = (hub: SignalingHub) => hub as unknown as SignalingHubInternals;

function base64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function bytesFromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

async function createDeviceIdentity(): Promise<DeviceIdentity> {
  const keys = (await crypto.subtle.generateKey({ name: 'Ed25519' }, true, [
    'sign',
    'verify',
  ])) as CryptoKeyPair;
  const publicKey = new Uint8Array((await crypto.subtle.exportKey('raw', keys.publicKey)) as ArrayBuffer);
  // Mirrors deviceIdFromPublicKey in the Worker: "gt-" + hex of the first 8 key bytes.
  const deviceId = `gt-${Array.from(publicKey.slice(0, 8), (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
  return { keys, deviceId, publicKeyB64: base64(publicKey) };
}

async function signedClientAuth(
  identity: DeviceIdentity,
  nonceB64: string,
  role: 'host' | 'client',
  extra: Record<string, unknown> = {},
): Promise<string> {
  const signature = new Uint8Array(
    await crypto.subtle.sign('Ed25519', identity.keys.privateKey, bytesFromBase64(nonceB64)),
  );
  return JSON.stringify({
    type: 'client_auth',
    device_id: identity.deviceId,
    public_key: identity.publicKeyB64,
    signature: base64(signature),
    role,
    ...extra,
  });
}

async function openHubSocket(stub: DurableObjectStub, path: string): Promise<HubSocket> {
  const response = await stub.fetch(`https://hub.test${path}`, {
    headers: { Upgrade: 'websocket' },
  });
  const client = response.webSocket;
  if (!client) throw new Error(`expected a websocket upgrade, got HTTP ${response.status}`);

  const backlog: Record<string, unknown>[] = [];
  const messages: Record<string, unknown>[] = [];
  const waiters: Array<(message: Record<string, unknown>) => void> = [];
  client.addEventListener('message', (event) => {
    const message = JSON.parse(String(event.data)) as Record<string, unknown>;
    messages.push(message);
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else backlog.push(message);
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    client.addEventListener('close', (event) => {
      // Complete the client half of the close handshake before an eviction
      // waits for the object's in-flight websocket events to drain.
      try { client.close(); } catch { /* Already closed. */ }
      resolve({ code: event.code, reason: event.reason });
    });
  });
  client.accept();

  const nextMessage = () => {
    const queued = backlog.shift();
    return queued ? Promise.resolve(queued) : new Promise<Record<string, unknown>>((resolve) => waiters.push(resolve));
  };
  const hello = await nextMessage();
  expect(hello).toMatchObject({ type: 'server_hello' });
  return { client, nonce: String(hello.nonce), nextMessage, closed, messages };
}

function deviceRow(identity: DeviceIdentity, kind: 'host' | 'phone'): Record<string, unknown> {
  const at = new Date().toISOString();
  return {
    id: `${kind}-${identity.deviceId}`,
    user_id: 'user-1',
    device_id: identity.deviceId,
    public_key_b64: identity.publicKeyB64,
    kind,
    label: 'Disposable browser',
    platform: null,
    app_version: null,
    last_seen_at: null,
    revoked_at: null,
    metadata: {},
    created_at: at,
    updated_at: at,
  };
}

/** The test Worker's gateway (test/wrangler.jsonc). */
const GATEWAY_URL = 'https://gateway-test.convex.site/worker/account-plane';
const GATEWAY_SECRET = 'worker-gateway-secret-for-tests-0123456789';

class GatewayRejection extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

class GatewayFailure extends Error {}

/** The account-plane function a fetch call made, or null for any other request. */
function gatewayFunction(input: RequestInfo | URL, init?: RequestInit): string | null {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (url !== GATEWAY_URL || typeof init?.body !== 'string') return null;
  return (JSON.parse(init.body) as { fn?: string }).fn ?? null;
}

/**
 * Replaces the Worker's outbound fetch with a fake Convex account-plane gateway.
 * Each function mirrors convex/accountPlane.ts over in-memory rows in the shape
 * the gateway returns. One call can be paused, which gives a test a deterministic
 * window in which a socket closes, or a row changes, while the hub is awaiting.
 */
function stubAccountPlane(options: {
  gateOn?: AccountGatePoint;
  devices?: Record<string, unknown>[];
  pairings?: Record<string, unknown>[];
  linkCodes?: Record<string, unknown>[];
  approvals?: Record<string, unknown>[];
  failPairingWrites?: boolean;
  failAuth?: boolean;
}) {
  let release: () => void = () => {};
  const released = new Promise<void>((resolve) => {
    release = resolve;
  });
  const gate = { reached: false, release, released };
  const devices = options.devices ?? [];
  const pairings = options.pairings ?? [];
  const linkCodes = options.linkCodes ?? [];
  const approvals = options.approvals ?? [];
  let generated = 0;
  const nextId = (prefix: string) => `${prefix}-${++generated}`;
  const pauseIf = async (point: AccountGatePoint) => {
    if (options.gateOn !== point || gate.reached) return;
    gate.reached = true;
    await gate.released;
  };
  const failPairingWrite = () => {
    if (options.failPairingWrites) throw new GatewayFailure('pairing writes unavailable');
  };
  const samePair = (row: Record<string, unknown>, args: Record<string, unknown>) =>
    row.owner_user_id === args.ownerUserId && row.host_device_uuid === args.hostDeviceUuid &&
    row.phone_device_uuid === args.requesterDeviceUuid;
  const remove = <Row,>(rows: Row[], drop: (row: Row) => boolean) => {
    const kept = rows.filter((row) => !drop(row));
    const removed = rows.length - kept.length;
    rows.splice(0, rows.length, ...kept);
    return removed;
  };

  const functions: Record<string, (args: Record<string, unknown>) => unknown | Promise<unknown>> = {
    async verifyBearerToken() {
      await pauseIf('auth-user');
      return options.failAuth ? null : { id: 'user-1', email: 'user@example.test' };
    },
    async findDeviceByDeviceId(args) {
      await pauseIf('device-lookup');
      return devices.find((row) => row.device_id === args.deviceId) ?? null;
    },
    findDeviceByUuid: (args) => devices.find((row) => row.id === args.id) ?? null,
    findProfileByUserId: () => null,
    listHostDevicesForUser: (args) =>
      devices.filter((row) => row.user_id === args.userId && row.kind === 'host' && row.revoked_at == null),
    listPairingsForRequester: (args) =>
      pairings.filter((row) => row.phone_device_uuid === args.requesterDeviceUuid && row.owner_user_id === args.ownerUserId),
    findActivePairing: (args) => pairings.find((row) => samePair(row, args) && row.revoked_at == null) ?? null,
    hasRevokedPairing: (args) => pairings.some((row) => samePair(row, args) && row.revoked_at != null),
    findPendingApproval: (args) => approvals.find((row) => row.host_device_uuid === args.hostDeviceUuid &&
      row.requester_device_uuid === args.requesterDeviceUuid && row.status === 'pending') ?? null,
    findApprovalById: (args) => approvals.find((row) => row.id === args.requestId) ?? null,
    listPendingApprovalsByHost: (args) =>
      approvals.filter((row) => row.host_device_uuid === args.hostDeviceUuid && row.status === 'pending'),
    getUnconsumedHostLinkCode: (args) => {
      const usable = linkCodes.filter((row) => row.code === args.code && row.consumed_at == null &&
        Date.parse(String(row.expires_at)) > Date.now());
      return usable.length === 1 ? usable[0] : null;
    },
    async upsertUserDevice(args) {
      const existing = devices.find((row) => row.device_id === args.deviceId);
      const at = new Date().toISOString();
      if (!existing) {
        const row = {
          id: nextId('convex-device'), user_id: args.userId, device_id: args.deviceId,
          public_key_b64: args.publicKeyB64, label: args.label, kind: args.kind,
          platform: args.platform ?? null, app_version: args.appVersion ?? null, last_seen_at: at,
          revoked_at: null, metadata: args.metadata ?? {}, created_at: at, updated_at: at,
        };
        devices.push(row);
        return row;
      }
      await pauseIf('device-update');
      // Checked after the pause, as the real mutation checks inside its transaction.
      if (existing.user_id !== args.userId) throw new GatewayRejection('device_belongs_to_another_account');
      if (existing.revoked_at != null || existing.public_key_b64 !== args.publicKeyB64 ||
          (existing.kind === 'host') !== (args.kind === 'host')) {
        throw new GatewayRejection('device_registration_not_authorized');
      }
      Object.assign(existing, {
        label: args.label, platform: args.platform ?? null, app_version: args.appVersion ?? null,
        metadata: args.metadata ?? {}, last_seen_at: at, updated_at: at,
      });
      return existing;
    },
    async touchDeviceLastSeen(args) {
      await pauseIf('last-seen-touch');
      const row = devices.find((device) => device.device_id === args.deviceId);
      if (row) row.last_seen_at = new Date().toISOString();
      return null;
    },
    insertApprovalRequest: (args) => {
      const pending = approvals.find((row) => row.host_device_uuid === args.hostDeviceUuid &&
        row.requester_device_uuid === args.requesterDeviceUuid && row.status === 'pending');
      if (pending) return pending;
      const at = new Date().toISOString();
      const row = {
        id: nextId('convex-approval'), owner_user_id: args.ownerUserId, host_device_uuid: args.hostDeviceUuid,
        requester_device_uuid: args.requesterDeviceUuid, requester_device_id: args.requesterDeviceId,
        requester_public_key_b64: args.requesterPublicKeyB64, requester_label: args.requesterLabel,
        status: 'pending', metadata: {}, created_at: at, updated_at: at, responded_at: null,
      };
      approvals.push(row);
      return row;
    },
    markApprovalStatus: (args) => {
      const row = approvals.find((approval) => approval.id === args.requestId);
      if (row) Object.assign(row, { status: args.status, responded_at: new Date().toISOString() });
      return null;
    },
    ensurePairing: (args) => {
      failPairingWrite();
      const host = devices.find((row) => row.id === args.hostDeviceUuid);
      const requester = devices.find((row) => row.id === args.requesterDeviceUuid);
      if (!host || !requester || host.kind !== 'host' || requester.kind === 'host' ||
          host.user_id !== args.ownerUserId || requester.user_id !== args.ownerUserId ||
          host.revoked_at != null || requester.revoked_at != null) {
        throw new GatewayRejection('pairing_not_authorized');
      }
      const existing = pairings.filter((row) => samePair(row, args));
      if (existing.some((row) => row.revoked_at != null)) throw new GatewayRejection('access_revoked');
      const active = existing.find((row) => row.revoked_at == null);
      if (active) return active;
      const row = {
        id: nextId('pair'), owner_user_id: args.ownerUserId, host_device_uuid: args.hostDeviceUuid,
        phone_device_uuid: args.requesterDeviceUuid, paired_at: new Date().toISOString(), revoked_at: null,
        metadata: args.metadata ?? { approved_via: 'native_prompt' },
      };
      pairings.push(row);
      return row;
    },
    createHostLinkCode: (args) => {
      if (linkCodes.some((row) => row.code === args.code && row.consumed_at == null &&
          Date.parse(String(row.expires_at)) > Date.now())) {
        throw new GatewayRejection('link_code_taken');
      }
      linkCodes.push({
        id: nextId('code'), code: args.code, host_device_id: args.hostDeviceId,
        host_public_key_b64: args.hostPublicKeyB64, host_label: args.hostLabel, host_metadata: args.hostMetadata,
        created_at: new Date().toISOString(), expires_at: args.expiresAt, consumed_at: null, claimed_user_id: null,
      });
      return null;
    },
    consumeHostLinkCode: (args) => {
      const row = linkCodes.find((code) => code.id === args.id);
      if (row) Object.assign(row, { consumed_at: new Date().toISOString(), claimed_user_id: args.claimedUserId });
      return null;
    },
    deleteHostLinkCodesByHostDeviceId: (args) => remove(linkCodes, (row) => row.host_device_id === args.hostDeviceId),
    deleteDeviceByUuid: (args) => {
      if (!devices.some((row) => row.id === args.id)) return false;
      remove(pairings, (row) => row.host_device_uuid === args.id || row.phone_device_uuid === args.id);
      remove(approvals, (row) => row.host_device_uuid === args.id);
      remove(devices, (row) => row.id === args.id);
      return true;
    },
    deleteRevokedPairings: (args) => {
      failPairingWrite();
      return remove(pairings, (row) => samePair(row, args) && row.revoked_at != null);
    },
    revokePairing: (args) => {
      failPairingWrite();
      const at = new Date().toISOString();
      const scope = pairings.filter((row) =>
        row.phone_device_uuid === args.requesterDeviceUuid && row.host_device_uuid === args.hostDeviceUuid);
      if (!scope.some((row) => row.owner_user_id === args.ownerUserId && row.revoked_at != null)) {
        pairings.push({
          id: nextId('pair'), owner_user_id: args.ownerUserId, host_device_uuid: args.hostDeviceUuid,
          phone_device_uuid: args.requesterDeviceUuid, paired_at: at, revoked_at: at,
          metadata: args.metadata ?? { revoked_via: 'host' },
        });
      }
      for (const row of scope) if (row.revoked_at == null) row.revoked_at = at;
      return null;
    },
  };

  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const fn = gatewayFunction(input, init);
    if (fn === null) {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      throw new Error(`unexpected outbound fetch: ${init?.method ?? 'GET'} ${url}`);
    }
    expect(init?.method).toBe('POST');
    expect(new Headers(init?.headers).get('authorization')).toBe(`Bearer ${GATEWAY_SECRET}`);
    const handler = Object.hasOwn(functions, fn) ? functions[fn] : undefined;
    if (!handler) return Response.json({ ok: false, code: 'unknown_function' }, { status: 404 });
    const { args } = JSON.parse(String(init?.body)) as { args: Record<string, unknown> };
    try {
      // Rows are copied out, as they would be over the wire.
      return Response.json({ ok: true, value: structuredClone((await handler(args)) ?? null) });
    } catch (error) {
      if (error instanceof GatewayRejection) return Response.json({ ok: false, code: error.code }, { status: 409 });
      if (error instanceof GatewayFailure) return Response.json({ ok: false, code: 'internal' }, { status: 500 });
      throw error;
    }
  });

  return gate;
}

async function waitFor(check: () => boolean | Promise<boolean>, label: string): Promise<void> {
  const deadline = Date.now() + 4_000;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function hubHealth(stub: DurableObjectStub): Promise<Record<string, unknown>> {
  const response = await stub.fetch('https://hub.test/health');
  return (await response.json()) as Record<string, unknown>;
}

function relayPath(hostDeviceId: string): string {
  return `/relay?host_device_id=${hostDeviceId}`;
}

// Runs the hub's own message handler for the given socket. Unlike sending over the
// wire, a throw inside the handler surfaces here as a rejection.
function driveAuth<Hub extends RelayHub | SignalingHub>(
  stub: DurableObjectStub<Hub>,
  authMessage: string,
): Promise<void> {
  return runInDurableObject(stub, (hub, state) => hub.webSocketMessage(state.getWebSockets()[0], authMessage));
}

describe('RelayHub account authorization', () => {
  afterEach(() => vi.unstubAllGlobals());

  it.each(['missing', 'revoked', 'wrong kind', 'wrong key'] as const)(
    'refuses a %s host record before accepting or publishing content', async (scenario) => {
      const host = await createDeviceIdentity();
      const row = deviceRow(host, 'host');
      if (scenario === 'revoked') row.revoked_at = new Date().toISOString();
      if (scenario === 'wrong kind') row.kind = 'phone';
      if (scenario === 'wrong key') row.public_key_b64 = (await createDeviceIdentity()).publicKeyB64;
      stubAccountPlane({ devices: scenario === 'missing' ? [] : [row] });
      const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
      const socket = await openHubSocket(stub, relayPath(host.deviceId));
      await driveAuth(stub, await signedClientAuth(host, socket.nonce, 'host'));

      await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: false });
      await expect(socket.closed).resolves.toMatchObject({ code: 1008 });
    },
  );

  it('refuses a previously revoked pairing rather than replaying cached content', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    const phoneRow = deviceRow(phone, 'phone');
    stubAccountPlane({ devices: [hostRow, phoneRow], pairings: [{
      id: 'revoked-pair', owner_user_id: 'user-1', host_device_uuid: hostRow.id,
      phone_device_uuid: phoneRow.id, revoked_at: new Date().toISOString(),
    }] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    await driveAuth(stub, await signedClientAuth(phone, socket.nonce, 'client', { access_token: 'test-token' }));

    await expect(hubHealth(stub)).resolves.toMatchObject({ clients: 0 });
    await expect(socket.closed).resolves.toMatchObject({ code: 4003 });
  });
});

describe('Account registration authorization', () => {
  afterEach(() => vi.unstubAllGlobals());

  it.each(['revoked', 'host role', 'mismatched key'] as const)(
    'does not overwrite an existing %s identity through browser registration', async (scenario) => {
      const phone = await createDeviceIdentity();
      const row = deviceRow(phone, scenario === 'host role' ? 'host' : 'phone');
      if (scenario === 'revoked') row.revoked_at = new Date().toISOString();
      if (scenario === 'mismatched key') row.public_key_b64 = (await createDeviceIdentity()).publicKeyB64;
      const before = structuredClone(row);
      stubAccountPlane({ devices: [row] });
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`register-${phone.deviceId}`));
      const response = await stub.fetch('https://hub.test/account/device/register', {
        method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
        body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone' }),
      });

      expect(response.status).toBe(403);
      expect(row).toEqual(before);
    },
  );

  it('refreshes a valid browser registration without changing its identity', async () => {
    const phone = await createDeviceIdentity();
    const row = deviceRow(phone, 'phone');
    stubAccountPlane({ devices: [row] });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`refresh-${phone.deviceId}`));
    const response = await stub.fetch('https://hub.test/account/device/register', {
      method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone', label: 'Renamed browser' }),
    });
    expect(response.status).toBe(200);
    expect(row).toMatchObject({ user_id: 'user-1', public_key_b64: phone.publicKeyB64, revoked_at: null, label: 'Renamed browser' });
  });

  async function withConvexGateway<T>(
    handler: (fn: string, args: Record<string, unknown>, request: { authorization: string | null }) => Response,
    run: (calls: string[]) => Promise<T>,
  ): Promise<T> {
    const workerEnv = env as unknown as Record<string, string | undefined>;
    const previousSecret = workerEnv.CONVEX_WORKER_SECRET;
    const calls: string[] = [];
    try {
      vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
        const fn = gatewayFunction(input, init);
        if (fn !== null) {
          expect(init?.method).toBe('POST');
          calls.push(fn);
          const { args } = JSON.parse(String(init?.body)) as { args: Record<string, unknown> };
          return handler(fn, args, { authorization: new Headers(init?.headers).get('authorization') });
        }
        throw new Error(`unexpected outbound fetch: ${init?.method ?? 'GET'} ${String(input)}`);
      });
      return await run(calls);
    } finally {
      workerEnv.CONVEX_WORKER_SECRET = previousSecret;
    }
  }

  it('routes registration account records through the authenticated Convex gateway', async () => {
    const phone = await createDeviceIdentity();
    const at = new Date().toISOString();
    const convexDeviceRow = (label: string) => ({
      id: `convex-${phone.deviceId}`,
      user_id: 'user-1',
      device_id: phone.deviceId,
      public_key_b64: phone.publicKeyB64,
      kind: 'phone',
      label,
      platform: null,
      app_version: null,
      last_seen_at: at,
      revoked_at: null,
      metadata: {},
      created_at: at,
      updated_at: at,
    });

    await withConvexGateway((fn, args, request) => {
      expect(request.authorization).toBe('Bearer worker-gateway-secret-for-tests-0123456789');
      switch (fn) {
        case 'verifyBearerToken':
          expect(args.token).toBe('test-token');
          return Response.json({ ok: true, value: { id: 'user-1', email: 'user@example.test', user_metadata: { provider: 'convex' }, session_expires_at: Date.now() + 60_000 } });
        case 'findDeviceByDeviceId':
          return Response.json({ ok: true, value: null });
        case 'upsertUserDevice':
          return Response.json({ ok: true, value: convexDeviceRow(String(args.label ?? 'This device')) });
        case 'listHostDevicesForUser':
        case 'listPairingsForRequester':
          return Response.json({ ok: true, value: [] });
        default:
          return Response.json({ ok: false, code: 'unknown_function' }, { status: 404 });
      }
    }, async (calls) => {
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`convex-register-${phone.deviceId}`));
      const response = await stub.fetch('https://hub.test/account/device/register', {
        method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
        body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone', label: 'Convex browser' }),
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ ok: true, device_id: phone.deviceId, hosts: [] });
      expect(calls).toEqual([
        'verifyBearerToken',
        'findDeviceByDeviceId',
        'upsertUserDevice',
        'listHostDevicesForUser',
        'listPairingsForRequester',
      ]);
    });
  });

  it('maps a gateway rejection to 403 and an unauthorized gateway to a failure, never to success', async () => {
    const phone = await createDeviceIdentity();
    const existing = {
      id: `convex-${phone.deviceId}`, user_id: 'user-1', device_id: phone.deviceId,
      public_key_b64: phone.publicKeyB64, kind: 'phone', label: 'Old', platform: null, app_version: null,
      last_seen_at: null, revoked_at: null, metadata: {}, created_at: 'x', updated_at: 'x',
    };
    await withConvexGateway((fn) => {
      if (fn === 'verifyBearerToken') return Response.json({ ok: true, value: { id: 'user-1', email: 'user@example.test' } });
      if (fn === 'findDeviceByDeviceId') return Response.json({ ok: true, value: existing });
      if (fn === 'upsertUserDevice') return Response.json({ ok: false, code: 'device_registration_not_authorized' }, { status: 409 });
      return Response.json({ ok: false, code: 'unknown_function' }, { status: 404 });
    }, async () => {
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`convex-reject-${phone.deviceId}`));
      const response = await stub.fetch('https://hub.test/account/device/register', {
        method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
        body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone', label: 'Renamed' }),
      });
      expect(response.status).toBe(403);
    });

    await withConvexGateway(() => Response.json({ ok: false, code: 'unauthorized' }, { status: 401 }), async () => {
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`convex-unauth-${phone.deviceId}`));
      const response = await stub.fetch('https://hub.test/account/device/register', {
        method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
        body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone', label: 'Renamed' }),
      });
      expect(response.status).toBe(503);
      expect(JSON.stringify(await response.json())).not.toContain('upsertUserDevice');
    });
  });

  it('answers 401 for a token the account plane does not recognise, and 503 when the gateway secret is missing', async () => {
    const phone = await createDeviceIdentity();
    await withConvexGateway((fn) => {
      if (fn === 'verifyBearerToken') return Response.json({ ok: true, value: null });
      return Response.json({ ok: false, code: 'unknown_function' }, { status: 404 });
    }, async () => {
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`convex-badtoken-${phone.deviceId}`));
      const response = await stub.fetch('https://hub.test/account/hosts?deviceId=' + phone.deviceId, {
        headers: { authorization: 'Bearer not-a-session' },
      });
      expect(response.status).toBe(401);
    });

    await withConvexGateway(() => Response.json({ ok: true, value: null }), async (calls) => {
      (env as unknown as Record<string, string | undefined>).CONVEX_WORKER_SECRET = '';
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`convex-nosecret-${phone.deviceId}`));
      const response = await stub.fetch('https://hub.test/account/hosts?deviceId=' + phone.deviceId, {
        headers: { authorization: 'Bearer some-token' },
      });
      expect(response.status).toBe(503);
      expect(calls).toEqual([]);
    });
  });

  it('cannot clear a revocation that arrives between lookup and registration write', async () => {
    const phone = await createDeviceIdentity();
    const row = deviceRow(phone, 'phone');
    const gate = stubAccountPlane({ devices: [row], gateOn: 'device-update' });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-${phone.deviceId}`));
    const registering = stub.fetch('https://hub.test/account/device/register', {
      method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone' }),
    });
    await waitFor(() => gate.reached, 'the conditional registration update');
    row.revoked_at = '2026-09-06T00:00:00.000Z';
    gate.release();
    expect((await registering).status).toBe(403);
    expect(row.revoked_at).toBe('2026-09-06T00:00:00.000Z');
  });
});

describe('RelayHub active revocation', () => {
  afterEach(() => vi.unstubAllGlobals());

  async function authenticate(stub: DurableObjectStub<RelayHub>, identity: DeviceIdentity, hostID: string, role: 'host' | 'client') {
    const socket = await openHubSocket(stub, relayPath(hostID));
    socket.client.send(await signedClientAuth(identity, socket.nonce, role, { access_token: 'test-token' }));
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    return socket;
  }

  async function hostMessage(stub: DurableObjectStub<RelayHub>, value: Record<string, unknown>) {
    await runInDurableObject(stub, (hub) => hub.webSocketMessage(relayInternals(hub).hostSocket!, JSON.stringify(value)));
  }

  async function revoke(stub: DurableObjectStub<RelayHub>, host: DeviceIdentity, phone: DeviceIdentity) {
    const response = await stub.fetch('https://hub.test/internal/revoke-device', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hostDeviceId: host.deviceId, hostPublicKeyB64: host.publicKeyB64, deviceId: phone.deviceId }),
    });
    // Drain the response: a live response body prevents runtime eviction.
    return { status: response.status, body: await response.json() };
  }

  it('keeps access denied after an unconfirmed database write and confirms a retry', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const options = { devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')], failPairingWrites: true };
    stubAccountPlane(options);
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    expect((await revoke(stub, host, phone)).status).toBe(503);
    await expect(client.closed).resolves.toMatchObject({ code: 4003 });
    options.failPairingWrites = false;
    expect((await revoke(stub, host, phone)).status).toBe(200);
  });

  it('limits revocation to the requested Mac and refuses a different account', async () => {
    const host = await createDeviceIdentity();
    const otherHost = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const foreign = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(otherHost, 'host'), deviceRow(phone, 'phone'), { ...deviceRow(foreign, 'phone'), user_id: 'another-user' }] });
    const first = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const second = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(otherHost.deviceId));
    expect((await revoke(first, host, foreign)).status).toBe(403);
    expect((await revoke(first, otherHost, phone)).status).toBe(403);
    expect((await revoke(first, host, phone)).status).toBe(200);
    await authenticate(second, phone, otherHost.deviceId, 'client');
    await expect(hubHealth(second)).resolves.toMatchObject({ clients: 1 });
  });

  it('rejects an expired account token without authenticating or replaying content', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')], failAuth: true });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const client = await openHubSocket(stub, relayPath(host.deviceId));
    client.client.send(await signedClientAuth(phone, client.nonce, 'client', { access_token: 'expired' }));
    await expect(client.closed).resolves.toMatchObject({ code: 1008 });
    expect(client.messages.some((m) => m.type === 'auth_ok' || m.type === 'relay_agent_state')).toBe(false);
  });

  it('tells the Mac about relay-only browsers and restores that list after host reconnect', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const first = await authenticate(stub, host, host.deviceId, 'host');
    await authenticate(stub, phone, host.deviceId, 'client');
    await waitFor(() => first.messages.some((m) => m.type === 'account_device_authorized'), 'relay trust notification');
    expect(first.messages.find((m) => m.type === 'account_device_authorized')).toMatchObject({
      requester_device_id: phone.deviceId, requester_public_key_b64: phone.publicKeyB64, requester_label: 'Disposable browser',
    });
    const second = await authenticate(stub, host, host.deviceId, 'host');
    await waitFor(() => second.messages.some((m) => m.requester_device_id === phone.deviceId), 'restored trust notification');
  });

  it('retains the denial after hibernation even if an old active pairing remains', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const pairings: Record<string, unknown>[] = [];
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')], pairings });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    expect((await revoke(stub, host, phone)).status).toBe(200);
    await client.closed;
    await runInDurableObject(stub, async (_hub, state) => {
      expect(await state.storage.get(`revoked-device:${phone.deviceId}`)).toBe(true);
    });
    pairings.length = 0;
    await evictDurableObject(stub);
    await runInDurableObject(stub, (hub) => {
      expect((hub as unknown as { revokedDevices: Set<string> }).revokedDevices.has(phone.deviceId)).toBe(true);
    });
    const retry = await openHubSocket(stub, relayPath(host.deviceId));
    retry.client.send(await signedClientAuth(phone, retry.nonce, 'client', { access_token: 'test-token' }));
    await expect(retry.closed).resolves.toMatchObject({ code: 4003 });
    expect(retry.messages.some((m) => m.type === 'auth_ok')).toBe(false);
  });

  it('expires an authenticated client before accepting its next command', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const hostSocket = await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    await runInDurableObject(stub, async (hub) => {
      const ws = relayInternals(hub).clientSockets.get(phone.deviceId)!;
      (relayInternals(hub).sessions.get(ws) as { authorizationExpiresAt: number }).authorizationExpiresAt = Date.now() - 1;
      await hub.webSocketMessage(ws, JSON.stringify({ type: 'relay_command', command: { messageId: 'expired', body: { kind: 'userInput' } } }));
    });
    expect(hostSocket.messages.some((m) => m.type === 'relay_command')).toBe(false);
    await expect(client.closed).resolves.toMatchObject({ code: 4001 });
  });

  it.each(['revoked', 'expired'] as const)('rejects a restored %s client attachment before replay', async (reason) => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    await runInDurableObject(stub, async (hub, state) => {
      if (reason === 'revoked') {
        await state.storage.put(`revoked-device:${phone.deviceId}`, true);
      } else {
        const ws = relayInternals(hub).clientSockets.get(phone.deviceId)!;
        ws.serializeAttachment({ ...ws.deserializeAttachment(), authorizationExpiresAt: Date.now() - 1 });
      }
    });
    await evictDurableObject(stub);
    await expect(hubHealth(stub)).resolves.toMatchObject({ clients: 0 });
    await expect(client.closed).resolves.toMatchObject({ code: reason === 'revoked' ? 4003 : 4001 });
  });

  it('cuts off one client and denies its reconnect while another client keeps receiving content', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const other = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone'), deviceRow(other, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const hostSocket = await authenticate(stub, host, host.deviceId, 'host');
    const phoneSocket = await authenticate(stub, phone, host.deviceId, 'client');
    const otherSocket = await authenticate(stub, other, host.deviceId, 'client');
    let staleServer!: WebSocket;
    await runInDurableObject(stub, (hub) => { staleServer = relayInternals(hub).clientSockets.get(phone.deviceId)!; });
    await hostMessage(stub, { type: 'relay_agent_state', snapshot: { agentId: 'test', marker: 'before' } });
    await waitFor(() => phoneSocket.messages.some((message) => message.type === 'relay_agent_state'), 'initial snapshot');

    expect((await revoke(stub, host, phone)).status).toBe(200);
    await expect(phoneSocket.closed).resolves.toMatchObject({ code: 4003 });
    await runInDurableObject(stub, (hub) => hub.webSocketMessage(staleServer, JSON.stringify({
      type: 'relay_command', command: { messageId: 'revoked-command', body: { kind: 'userInput' } },
    })));
    await hostMessage(stub, { type: 'relay_agent_state', snapshot: { agentId: 'test', marker: 'after' } });
    await waitFor(() => otherSocket.messages.some((message) => (message.snapshot as Record<string, unknown>)?.marker === 'after'), 'unrevoked snapshot');
    expect(phoneSocket.messages.some((message) => (message.snapshot as Record<string, unknown>)?.marker === 'after')).toBe(false);
    expect(hostSocket.messages.some((message) => message.type === 'relay_command')).toBe(false);

    const reconnect = await openHubSocket(stub, relayPath(host.deviceId));
    reconnect.client.send(await signedClientAuth(phone, reconnect.nonce, 'client', { access_token: 'test-token' }));
    await expect(reconnect.closed).resolves.toMatchObject({ code: 4003 });
    expect(reconnect.messages.some((message) => message.type === 'relay_agent_state' || message.type === 'auth_ok')).toBe(false);
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: true, clients: 1 });
  });

  it('does not admit a client whose authentication was in flight when revocation completed', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const gate = stubAccountPlane({ gateOn: 'device-lookup', devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    const authenticating = driveAuth(stub, await signedClientAuth(phone, socket.nonce, 'client', { access_token: 'test-token' }));
    await waitFor(() => gate.reached, 'client authorization lookup');
    const response = await revoke(stub, host, phone);
    gate.release();
    await authenticating;
    expect(response.status).toBe(200);
    await expect(socket.closed).resolves.toMatchObject({ code: 4003 });
    expect(socket.messages.some((message) => message.type === 'auth_ok')).toBe(false);
  });
});

describe('SignalingHub revocation', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('does not enqueue unauthorised offline signaling or replay a revoked stored envelope', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const foreign = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone'), { ...deviceRow(foreign, 'phone'), user_id: 'other-user' }] });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`offline-${host.deviceId}`));
    const phoneSocket = await openHubSocket(stub, '/signal');
    phoneSocket.client.send(await signedClientAuth(phone, phoneSocket.nonce, 'client'));
    await phoneSocket.nextMessage();
    const foreignSocket = await openHubSocket(stub, '/signal');
    foreignSocket.client.send(await signedClientAuth(foreign, foreignSocket.nonce, 'client'));
    await foreignSocket.nextMessage();
    for (const identity of [phone, foreign]) {
      await runInDurableObject(stub, (hub) => hub.webSocketMessage(signalingInternals(hub).peers.get(identity.deviceId)!, JSON.stringify({
        fromDeviceId: identity.deviceId, toDeviceId: host.deviceId, envelopeId: identity.deviceId, payload: { kind: 'ping' },
      })));
    }
    await runInDurableObject(stub, async (hub, state) => {
      const queues = (hub as unknown as { offlineQueues: Map<string, unknown[]> }).offlineQueues;
      expect(queues.get(host.deviceId)).toHaveLength(1);
      const denial = `${phone.deviceId}->${host.deviceId}`;
      // Use the implementation's persisted key shape, then restore the object.
      await state.storage.put(`revoked-pair:${denial}`, true);
    });
    await evictDurableObject(stub);
    const hostSocket = await openHubSocket(stub, '/signal');
    hostSocket.client.send(await signedClientAuth(host, hostSocket.nonce, 'host'));
    await hostSocket.nextMessage();
    await waitFor(() => hostSocket.messages.some((m) => m.type === 'host_identity'), 'host initialization');
    expect(hostSocket.messages.some((m) => m.envelopeId === phone.deviceId || m.envelopeId === foreign.deviceId)).toBe(false);
  });

  it('acknowledges host revocation and refuses cached signaling authorization in both directions', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`revoke-${host.deviceId}`));
    const hostSocket = await openHubSocket(stub, '/signal');
    hostSocket.client.send(await signedClientAuth(host, hostSocket.nonce, 'host'));
    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    const phoneSocket = await openHubSocket(stub, '/signal');
    phoneSocket.client.send(await signedClientAuth(phone, phoneSocket.nonce, 'client'));
    await expect(phoneSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    const envelope = { fromDeviceId: phone.deviceId, toDeviceId: host.deviceId, payload: { kind: 'ping' }, envelopeId: 'before' };
    phoneSocket.client.send(JSON.stringify(envelope));
    await waitFor(() => hostSocket.messages.some((message) => message.envelopeId === 'before'), 'initial signaling');

    await runInDurableObject(stub, (hub) => hub.webSocketMessage(signalingInternals(hub).peers.get(host.deviceId)!, JSON.stringify({
      type: 'revoke_device', device_id: phone.deviceId, request_id: 'revoke-1',
    })));
    await waitFor(() => hostSocket.messages.some((message) => message.type === 'device_revoked'), 'revocation acknowledgement');
    expect(hostSocket.messages.find((message) => message.type === 'device_revoked')).toMatchObject({ ok: true, request_id: 'revoke-1', device_id: phone.deviceId });
    await runInDurableObject(stub, (hub) => hub.webSocketMessage(signalingInternals(hub).peers.get(phone.deviceId)!, JSON.stringify({ ...envelope, envelopeId: 'after' })));
    await runInDurableObject(stub, (hub) => hub.webSocketMessage(signalingInternals(hub).peers.get(host.deviceId)!, JSON.stringify({ ...envelope, fromDeviceId: host.deviceId, toDeviceId: phone.deviceId, envelopeId: 'reverse-after' })));
    expect(hostSocket.messages.some((message) => message.envelopeId === 'after')).toBe(false);
    expect(phoneSocket.messages.some((message) => message.envelopeId === 'reverse-after')).toBe(false);
  });
});

describe('RelayHub auth when the socket closes mid-auth', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // This is the Local Test Lab failure: the hub closes the stale socket itself when the
  // reconnecting host replaces it, and in workerd a send() after that close() throws.
  // (A close initiated by the peer only moves the socket to CLOSING; send() still returns.)
  it('survives a quick host reconnect that replaces a socket whose auth is still awaiting the account service', async () => {
    const host = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const accountPlane = stubAccountPlane({ gateOn: 'last-seen-touch', devices: [deviceRow(host, 'host')] });

    const stale = await openHubSocket(stub, relayPath(host.deviceId));
    const staleAuth = driveAuth(stub, await signedClientAuth(host, stale.nonce, 'host'));
    await waitFor(() => accountPlane.reached, 'the stale auth to reach the last-seen touch');

    // The host reconnects before the first auth finishes; the hub closes the stale socket.
    const fresh = await openHubSocket(stub, relayPath(host.deviceId));
    fresh.client.send(await signedClientAuth(host, fresh.nonce, 'host'));
    await expect(fresh.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await expect(stale.closed).resolves.toEqual({ code: 1000, reason: 'replaced by newer host relay' });

    await runInDurableObject(stub, () => accountPlane.release());
    await expect(staleAuth).resolves.toBeUndefined();

    await runInDurableObject(stub, (hub, state) => {
      const sockets = state.getWebSockets();
      expect(sockets).toHaveLength(1);
      expect(relayInternals(hub).hostSocket).toBe(sockets[0]);
      expect(relayInternals(hub).hostSocket?.readyState).toBe(WebSocket.READY_STATE_OPEN);
      expect(relayInternals(hub).clientSockets.size).toBe(0);
      expect(relayInternals(hub).sessions.size).toBe(1);
    });
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: true, clients: 0 });
  });

  it.each<[string, AccountGatePoint]>([
    ['device lookup', 'device-lookup'],
    ['last-seen touch', 'last-seen-touch'],
  ])('forgets a host socket the peer closed during the %s', async (label, gateOn) => {
    const host = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const accountPlane = stubAccountPlane({ gateOn, devices: [deviceRow(host, 'host')] });

    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    const auth = driveAuth(stub, await signedClientAuth(host, socket.nonce, 'host'));
    await waitFor(() => accountPlane.reached, `the auth to reach the ${label}`);

    socket.client.close(1000, 'relay reconnect');
    await waitFor(
      () => runInDurableObject(stub, (hub, state) => state.getWebSockets().length === 0 && relayInternals(hub).sessions.size === 0),
      'the hub to process the close',
    );
    await runInDurableObject(stub, () => accountPlane.release());
    await expect(auth).resolves.toBeUndefined();

    await runInDurableObject(stub, (hub, state) => {
      expect(state.getWebSockets()).toHaveLength(0);
      expect(relayInternals(hub).hostSocket).toBeNull();
      expect(relayInternals(hub).clientSockets.size).toBe(0);
      expect(relayInternals(hub).sessions.size).toBe(0);
    });
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: false, clients: 0 });

    // Nothing stale blocks the host's next connection.
    const next = await openHubSocket(stub, relayPath(host.deviceId));
    next.client.send(await signedClientAuth(host, next.nonce, 'host'));
    await expect(next.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: true });
  });

  it('forgets a client socket the peer closed while its account was being verified', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const accountPlane = stubAccountPlane({
      gateOn: 'auth-user',
      devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')],
    });

    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    const auth = driveAuth(
      stub,
      await signedClientAuth(phone, socket.nonce, 'client', { access_token: 'phone-access-token' }),
    );
    await waitFor(() => accountPlane.reached, 'the auth to reach the account lookup');

    socket.client.close(1000, 'app backgrounded');
    await waitFor(
      () => runInDurableObject(stub, (hub, state) => state.getWebSockets().length === 0 && relayInternals(hub).sessions.size === 0),
      'the hub to process the close',
    );
    await runInDurableObject(stub, () => accountPlane.release());
    await expect(auth).resolves.toBeUndefined();

    await runInDurableObject(stub, (hub, state) => {
      expect(state.getWebSockets()).toHaveLength(0);
      expect(relayInternals(hub).clientSockets.size).toBe(0);
      expect(relayInternals(hub).sessions.size).toBe(0);
    });
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: false, clients: 0 });

    const next = await openHubSocket(stub, relayPath(host.deviceId));
    next.client.send(await signedClientAuth(phone, next.nonce, 'client', { access_token: 'phone-access-token' }));
    await expect(next.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: phone.deviceId });
    await expect(next.nextMessage()).resolves.toMatchObject({ type: 'relay_presence', online: false });
    await expect(hubHealth(stub)).resolves.toMatchObject({ clients: 1 });
  });
});

describe('SignalingHub auth when the socket closes mid-auth', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('survives a quick host reconnect on /signal while the replaced socket is still touching last-seen', async () => {
    const host = await createDeviceIdentity();
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`test-${host.deviceId}`));
    const accountPlane = stubAccountPlane({ gateOn: 'last-seen-touch' });

    const stale = await openHubSocket(stub, '/signal');
    const staleAuth = driveAuth(stub, await signedClientAuth(host, stale.nonce, 'host'));
    await expect(stale.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await waitFor(() => accountPlane.reached, 'the stale auth to reach the last-seen touch');

    const fresh = await openHubSocket(stub, '/signal');
    fresh.client.send(await signedClientAuth(host, fresh.nonce, 'host'));
    await expect(fresh.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await expect(stale.closed).resolves.toEqual({ code: 1000, reason: 'replaced by newer connection' });

    await runInDurableObject(stub, () => accountPlane.release());
    await expect(staleAuth).resolves.toBeUndefined();

    await runInDurableObject(stub, (hub, state) => {
      const sockets = state.getWebSockets();
      expect(sockets).toHaveLength(1);
      expect(signalingInternals(hub).peers.get(host.deviceId)).toBe(sockets[0]);
      expect(signalingInternals(hub).sessions.size).toBe(1);
    });
    await expect(hubHealth(stub)).resolves.toMatchObject({ peers: 1 });
  });
});

describe('RelayHub message detail replies', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it.each(['relay_message_detail', 'relay_agent_state'])('forwards a targeted %s only to the named client without caching it', async (type) => {
    const host = await createDeviceIdentity();
    const phoneA = await createDeviceIdentity();
    const phoneB = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const accountPlane = stubAccountPlane({
      gateOn: 'last-seen-touch',
      devices: [deviceRow(host, 'host'), deviceRow(phoneA, 'phone'), deviceRow(phoneB, 'phone')],
    });
    accountPlane.release();

    const hostSocket = await openHubSocket(stub, relayPath(host.deviceId));
    hostSocket.client.send(await signedClientAuth(host, hostSocket.nonce, 'host'));
    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });

    const clients = [];
    for (const phone of [phoneA, phoneB]) {
      const socket = await openHubSocket(stub, relayPath(host.deviceId));
      socket.client.send(await signedClientAuth(phone, socket.nonce, 'client', { access_token: 'phone-access-token' }));
      await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: phone.deviceId });
      await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'relay_presence', online: true });
      clients.push(socket);
    }
    const [socketA, socketB] = clients;

    const detail = { agentId: 'claude-desktop', messageId: 'm-7', text: 'full output', redacted: false, truncated: false };
    const payload = type === 'relay_message_detail' ? { detail } : { snapshot: { agentId: 'private-rejection', statusDetail: 'read-only mode is on' } };
    hostSocket.client.send(JSON.stringify({ type, client_device_id: phoneA.deviceId, ...payload }));
    await expect(socketA.nextMessage()).resolves.toMatchObject({ type, ...payload });
    await runInDurableObject(stub, async (_hub, state) => {
      const entries = await state.storage.list();
      expect(JSON.stringify([...entries])).not.toContain('private-rejection');
    });

    // B never sees it: the next thing B receives is a broadcast sent afterwards.
    hostSocket.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'claude-desktop' } }));
    await expect(socketB.nextMessage()).resolves.toMatchObject({ type: 'relay_agent_state' });
    await expect(socketA.nextMessage()).resolves.toMatchObject({ type: 'relay_agent_state' });
  });
});

describe('RelayHub cache retention', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('keeps expired data unreadable during a deletion failure and retries with a visible counter', async () => {
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(crypto.randomUUID()));
    await runInDurableObject(stub, async (_hub, state) => {
      await state.storage.put('contentRetentionV1', true);
      await state.storage.put('relayHello', { version: 1, receivedAt: Date.now() - 100, expiresAt: Date.now() - 1, data: {} });
    });
    await evictDurableObject(stub);
    await runInDurableObject(stub, async (hub, state) => {
      const failing = vi.spyOn(state.storage, 'delete').mockRejectedValueOnce(new Error('disposable storage failure'));
      await hub.alarm();
      failing.mockRestore();
      expect(await state.storage.get('retentionCleanupFailures')).toBe(1);
      expect(await state.storage.getAlarm()).toBeGreaterThan(Date.now());
      expect((hub as unknown as { latestHello: unknown }).latestHello).toBeNull();
      (hub as unknown as { cleanupAt: number }).cleanupAt = Date.now();
      await hub.alarm();
      expect(await state.storage.get('relayHello')).toBeUndefined();
      expect(await state.storage.get('retentionCleanupFailures')).toBeUndefined();
    });
  });

  it('publishes fixed deadlines which survive heartbeat and client replay', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const hs = await openHubSocket(stub, relayPath(host.deviceId));
    hs.client.send(await signedClientAuth(host, hs.nonce, 'host'));
    await expect(hs.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    hs.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'fixture' } }));
    let record: { receivedAt: number; expiresAt: number };
    await waitFor(async () => runInDurableObject(stub, async (_hub, state) => {
      record = await state.storage.get('relayAgentSnapshot:fixture') as typeof record;
      return !!record;
    }), 'snapshot persisted');
    expect(record!.expiresAt - record!.receivedAt).toBe(24 * 60 * 60_000);
    hs.client.send(JSON.stringify({ type: 'relay_ping' }));
    await expect(hs.nextMessage()).resolves.toMatchObject({ type: 'relay_pong' });
    const ps = await openHubSocket(stub, relayPath(host.deviceId));
    ps.client.send(await signedClientAuth(phone, ps.nonce, 'client', { access_token: 'phone-access-token', cache_retention_version: 1 }));
    await expect(ps.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    await expect(ps.nextMessage()).resolves.toMatchObject({ type: 'relay_presence' });
    await expect(ps.nextMessage()).resolves.toMatchObject({ type: 'relay_agent_state', cached: true, cache: { receivedAt: record!.receivedAt, expiresAt: record!.expiresAt } });
    await expect(ps.nextMessage()).resolves.toMatchObject({ type: 'relay_cache_manifest', agentIds: ['fixture'] });
    await runInDurableObject(stub, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:fixture')).toMatchObject(record!);
    });
    hs.client.close(); ps.client.close();
  });

  it('paginates migration without deleting unrelated keys or fresh content', async () => {
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(crypto.randomUUID()));
    await runInDurableObject(stub, async (hub, state) => {
      for (let i = 0; i < 140; i++) await state.storage.put(`relayAgentSnapshot:${i}`, { legacy: true });
      await state.storage.put('unrelated', { kept: true });
      const first = await hub.cacheMaintenance({ dryRun: true });
      expect(first.scanned).toBeLessThanOrEqual(128);
      expect(first.cursor).not.toBeNull();
      const page = await hub.cacheMaintenance({ dryRun: false });
      const next = await hub.cacheMaintenance({ dryRun: false, cursor: page.cursor! });
      expect(page.deleted + next.deleted).toBe(140);
      expect(next.cursor).toBeNull();
      expect(await state.storage.get('unrelated')).toEqual({ kept: true });
    });
  });

  it('inventories legacy data before a scoped, idempotent migration and preserves denials', async () => {
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(crypto.randomUUID()));
    await runInDurableObject(stub, async (_hub, state) => {
      await state.storage.put('relayHello', { deviceName: 'legacy' });
      await state.storage.put('relayAgentSnapshots', { fixture: { messages: [] } });
      await state.storage.put('relayAgentSnapshot:%broken', { marker: 'legacy' });
      await state.storage.put('revoked-device:fixture', true);
      await state.storage.put('relayLastHostSeenAt', 42);
    });
    await evictDurableObject(stub);
    await runInDurableObject(stub, async (hub, state) => {
      const before = await hub.cacheMaintenance({ dryRun: true });
      expect(before.invalid).toBe(3);
      expect(before.deleted).toBe(0);
      expect(await state.storage.get('relayHello')).toEqual({ deviceName: 'legacy' });
      const applied = await hub.cacheMaintenance({ dryRun: false });
      expect(applied.deleted).toBe(3);
      expect((await hub.cacheMaintenance({ dryRun: false })).deleted).toBe(0);
      expect(await state.storage.get('revoked-device:fixture')).toBe(true);
      expect(await state.storage.get('relayLastHostSeenAt')).toBe(42);
    });
  });

  it('arms cleanup on restore, removes expired copies without peers and keeps fresh copies', async () => {
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(crypto.randomUUID()));
    const now = Date.now();
    await runInDurableObject(stub, async (_hub, state) => {
      await state.storage.put('contentRetentionV1', true);
      await state.storage.put('relayHello', { version: 1, receivedAt: now - 100, expiresAt: now + 60_000, data: { deviceName: 'fresh' } });
      await state.storage.put('relayAgentSnapshot:expired', { version: 1, receivedAt: now - 100, expiresAt: now - 1, data: { agentId: 'expired' } });
      await state.storage.put('revoked-device:fixture', true);
    });
    await evictDurableObject(stub);
    await runInDurableObject(stub, async (hub, state) => {
      expect(await state.storage.getAlarm()).not.toBeNull();
      await hub.alarm();
      expect(await state.storage.get('relayAgentSnapshot:expired')).toBeUndefined();
      expect(await state.storage.get('relayHello')).toMatchObject({ expiresAt: now + 60_000 });
      expect(await state.storage.get('revoked-device:fixture')).toBe(true);
      expect(await state.storage.getAlarm()).toBeLessThanOrEqual(now + 60_000);
    });
  });

  it('never restores timestamp-free legacy transcripts after eviction', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await runInDurableObject(stub, async (_hub, state) => {
      await state.storage.put('relayAgentSnapshot:test', { agentId: 'test', marker: 'legacy' });
      await state.storage.put('relayHello', { deviceName: 'Legacy' });
    });
    await evictDurableObject(stub);
    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    socket.client.send(await signedClientAuth(phone, socket.nonce, 'client', { access_token: 'phone-access-token' }));
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'relay_presence' });
    socket.client.send(JSON.stringify({ type: 'relay_ping' }));
    await waitFor(() => socket.messages.some((m) => m.type === 'relay_pong'), 'replay completed');
    expect(socket.messages.some((m) => m.type === 'relay_agent_state' || m.type === 'relay_hello')).toBe(false);
    socket.client.close();
  });
});

describe('offline signaling retention', () => {
  it('deletes expired and invalid envelopes via a persistent alarm without deleting revocations', async () => {
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(crypto.randomUUID()));
    await runInDurableObject(stub, async (hub, state) => {
      const now = Date.now();
      const queues = (hub as unknown as { offlineQueues: Map<string, unknown[]> }).offlineQueues;
      queues.set('fixture', [
        { raw: '{}', enqueuedAt: now - 60_001 },
        { raw: '{}', enqueuedAt: Infinity },
        { raw: '{}', enqueuedAt: now - 100 },
      ]);
      await state.storage.put('revoked-pair:fixture', true);
      await hub.alarm();
      expect(await state.storage.get('offlineQueues')).toEqual({ fixture: [{ raw: '{}', enqueuedAt: now - 100 }] });
      expect(await state.storage.getAlarm()).toBeLessThanOrEqual(now + 59_900);
      queues.set('fixture', [{ raw: '{}', enqueuedAt: now - 60_001 }]);
      await hub.alarm();
      expect(await state.storage.get('offlineQueues')).toBeUndefined();
      expect(await state.storage.getAlarm()).toBeNull();
      expect(await state.storage.get('revoked-pair:fixture')).toBe(true);
    });
  });
});

describe('RelayHub host liveness', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  async function connectHostAndPhone() {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });

    const hostSocket = await openHubSocket(stub, relayPath(host.deviceId));
    hostSocket.client.send(await signedClientAuth(host, hostSocket.nonce, 'host'));
    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });

    const phoneSocket = await openHubSocket(stub, relayPath(host.deviceId));
    phoneSocket.client.send(
      await signedClientAuth(phone, phoneSocket.nonce, 'client', { access_token: 'phone-access-token' }),
    );
    await expect(phoneSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: phone.deviceId });
    await expect(phoneSocket.nextMessage()).resolves.toMatchObject({ type: 'relay_presence', online: true });

    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'account_device_authorized', requester_device_id: phone.deviceId });
    return { stub, hostSocket, phoneSocket };
  }

  // A Mac whose network path died without a FIN keeps an OPEN socket here. Without this
  // check phones kept seeing the Mac online and their screen start requests were acked
  // into the void until the edge timed the connection out.
  it('closes a host socket that stopped pinging and tells phones the Mac is offline', async () => {
    const { stub, hostSocket, phoneSocket } = await connectHostAndPhone();

    await runInDurableObject(stub, async (hub) => {
      (hub as unknown as { lastHostSeenAt: number }).lastHostSeenAt = Date.now() - 70_000;
      await hub.alarm();
    });

    await expect(hostSocket.closed).resolves.toEqual({ code: 1001, reason: 'host silent' });
    await expect(phoneSocket.nextMessage()).resolves.toMatchObject({ type: 'relay_presence', online: false });
    await runInDurableObject(stub, (hub) => {
      expect(relayInternals(hub).hostSocket).toBeNull();
      expect(relayInternals(hub).clientSockets.size).toBe(1);
    });
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: false, clients: 1 });
  });

  it('keeps a host that pinged recently', async () => {
    const { stub, hostSocket } = await connectHostAndPhone();

    await runInDurableObject(stub, async (hub) => {
      (hub as unknown as { lastHostSeenAt: number }).lastHostSeenAt = Date.now() - 10_000;
      await hub.alarm();
    });

    await runInDurableObject(stub, (hub) => {
      expect(relayInternals(hub).hostSocket?.readyState).toBe(WebSocket.READY_STATE_OPEN);
    });
    await expect(hubHealth(stub)).resolves.toMatchObject({ hostOnline: true, clients: 1 });
    hostSocket.client.close(1000, 'done');
  });

  it('counts a relay ping as the host being seen', async () => {
    const { stub, hostSocket } = await connectHostAndPhone();
    await runInDurableObject(stub, (hub) => {
      (hub as unknown as { lastHostSeenAt: number }).lastHostSeenAt = Date.now() - 70_000;
    });

    hostSocket.client.send(JSON.stringify({ type: 'relay_ping', at: Date.now() }));
    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'relay_pong' });

    await runInDurableObject(stub, async (hub) => {
      await hub.alarm();
      expect(relayInternals(hub).hostSocket?.readyState).toBe(WebSocket.READY_STATE_OPEN);
    });
    hostSocket.client.close(1000, 'done');
  });
});

describe('RelayHub in-place reauthentication', () => {
  afterEach(() => vi.unstubAllGlobals());

  async function authenticate(stub: DurableObjectStub<RelayHub>, identity: DeviceIdentity, hostID: string, role: 'host' | 'client') {
    const socket = await openHubSocket(stub, relayPath(hostID));
    socket.client.send(await signedClientAuth(identity, socket.nonce, role, { access_token: 'test-token' }));
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    return socket;
  }

  // Moves the browser's deadline close and runs the alarm the way the runtime would.
  async function shortenDeadline(stub: DurableObjectStub<RelayHub>, phone: DeviceIdentity, msFromNow: number) {
    await runInDurableObject(stub, async (hub) => {
      const ws = relayInternals(hub).clientSockets.get(phone.deviceId)!;
      const session = relayInternals(hub).sessions.get(ws) as { authorizationExpiresAt: number };
      session.authorizationExpiresAt = Date.now() + msFromNow;
      ws.serializeAttachment({ ...ws.deserializeAttachment(), authorizationExpiresAt: session.authorizationExpiresAt });
      await hub.alarm();
    });
  }

  it('asks a browser to renew before its deadline and keeps the socket after a valid renewal', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const hostSocket = await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    await shortenDeadline(stub, phone, 30_000);
    await waitFor(() => client.messages.some((m) => m.type === 'relay_reauth_required'), 'renewal request');
    client.client.send(JSON.stringify({ type: 'relay_reauth', access_token: 'renewed-token' }));
    await waitFor(() => client.messages.some((m) => m.type === 'relay_reauth_ok'), 'renewal acknowledgement');
    await runInDurableObject(stub, (hub) => {
      const ws = relayInternals(hub).clientSockets.get(phone.deviceId)!;
      const session = relayInternals(hub).sessions.get(ws) as { authorizationExpiresAt: number; reauthRequestedAt?: number };
      expect(session.authorizationExpiresAt).toBeGreaterThan(Date.now() + 4 * 60_000);
      expect(session.reauthRequestedAt).toBeUndefined();
    });
    client.client.send(JSON.stringify({ type: 'relay_command', command: { messageId: 'after-renewal', body: { kind: 'userInput' } } }));
    await waitFor(() => hostSocket.messages.some((m) => m.type === 'relay_command'), 'command after renewal');
    await expect(hubHealth(stub)).resolves.toMatchObject({ clients: 1 });
  });

  it('closes a browser whose renewed token is rejected', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host'), deviceRow(phone, 'phone')];
    stubAccountPlane({ devices });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    stubAccountPlane({ devices, failAuth: true });
    client.client.send(JSON.stringify({ type: 'relay_reauth', access_token: 'stale-token' }));
    await expect(client.closed).resolves.toMatchObject({ code: 4001 });
    await expect(hubHealth(stub)).resolves.toMatchObject({ clients: 0 });
  });

  it('keeps the current deadline and asks for a retry when the account service is unreachable', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    const stubbed = globalThis.fetch;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      if (gatewayFunction(input, init) === 'verifyBearerToken') throw new Error('account service unreachable');
      return stubbed(input, init);
    });
    client.client.send(JSON.stringify({ type: 'relay_reauth', access_token: 'renewed-token' }));
    await waitFor(() => client.messages.some((m) => m.type === 'relay_reauth_failed'), 'retry request');
    expect(client.messages.find((m) => m.type === 'relay_reauth_failed')).toMatchObject({ retry: true });
    await expect(hubHealth(stub)).resolves.toMatchObject({ clients: 1 });
  });
});

describe('RelayHub restore after revocation', () => {
  afterEach(() => vi.unstubAllGlobals());

  async function authenticate(stub: DurableObjectStub<RelayHub>, identity: DeviceIdentity, hostID: string, role: 'host' | 'client') {
    const socket = await openHubSocket(stub, relayPath(hostID));
    socket.client.send(await signedClientAuth(identity, socket.nonce, role, { access_token: 'test-token' }));
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    return socket;
  }

  it('lets a browser back in only after the internal restore call', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const pairings: Record<string, unknown>[] = [];
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')], pairings });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await authenticate(stub, host, host.deviceId, 'host');
    const client = await authenticate(stub, phone, host.deviceId, 'client');
    const revoke = await stub.fetch('https://hub.test/internal/revoke-device', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hostDeviceId: host.deviceId, hostPublicKeyB64: host.publicKeyB64, deviceId: phone.deviceId }),
    });
    expect(revoke.status).toBe(200);
    await revoke.json();
    await expect(client.closed).resolves.toMatchObject({ code: 4003 });

    const denied = await openHubSocket(stub, relayPath(host.deviceId));
    denied.client.send(await signedClientAuth(phone, denied.nonce, 'client', { access_token: 'test-token' }));
    await expect(denied.closed).resolves.toMatchObject({ code: 4003 });

    // The signaling hub deletes the revoked pairing rows when a link code is claimed.
    pairings.splice(0, pairings.length);
    const restore = await stub.fetch('https://hub.test/internal/restore-device', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hostDeviceId: host.deviceId, deviceId: phone.deviceId }),
    });
    expect(restore.status).toBe(200);
    expect(await restore.json()).toMatchObject({ ok: true, device_id: phone.deviceId });
    await runInDurableObject(stub, async (_hub, state) => {
      expect(await state.storage.get(`revoked-device:${phone.deviceId}`)).toBeUndefined();
    });
    const back = await openHubSocket(stub, relayPath(host.deviceId));
    back.client.send(await signedClientAuth(phone, back.nonce, 'client', { access_token: 'test-token' }));
    await expect(back.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
  });

  it('refuses to restore a browser that belongs to another account', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), { ...deviceRow(phone, 'phone'), user_id: 'other-user' }] });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const restore = await stub.fetch('https://hub.test/internal/restore-device', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hostDeviceId: host.deviceId, deviceId: phone.deviceId }),
    });
    expect(restore.status).toBe(403);
    await restore.json();
  });
});

describe('SignalingHub link-code re-authorization', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('lifts a revoked pairing, clears both hubs, and tells the Mac with reauthorized_at', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    const phoneRow = deviceRow(phone, 'phone');
    const pairings: Record<string, unknown>[] = [{
      id: 'pair-old', owner_user_id: 'user-1', host_device_uuid: hostRow.id, phone_device_uuid: phoneRow.id,
      paired_at: '2026-09-01T00:00:00.000Z', revoked_at: '2026-09-02T00:00:00.000Z', metadata: { revoked_via: 'host' },
    }];
    const linkCodes: Record<string, unknown>[] = [{
      id: 'code-1', code: 'ABC234', host_device_id: host.deviceId, host_public_key_b64: host.publicKeyB64,
      host_label: 'Test Mac', host_metadata: {}, created_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 600_000).toISOString(), consumed_at: null, claimed_user_id: null,
    }];
    stubAccountPlane({ devices: [hostRow, phoneRow], pairings, linkCodes });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`relink-${host.deviceId}`));
    const denial = `${phone.deviceId}->${host.deviceId}`;
    await runInDurableObject(stub, async (_hub, state) => { await state.storage.put(`revoked-pair:${denial}`, true); });
    await evictDurableObject(stub);
    const relay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await runInDurableObject(relay, async (_hub, state) => { await state.storage.put(`revoked-device:${phone.deviceId}`, true); });
    await evictDurableObject(relay);

    const hostSocket = await openHubSocket(stub, '/signal');
    hostSocket.client.send(await signedClientAuth(host, hostSocket.nonce, 'host'));
    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });

    const response = await stub.fetch('https://hub.test/account/claim-host-code', {
      method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
      body: JSON.stringify({ code: 'ABC234', requesterDeviceId: phone.deviceId }),
    });
    const body = await response.json() as { ok?: boolean; host?: { paired?: boolean } };
    expect(response.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(pairings.filter((row) => row.revoked_at != null)).toHaveLength(0);
    const active = pairings.find((row) => row.revoked_at == null) as { metadata?: { reauthorized_at?: string } } | undefined;
    expect(typeof active?.metadata?.reauthorized_at).toBe('string');
    await waitFor(() => hostSocket.messages.some((m) => m.type === 'account_device_authorized'), 'host notice');
    expect(hostSocket.messages.find((m) => m.type === 'account_device_authorized')).toMatchObject({
      requester_device_id: phone.deviceId, reauthorized_at: active?.metadata?.reauthorized_at,
    });
    await runInDurableObject(stub, async (_hub, state) => {
      expect(await state.storage.get(`revoked-pair:${denial}`)).toBeUndefined();
    });
    await runInDurableObject(relay, async (_hub, state) => {
      expect(await state.storage.get(`revoked-device:${phone.deviceId}`)).toBeUndefined();
    });
  });
});

describe('SignalingHub Mac-to-browser envelope authorization', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('looks the pair up once and reuses the decision for following envelopes', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
    let deviceLookups = 0;
    const stubbed = globalThis.fetch;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      if (gatewayFunction(input, init) === 'findDeviceByDeviceId') deviceLookups += 1;
      return stubbed(input, init);
    });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`hostcache-${host.deviceId}`));
    const phoneSocket = await openHubSocket(stub, '/signal');
    phoneSocket.client.send(await signedClientAuth(phone, phoneSocket.nonce, 'client'));
    await expect(phoneSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    const hostSocket = await openHubSocket(stub, '/signal');
    hostSocket.client.send(await signedClientAuth(host, hostSocket.nonce, 'host'));
    await expect(hostSocket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    const envelope = { fromDeviceId: host.deviceId, toDeviceId: phone.deviceId, payload: { kind: 'ping' } };

    await runInDurableObject(stub, (hub) => hub.webSocketMessage(signalingInternals(hub).peers.get(host.deviceId)!, JSON.stringify({ ...envelope, envelopeId: 'first' })));
    await waitFor(() => phoneSocket.messages.some((m) => m.envelopeId === 'first'), 'first envelope');
    const lookupsAfterFirst = deviceLookups;
    expect(lookupsAfterFirst).toBeGreaterThan(0);

    await runInDurableObject(stub, (hub) => hub.webSocketMessage(signalingInternals(hub).peers.get(host.deviceId)!, JSON.stringify({ ...envelope, envelopeId: 'second' })));
    await waitFor(() => phoneSocket.messages.some((m) => m.envelopeId === 'second'), 'second envelope');
    expect(deviceLookups).toBe(lookupsAfterFirst);
  });
});
