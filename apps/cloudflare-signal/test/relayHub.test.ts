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

type SupabaseGatePoint = 'device-lookup' | 'last-seen-touch' | 'auth-user' | 'device-update';

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
  return {
    id: `${kind}-${identity.deviceId}`,
    user_id: 'user-1',
    device_id: identity.deviceId,
    public_key_b64: identity.publicKeyB64,
    kind,
    label: 'Disposable browser',
    created_at: new Date().toISOString(),
    revoked_at: null,
  };
}

/**
 * Replaces the Worker's outbound fetch with a fake Supabase that can pause exactly one
 * call. Pausing gives the test a deterministic window in which the socket under test
 * closes while the hub's auth handler is still awaiting.
 */
function stubSupabase(options: {
  gateOn?: SupabaseGatePoint;
  devices?: Record<string, unknown>[];
  pairings?: Record<string, unknown>[];
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

  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    const method = (init?.method ?? 'GET').toUpperCase();
    const pauseIf = async (point: SupabaseGatePoint) => {
      if (options.gateOn !== point || gate.reached) return;
      gate.reached = true;
      await gate.released;
    };

    if (url.pathname === '/auth/v1/user') {
      await pauseIf('auth-user');
      if (options.failAuth) return Response.json({ error: 'expired token' }, { status: 401 });
      return Response.json({ id: 'user-1', email: 'user@example.test' });
    }
    if (url.pathname === '/rest/v1/profiles' || url.pathname === '/rest/v1/device_approval_requests') {
      return Response.json([]);
    }
    if (url.pathname === '/rest/v1/devices' && method === 'GET') {
      await pauseIf('device-lookup');
      const wanted = url.searchParams.get('device_id')?.replace(/^eq\./, '');
      const kind = url.searchParams.get('kind')?.replace(/^eq\./, '');
      return Response.json(devices.filter((row) =>
        (!wanted || row.device_id === wanted) && (!kind || row.kind === kind) &&
        (url.searchParams.get('revoked_at') !== 'is.null' || row.revoked_at == null),
      ));
    }
    if (url.pathname === '/rest/v1/devices' && method === 'POST') {
      const payload = JSON.parse(String(init?.body)) as Record<string, unknown>;
      const existing = devices.find((row) => row.device_id === payload.device_id);
      if (existing) Object.assign(existing, payload);
      else devices.push({ id: `new-${payload.device_id}`, revoked_at: null, ...payload });
      return Response.json(devices.filter((row) => row.device_id === payload.device_id));
    }
    if (url.pathname === '/rest/v1/devices' && method === 'PATCH') {
      const payload = JSON.parse(String(init?.body)) as Record<string, unknown>;
      if ('label' in payload) {
        await pauseIf('device-update');
        const id = url.searchParams.get('id')?.replace(/^eq\./, '');
        const user = url.searchParams.get('user_id')?.replace(/^eq\./, '');
        const rows = devices.filter((row) => row.id === id && row.user_id === user &&
          (url.searchParams.get('revoked_at') !== 'is.null' || row.revoked_at == null));
        for (const row of rows) Object.assign(row, payload);
        return Response.json(rows);
      }
      await pauseIf('last-seen-touch');
      return new Response(null, { status: 204 });
    }
    if (url.pathname === '/rest/v1/device_pairings' && method === 'GET') {
      const host = url.searchParams.get('host_device_uuid')?.replace(/^eq\./, '');
      const phone = url.searchParams.get('phone_device_uuid')?.replace(/^eq\./, '');
      return Response.json(pairings.filter((row) =>
        (!host || row.host_device_uuid === host) && (!phone || row.phone_device_uuid === phone) &&
        (url.searchParams.get('revoked_at') !== 'not.is.null' || row.revoked_at != null) &&
        (url.searchParams.get('revoked_at') !== 'is.null' || row.revoked_at == null),
      ));
    }
    if (url.pathname === '/rest/v1/device_pairings' && method === 'POST') {
      if (options.failPairingWrites) return Response.json({ error: 'unavailable' }, { status: 503 });
      const row = { id: `pair-${pairings.length}`, paired_at: new Date().toISOString(), revoked_at: null, ...JSON.parse(String(init?.body)) };
      pairings.push(row);
      return Response.json([row]);
    }
    if (url.pathname === '/rest/v1/device_pairings' && method === 'PATCH') {
      const host = url.searchParams.get('host_device_uuid')?.replace(/^eq\./, '');
      const phone = url.searchParams.get('phone_device_uuid')?.replace(/^eq\./, '');
      const rows = pairings.filter((row) => row.host_device_uuid === host && row.phone_device_uuid === phone);
      for (const row of rows) Object.assign(row, JSON.parse(String(init?.body)));
      return Response.json(rows);
    }
    throw new Error(`unexpected outbound fetch: ${method} ${url.href}`);
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
      stubSupabase({ devices: scenario === 'missing' ? [] : [row] });
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
    stubSupabase({ devices: [hostRow, phoneRow], pairings: [{
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
      stubSupabase({ devices: [row] });
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
    stubSupabase({ devices: [row] });
    const stub = env.SIGNALING_HUB.get(env.SIGNALING_HUB.idFromName(`refresh-${phone.deviceId}`));
    const response = await stub.fetch('https://hub.test/account/device/register', {
      method: 'POST', headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: phone.deviceId, publicKeyB64: phone.publicKeyB64, kind: 'phone', label: 'Renamed browser' }),
    });
    expect(response.status).toBe(200);
    expect(row).toMatchObject({ user_id: 'user-1', public_key_b64: phone.publicKeyB64, revoked_at: null, label: 'Renamed browser' });
  });

  it('cannot clear a revocation that arrives between lookup and registration write', async () => {
    const phone = await createDeviceIdentity();
    const row = deviceRow(phone, 'phone');
    const gate = stubSupabase({ devices: [row], gateOn: 'device-update' });
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
    stubSupabase(options);
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(otherHost, 'host'), deviceRow(phone, 'phone'), { ...deviceRow(foreign, 'phone'), user_id: 'another-user' }] });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')], failAuth: true });
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const client = await openHubSocket(stub, relayPath(host.deviceId));
    client.client.send(await signedClientAuth(phone, client.nonce, 'client', { access_token: 'expired' }));
    await expect(client.closed).resolves.toMatchObject({ code: 1008 });
    expect(client.messages.some((m) => m.type === 'auth_ok' || m.type === 'relay_agent_state')).toBe(false);
  });

  it('tells the Mac about relay-only browsers and restores that list after host reconnect', async () => {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')], pairings });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone'), deviceRow(other, 'phone')] });
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
    const gate = stubSupabase({ gateOn: 'device-lookup', devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone'), { ...deviceRow(foreign, 'phone'), user_id: 'other-user' }] });
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
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });
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
  it('survives a quick host reconnect that replaces a socket whose auth is still awaiting Supabase', async () => {
    const host = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const supabase = stubSupabase({ gateOn: 'last-seen-touch', devices: [deviceRow(host, 'host')] });

    const stale = await openHubSocket(stub, relayPath(host.deviceId));
    const staleAuth = driveAuth(stub, await signedClientAuth(host, stale.nonce, 'host'));
    await waitFor(() => supabase.reached, 'the stale auth to reach the last-seen touch');

    // The host reconnects before the first auth finishes; the hub closes the stale socket.
    const fresh = await openHubSocket(stub, relayPath(host.deviceId));
    fresh.client.send(await signedClientAuth(host, fresh.nonce, 'host'));
    await expect(fresh.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await expect(stale.closed).resolves.toEqual({ code: 1000, reason: 'replaced by newer host relay' });

    await runInDurableObject(stub, () => supabase.release());
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

  it.each<[string, SupabaseGatePoint]>([
    ['device lookup', 'device-lookup'],
    ['last-seen touch', 'last-seen-touch'],
  ])('forgets a host socket the peer closed during the %s', async (label, gateOn) => {
    const host = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    const supabase = stubSupabase({ gateOn, devices: [deviceRow(host, 'host')] });

    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    const auth = driveAuth(stub, await signedClientAuth(host, socket.nonce, 'host'));
    await waitFor(() => supabase.reached, `the auth to reach the ${label}`);

    socket.client.close(1000, 'relay reconnect');
    await waitFor(
      () => runInDurableObject(stub, (hub, state) => state.getWebSockets().length === 0 && relayInternals(hub).sessions.size === 0),
      'the hub to process the close',
    );
    await runInDurableObject(stub, () => supabase.release());
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
    const supabase = stubSupabase({
      gateOn: 'auth-user',
      devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')],
    });

    const socket = await openHubSocket(stub, relayPath(host.deviceId));
    const auth = driveAuth(
      stub,
      await signedClientAuth(phone, socket.nonce, 'client', { access_token: 'phone-access-token' }),
    );
    await waitFor(() => supabase.reached, 'the auth to reach the account lookup');

    socket.client.close(1000, 'app backgrounded');
    await waitFor(
      () => runInDurableObject(stub, (hub, state) => state.getWebSockets().length === 0 && relayInternals(hub).sessions.size === 0),
      'the hub to process the close',
    );
    await runInDurableObject(stub, () => supabase.release());
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
    const supabase = stubSupabase({ gateOn: 'last-seen-touch' });

    const stale = await openHubSocket(stub, '/signal');
    const staleAuth = driveAuth(stub, await signedClientAuth(host, stale.nonce, 'host'));
    await expect(stale.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await waitFor(() => supabase.reached, 'the stale auth to reach the last-seen touch');

    const fresh = await openHubSocket(stub, '/signal');
    fresh.client.send(await signedClientAuth(host, fresh.nonce, 'host'));
    await expect(fresh.nextMessage()).resolves.toMatchObject({ type: 'auth_ok', device_id: host.deviceId });
    await expect(stale.closed).resolves.toEqual({ code: 1000, reason: 'replaced by newer connection' });

    await runInDurableObject(stub, () => supabase.release());
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
    const supabase = stubSupabase({
      gateOn: 'last-seen-touch',
      devices: [deviceRow(host, 'host'), deviceRow(phoneA, 'phone'), deviceRow(phoneB, 'phone')],
    });
    supabase.release();

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

describe('RelayHub host liveness', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  async function connectHostAndPhone() {
    const host = await createDeviceIdentity();
    const phone = await createDeviceIdentity();
    const stub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(host.deviceId));
    stubSupabase({ devices: [deviceRow(host, 'host'), deviceRow(phone, 'phone')] });

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
