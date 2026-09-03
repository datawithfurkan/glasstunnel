import { runInDurableObject } from "cloudflare:test";
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
}

type SupabaseGatePoint = 'device-lookup' | 'last-seen-touch' | 'auth-user';

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
  const waiters: Array<(message: Record<string, unknown>) => void> = [];
  client.addEventListener('message', (event) => {
    const message = JSON.parse(String(event.data)) as Record<string, unknown>;
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else backlog.push(message);
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    client.addEventListener('close', (event) => resolve({ code: event.code, reason: event.reason }));
  });
  client.accept();

  const nextMessage = () => {
    const queued = backlog.shift();
    return queued ? Promise.resolve(queued) : new Promise<Record<string, unknown>>((resolve) => waiters.push(resolve));
  };
  const hello = await nextMessage();
  expect(hello).toMatchObject({ type: 'server_hello' });
  return { client, nonce: String(hello.nonce), nextMessage, closed };
}

function deviceRow(identity: DeviceIdentity, kind: 'host' | 'phone'): Record<string, unknown> {
  return {
    id: `${kind}-${identity.deviceId}`,
    user_id: 'user-1',
    device_id: identity.deviceId,
    public_key_b64: identity.publicKeyB64,
    kind,
    revoked_at: null,
  };
}

/**
 * Replaces the Worker's outbound fetch with a fake Supabase that can pause exactly one
 * call. Pausing gives the test a deterministic window in which the socket under test
 * closes while the hub's auth handler is still awaiting.
 */
function stubSupabase(options: { gateOn?: SupabaseGatePoint; devices?: Record<string, unknown>[] }) {
  let release: () => void = () => {};
  const released = new Promise<void>((resolve) => {
    release = resolve;
  });
  const gate = { reached: false, release, released };
  const devices = options.devices ?? [];

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
      return Response.json({ id: 'user-1', email: 'user@example.test' });
    }
    if (url.pathname === '/rest/v1/devices' && method === 'GET') {
      await pauseIf('device-lookup');
      const wanted = url.searchParams.get('device_id')?.replace(/^eq\./, '');
      return Response.json(devices.filter((row) => row.device_id === wanted));
    }
    if (url.pathname === '/rest/v1/devices' && method === 'PATCH') {
      await pauseIf('last-seen-touch');
      return new Response(null, { status: 204 });
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

  it('forwards a relay_message_detail only to the client it names', async () => {
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
    hostSocket.client.send(JSON.stringify({ type: 'relay_message_detail', client_device_id: phoneA.deviceId, detail }));
    await expect(socketA.nextMessage()).resolves.toMatchObject({ type: 'relay_message_detail', detail });

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
