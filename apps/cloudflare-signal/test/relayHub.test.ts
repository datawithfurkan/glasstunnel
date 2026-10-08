import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { checkHostLabel } from "../../../convex/hostLabel";
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
  accountAuthorizationCache: Map<string, unknown>;
  hostEnvelopeAuthorizations: Map<string, unknown>;
  offlineQueues: Map<string, unknown[]>;
  pendingRemovals: Map<string, { userId: string; at: number; checkAt: number }>;
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

/**
 * Where the fake gateway can pause. 'device-lookup' pauses before the row is
 * read; 'device-lookup-reply' reads it and then pauses, like an answer that
 * arrives after the row changed.
 */
type AccountGatePoint =
  'device-lookup' | 'device-lookup-reply' | 'profile-lookup' | 'last-seen-touch' | 'auth-user' | 'device-update';

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
/** The fake gateway's session token for a second account ('user-2'); any other token is 'user-1'. */
const SECOND_ACCOUNT_TOKEN = 'second-account-token';

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
  /** Passes the gate point this many times before it pauses. */
  gateSkip?: number;
  devices?: Record<string, unknown>[];
  pairings?: Record<string, unknown>[];
  linkCodes?: Record<string, unknown>[];
  approvals?: Record<string, unknown>[];
  failPairingWrites?: boolean;
  failAuth?: boolean;
  /** Every gateway function called, in order. */
  calls?: string[];
  /** Functions that answer as an outage (HTTP 500); a test may change the set mid-way. */
  failFunctions?: Set<string>;
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
  let gateSkipped = 0;
  const pauseIf = async (point: AccountGatePoint) => {
    if (options.gateOn !== point || gate.reached) return;
    if (gateSkipped < (options.gateSkip ?? 0)) {
      gateSkipped += 1;
      return;
    }
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
  const metadataOf = (row: Record<string, unknown>) =>
    (row.metadata && typeof row.metadata === 'object' ? { ...(row.metadata as Record<string, unknown>) } : {}) as Record<string, unknown>;
  // As convex/accountPlane.ts activeHostOfUser: one answer for every device outside the account.
  const activeHostOfUser = (args: Record<string, unknown>) => {
    const row = devices.find((device) => device.device_id === args.deviceId);
    if (!row || row.user_id !== args.userId || row.kind !== 'host' || row.revoked_at != null) {
      throw new GatewayRejection('host_not_found');
    }
    return row;
  };

  const functions: Record<string, (args: Record<string, unknown>) => unknown | Promise<unknown>> = {
    async verifyBearerToken(args) {
      await pauseIf('auth-user');
      if (options.failAuth) return null;
      // A second account, for tests where two accounts act at once.
      return args.token === SECOND_ACCOUNT_TOKEN
        ? { id: 'user-2', email: 'second@example.test' }
        : { id: 'user-1', email: 'user@example.test' };
    },
    async findDeviceByDeviceId(args) {
      await pauseIf('device-lookup');
      // Read now: an answer held at 'device-lookup-reply' is the row as it was.
      const row = structuredClone(devices.find((device) => device.device_id === args.deviceId) ?? null);
      await pauseIf('device-lookup-reply');
      return row;
    },
    findDeviceByUuid: (args) => devices.find((row) => row.id === args.id) ?? null,
    async findProfileByUserId() {
      await pauseIf('profile-lookup');
      return null;
    },
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
      // Metadata merges; a name the owner chose (label_customized_at) is kept.
      const previous = metadataOf(existing);
      const customizedAt = typeof previous.label_customized_at === 'string' && previous.label_customized_at
        ? previous.label_customized_at : null;
      const metadata: Record<string, unknown> = { ...previous, ...((args.metadata as Record<string, unknown>) ?? {}) };
      if (customizedAt) metadata.label_customized_at = customizedAt;
      else delete metadata.label_customized_at;
      Object.assign(existing, {
        label: customizedAt ? existing.label : args.label, platform: args.platform ?? null,
        app_version: args.appVersion ?? existing.app_version ?? null,
        metadata, last_seen_at: at, updated_at: at,
      });
      return existing;
    },
    async touchDeviceLastSeen(args) {
      await pauseIf('last-seen-touch');
      const row = devices.find((device) => device.device_id === args.deviceId);
      if (row) {
        row.last_seen_at = new Date().toISOString();
        if (row.kind === 'host' && typeof args.appVersion === 'string' &&
            /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/.test(args.appVersion)) {
          row.app_version = args.appVersion;
        }
      }
      return null;
    },
    renameHostDevice: (args) => {
      // The real rule from convex/hostLabel.ts, as renameHostDevice applies it.
      const checked = checkHostLabel(String(args.label));
      if (!checked.ok) throw new GatewayRejection('invalid_label');
      const row = activeHostOfUser(args);
      const at = new Date().toISOString();
      Object.assign(row, { label: checked.label, metadata: { ...metadataOf(row), label_customized_at: at }, updated_at: at });
      return row;
    },
    // One transaction in Convex: synchronous here from the ownership check to the last delete.
    removeHostDevice: (args) => {
      const row = activeHostOfUser(args);
      const removed = structuredClone(row);
      remove(pairings, (pairing) => pairing.host_device_uuid === row.id);
      remove(approvals, (approval) => approval.host_device_uuid === row.id);
      remove(linkCodes, (code) => code.host_device_id === row.device_id);
      remove(devices, (device) => device === row);
      return removed;
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
    // Synchronous from lookup to write, as the real mutation is one serializable
    // transaction: two racing claims cannot both see the code unconsumed.
    claimHostLinkCode: (args) => {
      const unconsumed = linkCodes.filter((row) => row.code === args.code && row.consumed_at == null).slice(0, 20);
      const live = unconsumed.filter((row) => Date.parse(String(row.expires_at)) > Date.now());
      if (live.length === 1) {
        Object.assign(live[0], { consumed_at: new Date().toISOString(), claimed_user_id: args.claimedUserId });
        return live[0];
      }
      if (live.length === 0 && unconsumed.length > 0) throw new GatewayRejection('link_code_expired');
      throw new GatewayRejection('link_code_not_found');
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
    options.calls?.push(fn);
    if (options.failFunctions?.has(fn)) return Response.json({ ok: false, code: 'internal' }, { status: 500 });
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

describe('SignalingHub link-code claims', () => {
  afterEach(() => vi.unstubAllGlobals());

  function linkCodeRow(host: DeviceIdentity, overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      id: 'code-1', code: 'RACE23', host_device_id: host.deviceId, host_public_key_b64: host.publicKeyB64,
      host_label: 'Test Mac', host_metadata: {}, created_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 600_000).toISOString(), consumed_at: null, claimed_user_id: null,
      ...overrides,
    };
  }

  function claim(stub: DurableObjectStub<SignalingHub>, token: string, body: Record<string, unknown>) {
    return stub.fetch('https://hub.test/account/claim-host-code', {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
  }

  it.each([
    ['one account', 'test-token', 'user-1'],
    ['two accounts', SECOND_ACCOUNT_TOKEN, 'user-2'],
  ] as const)('lets exactly one of two racing claims from %s use the code', async (_label, secondToken, secondUser) => {
    const host = await createDeviceIdentity();
    const firstPhone = await createDeviceIdentity();
    const secondPhone = await createDeviceIdentity();
    const devices = [deviceRow(firstPhone, 'phone'), { ...deviceRow(secondPhone, 'phone'), user_id: secondUser }];
    const pairings: Record<string, unknown>[] = [];
    const linkCodes = [linkCodeRow(host)];
    // The first claim pauses at its first device lookup, after the code is claimed
    // and before the Mac is linked or a browser paired. The second claim starts and
    // finishes inside that window, as it would when both requests arrive together.
    const gate = stubAccountPlane({ gateOn: 'device-lookup', devices, pairings, linkCodes });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`claim-race-${host.deviceId}`));

    const first = claim(stub, 'test-token', { code: 'RACE23', requesterDeviceId: firstPhone.deviceId });
    await waitFor(() => gate.reached, 'the first claim to pause');
    const second = await claim(stub, secondToken, { code: 'race-23', requesterDeviceId: secondPhone.deviceId });
    gate.release();
    const winner = await first;

    expect(second.status).toBe(404);
    expect(await second.json()).toEqual({ ok: false, error: 'link code not found' });
    expect(winner.status).toBe(200);
    expect(await winner.json()).toMatchObject({ ok: true, host: { deviceId: host.deviceId, trusted: true } });
    expect(linkCodes).toEqual([expect.objectContaining({ claimed_user_id: 'user-1', consumed_at: expect.any(String) })]);
    expect(devices.filter((row) => row.kind === 'host')).toEqual([
      expect.objectContaining({ device_id: host.deviceId, user_id: 'user-1' }),
    ]);
    // One code pairs one browser: the losing claim paired nothing.
    expect(pairings).toEqual([expect.objectContaining({ owner_user_id: 'user-1', phone_device_uuid: `phone-${firstPhone.deviceId}` })]);
  });

  it('tells the person to show a new code when linking fails after the code was claimed', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const linkCodes = [linkCodeRow(host)];
    stubAccountPlane({ devices: [deviceRow(phone, 'phone')], linkCodes });
    const stubbed = globalThis.fetch;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      if (gatewayFunction(input, init) === 'findDeviceByDeviceId') throw new Error('account service unreachable');
      return stubbed(input, init);
    });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`claim-spent-${host.deviceId}`));

    const response = await claim(stub, 'test-token', { code: 'RACE23', requesterDeviceId: phone.deviceId });

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      ok: false,
      error: "Linking didn't finish, and this code can't be used again. Show a new code on your Mac and enter it.",
    });
    expect(linkCodes).toEqual([expect.objectContaining({ claimed_user_id: 'user-1', consumed_at: expect.any(String) })]);
  });

  it.each([
    ['expired', [{ expires_at: new Date(Date.now() - 1_000).toISOString() }], 400, 'link code expired'],
    ['already used', [{ consumed_at: new Date().toISOString(), claimed_user_id: 'user-9' }], 404, 'link code not found'],
    ['ambiguous', [{}, { id: 'code-2' }], 404, 'link code not found'],
    ['unknown', [], 404, 'link code not found'],
  ] as const)('refuses an %s code without linking the Mac', async (_label, rows, status, error) => {
    const host = await createDeviceIdentity();
    const devices: Record<string, unknown>[] = [];
    const linkCodes = rows.map((overrides) => linkCodeRow(host, overrides));
    const before = structuredClone(linkCodes);
    stubAccountPlane({ devices, linkCodes });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`claim-refused-${host.deviceId}`));

    const response = await claim(stub, 'test-token', { code: 'RACE23' });

    expect(response.status).toBe(status);
    expect(await response.json()).toEqual({ ok: false, error });
    expect(linkCodes).toEqual(before);
    expect(devices).toEqual([]);
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

describe('Mac management: rename and remove', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  const REMOVED = { code: 4003, reason: 'mac removed from account' };

  async function accountRequest(
    stub: DurableObjectStub<SignalingHub>,
    path: string,
    body: unknown,
    token = 'test-token',
  ): Promise<{ status: number; body: Record<string, unknown> }> {
    const response = await stub.fetch(`https://hub.test${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: (await response.json()) as Record<string, unknown> };
  }

  /** A Mac signed in to signaling, after the hub sent its first host_identity. */
  async function connectSignalingHost(
    stub: DurableObjectStub<SignalingHub>,
    host: DeviceIdentity,
    extra: Record<string, unknown> = {},
  ): Promise<HubSocket> {
    const socket = await openHubSocket(stub, '/signal');
    socket.client.send(await signedClientAuth(host, socket.nonce, 'host', extra));
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await waitFor(() => socket.messages.some((m) => m.type === 'host_identity'), 'the first host identity');
    return socket;
  }

  async function relayAuthenticate(stub: DurableObjectStub<RelayHub>, identity: DeviceIdentity, hostDeviceId: string, role: 'host' | 'client') {
    const socket = await openHubSocket(stub, relayPath(hostDeviceId));
    socket.client.send(await signedClientAuth(identity, socket.nonce, role, { access_token: 'test-token' }));
    await expect(socket.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    return socket;
  }

  function hostIdentities(socket: HubSocket) {
    return socket.messages.filter((message) => message.type === 'host_identity');
  }

  function linkCodeRow(host: DeviceIdentity, overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      id: `code-${host.deviceId}`, code: 'KEEP23', host_device_id: host.deviceId, host_public_key_b64: host.publicKeyB64,
      host_label: "Studio Mac mini", host_metadata: { signaling_url: 'wss://new.example.test/signal', turn_url: '' },
      created_at: new Date().toISOString(), expires_at: new Date(Date.now() + 600_000).toISOString(),
      consumed_at: null, claimed_user_id: null, ...overrides,
    };
  }

  it('renames a Mac, marks the name as chosen, and sends the connected Mac its new name', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow: Record<string, unknown> = {
      ...deviceRow(host, 'host'), label: "Studio Mac mini", created_at: '2026-08-01T10:00:00.000Z',
      metadata: { signaling_url: 'wss://signal.example.test/signal' },
    };
    const phoneRow = deviceRow(phone, 'phone');
    const pairings = [{
      id: 'pair-1', owner_user_id: 'user-1', host_device_uuid: hostRow.id, phone_device_uuid: phoneRow.id,
      paired_at: '2026-08-02T10:00:00.000Z', revoked_at: null, metadata: {},
    }];
    stubAccountPlane({ devices: [hostRow, phoneRow], pairings });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`rename-${host.deviceId}`));
    const mac = await connectSignalingHost(stub, host);
    expect(hostIdentities(mac)[0]).toMatchObject({ linked: true, user_id: 'user-1', host_label: "Studio Mac mini" });

    const reply = await accountRequest(stub, '/account/hosts/rename', {
      deviceId: host.deviceId, label: '  Studio Mac  ', requesterDeviceId: phone.deviceId,
    });

    expect(reply.status).toBe(200);
    expect(reply.body).toMatchObject({
      ok: true,
      host: {
        deviceId: host.deviceId, label: 'Studio Mac', trusted: true,
        pairedAtUnixMs: Date.parse('2026-08-02T10:00:00.000Z'), addedAtUnixMs: Date.parse('2026-08-01T10:00:00.000Z'),
        signalingUrl: 'wss://signal.example.test/signal',
      },
    });
    expect(hostRow.label).toBe('Studio Mac');
    expect(hostRow.metadata).toEqual({ signaling_url: 'wss://signal.example.test/signal', label_customized_at: expect.any(String) });
    await waitFor(() => hostIdentities(mac).some((m) => m.host_label === 'Studio Mac'), 'the renamed host identity');
    expect(hostIdentities(mac).at(-1)).toEqual({
      type: 'host_identity', linked: true, user_id: 'user-1', email: 'user@example.test',
      display_name: 'user', avatar_url: '', host_label: 'Studio Mac',
    });
  });

  // Built from code points so no tool can turn an escape into the invisible character.
  const cp = (...codePoints: number[]) => String.fromCodePoint(...codePoints);
  const PERSIAN_WITH_ZWNJ = `${cp(0x6a9, 0x62a, 0x627, 0x628)}${cp(0x200c)}${cp(0x62e, 0x627, 0x646, 0x647)}`;

  it.each([
    ['40 characters', 'x'.repeat(40), 'x'.repeat(40)],
    ['40 code points that are 80 UTF-16 units', cp(0x1f5a5).repeat(40), cp(0x1f5a5).repeat(40)],
    ['a ZWJ emoji sequence', `Dev ${cp(0x1f9d1, 0x200d, 0x1f4bb)} Mac`, `Dev ${cp(0x1f9d1, 0x200d, 0x1f4bb)} Mac`],
    ['a Persian name with ZWNJ', PERSIAN_WITH_ZWNJ, PERSIAN_WITH_ZWNJ],
    ['a decomposed accent, stored as NFC', `Caf${cp(0x65, 0x301)}`, `Caf${cp(0xe9)}`],
    ['40 accents that are 80 code points before NFC', cp(0x65, 0x301).repeat(40), cp(0xe9).repeat(40)],
  ] as const)('accepts and stores %s', async (_label, label, stored) => {
    const host = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    stubAccountPlane({ devices: [hostRow] });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`rename-accepted-${host.deviceId}`));

    const reply = await accountRequest(stub, '/account/hosts/rename', { deviceId: host.deviceId, label });

    expect(reply.status).toBe(200);
    expect(reply.body).toMatchObject({ ok: true, host: { label: stored } });
    expect(hostRow.label).toBe(stored);
  });

  it.each([
    ['empty', '', 'Enter a name.'],
    ['blank', '   ', 'Enter a name.'],
    ['not text', 42, 'Enter a name.'],
    ['41 characters', 'x'.repeat(41), 'Use 40 characters or fewer.'],
    ['41 code points', cp(0x1f5a5).repeat(41), 'Use 40 characters or fewer.'],
    ['41 code points after NFC', cp(0x65, 0x301).repeat(41), 'Use 40 characters or fewer.'],
    ['a line break', 'Studio\nMac', 'Remove hidden characters from the name.'],
    ['a tab', 'Studio\tMac', 'Remove hidden characters from the name.'],
    ['a NUL character', `Studio${cp(0)}Mac`, 'Remove hidden characters from the name.'],
    ['a line separator', `Studio${cp(0x2028)}Mac`, 'Remove hidden characters from the name.'],
    ['a right-to-left override', `Studio${cp(0x202e)}Mac`, 'Remove hidden characters from the name.'],
    ['a directional isolate', `${cp(0x2067)}Studio${cp(0x2069)}`, 'Remove hidden characters from the name.'],
    ['a left-to-right mark', `Studio Mac${cp(0x200e)}`, 'Remove hidden characters from the name.'],
    ['a zero width space', `Studio Mac mini${cp(0x200b)}`, 'Remove hidden characters from the name.'],
    ['a word joiner', `Studio${cp(0x2060)}Mac`, 'Remove hidden characters from the name.'],
    ['a byte order mark inside', `Studio${cp(0xfeff)}Mac`, 'Remove hidden characters from the name.'],
  ] as const)('refuses a name with %s before it reaches the account', async (_label, label, error) => {
    const host = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    const before = structuredClone(hostRow);
    const calls: string[] = [];
    stubAccountPlane({ devices: [hostRow], calls });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`rename-invalid-${host.deviceId}`));

    const reply = await accountRequest(stub, '/account/hosts/rename', { deviceId: host.deviceId, label });

    expect(reply).toEqual({ status: 400, body: { ok: false, error } });
    expect(calls).not.toContain('renameHostDevice');
    expect(hostRow).toEqual(before);
  });

  it.each(['another account', 'a phone', 'a revoked Mac', 'an unknown device'] as const)(
    'answers Mac not found for %s and changes nothing', async (scenario) => {
      const device = await createDeviceIdentity();
      const phone = await createDeviceIdentity();
      const row = scenario === 'a phone' ? deviceRow(device, 'phone') : deviceRow(device, 'host');
      if (scenario === 'another account') row.user_id = 'user-2';
      if (scenario === 'a revoked Mac') row.revoked_at = '2026-09-01T00:00:00.000Z';
      const phoneRow = deviceRow(phone, 'phone');
      const devices = scenario === 'an unknown device' ? [phoneRow] : [row, phoneRow];
      const pairings = [{
        id: 'pair-1', owner_user_id: String(row.user_id), host_device_uuid: row.id, phone_device_uuid: phoneRow.id,
        paired_at: '2026-08-02T10:00:00.000Z', revoked_at: null, metadata: {},
      }];
      const linkCodes = [linkCodeRow(device)];
      const before = structuredClone({ devices, pairings, linkCodes });
      const calls: string[] = [];
      stubAccountPlane({ devices, pairings, linkCodes, calls });
      const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`notfound-${device.deviceId}`));

      const renamed = await accountRequest(stub, '/account/hosts/rename', { deviceId: device.deviceId, label: 'Mine now' });
      const removed = await accountRequest(stub, '/account/hosts/remove', { deviceId: device.deviceId });

      expect(renamed).toEqual({ status: 404, body: { ok: false, error: 'Mac not found' } });
      expect(removed).toEqual({ status: 404, body: { ok: false, error: 'Mac not found' } });
      expect({ devices, pairings, linkCodes }).toEqual(before);
      // The removal stops at its own lookup: Convex is never asked, and the hub keeps nothing.
      expect(calls).not.toContain('removeHostDevice');
      await runInDurableObject(stub, async (_hub, state) => {
        expect([...(await state.storage.list({ prefix: 'removed-host:' })).keys()]).toEqual([]);
        expect([...(await state.storage.list({ prefix: 'pending-removal:' })).keys()]).toEqual([]);
      });
    },
  );

  it('requires a signed-in account and a device id', async () => {
    const host = await createDeviceIdentity();
    stubAccountPlane({ devices: [deviceRow(host, 'host')] });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`manage-auth-${host.deviceId}`));
    for (const path of ['/account/hosts/rename', '/account/hosts/remove']) {
      const unsigned = await stub.fetch(`https://hub.test${path}`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ deviceId: host.deviceId, label: 'x' }),
      });
      expect(unsigned.status).toBe(401);
      await unsigned.json();
      expect(await accountRequest(stub, path, { label: 'x' })).toEqual({ status: 400, body: { ok: false, error: 'deviceId is required' } });
      const wrongMethod = await stub.fetch(`https://hub.test${path}`, { headers: { authorization: 'Bearer test-token' } });
      expect(wrongMethod.status).toBe(405);
      await wrongMethod.json();
    }
  });

  it('removes a Mac: account rows, the Mac told, browsers cut off, and cached content deleted', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const otherHost = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    const phoneRow = deviceRow(phone, 'phone');
    const otherRow = deviceRow(otherHost, 'host');
    const devices = [hostRow, phoneRow, otherRow];
    const at = new Date().toISOString();
    const pairings = [
      { id: 'pair-1', owner_user_id: 'user-1', host_device_uuid: hostRow.id, phone_device_uuid: phoneRow.id, paired_at: at, revoked_at: null, metadata: {} },
      { id: 'pair-2', owner_user_id: 'user-1', host_device_uuid: otherRow.id, phone_device_uuid: phoneRow.id, paired_at: at, revoked_at: null, metadata: {} },
    ];
    const approvals = [{
      id: 'approval-1', owner_user_id: 'user-1', host_device_uuid: hostRow.id, requester_device_uuid: phoneRow.id,
      requester_device_id: phone.deviceId, requester_public_key_b64: phone.publicKeyB64, requester_label: 'Phone',
      status: 'pending', metadata: {}, created_at: at, updated_at: at, responded_at: null,
    }];
    const linkCodes = [linkCodeRow(host), linkCodeRow(otherHost, { code: 'OTHER2' })];
    stubAccountPlane({ devices, pairings, approvals, linkCodes });

    // Signaling: the Mac and a browser that already exchanged an envelope, so
    // the hub holds a cached authorization for the pair.
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remove-${host.deviceId}`));
    const macSignal = await connectSignalingHost(signaling, host);
    const phoneSignal = await openHubSocket(signaling, '/signal');
    phoneSignal.client.send(await signedClientAuth(phone, phoneSignal.nonce, 'client'));
    await expect(phoneSignal.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    const envelope = { fromDeviceId: phone.deviceId, toDeviceId: host.deviceId, payload: { kind: 'ping' } };
    phoneSignal.client.send(JSON.stringify({ ...envelope, envelopeId: 'before' }));
    await waitFor(() => macSignal.messages.some((m) => m.envelopeId === 'before'), 'signaling before removal');

    // Relay: the Mac publishes content that the browser receives and the relay caches.
    const relay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const macRelay = await relayAuthenticate(relay, host, host.deviceId, 'host');
    const phoneRelay = await relayAuthenticate(relay, phone, host.deviceId, 'client');
    macRelay.client.send(JSON.stringify({ type: 'relay_hello', hello: { deviceName: 'Studio Mac' } }));
    macRelay.client.send(JSON.stringify({ type: 'relay_remote_apps', remoteApps: [{ id: 'terminal' }] }));
    macRelay.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'codex', marker: 'before' } }));
    await waitFor(() => phoneRelay.messages.some((m) => m.type === 'relay_agent_state'), 'content before removal');
    await runInDurableObject(relay, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:codex')).toBeDefined();
      await state.storage.put('revoked-device:gt-0000000000000000', true);
    });

    const reply = await accountRequest(signaling, '/account/hosts/remove', { deviceId: host.deviceId });

    expect(reply).toEqual({ status: 200, body: { ok: true } });
    // (1) The account rows that pointed at the Mac are gone; everything else stays.
    expect(devices.map((row) => row.device_id)).toEqual([phone.deviceId, otherHost.deviceId]);
    expect(pairings.map((row) => row.id)).toEqual(['pair-2']);
    expect(approvals).toEqual([]);
    expect(linkCodes.map((row) => row.host_device_id)).toEqual([otherHost.deviceId]);
    // (2) The Mac is told, and keeps its signaling connection so it can be linked again.
    await waitFor(() => hostIdentities(macSignal).some((m) => m.linked === false), 'the removal notice');
    expect(hostIdentities(macSignal).at(-1)).toEqual({ type: 'host_identity', linked: false, reason: 'removed_from_account' });
    await runInDurableObject(signaling, (hub) => {
      expect(signalingInternals(hub).peers.has(host.deviceId)).toBe(true);
    });
    await runInDurableObject(signaling, (hub) => hub.webSocketMessage(
      signalingInternals(hub).peers.get(phone.deviceId)!, JSON.stringify({ ...envelope, envelopeId: 'after' }),
    ));
    expect(macSignal.messages.some((m) => m.envelopeId === 'after')).toBe(false);
    // (3) Every relay socket closes with the removal reason and the cache is gone.
    await expect(phoneRelay.closed).resolves.toEqual(REMOVED);
    await expect(macRelay.closed).resolves.toEqual(REMOVED);
    await expect(hubHealth(relay)).resolves.toMatchObject({ hostOnline: false, clients: 0 });
    await runInDurableObject(relay, async (hub, state) => {
      const keys = [...(await state.storage.list()).keys()];
      expect(keys.filter((key) => key === 'relayHello' || key === 'relayRemoteApps' || key.startsWith('relayAgentSnapshot'))).toEqual([]);
      expect(await state.storage.get('revoked-device:gt-0000000000000000')).toBe(true);
      expect(await state.storage.get('contentRetentionV1')).toBe(true);
      const internals = hub as unknown as { latestHello: unknown; latestRemoteApps: unknown; latestAgentSnapshots: Map<string, unknown> };
      expect(internals.latestHello).toBeNull();
      expect(internals.latestRemoteApps).toBeNull();
      expect(internals.latestAgentSnapshots.size).toBe(0);
    });
    // The removed Mac's relay is refused like any unlinked Mac.
    const refused = await openHubSocket(relay, relayPath(host.deviceId));
    refused.client.send(await signedClientAuth(host, refused.nonce, 'host'));
    await expect(refused.closed).resolves.toMatchObject({ code: 1008 });

    // Linked again later: the relay starts clean and replays only fresh content.
    devices.push({ ...deviceRow(host, 'host'), id: 'host-relinked' });
    const macAgain = await relayAuthenticate(relay, host, host.deviceId, 'host');
    macAgain.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'codex', marker: 'after' } }));
    await waitFor(() => runInDurableObject(relay, async (_hub, state) => !!(await state.storage.get('relayAgentSnapshot:codex'))), 'fresh content');
    const phoneAgain = await relayAuthenticate(relay, phone, host.deviceId, 'client');
    await waitFor(() => phoneAgain.messages.some((m) => m.type === 'relay_agent_state'), 'fresh replay');
    const replayed = phoneAgain.messages.filter((m) => m.type === 'relay_agent_state' || m.type === 'relay_hello' || m.type === 'relay_remote_apps');
    expect(replayed).toEqual([expect.objectContaining({ type: 'relay_agent_state', cached: true, snapshot: expect.objectContaining({ marker: 'after' }) })]);
    macAgain.client.close();
    phoneAgain.client.close();
  });

  it('still answers 200 once the account removed the Mac, even if the relay cannot confirm the cleanup', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host'), deviceRow(phone, 'phone')];
    const failFunctions = new Set<string>();
    stubAccountPlane({ devices, failFunctions });
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remove-relayfail-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    const relay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    await relayAuthenticate(relay, host, host.deviceId, 'host');
    await relayAuthenticate(relay, phone, host.deviceId, 'client');

    // Once Convex removed the Mac, lookups fail: the relay cannot check the Mac.
    const stubbed = globalThis.fetch;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const response = await stubbed(input, init);
      if (gatewayFunction(input, init) === 'removeHostDevice') failFunctions.add('findDeviceByDeviceId');
      return response;
    });
    const reply = await accountRequest(signaling, '/account/hosts/remove', { deviceId: host.deviceId });

    expect(reply).toEqual({ status: 200, body: { ok: true } });
    expect(devices.map((row) => row.device_id)).toEqual([phone.deviceId]);
    await waitFor(() => hostIdentities(mac).some((m) => m.reason === 'removed_from_account'), 'the removal notice');
    expect(errors.mock.calls.flat().join(' ')).toContain('relay cleanup not confirmed');
    // The removal finished: its pending marker is gone with it.
    await runInDurableObject(signaling, async (hub, state) => {
      expect(signalingInternals(hub).pendingRemovals.has(host.deviceId)).toBe(false);
      expect(await state.storage.get(`pending-removal:${host.deviceId}`)).toBeUndefined();
    });
  });

  it('refuses to clear the relay of a Mac that is still linked, or from another Mac\'s relay', async () => {
    const host = await createDeviceIdentity();
    const otherHost = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    stubAccountPlane({ devices: [hostRow, deviceRow(phone, 'phone')] });
    const relay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const mac = await relayAuthenticate(relay, host, host.deviceId, 'host');
    const browser = await relayAuthenticate(relay, phone, host.deviceId, 'client');
    mac.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'codex' } }));
    await waitFor(() => browser.messages.some((m) => m.type === 'relay_agent_state'), 'content');

    const attempt = async (body: unknown) => {
      const response = await relay.fetch('https://hub.test/internal/host-removed', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    };
    expect(await attempt({ hostDeviceId: host.deviceId })).toMatchObject({ status: 409, body: { ok: false, closed: 0 } });
    expect(await attempt({ hostDeviceId: otherHost.deviceId })).toMatchObject({ status: 403, body: { ok: false } });
    expect(await attempt({})).toMatchObject({ status: 403, body: { ok: false } });
    await expect(hubHealth(relay)).resolves.toMatchObject({ hostOnline: true, clients: 1 });
    await runInDurableObject(relay, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:codex')).toBeDefined();
    });

    // Linked to another account before the removal reached the relay: the
    // Mac and its content stay, but the old account's browser is cut off now.
    hostRow.user_id = 'user-2';
    expect(await attempt({ hostDeviceId: host.deviceId })).toMatchObject({ status: 409, body: { ok: false, closed: 1 } });
    await expect(browser.closed).resolves.toEqual(REMOVED);
    await expect(hubHealth(relay)).resolves.toMatchObject({ hostOnline: true, clients: 0 });
    mac.client.close();
  });

  it.each([
    ['keeps a name the owner chose', '2026-10-01T00:00:00.000Z', 'Studio Mac'],
    ['takes the Mac\'s name when the owner never chose one', null, "Studio Mac mini"],
  ] as const)('re-linking the same Mac to the same account %s', async (_label, customizedAt, expectedLabel) => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow = {
      ...deviceRow(host, 'host'), label: 'Studio Mac',
      metadata: {
        signaling_url: 'wss://old.example.test/signal', note: 'kept',
        ...(customizedAt ? { label_customized_at: customizedAt } : {}),
      },
    };
    const linkCodes = [linkCodeRow(host)];
    stubAccountPlane({ devices: [hostRow, deviceRow(phone, 'phone')], linkCodes });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`relink-label-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);

    const reply = await accountRequest(signaling, '/account/claim-host-code', { code: 'KEEP23', requesterDeviceId: phone.deviceId });

    expect(reply.status).toBe(200);
    expect(reply.body).toMatchObject({ ok: true, host: { deviceId: host.deviceId, label: expectedLabel } });
    expect(hostRow.label).toBe(expectedLabel);
    expect(hostRow.metadata).toEqual({
      signaling_url: 'wss://new.example.test/signal', turn_url: '', note: 'kept',
      ...(customizedAt ? { label_customized_at: customizedAt } : {}),
    });
    await waitFor(() => hostIdentities(mac).length >= 2, 'the link notice');
    expect(hostIdentities(mac).at(-1)).toMatchObject({ linked: true, host_label: expectedLabel });
  });

  it('records the Mac app version a Mac reports and lists it with the date the Mac was added', async () => {
    const host = await createDeviceIdentity();
    const otherHost = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow: Record<string, unknown> = { ...deviceRow(host, 'host'), created_at: '2026-08-01T10:00:00.000Z' };
    const otherRow = deviceRow(otherHost, 'host');
    stubAccountPlane({ devices: [hostRow, otherRow, deviceRow(phone, 'phone')] });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`app-version-${host.deviceId}`));
    await connectSignalingHost(signaling, host, { app_version: '0.1.11' });
    await connectSignalingHost(signaling, otherHost, { app_version: '<script>' });
    expect(hostRow.app_version).toBe('0.1.11');
    expect(otherRow.app_version).toBeNull();

    const response = await signaling.fetch(`https://hub.test/account/hosts?device_id=${phone.deviceId}`, {
      headers: { authorization: 'Bearer test-token' },
    });
    const { hosts } = (await response.json()) as { hosts: Record<string, unknown>[] };
    expect(hosts.find((h) => h.deviceId === host.deviceId)).toMatchObject({
      appVersion: '0.1.11', addedAtUnixMs: Date.parse('2026-08-01T10:00:00.000Z'),
    });
    expect(hosts.find((h) => h.deviceId === otherHost.deviceId)).not.toHaveProperty('appVersion');
  });

  /** Resolves once every message the hub sent this socket before a ping has arrived. */
  async function roundTrip(socket: HubSocket): Promise<void> {
    const pongs = () => socket.messages.filter((message) => message.type === 'pong').length;
    const before = pongs();
    socket.client.send(JSON.stringify({ type: 'ping' }));
    await waitFor(() => pongs() > before, 'a pong');
  }

  const DAY_MS = 24 * 60 * 60_000;
  const removalKey = (deviceId: string) => `removed-host:${deviceId}`;

  const MINUTE_MS = 60_000;
  const HOUR_MS = 60 * MINUTE_MS;
  const pendingKey = (deviceId: string) => `pending-removal:${deviceId}`;

  /**
   * From here on, Convex commits a removal and the connection drops before its
   * answer arrives. Given `failFunctions`, the account service also stops
   * answering lookups at that moment, until the test deletes that entry.
   */
  function loseRemovalAnswer(failFunctions?: Set<string>): void {
    const stubbed = globalThis.fetch;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const response = await stubbed(input, init);
      if (gatewayFunction(input, init) !== 'removeHostDevice') return response;
      failFunctions?.add('findDeviceByDeviceId');
      throw new TypeError('Network connection lost.');
    });
  }

  /** A Mac on signaling and on its relay with a browser and cached content, for the removal tests. */
  async function removableMac(name: string, options: { failFunctions?: Set<string>; calls?: string[] } = {}) {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host'), deviceRow(phone, 'phone')];
    stubAccountPlane({ devices, ...options });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`${name}-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    const relay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const macRelay = await relayAuthenticate(relay, host, host.deviceId, 'host');
    const phoneRelay = await relayAuthenticate(relay, phone, host.deviceId, 'client');
    macRelay.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'codex', marker: 'before' } }));
    await waitFor(() => phoneRelay.messages.some((m) => m.type === 'relay_agent_state'), 'cached content');
    return { host, phone, devices, signaling, mac, relay, macRelay, phoneRelay };
  }

  /** Nothing of a removal happened yet: the Mac is linked on signaling and its relay serves the browser. */
  async function expectMacUntouched(setup: Awaited<ReturnType<typeof removableMac>>) {
    await roundTrip(setup.mac);
    expect(hostIdentities(setup.mac)).toEqual([expect.objectContaining({ linked: true })]);
    await expect(hubHealth(setup.relay)).resolves.toMatchObject({ hostOnline: true, clients: 1 });
    await runInDurableObject(setup.relay, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:codex')).toBeDefined();
    });
    await runInDurableObject(setup.signaling, async (_hub, state) => {
      expect(await state.storage.get(removalKey(setup.host.deviceId))).toBeUndefined();
    });
  }

  /** The removal's cleanup ran: the Mac told why, every relay socket closed, the record kept and the marker gone. */
  async function expectRemovalFinished(setup: Awaited<ReturnType<typeof removableMac>>) {
    await waitFor(() => hostIdentities(setup.mac).some((m) => m.reason === 'removed_from_account'), 'the removal notice');
    await expect(setup.phoneRelay.closed).resolves.toEqual(REMOVED);
    await expect(setup.macRelay.closed).resolves.toEqual(REMOVED);
    await runInDurableObject(setup.relay, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:codex')).toBeUndefined();
    });
    await runInDurableObject(setup.signaling, async (hub, state) => {
      expect(typeof (await state.storage.get(removalKey(setup.host.deviceId)))).toBe('number');
      expect(signalingInternals(hub).pendingRemovals.has(setup.host.deviceId)).toBe(false);
      expect(await state.storage.get(pendingKey(setup.host.deviceId))).toBeUndefined();
    });
  }

  it('finishes a removal whose answer from the account service was lost', async () => {
    const calls: string[] = [];
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const setup = await removableMac('remove-lost', { calls });
    loseRemovalAnswer();
    calls.length = 0;

    const reply = await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId });

    expect(reply).toEqual({ status: 200, body: { ok: true } });
    expect(setup.devices.map((row) => row.device_id)).toEqual([setup.phone.deviceId]);
    // Looked up first (the caller's Mac), removed, and looked up again after the lost answer.
    expect(calls.slice(0, 4)).toEqual(['verifyBearerToken', 'findDeviceByDeviceId', 'removeHostDevice', 'findDeviceByDeviceId']);
    await expectRemovalFinished(setup);
    const logged = errors.mock.calls.flat().join(' ');
    expect(logged).toContain("the account service's answer was lost after the Mac was removed");
    expect(logged).not.toContain(setup.host.deviceId);
    expect(logged).not.toContain('user@example.test');
  });

  it.each([
    ['did not remove the Mac', ['removeHostDevice'], 'the Mac is still in an account', true],
    ['cannot be reached at all', ['findDeviceByDeviceId'], 'account plane findDeviceByDeviceId failed', false],
  ] as const)('answers 503 and changes nothing when the account service %s', async (_label, failing, logged, keepsMarker) => {
    const failFunctions = new Set<string>();
    const calls: string[] = [];
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const setup = await removableMac('remove-unavailable', { failFunctions, calls });
    for (const fn of failing) failFunctions.add(fn);

    const reply = await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId });

    expect(reply).toEqual({ status: 503, body: { ok: false, error: 'Account service is temporarily unavailable. Try again.' } });
    expect(setup.devices.map((row) => row.device_id)).toEqual([setup.host.deviceId, setup.phone.deviceId]);
    await expectMacUntouched(setup);
    // Asked, but without an answer: the hub keeps a marker for its alarm. Not
    // even looked up: Convex was never asked, and there is nothing to remember.
    expect(calls.includes('removeHostDevice')).toBe(keepsMarker);
    await runInDurableObject(setup.signaling, async (_hub, state) => {
      const marker = await state.storage.get(pendingKey(setup.host.deviceId));
      if (keepsMarker) expect(marker).toEqual({ userId: 'user-1', at: expect.any(Number) });
      else expect(marker).toBeUndefined();
    });
    expect(errors.mock.calls.flat().join(' ')).toContain(logged);
    setup.macRelay.client.close();
  });

  it('keeps a removal whose answer was lost while lookups fail, and finishes it when the same account asks again', async () => {
    const failFunctions = new Set<string>();
    const calls: string[] = [];
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const setup = await removableMac('remove-retry', { failFunctions, calls });
    loseRemovalAnswer(failFunctions);
    const before = Date.now();

    const first = await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId });

    // Convex removed the Mac, but neither its answer nor a second lookup came back.
    expect(first).toEqual({ status: 503, body: { ok: false, error: 'Account service is temporarily unavailable. Try again.' } });
    expect(setup.devices.map((row) => row.device_id)).toEqual([setup.phone.deviceId]);
    expect(errors.mock.calls.flat().join(' ')).toContain('the Mac could not be looked up again');
    await runInDurableObject(setup.signaling, async (_hub, state) => {
      const marker = await state.storage.get<{ userId: string; at: number }>(pendingKey(setup.host.deviceId));
      expect(marker).toEqual({ userId: 'user-1', at: expect.any(Number) });
      expect(marker!.at).toBeGreaterThanOrEqual(before);
    });
    // The account service answers again. Another account asking learns nothing and changes nothing.
    failFunctions.delete('findDeviceByDeviceId');
    expect(await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId }, SECOND_ACCOUNT_TOKEN))
      .toEqual({ status: 404, body: { ok: false, error: 'Mac not found' } });
    await expectMacUntouched(setup);

    // The same account asks again: the Mac is gone and its removal is pending, so it happened.
    calls.length = 0;
    const retry = await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId });

    expect(retry).toEqual({ status: 200, body: { ok: true } });
    expect(calls).not.toContain('removeHostDevice');
    await expectRemovalFinished(setup);
    expect(errors.mock.calls.flat().join(' ')).toContain("finishing an earlier removal whose answer was lost");
    // Finished: asking once more is a plain "Mac not found".
    expect(await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId }))
      .toEqual({ status: 404, body: { ok: false, error: 'Mac not found' } });
    const logged = errors.mock.calls.flat().join(' ');
    expect(logged).not.toContain(setup.host.deviceId);
    expect(logged).not.toContain('user@example.test');
  });

  it("finishes a removal whose answer was lost from the hub's alarm once Convex answers again", async () => {
    const failFunctions = new Set<string>();
    const calls: string[] = [];
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const setup = await removableMac('remove-alarm', { failFunctions, calls });
    loseRemovalAnswer(failFunctions);
    const reply = await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId });
    expect(reply.status).toBe(503);

    await runInDurableObject(setup.signaling, async (hub, state) => {
      const marker = signalingInternals(hub).pendingRemovals.get(setup.host.deviceId)!;
      expect(marker).toMatchObject({ userId: 'user-1', checkAt: marker.at + MINUTE_MS });
      // The hub's alarm is set for the marker's first check, a minute after it was written.
      expect(await state.storage.getAlarm()).toBe(marker.at + MINUTE_MS);

      // Younger than a minute: a request may still be finishing it, so the alarm leaves it alone.
      calls.length = 0;
      await hub.alarm();
      expect(calls).toEqual([]);

      // Due, but Convex still does not answer: kept, and checked again a minute later.
      marker.checkAt = Date.now() - 1;
      await hub.alarm();
      expect(calls).toEqual(['findDeviceByDeviceId']);
      expect(signalingInternals(hub).pendingRemovals.get(setup.host.deviceId)).toBe(marker);
      expect(marker.checkAt).toBeGreaterThan(Date.now());
      expect(await state.storage.getAlarm()).toBe(marker.checkAt);
      expect(await state.storage.get(removalKey(setup.host.deviceId))).toBeUndefined();

      // Convex answers: the Mac's row is gone, so the removal happened, and the alarm finishes it.
      failFunctions.delete('findDeviceByDeviceId');
      marker.checkAt = Date.now() - 1;
      await hub.alarm();
      const removedAt = await state.storage.get<number>(removalKey(setup.host.deviceId));
      expect(await state.storage.getAlarm()).toBe(removedAt! + 90 * DAY_MS);
    });
    expect(calls).not.toContain('removeHostDevice');
    await expectRemovalFinished(setup);
  });

  it('drops a pending removal after an hour while Convex still lists the Mac, and cleans up nothing', async () => {
    const failFunctions = new Set<string>();
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const setup = await removableMac('remove-stale', { failFunctions });
    // Convex fails before it commits: the Mac stays in the account.
    failFunctions.add('removeHostDevice');
    expect((await accountRequest(setup.signaling, '/account/hosts/remove', { deviceId: setup.host.deviceId })).status).toBe(503);

    await runInDurableObject(setup.signaling, async (hub, state) => {
      const marker = signalingInternals(hub).pendingRemovals.get(setup.host.deviceId)!;
      // Still listed two minutes later: kept for now.
      marker.at -= 2 * MINUTE_MS;
      marker.checkAt = Date.now() - 1;
      await hub.alarm();
      expect(signalingInternals(hub).pendingRemovals.get(setup.host.deviceId)).toBe(marker);
      expect(await state.storage.get(pendingKey(setup.host.deviceId))).toBeDefined();

      // Still listed an hour later: the removal never happened, so the marker goes and nothing else.
      marker.at -= HOUR_MS;
      marker.checkAt = Date.now() - 1;
      await hub.alarm();
      expect(signalingInternals(hub).pendingRemovals.has(setup.host.deviceId)).toBe(false);
      expect(await state.storage.get(pendingKey(setup.host.deviceId))).toBeUndefined();
      expect(await state.storage.getAlarm()).toBeNull();
    });
    await expectMacUntouched(setup);
    setup.macRelay.client.close();
  });

  it('keeps pending removals across eviction, checks them at the alarm, and drops unreadable markers', async () => {
    const host = await createDeviceIdentity();
    stubAccountPlane({ devices: [] });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remove-load-${host.deviceId}`));
    const at = Date.now();
    await runInDurableObject(signaling, async (_hub, state) => {
      await state.storage.put(pendingKey(host.deviceId), { userId: 'user-1', at });
      await state.storage.put(pendingKey('gt-unreadable'), 'not a marker');
      await state.storage.put(pendingKey('gt-no-account'), { at });
    });
    await evictDurableObject(signaling);

    await runInDurableObject(signaling, async (hub, state) => {
      expect([...signalingInternals(hub).pendingRemovals]).toEqual([[host.deviceId, { userId: 'user-1', at, checkAt: at + MINUTE_MS }]]);
      expect([...(await state.storage.list({ prefix: 'pending-removal:' })).keys()]).toEqual([pendingKey(host.deviceId)]);
      expect(await state.storage.getAlarm()).toBe(at + MINUTE_MS);
    });
  });

  it("never runs a removal's cleanup for another account's Mac or an unlinked device", async () => {
    const otherAccountMac = await createDeviceIdentity();
    const unlinked = await createDeviceIdentity();
    const calls: string[] = [];
    // A removal that reached Convex now would lose its answer and look the device up again.
    const failFunctions = new Set(['removeHostDevice']);
    stubAccountPlane({ devices: [{ ...deviceRow(otherAccountMac, 'host'), user_id: 'user-2' }], calls, failFunctions });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remove-foreign-${otherAccountMac.deviceId}`));
    const otherMac = await connectSignalingHost(signaling, otherAccountMac);
    const otherRelay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(otherAccountMac.deviceId));
    const otherMacRelay = await relayAuthenticate(otherRelay, otherAccountMac, otherAccountMac.deviceId, 'host');
    otherMacRelay.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'codex' } }));
    await waitFor(
      () => runInDurableObject(otherRelay, async (_hub, state) => !!(await state.storage.get('relayAgentSnapshot:codex'))),
      "the other account's cached content",
    );
    const unlinkedRelay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(unlinked.deviceId));
    await runInDurableObject(unlinkedRelay, (_hub, state) => state.storage.put('relayAgentSnapshot:sentinel', 'kept'));
    // Another account's removal of the unlinked device is still pending.
    const othersMarker = { userId: 'user-2', at: Date.now() };
    await runInDurableObject(signaling, async (hub, state) => {
      signalingInternals(hub).pendingRemovals.set(unlinked.deviceId, { ...othersMarker, checkAt: othersMarker.at + MINUTE_MS });
      await state.storage.put(pendingKey(unlinked.deviceId), othersMarker);
    });

    for (const deviceId of [otherAccountMac.deviceId, unlinked.deviceId]) {
      expect(await accountRequest(signaling, '/account/hosts/remove', { deviceId }))
        .toEqual({ status: 404, body: { ok: false, error: 'Mac not found' } });
    }

    expect(calls).not.toContain('removeHostDevice');
    await runInDurableObject(signaling, async (_hub, state) => {
      expect([...(await state.storage.list({ prefix: 'removed-host:' })).keys()]).toEqual([]);
      expect(Object.fromEntries(await state.storage.list({ prefix: 'pending-removal:' }))).toEqual({
        [pendingKey(unlinked.deviceId)]: othersMarker,
      });
    });
    await roundTrip(otherMac);
    expect(hostIdentities(otherMac)).toEqual([expect.objectContaining({ linked: true, user_id: 'user-2' })]);
    await expect(hubHealth(otherRelay)).resolves.toMatchObject({ hostOnline: true });
    await runInDurableObject(otherRelay, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:codex')).toBeDefined();
    });
    await runInDurableObject(unlinkedRelay, async (_hub, state) => {
      expect(await state.storage.get('relayAgentSnapshot:sentinel')).toBe('kept');
    });
    otherMacRelay.client.close();
  });

  it('tells a Mac that was offline when it was removed why it is unlinked, until it is linked again', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const devices: Record<string, unknown>[] = [
      { ...deviceRow(host, 'host'), created_at: '2026-08-01T10:00:00.000Z' },
      deviceRow(phone, 'phone'),
    ];
    stubAccountPlane({ devices });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remember-${host.deviceId}`));

    const before = Date.now();
    const removed = await accountRequest(signaling, '/account/hosts/remove', { deviceId: host.deviceId });
    expect(removed).toEqual({ status: 200, body: { ok: true } });
    await runInDurableObject(signaling, async (_hub, state) => {
      const removedAt = await state.storage.get<number>(removalKey(host.deviceId));
      expect(removedAt).toBeGreaterThanOrEqual(before);
      // Kept 90 days; the hub's cleanup alarm is set for that moment.
      expect(await state.storage.getAlarm()).toBe(removedAt! + 90 * DAY_MS);
    });

    // Remembered across eviction: the Mac learns the reason when it comes back.
    await evictDurableObject(signaling);
    const mac = await connectSignalingHost(signaling, host);
    await roundTrip(mac);
    expect(hostIdentities(mac)).toEqual([{ type: 'host_identity', linked: false, reason: 'removed_from_account' }]);

    // Linked again with a new code from the Mac: the record is deleted, and
    // so is a removal still pending for the Mac.
    await runInDurableObject(signaling, async (hub, state) => {
      const at = Date.now();
      signalingInternals(hub).pendingRemovals.set(host.deviceId, { userId: 'user-1', at, checkAt: at + 60_000 });
      await state.storage.put(`pending-removal:${host.deviceId}`, { userId: 'user-1', at });
    });
    mac.client.send(JSON.stringify({ type: 'create_link_code', host_label: 'Studio Mac mini' }));
    await waitFor(() => mac.messages.some((m) => m.type === 'link_code_created'), 'a link code');
    const code = String(mac.messages.find((m) => m.type === 'link_code_created')?.code);
    const claimed = await accountRequest(signaling, '/account/claim-host-code', { code, requesterDeviceId: phone.deviceId });
    expect(claimed.status).toBe(200);
    await waitFor(() => hostIdentities(mac).some((m) => m.linked === true), 'the link notice');
    expect(hostIdentities(mac).at(-1)).toMatchObject({ linked: true, user_id: 'user-1', host_label: 'Studio Mac mini' });
    await runInDurableObject(signaling, async (hub, state) => {
      expect(await state.storage.get(removalKey(host.deviceId))).toBeUndefined();
      expect(signalingInternals(hub).pendingRemovals.has(host.deviceId)).toBe(false);
      expect(await state.storage.get(`pending-removal:${host.deviceId}`)).toBeUndefined();
    });
    const reconnected = await connectSignalingHost(signaling, host);
    await roundTrip(reconnected);
    expect(hostIdentities(reconnected)).toEqual([
      expect.objectContaining({ linked: true, user_id: 'user-1', host_label: 'Studio Mac mini' }),
    ]);
  });

  it('links a Mac under its proposed name made to follow the name rule', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const devices: Record<string, unknown>[] = [deviceRow(phone, 'phone')];
    const linkCodes: Record<string, unknown>[] = [];
    stubAccountPlane({ devices, linkCodes });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`proposed-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    expect(hostIdentities(mac)).toEqual([{ type: 'host_identity', linked: false }]);

    // A computer name with a direction override, a zero width space and a line break.
    const proposed = `Studio${String.fromCodePoint(0x202e)} Mac${String.fromCodePoint(0x200b)}\nmini`;
    mac.client.send(JSON.stringify({ type: 'create_link_code', host_label: proposed }));
    await waitFor(() => mac.messages.some((m) => m.type === 'link_code_created'), 'a link code');
    expect(linkCodes).toEqual([expect.objectContaining({ host_label: 'Studio Mac mini' })]);

    const code = String(mac.messages.find((m) => m.type === 'link_code_created')?.code);
    const claimed = await accountRequest(signaling, '/account/claim-host-code', { code, requesterDeviceId: phone.deviceId });
    expect(claimed.status).toBe(200);
    expect(devices.find((row) => row.device_id === host.deviceId)).toMatchObject({ label: 'Studio Mac mini' });
    await waitFor(() => hostIdentities(mac).some((m) => m.linked === true), 'the link notice');
    expect(hostIdentities(mac).at(-1)).toMatchObject({ linked: true, host_label: 'Studio Mac mini' });
  });

  it.each([
    ['ignores a removal record older than the Mac\'s current account row', -DAY_MS, { linked: true }],
    ['applies a removal record to an account row older than it', DAY_MS, { linked: false, reason: 'removed_from_account' }],
  ] as const)('%s', async (_label, removedAfterCreationMs, expected) => {
    const host = await createDeviceIdentity();
    const createdAt = Date.now() - 2 * DAY_MS;
    // A stale read can still return the removed row; a later link creates a newer one.
    stubAccountPlane({ devices: [{ ...deviceRow(host, 'host'), created_at: new Date(createdAt).toISOString() }] });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remember-stale-${host.deviceId}`));
    await runInDurableObject(signaling, async (_hub, state) => {
      await state.storage.put(removalKey(host.deviceId), createdAt + removedAfterCreationMs);
    });
    await evictDurableObject(signaling);

    const mac = await connectSignalingHost(signaling, host);

    expect(hostIdentities(mac)).toEqual([expect.objectContaining(expected)]);
  });

  it('forgets a removal after 90 days, on load and from the cleanup alarm', async () => {
    const host = await createDeviceIdentity();
    const recentHost = await createDeviceIdentity();
    stubAccountPlane({ devices: [] });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`remember-expiry-${host.deviceId}`));
    const recentAt = Date.now() - DAY_MS;
    await runInDurableObject(signaling, async (_hub, state) => {
      await state.storage.put(removalKey(host.deviceId), Date.now() - 91 * DAY_MS);
      await state.storage.put(removalKey(recentHost.deviceId), recentAt);
    });
    await evictDurableObject(signaling);

    const mac = await connectSignalingHost(signaling, host);
    const recent = await connectSignalingHost(signaling, recentHost);

    expect(hostIdentities(mac)).toEqual([{ type: 'host_identity', linked: false }]);
    expect(hostIdentities(recent)).toEqual([{ type: 'host_identity', linked: false, reason: 'removed_from_account' }]);
    await runInDurableObject(signaling, async (hub, state) => {
      expect(await state.storage.get(removalKey(host.deviceId))).toBeUndefined();
      expect(await state.storage.get(removalKey(recentHost.deviceId))).toBe(recentAt);
      expect(await state.storage.getAlarm()).toBe(recentAt + 90 * DAY_MS);

      // A record that expires while the hub stays loaded goes at its alarm.
      const removedHosts = (hub as unknown as { removedHosts: Map<string, number> }).removedHosts;
      removedHosts.set(recentHost.deviceId, Date.now() - 90 * DAY_MS);
      await hub.alarm();
      expect(removedHosts.has(recentHost.deviceId)).toBe(false);
      expect(await state.storage.get(removalKey(recentHost.deviceId))).toBeUndefined();
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });

  it('signs a Mac out from the Mac: browsers cut off and caches cleared at once, without the removal reason', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    const phoneRow = deviceRow(phone, 'phone');
    const devices = [hostRow, phoneRow];
    const pairings = [{
      id: 'pair-1', owner_user_id: 'user-1', host_device_uuid: hostRow.id, phone_device_uuid: phoneRow.id,
      paired_at: new Date().toISOString(), revoked_at: null, metadata: {},
    }];
    stubAccountPlane({ devices, pairings });

    // Signaling in both directions, so the hub caches both authorizations.
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`signout-${host.deviceId}`));
    const macSignal = await connectSignalingHost(signaling, host);
    const phoneSignal = await openHubSocket(signaling, '/signal');
    phoneSignal.client.send(await signedClientAuth(phone, phoneSignal.nonce, 'client'));
    await expect(phoneSignal.nextMessage()).resolves.toMatchObject({ type: 'auth_ok' });
    phoneSignal.client.send(JSON.stringify({ fromDeviceId: phone.deviceId, toDeviceId: host.deviceId, payload: { kind: 'ping' }, envelopeId: 'offer' }));
    await waitFor(() => macSignal.messages.some((m) => m.envelopeId === 'offer'), 'browser signaling');
    await runInDurableObject(signaling, (hub) => hub.webSocketMessage(
      signalingInternals(hub).peers.get(host.deviceId)!,
      JSON.stringify({ fromDeviceId: host.deviceId, toDeviceId: phone.deviceId, payload: { kind: 'ping' }, envelopeId: 'answer' }),
    ));
    await waitFor(() => phoneSignal.messages.some((m) => m.envelopeId === 'answer'), 'Mac signaling');
    const pair = `${phone.deviceId}->${host.deviceId}`;
    await runInDurableObject(signaling, (hub) => {
      expect(signalingInternals(hub).accountAuthorizationCache.has(pair)).toBe(true);
      expect(signalingInternals(hub).hostEnvelopeAuthorizations.has(pair)).toBe(true);
    });
    const relay = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const macRelay = await relayAuthenticate(relay, host, host.deviceId, 'host');
    const phoneRelay = await relayAuthenticate(relay, phone, host.deviceId, 'client');
    macRelay.client.send(JSON.stringify({ type: 'relay_agent_state', snapshot: { agentId: 'codex', marker: 'before' } }));
    await waitFor(() => phoneRelay.messages.some((m) => m.type === 'relay_agent_state'), 'content before sign-out');

    // An earlier removal of this Mac is still pending (its answer was lost).
    await runInDurableObject(signaling, async (hub, state) => {
      const at = Date.now();
      signalingInternals(hub).pendingRemovals.set(host.deviceId, { userId: 'user-1', at, checkAt: at + 60_000 });
      await state.storage.put(`pending-removal:${host.deviceId}`, { userId: 'user-1', at });
    });

    macSignal.client.send(JSON.stringify({ type: 'unlink_host' }));

    await waitFor(() => macSignal.messages.some((m) => m.type === 'host_unlinked'), 'the sign-out answer');
    expect(macSignal.messages.find((m) => m.type === 'host_unlinked')).toMatchObject({ ok: true, linked: false });
    expect(devices.map((row) => row.device_id)).toEqual([phone.deviceId]);
    expect(pairings).toEqual([]);
    // The account's browsers lose relay access now, and the relay's copies are deleted.
    await expect(phoneRelay.closed).resolves.toEqual(REMOVED);
    await expect(macRelay.closed).resolves.toEqual(REMOVED);
    await waitFor(
      () => runInDurableObject(relay, async (_hub, state) => (await state.storage.get('relayAgentSnapshot:codex')) === undefined),
      'the relay cache deletion',
    );
    // The Sign Out ran the cleanup: the pending removal has nothing left to finish.
    await waitFor(
      () => runInDurableObject(signaling, (hub) => !signalingInternals(hub).pendingRemovals.has(host.deviceId)),
      'the pending removal to be dropped',
    );
    await runInDurableObject(signaling, async (hub, state) => {
      expect(signalingInternals(hub).accountAuthorizationCache.has(pair)).toBe(false);
      expect(signalingInternals(hub).hostEnvelopeAuthorizations.has(pair)).toBe(false);
      expect([...(await state.storage.list({ prefix: 'removed-host:' })).keys()]).toEqual([]);
      expect([...(await state.storage.list({ prefix: 'pending-removal:' })).keys()]).toEqual([]);
    });
    // Signed out, not removed: no removal reason now or at the next connection.
    expect(hostIdentities(macSignal).at(-1)).toEqual({ type: 'host_identity', linked: false });
    expect(hostIdentities(macSignal).some((m) => 'reason' in m)).toBe(false);
    const reconnected = await connectSignalingHost(signaling, host);
    expect(hostIdentities(reconnected)).toEqual([{ type: 'host_identity', linked: false }]);
  });

  it('never sends linked:true for a rename that loses a race with the Mac\'s removal', async () => {
    const host = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host')];
    stubAccountPlane({ devices });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-remove-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    // The rename commits and then waits for the profile while the removal lands.
    const gate = stubAccountPlane({ devices, gateOn: 'profile-lookup' });
    const renaming = accountRequest(signaling, '/account/hosts/rename', { deviceId: host.deviceId, label: 'Renamed Mac' });
    await waitFor(() => gate.reached, 'the rename to wait for the profile');

    const removed = await accountRequest(signaling, '/account/hosts/remove', { deviceId: host.deviceId });
    gate.release();

    expect(removed).toEqual({ status: 200, body: { ok: true } });
    expect((await renaming).status).toBe(200);
    await roundTrip(mac);
    expect(hostIdentities(mac).slice(1)).toEqual([{ type: 'host_identity', linked: false, reason: 'removed_from_account' }]);
  });

  // Where the rename's own lookups wait while the Mac's account changes:
  // before its device lookup, before its profile lookup (the device lookup
  // follows it), or with a device lookup that read the row before the change.
  it.each([
    ['is signed out on the Mac', 'device-lookup', 1],
    ['is signed out on the Mac', 'profile-lookup', 1],
    ['is signed out on the Mac', 'device-lookup-reply', 1],
    ['is linked to another account', 'device-lookup', 0],
    ['is linked to another account', 'profile-lookup', 0],
    ['is revoked', 'device-lookup', 0],
    ['is revoked', 'profile-lookup', 0],
  ] as const)('never sends linked:true for a rename while the Mac %s (rename waiting at %s)', async (scenario, gateOn, unlinkedNotices) => {
    const host = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    const devices = [hostRow];
    stubAccountPlane({ devices });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-rename-${gateOn}-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    // The rename commits and then loads the profile and looks the Mac up again; one of those waits.
    const gate = stubAccountPlane({ devices, gateOn });
    const renaming = accountRequest(signaling, '/account/hosts/rename', { deviceId: host.deviceId, label: 'Renamed Mac' });
    await waitFor(() => gate.reached, 'the rename to wait for the account service');

    if (scenario === 'is signed out on the Mac') {
      mac.client.send(JSON.stringify({ type: 'unlink_host' }));
      await waitFor(() => mac.messages.some((m) => m.type === 'host_unlinked'), 'the sign-out answer');
    } else if (scenario === 'is linked to another account') {
      hostRow.user_id = 'user-2';
    } else {
      hostRow.revoked_at = new Date().toISOString();
    }
    gate.release();

    expect((await renaming).status).toBe(200);
    await roundTrip(mac);
    const later = hostIdentities(mac).slice(1);
    expect(later.some((m) => m.linked === true)).toBe(false);
    expect(later).toHaveLength(unlinkedNotices);
  });

  it('never sends linked:true for a rename that runs while a Sign Out on the Mac is still deleting its rows', async () => {
    const host = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host')];
    stubAccountPlane({ devices });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-signout-first-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    // The Sign Out starts first and waits at its own device lookup; the rename
    // then runs start to finish while the Mac's rows still exist.
    const gate = stubAccountPlane({ devices, gateOn: 'device-lookup' });
    mac.client.send(JSON.stringify({ type: 'unlink_host' }));
    await waitFor(() => gate.reached, 'the Sign Out to wait for its device lookup');

    const renamed = await accountRequest(signaling, '/account/hosts/rename', { deviceId: host.deviceId, label: 'Renamed Mac' });
    expect(renamed.status).toBe(200);
    await roundTrip(mac);
    expect(hostIdentities(mac).slice(1).some((m) => m.linked === true)).toBe(false);

    gate.release();
    await waitFor(() => mac.messages.some((m) => m.type === 'host_unlinked'), 'the sign-out answer');
    await roundTrip(mac);
    const later = hostIdentities(mac).slice(1);
    expect(later.some((m) => m.linked === true)).toBe(false);
    expect(later.at(-1)).toEqual({ type: 'host_identity', linked: false });
  });

  it('never sends linked:true to a Mac whose identity lookup read its row before it signed out', async () => {
    const host = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host')];
    // The Mac's second lookup at sign-in reads its linked row, then answers only after the Sign Out.
    const gate = stubAccountPlane({ devices, gateOn: 'device-lookup-reply', gateSkip: 1 });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-signout-connect-${host.deviceId}`));
    const socket = await openHubSocket(signaling, '/signal');
    socket.client.send(await signedClientAuth(host, socket.nonce, 'host'));
    await waitFor(() => gate.reached, "the Mac's identity lookup to hold a linked row");

    socket.client.send(JSON.stringify({ type: 'unlink_host' }));
    await waitFor(() => socket.messages.some((m) => m.type === 'host_unlinked'), 'the sign-out answer');
    expect(devices).toEqual([]);
    gate.release();

    await waitFor(() => hostIdentities(socket).length >= 2, 'both identities');
    await roundTrip(socket);
    expect(hostIdentities(socket)).toEqual([
      { type: 'host_identity', linked: false },
      { type: 'host_identity', linked: false },
    ]);
  });

  it.each([
    // The new account's link tells the Mac itself; this sign-in sends nothing.
    ['is linked to another account', []],
    ['is revoked', [{ type: 'host_identity', linked: false }]],
  ] as const)('never sends linked:true to a Mac that signs in while it %s', async (scenario, expected) => {
    const host = await createDeviceIdentity();
    const hostRow = deviceRow(host, 'host');
    // The Mac's sign-in waits for the profile; its device lookup again comes after it.
    const gate = stubAccountPlane({ devices: [hostRow], gateOn: 'profile-lookup' });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-signin-${host.deviceId}`));
    const socket = await openHubSocket(signaling, '/signal');
    socket.client.send(await signedClientAuth(host, socket.nonce, 'host'));
    await waitFor(() => gate.reached, "the Mac's identity to wait for the profile");

    if (scenario === 'is linked to another account') hostRow.user_id = 'user-2';
    else hostRow.revoked_at = new Date().toISOString();
    gate.release();

    await roundTrip(socket);
    expect(hostIdentities(socket)).toEqual(expected);
  });

  it('never sends linked:true to a Mac that reconnects while it is being removed', async () => {
    const host = await createDeviceIdentity();
    const devices = [deviceRow(host, 'host')];
    const gate = stubAccountPlane({ devices, gateOn: 'profile-lookup' });
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`race-reconnect-${host.deviceId}`));
    const socket = await openHubSocket(signaling, '/signal');
    socket.client.send(await signedClientAuth(host, socket.nonce, 'host'));
    await waitFor(() => gate.reached, "the Mac's identity to wait for the profile");

    const removed = await accountRequest(signaling, '/account/hosts/remove', { deviceId: host.deviceId });
    gate.release();

    expect(removed).toEqual({ status: 200, body: { ok: true } });
    await waitFor(() => hostIdentities(socket).length >= 2, 'both identities');
    await roundTrip(socket);
    expect(hostIdentities(socket)).toEqual([
      { type: 'host_identity', linked: false, reason: 'removed_from_account' },
      { type: 'host_identity', linked: false, reason: 'removed_from_account' },
    ]);
  });

  it('answers 200 with the renamed Mac when the reply\'s other details cannot be loaded', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const hostRow: Record<string, unknown> = { ...deviceRow(host, 'host'), created_at: '2026-08-01T10:00:00.000Z' };
    const failFunctions = new Set<string>();
    stubAccountPlane({ devices: [hostRow, deviceRow(phone, 'phone')], failFunctions });
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const signaling = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`rename-degraded-${host.deviceId}`));
    const mac = await connectSignalingHost(signaling, host);
    failFunctions.add('findActivePairing');

    const reply = await accountRequest(signaling, '/account/hosts/rename', {
      deviceId: host.deviceId, label: 'Studio Mac', requesterDeviceId: phone.deviceId,
    });

    expect(reply.status).toBe(200);
    expect(reply.body).toMatchObject({
      ok: true,
      host: {
        deviceId: host.deviceId, label: 'Studio Mac', trusted: true, online: false,
        pairedAtUnixMs: Date.parse('2026-08-01T10:00:00.000Z'), addedAtUnixMs: Date.parse('2026-08-01T10:00:00.000Z'),
      },
    });
    expect(hostRow.label).toBe('Studio Mac');
    await waitFor(() => hostIdentities(mac).some((m) => m.host_label === 'Studio Mac'), 'the renamed host identity');
    expect(errors.mock.calls.flat().join(' ')).toContain('host record details unavailable');
  });
});
