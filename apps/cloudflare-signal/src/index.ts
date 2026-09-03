import { DurableObject } from "cloudflare:workers";
import {
  compactRelayAgentSnapshot,
  type CacheJsonValue,
} from "./relaySnapshotCache";

export interface Env {
  SIGNALING_HUB: DurableObjectNamespace;
  RELAY_HUB: DurableObjectNamespace;
  ACCOUNT_RATE_LIMITER: RateLimit;
  ACCOUNT_ADDRESS_RATE_LIMITER: RateLimit;
  UPGRADE_RATE_LIMITER: RateLimit;
  PUBLIC_APP_URL: string;
  ALLOWED_ORIGINS?: string;
  SUPABASE_URL?: string;
  SUPABASE_SERVICE_ROLE_KEY?: string;
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string;
  VAPID_SUBJECT?: string;
}

type JsonPrimitive = string | number | boolean | null;
type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };

type WebSocketWithAttachment = WebSocket & {
  serializeAttachment(value: SessionAttachment | RelaySessionAttachment): void;
  deserializeAttachment(): SessionAttachment | RelaySessionAttachment | null;
};

interface SessionAttachment {
  authenticated: boolean;
  deviceId?: string;
  publicKeyB64?: string;
  role?: string;
  issuedAt: number;
  nonceB64: string;
}

interface RelaySessionAttachment {
  kind: "relay";
  authenticated: boolean;
  deviceId?: string;
  publicKeyB64?: string;
  role?: "host" | "client";
  userId?: string;
  hostDeviceId: string;
  issuedAt: number;
  nonceB64: string;
}

interface RelayCommandMessage {
  messageId?: string;
  atUnixMs?: number;
  body?: JsonValue;
}

interface QueuedEnvelope {
  raw: string;
  enqueuedAt: number;
}

interface AccountAuthorizationCacheEntry {
  requesterDeviceId: string;
  requesterPublicKeyB64: string;
  requesterLabel: string;
  pairedAt: string;
  expiresAt: number;
  notifiedHostSessionIssuedAt?: number;
}

interface ControlMessage {
  type: string;
  [key: string]: unknown;
}

interface EnvelopePayload {
  kind?: string;
  [key: string]: unknown;
}

interface EnvelopeLike {
  envelopeId?: string;
  fromDeviceId?: string;
  toDeviceId?: string;
  payload?: EnvelopePayload;
}

interface SupabaseAuthUser {
  id: string;
  email?: string | null;
  user_metadata?: Record<string, unknown> | null;
}

interface ProfileRow {
  user_id: string;
  email: string | null;
  display_name: string | null;
  avatar_url: string | null;
}

interface DeviceRow {
  id: string;
  user_id: string;
  device_id: string;
  public_key_b64: string;
  label: string;
  kind: "host" | "phone" | "browser";
  platform: string | null;
  app_version: string | null;
  last_seen_at: string | null;
  revoked_at: string | null;
  metadata: Record<string, JsonValue> | null;
  created_at: string;
  updated_at: string;
}

interface DevicePairingRow {
  id: string;
  owner_user_id: string;
  host_device_uuid: string;
  phone_device_uuid: string;
  paired_at: string;
  revoked_at: string | null;
}

interface HostLinkCodeRow {
  id: string;
  code: string;
  host_device_id: string;
  host_public_key_b64: string;
  host_label: string;
  host_metadata: Record<string, JsonValue> | null;
  created_at: string;
  expires_at: string;
  consumed_at: string | null;
  claimed_user_id: string | null;
}

interface DeviceApprovalRequestRow {
  id: string;
  owner_user_id: string;
  host_device_uuid: string;
  requester_device_uuid: string;
  requester_device_id: string;
  requester_public_key_b64: string;
  requester_label: string;
  status: "pending" | "approved" | "rejected" | "expired" | "cancelled";
  metadata: Record<string, JsonValue> | null;
  created_at: string;
  updated_at: string;
  responded_at: string | null;
}

interface PublicHostRecord {
  deviceId: string;
  publicKeyB64: string;
  label: string;
  signalingUrl: string;
  turnUrl?: string;
  turnUsername?: string;
  turnPassword?: string;
  online: boolean;
  trusted: boolean;
  pairedAtUnixMs: number;
  lastSeenAtUnixMs?: number;
}

const VERSION = "0.1.0";
const NONCE_TTL_MS = 30_000;
const OFFLINE_QUEUE_TTL_MS = 60_000;
const HOST_LINK_CODE_TTL_MS = 10 * 60_000;
const APPROVAL_REQUEST_TTL_MS = 10 * 60_000;
const MAX_QUEUED_PER_PEER = 256;
const LAST_SEEN_TOUCH_MIN_INTERVAL_MS = 60_000;
const ACCOUNT_AUTH_CACHE_TTL_MS = 2 * 60_000;
const GLOBAL_HUB_NAME = "global";
const STORAGE_OFFLINE_QUEUES_KEY = "offlineQueues";
const STORAGE_RELAY_REMOTE_APPS_KEY = "relayRemoteApps";
const STORAGE_RELAY_AGENT_SNAPSHOTS_KEY = "relayAgentSnapshots";
const STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX = "relayAgentSnapshot:";
const STORAGE_RELAY_HELLO_KEY = "relayHello";
const STORAGE_RELAY_LAST_HOST_SEEN_KEY = "relayLastHostSeenAt";
const RELAY_LAST_SEEN_PERSIST_INTERVAL_MS = 60_000;
const RELAY_PRESENCE_STALE_MS = 2 * 60_000;
const MAX_RELAY_HOST_HEALTH_CHECKS = 24;
const LINK_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const RATE_LIMIT_RETRY_SECONDS = 60;

function configuredBrowserOrigins(env: Env): Set<string> {
  const configured = env.ALLOWED_ORIGINS ?? env.PUBLIC_APP_URL;
  const origins = configured
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => {
      try {
        return new URL(value).origin;
      } catch {
        return "";
      }
    })
    .filter(Boolean);
  return new Set(origins);
}

function isAllowedBrowserOrigin(origin: string | null, env: Env): boolean {
  if (origin === null) return true;
  return configuredBrowserOrigins(env).has(origin);
}

function appendVary(headers: Headers, value: string): void {
  const values = (headers.get("vary") ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  if (!values.some((item) => item.toLowerCase() === value.toLowerCase())) {
    values.push(value);
  }
  headers.set("vary", values.join(", "));
}

function corsHeaders(origin: string): Headers {
  const headers = new Headers({
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type, authorization",
    "access-control-max-age": "600",
  });
  appendVary(headers, "Origin");
  return headers;
}

function responseWithCors(response: Response, origin: string | null): Response {
  if (origin === null) return response;
  const headers = new Headers(response.headers);
  for (const [name, value] of corsHeaders(origin)) headers.set(name, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function json(data: object, init?: ResponseInit): Response {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...(init?.headers ?? {}),
    },
  });
}

function textResponse(body: string, init?: ResponseInit): Response {
  return new Response(body, init);
}

function isWebSocketUpgrade(request: Request): boolean {
  return request.headers.get("upgrade")?.toLowerCase() === "websocket";
}

function connectingClientAddress(request: Request): string {
  const cloudflareAddress = request.headers.get("cf-connecting-ip")?.trim();
  if (cloudflareAddress) return cloudflareAddress;
  const forwardedAddress = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return forwardedAddress || "unknown";
}

async function digestRateLimitKey(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return hexFromBytes(new Uint8Array(digest).slice(0, 16));
}

async function accountRateLimitKey(request: Request, pathname: string): Promise<string> {
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const actor = authorization.toLowerCase().startsWith("bearer ")
    ? `bearer:${authorization.slice(7).trim()}`
    : `address:${connectingClientAddress(request)}`;
  return `account:${pathname}:${await digestRateLimitKey(actor)}`;
}

async function accountAddressRateLimitKey(request: Request, pathname: string): Promise<string> {
  const address = await digestRateLimitKey(connectingClientAddress(request));
  return `account-address:${pathname}:${address}`;
}

async function upgradeRateLimitKey(request: Request, pathname: string): Promise<string> {
  return `upgrade:${pathname}:${await digestRateLimitKey(connectingClientAddress(request))}`;
}

async function isRateLimited(limiter: RateLimit, key: string): Promise<boolean> {
  try {
    return !(await limiter.limit({ key })).success;
  } catch (error) {
    console.error("Rate limiter unavailable", error);
    return false;
  }
}

function rateLimitedResponse(): Response {
  return json(
    { ok: false, error: "too many requests" },
    {
      status: 429,
      headers: { "retry-after": String(RATE_LIMIT_RETRY_SECONDS) },
    },
  );
}

function asAttachmentSocket(ws: WebSocket): WebSocketWithAttachment {
  return ws as WebSocketWithAttachment;
}

function isSocketOpen(ws: WebSocket): boolean {
  return ws.readyState === WebSocket.READY_STATE_OPEN;
}

/**
 * Sends a frame to a socket that may have closed while the caller was awaiting
 * (a peer close, or the hub closing a replaced connection). Returns false instead of
 * throwing when the socket is no longer open, so the caller can drop the frame and
 * forget the socket rather than failing the whole event handler. A send that fails on
 * a socket that is still open is a payload problem, not a dead peer: it is logged and
 * the socket stays usable.
 */
function sendToOpenSocket(ws: WebSocket, raw: string): boolean {
  if (!isSocketOpen(ws)) return false;
  try {
    ws.send(raw);
  } catch (error) {
    if (!isSocketOpen(ws)) return false;
    console.error("WebSocket send failed on an open socket", error);
  }
  return true;
}

function sendJsonToOpenSocket(ws: WebSocket, value: Record<string, unknown>): boolean {
  return sendToOpenSocket(ws, JSON.stringify(value));
}

function base64FromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function bytesFromBase64(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(normalized);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function hexFromBytes(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function deviceIdFromPublicKey(publicKey: Uint8Array): string {
  return `gt-${hexFromBytes(publicKey.slice(0, 8))}`;
}

async function verifyEd25519(
  publicKey: Uint8Array,
  message: Uint8Array,
  signature: Uint8Array,
): Promise<boolean> {
  if (publicKey.byteLength !== 32 || signature.byteLength !== 64) return false;
  const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, [
    "verify",
  ]);
  return crypto.subtle.verify("Ed25519", key, signature, message);
}

function stringField(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function boolField(value: unknown): boolean {
  return typeof value === "boolean" ? value : false;
}

function intFromIso(value: string | null | undefined): number | undefined {
  if (!value) return undefined;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function isoNow(): string {
  return new Date().toISOString();
}

function futureIso(ms: number): string {
  return new Date(Date.now() + ms).toISOString();
}

function generateLinkCode(): string {
  let code = "";
  const random = crypto.getRandomValues(new Uint8Array(6));
  for (const byte of random) {
    code += LINK_CODE_ALPHABET[byte % LINK_CODE_ALPHABET.length];
  }
  return code;
}

function normalizeCode(raw: string): string {
  return raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function requireSupabase(env: Env): { url: string; serviceRoleKey: string } {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("supabase auth bridge is not configured");
  }
  return {
    url: env.SUPABASE_URL.replace(/\/+$/, ""),
    serviceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

async function supabaseRest<T>(env: Env, path: string, init: RequestInit = {}): Promise<T> {
  const { url, serviceRoleKey } = requireSupabase(env);
  const headers = new Headers(init.headers);
  headers.set("apikey", serviceRoleKey);
  headers.set("authorization", `Bearer ${serviceRoleKey}`);
  if (init.body !== undefined && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }

  const response = await fetch(`${url}/rest/v1${path}`, {
    ...init,
    headers,
  });

  if (!response.ok) {
    throw new Error(`supabase ${response.status}: ${await response.text()}`);
  }

  if (response.status === 204) {
    return null as T;
  }
  const body = await response.text();
  if (!body.trim()) {
    return null as T;
  }

  return JSON.parse(body) as T;
}

async function resolveAuthenticatedUser(env: Env, request: Request): Promise<SupabaseAuthUser> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    throw new Error("missing bearer token");
  }
  return resolveUserFromAccessToken(env, token);
}

async function resolveUserFromAccessToken(env: Env, token: string): Promise<SupabaseAuthUser> {
  const { url, serviceRoleKey } = requireSupabase(env);
  const response = await fetch(`${url}/auth/v1/user`, {
    headers: {
      apikey: serviceRoleKey,
      authorization: `Bearer ${token}`,
    },
  });

  if (!response.ok) {
    throw new Error(`auth ${response.status}`);
  }

  return (await response.json()) as SupabaseAuthUser;
}

async function readJsonBody<T>(request: Request): Promise<T> {
  return (await request.json()) as T;
}

function encodeFilterValue(value: string): string {
  return encodeURIComponent(value);
}

async function findDeviceByDeviceId(env: Env, deviceId: string): Promise<DeviceRow | null> {
  const rows = await supabaseRest<DeviceRow[]>(
    env,
    `/devices?device_id=eq.${encodeFilterValue(deviceId)}&select=*`,
  );
  return rows[0] ?? null;
}

async function findDeviceByUuid(env: Env, id: string): Promise<DeviceRow | null> {
  const rows = await supabaseRest<DeviceRow[]>(env, `/devices?id=eq.${encodeFilterValue(id)}&select=*`);
  return rows[0] ?? null;
}

async function findProfileByUserId(env: Env, userId: string): Promise<ProfileRow | null> {
  const rows = await supabaseRest<ProfileRow[]>(
    env,
    `/profiles?user_id=eq.${encodeFilterValue(userId)}&select=user_id,email,display_name,avatar_url`,
  );
  return rows[0] ?? null;
}

async function upsertUserDevice(
  env: Env,
  input: {
    userId: string;
    deviceId: string;
    publicKeyB64: string;
    label: string;
    kind: "host" | "phone" | "browser";
    platform?: string;
    appVersion?: string;
    metadata?: Record<string, JsonValue>;
  },
): Promise<DeviceRow> {
  const payload = {
    user_id: input.userId,
    device_id: input.deviceId,
    public_key_b64: input.publicKeyB64,
    label: input.label,
    kind: input.kind,
    platform: input.platform ?? null,
    app_version: input.appVersion ?? null,
    metadata: input.metadata ?? {},
    last_seen_at: isoNow(),
    revoked_at: null,
  };

  const existing = await findDeviceByDeviceId(env, input.deviceId);
  if (existing && existing.user_id !== input.userId) {
    throw new Error("device belongs to another account");
  }

  const rows = await supabaseRest<DeviceRow[]>(env, `/devices?on_conflict=device_id`, {
    method: "POST",
    headers: {
      Prefer: "resolution=merge-duplicates,return=representation",
    },
    body: JSON.stringify(payload),
  });
  return rows[0];
}

async function touchDeviceLastSeen(env: Env, deviceId: string): Promise<void> {
  try {
    await supabaseRest<DeviceRow[]>(
      env,
      `/devices?device_id=eq.${encodeFilterValue(deviceId)}`,
      {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ last_seen_at: isoNow() }),
      },
    );
  } catch {
    // Unlinked devices are expected before account claim. Ignore.
  }
}

function hostMetadataString(row: DeviceRow, key: string): string {
  const value = row.metadata?.[key];
  return typeof value === "string" ? value : "";
}

function publicHostRecord(
  row: DeviceRow,
  trusted: boolean,
  pairedAt?: string | null,
  online = false,
  lastSeenAtOverrideUnixMs?: number,
): PublicHostRecord {
  const rowLastSeenAtUnixMs = intFromIso(row.last_seen_at);
  const lastSeenAtUnixMs = Math.max(
    rowLastSeenAtUnixMs ?? 0,
    lastSeenAtOverrideUnixMs ?? 0,
  );
  return {
    deviceId: row.device_id,
    publicKeyB64: row.public_key_b64,
    label: row.label,
    signalingUrl: hostMetadataString(row, "signaling_url"),
    turnUrl: hostMetadataString(row, "turn_url") || undefined,
    turnUsername: hostMetadataString(row, "turn_username") || undefined,
    turnPassword: hostMetadataString(row, "turn_password") || undefined,
    online,
    trusted,
    pairedAtUnixMs: intFromIso(pairedAt) ?? intFromIso(row.created_at) ?? Date.now(),
    ...(lastSeenAtUnixMs > 0 ? { lastSeenAtUnixMs } : {}),
  };
}

async function relayPresenceForHosts(
  env: Env,
  hostDeviceIds: string[],
): Promise<Map<string, { online: boolean; lastSeenAtUnixMs?: number }>> {
  const uniqueHostDeviceIds = [...new Set(hostDeviceIds)].slice(0, MAX_RELAY_HOST_HEALTH_CHECKS);
  const entries = await Promise.all(
    uniqueHostDeviceIds.map(async (hostDeviceId) => {
      try {
        const id = env.RELAY_HUB.idFromName(hostDeviceId);
        const response = await env.RELAY_HUB.get(id).fetch("https://relay.glasstunnel.internal/health");
        if (!response.ok) return null;
        const body = (await response.json()) as {
          hostOnline?: boolean;
          lastHostSeenAt?: number;
        };
        return [
          hostDeviceId,
          {
            online: body.hostOnline === true,
            lastSeenAtUnixMs: typeof body.lastHostSeenAt === "number" ? body.lastHostSeenAt : undefined,
          },
        ] as const;
      } catch {
        return null;
      }
    }),
  );

  return new Map(entries.filter((entry): entry is NonNullable<typeof entry> => entry !== null));
}

async function relayPresenceForHost(
  env: Env,
  hostDeviceId: string,
): Promise<{ online: boolean; lastSeenAtUnixMs?: number } | undefined> {
  return (await relayPresenceForHosts(env, [hostDeviceId])).get(hostDeviceId);
}

async function listHostsForUser(
  env: Env,
  userId: string,
  requesterDeviceId: string,
  requesterDevice?: DeviceRow,
): Promise<PublicHostRecord[]> {
  const [hosts, requester] = await Promise.all([
    supabaseRest<DeviceRow[]>(
      env,
      `/devices?user_id=eq.${encodeFilterValue(userId)}&kind=eq.host&revoked_at=is.null&order=created_at.desc&select=*`,
    ),
    requesterDevice ? Promise.resolve(requesterDevice) : findDeviceByDeviceId(env, requesterDeviceId),
  ]);
  const relayPresence = await relayPresenceForHosts(env, hosts.map((host) => host.device_id));
  const isHostOnline = (host: DeviceRow) => relayPresence.get(host.device_id)?.online === true;
  const hostLastSeen = (host: DeviceRow) => relayPresence.get(host.device_id)?.lastSeenAtUnixMs;

  if (!requester || requester.user_id !== userId || requester.revoked_at) {
    return hosts.map((host) => publicHostRecord(host, false, null, isHostOnline(host), hostLastSeen(host)));
  }

  // Account-first access means the signed-in device can open linked hosts immediately.
  // Keep this listing path read-only and bounded; creating missing pairings here made
  // /account/hosts scale with host count and could exceed Workers subrequest limits.
  const activePairings = await supabaseRest<DevicePairingRow[]>(
    env,
    `/device_pairings?owner_user_id=eq.${encodeFilterValue(userId)}&phone_device_uuid=eq.${encodeFilterValue(requester.id)}&revoked_at=is.null&select=host_device_uuid,paired_at`,
  );
  const pairedAtByHost = new Map<string, string>();
  for (const pairing of activePairings) {
    pairedAtByHost.set(pairing.host_device_uuid, pairing.paired_at);
  }

  return hosts.map((host) =>
    publicHostRecord(
      host,
      true,
      pairedAtByHost.get(host.id),
      isHostOnline(host),
      hostLastSeen(host),
    ),
  );
}

async function findActivePairing(
  env: Env,
  ownerUserId: string,
  hostDeviceUuid: string,
  requesterDeviceUuid: string,
): Promise<DevicePairingRow | null> {
  const rows = await supabaseRest<DevicePairingRow[]>(
    env,
    `/device_pairings?owner_user_id=eq.${encodeFilterValue(ownerUserId)}&host_device_uuid=eq.${encodeFilterValue(hostDeviceUuid)}&phone_device_uuid=eq.${encodeFilterValue(requesterDeviceUuid)}&revoked_at=is.null&select=*`,
  );
  return rows[0] ?? null;
}

async function findPendingApproval(
  env: Env,
  hostDeviceUuid: string,
  requesterDeviceUuid: string,
): Promise<DeviceApprovalRequestRow | null> {
  const rows = await supabaseRest<DeviceApprovalRequestRow[]>(
    env,
    `/device_approval_requests?host_device_uuid=eq.${encodeFilterValue(hostDeviceUuid)}&requester_device_uuid=eq.${encodeFilterValue(requesterDeviceUuid)}&status=eq.pending&select=*`,
  );
  return rows[0] ?? null;
}

async function findApprovalById(env: Env, requestId: string): Promise<DeviceApprovalRequestRow | null> {
  const rows = await supabaseRest<DeviceApprovalRequestRow[]>(
    env,
    `/device_approval_requests?id=eq.${encodeFilterValue(requestId)}&select=*`,
  );
  return rows[0] ?? null;
}

async function insertApprovalRequest(
  env: Env,
  input: {
    ownerUserId: string;
    hostDeviceUuid: string;
    requesterDeviceUuid: string;
    requesterDeviceId: string;
    requesterPublicKeyB64: string;
    requesterLabel: string;
  },
): Promise<DeviceApprovalRequestRow> {
  const rows = await supabaseRest<DeviceApprovalRequestRow[]>(env, `/device_approval_requests`, {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({
      owner_user_id: input.ownerUserId,
      host_device_uuid: input.hostDeviceUuid,
      requester_device_uuid: input.requesterDeviceUuid,
      requester_device_id: input.requesterDeviceId,
      requester_public_key_b64: input.requesterPublicKeyB64,
      requester_label: input.requesterLabel,
    }),
  });
  return rows[0];
}

async function markApprovalStatus(
  env: Env,
  requestId: string,
  status: DeviceApprovalRequestRow["status"],
): Promise<void> {
  await supabaseRest<DeviceApprovalRequestRow[]>(
    env,
    `/device_approval_requests?id=eq.${encodeFilterValue(requestId)}`,
    {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        status,
        responded_at: isoNow(),
      }),
    },
  );
}

async function ensurePairing(
  env: Env,
  input: {
    ownerUserId: string;
    hostDeviceUuid: string;
    requesterDeviceUuid: string;
    metadata?: Record<string, JsonValue>;
  },
): Promise<DevicePairingRow> {
  const existing = await findActivePairing(env, input.ownerUserId, input.hostDeviceUuid, input.requesterDeviceUuid);
  if (existing) return existing;

  try {
    const rows = await supabaseRest<DevicePairingRow[]>(env, `/device_pairings`, {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        owner_user_id: input.ownerUserId,
        host_device_uuid: input.hostDeviceUuid,
        phone_device_uuid: input.requesterDeviceUuid,
        metadata: input.metadata ?? { approved_via: "native_prompt" },
      }),
    });
    return rows[0];
  } catch (error) {
    if (!/duplicate key|23505|device_pairings_active_unique_idx/i.test((error as Error).message)) {
      throw error;
    }
    const created = await findActivePairing(
      env,
      input.ownerUserId,
      input.hostDeviceUuid,
      input.requesterDeviceUuid,
    );
    if (created) return created;
    throw error;
  }
}

function userDisplayName(user: SupabaseAuthUser): string {
  const metadata = user.user_metadata ?? {};
  const candidate = metadata.full_name ?? metadata.name;
  if (typeof candidate === "string" && candidate.trim()) {
    return candidate.trim();
  }
  if (user.email) {
    return user.email.split("@")[0];
  }
  return "Glasstunnel user";
}

function isControlMessage(value: unknown): value is ControlMessage {
  return !!value && typeof value === "object" && typeof (value as Record<string, unknown>).type === "string";
}

function isEnvelope(value: unknown): value is EnvelopeLike {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return typeof record.fromDeviceId === "string" && typeof record.toDeviceId === "string";
}

export class SignalingHub extends DurableObject<Env> {
  private readonly sessions = new Map<WebSocket, SessionAttachment>();
  private readonly peers = new Map<string, WebSocket>();
  private offlineQueues = new Map<string, QueuedEnvelope[]>();
  private lastSeenTouchAt = new Map<string, number>();
  private accountAuthorizationCache = new Map<string, AccountAuthorizationCacheEntry>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);

    this.ctx.blockConcurrencyWhile(async () => {
      await this.loadState();
      for (const ws of this.ctx.getWebSockets()) {
        const attachment = asAttachmentSocket(ws).deserializeAttachment();
        if (!attachment) continue;
        this.sessions.set(ws, attachment);
        if (attachment.authenticated && attachment.deviceId) {
          this.peers.set(attachment.deviceId, ws);
        }
      }
      await this.evictExpiredState();
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({
        ok: true,
        version: VERSION,
        peers: this.peers.size,
      });
    }

    if (url.pathname.startsWith("/account/")) {
      return this.handleAccountRequest(request, url);
    }

    if (url.pathname !== "/signal") {
      return textResponse("Not found", { status: 404 });
    }

    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return textResponse("Expected websocket upgrade", { status: 426 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const nonce = crypto.getRandomValues(new Uint8Array(32));
    const attachment: SessionAttachment = {
      authenticated: false,
      issuedAt: Date.now(),
      nonceB64: base64FromBytes(nonce),
    };

    this.ctx.acceptWebSocket(server);
    asAttachmentSocket(server).serializeAttachment(attachment);
    this.sessions.set(server, attachment);

    server.send(
      JSON.stringify({
        type: "server_hello",
        nonce: attachment.nonceB64,
        ttl_ms: NONCE_TTL_MS,
        version: VERSION,
        issued_at: attachment.issuedAt,
      }),
    );

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const raw =
      typeof message === "string" ? message : new TextDecoder().decode(new Uint8Array(message));
    const session = this.getSession(ws);
    if (!session) {
      ws.close(1011, "missing session");
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return;
    }

    if (!session.authenticated) {
      await this.handleClientAuth(ws, parsed);
      return;
    }

    await this.touchAuthenticatedDevice(session);

    if (isControlMessage(parsed)) {
      await this.handleControl(ws, parsed);
      return;
    }

    await this.handleEnvelope(ws, raw, parsed);
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const session = this.getSession(ws);
    if (session) await this.touchAuthenticatedDevice(session, true);
    this.unregisterPeer(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    const session = this.getSession(ws);
    if (session) await this.touchAuthenticatedDevice(session, true);
    this.unregisterPeer(ws);
  }

  private getSession(ws: WebSocket): SessionAttachment | null {
    const inMemory = this.sessions.get(ws);
    if (inMemory) return inMemory;
    const restored = asAttachmentSocket(ws).deserializeAttachment();
    if (restored) {
      this.sessions.set(ws, restored);
      return restored;
    }
    return null;
  }

  private async touchAuthenticatedDevice(session: SessionAttachment, force = false): Promise<void> {
    if (!session.authenticated || !session.deviceId) return;
    const now = Date.now();
    const previous = this.lastSeenTouchAt.get(session.deviceId) ?? 0;
    if (!force && now - previous < LAST_SEEN_TOUCH_MIN_INTERVAL_MS) return;
    this.lastSeenTouchAt.set(session.deviceId, now);
    await touchDeviceLastSeen(this.env, session.deviceId);
  }

  private async handleClientAuth(ws: WebSocket, parsed: unknown): Promise<void> {
    if (!isControlMessage(parsed) || parsed.type !== "client_auth") {
      ws.close(1008, "expected client_auth");
      return;
    }

    const session = this.getSession(ws);
    if (!session) {
      ws.close(1011, "missing session");
      return;
    }

    if (Date.now() - session.issuedAt > NONCE_TTL_MS) {
      ws.close(1008, "auth nonce expired");
      return;
    }

    const deviceId = stringField(parsed.device_id);
    const publicKeyB64 = stringField(parsed.public_key);
    const signatureB64 = stringField(parsed.signature);
    const role = stringField(parsed.role) || "unknown";

    if (!deviceId || !publicKeyB64 || !signatureB64 || !session.nonceB64) {
      ws.close(1008, "client_auth missing fields");
      return;
    }

    let publicKey: Uint8Array;
    let signature: Uint8Array;
    let nonce: Uint8Array;
    try {
      publicKey = bytesFromBase64(publicKeyB64);
      signature = bytesFromBase64(signatureB64);
      nonce = bytesFromBase64(session.nonceB64);
    } catch {
      ws.close(1008, "client_auth malformed");
      return;
    }

    if (!(await verifyEd25519(publicKey, nonce, signature))) {
      ws.close(1008, "signature verification failed");
      return;
    }

    if (deviceIdFromPublicKey(publicKey) !== deviceId) {
      ws.close(1008, "device_id does not match public_key");
      return;
    }

    // The signature check yielded; a socket that closed meanwhile must not be registered.
    if (!isSocketOpen(ws)) {
      this.unregisterPeer(ws);
      return;
    }

    const updated: SessionAttachment = {
      authenticated: true,
      deviceId,
      publicKeyB64,
      role,
      issuedAt: session.issuedAt,
      nonceB64: session.nonceB64,
    };

    const previous = this.peers.get(deviceId);
    if (previous && previous !== ws) {
      previous.close(1000, "replaced by newer connection");
      this.unregisterPeer(previous);
    }

    this.sessions.set(ws, updated);
    asAttachmentSocket(ws).serializeAttachment(updated);
    this.peers.set(deviceId, ws);

    if (!sendJsonToOpenSocket(ws, { type: "auth_ok", device_id: deviceId, at: Date.now() })) {
      this.unregisterPeer(ws);
      return;
    }

    await this.touchAuthenticatedDevice(updated, true);
    if (!isSocketOpen(ws)) {
      // Closed, or replaced by a newer connection, while last-seen was being persisted.
      this.unregisterPeer(ws);
      return;
    }
    if (role === "host") {
      await this.sendHostIdentity(ws, deviceId);
      await this.pushPendingApprovals(ws, deviceId);
    }
    await this.flushOfflineQueue(deviceId);
  }

  private async handleAccountRequest(request: Request, url: URL): Promise<Response> {
    try {
      switch (url.pathname) {
        case "/account/device/register":
          return await this.handleRegisterDeviceRequest(request);
        case "/account/hosts":
          return await this.handleListHostsRequest(request, url);
        case "/account/claim-host-code":
          return await this.handleClaimHostCodeRequest(request);
        case "/account/request-approval":
          return await this.handleRequestApprovalRequest(request);
        case "/account/approval-status":
          return await this.handleApprovalStatusRequest(request, url);
        default:
          return json({ ok: false, error: "not found" }, { status: 404 });
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      const status =
        message === "missing bearer token" || message.startsWith("auth ")
          ? 401
          : message.includes("another account")
            ? 409
            : message.includes("not found")
              ? 404
              : message.includes("not configured")
                ? 503
                : 400;
      return json({ ok: false, error: message }, { status });
    }
  }

  private async handleRegisterDeviceRequest(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const body = await readJsonBody<{
      deviceId?: string;
      publicKeyB64?: string;
      label?: string;
      kind?: string;
      platform?: string;
      appVersion?: string;
    }>(request);

    const deviceId = stringField(body.deviceId);
    const publicKeyB64 = stringField(body.publicKeyB64);
    const label = stringField(body.label) || "This device";
    const kind = stringField(body.kind) === "phone" ? "phone" : "browser";

    if (!deviceId || !publicKeyB64) {
      throw new Error("device registration missing fields");
    }

    const device = await upsertUserDevice(this.env, {
      userId: user.id,
      deviceId,
      publicKeyB64,
      label,
      kind,
      platform: stringField(body.platform) || undefined,
      appVersion: stringField(body.appVersion) || undefined,
      metadata: {
        auth_provider: stringField((user.user_metadata ?? {}).provider),
      },
    });

    const hosts = await listHostsForUser(this.env, user.id, deviceId, device);
    return json({
      ok: true,
      device_id: device.device_id,
      hosts,
    });
  }

  private async handleListHostsRequest(request: Request, url: URL): Promise<Response> {
    if (request.method !== "GET") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const requesterDeviceId = url.searchParams.get("device_id") ?? "";
    if (!requesterDeviceId) {
      throw new Error("device_id is required");
    }

    const hosts = await listHostsForUser(this.env, user.id, requesterDeviceId);
    return json({ ok: true, hosts });
  }

  private async handleClaimHostCodeRequest(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const profile = await findProfileByUserId(this.env, user.id);
    const body = await readJsonBody<{ code?: string; requesterDeviceId?: string }>(request);
    const code = normalizeCode(stringField(body.code));
    const requesterDeviceId = stringField(body.requesterDeviceId);
    if (!code) {
      throw new Error("link code is required");
    }

    const rows = await supabaseRest<HostLinkCodeRow[]>(
      this.env,
      `/host_link_codes?code=eq.${encodeFilterValue(code)}&consumed_at=is.null&select=*`,
    );
    const linkCode = rows[0];
    if (!linkCode) {
      throw new Error("link code not found");
    }
    if (Date.parse(linkCode.expires_at) <= Date.now()) {
      throw new Error("link code expired");
    }

    const existingDevice = await findDeviceByDeviceId(this.env, linkCode.host_device_id);
    if (existingDevice && existingDevice.user_id !== user.id) {
      throw new Error("host already belongs to another account");
    }

    const hostDevice = await upsertUserDevice(this.env, {
      userId: user.id,
      deviceId: linkCode.host_device_id,
      publicKeyB64: linkCode.host_public_key_b64,
      label: linkCode.host_label,
      kind: "host",
      platform: "macOS",
      metadata: linkCode.host_metadata ?? {},
    });
    let pairing: DevicePairingRow | null = null;
    if (requesterDeviceId) {
      const requester = await findDeviceByDeviceId(this.env, requesterDeviceId);
      if (requester && requester.user_id === user.id && requester.kind !== "host" && !requester.revoked_at) {
        pairing = await ensurePairing(this.env, {
          ownerUserId: user.id,
          hostDeviceUuid: hostDevice.id,
          requesterDeviceUuid: requester.id,
          metadata: { approved_via: "link_code_claim" },
        });
      }
    }

    await supabaseRest<HostLinkCodeRow[]>(
      this.env,
      `/host_link_codes?id=eq.${encodeFilterValue(linkCode.id)}`,
      {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          consumed_at: isoNow(),
          claimed_user_id: user.id,
        }),
      },
    );

    const hostSocket = this.peers.get(linkCode.host_device_id);
    if (hostSocket) {
      const notified = sendJsonToOpenSocket(hostSocket, {
        type: "host_identity",
        linked: true,
        user_id: user.id,
        email: profile?.email ?? user.email ?? "",
        display_name: profile?.display_name ?? userDisplayName(user),
        avatar_url: profile?.avatar_url ?? "",
      });
      if (!notified) this.unregisterPeer(hostSocket);
    }

    const relayPresence = await relayPresenceForHost(this.env, linkCode.host_device_id);

    return json({
      ok: true,
      host: publicHostRecord(
        hostDevice,
        pairing != null,
        pairing?.paired_at,
        relayPresence?.online === true,
        relayPresence?.lastSeenAtUnixMs,
      ),
    });
  }

  private async handleRequestApprovalRequest(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const body = await readJsonBody<{
      hostDeviceId?: string;
      requesterDeviceId?: string;
      requesterPublicKeyB64?: string;
      requesterLabel?: string;
    }>(request);

    const hostDeviceId = stringField(body.hostDeviceId);
    const requesterDeviceId = stringField(body.requesterDeviceId);
    const requesterPublicKeyB64 = stringField(body.requesterPublicKeyB64);
    const requesterLabel = stringField(body.requesterLabel) || "This device";

    if (!hostDeviceId || !requesterDeviceId || !requesterPublicKeyB64) {
      throw new Error("approval request missing fields");
    }

    const host = await findDeviceByDeviceId(this.env, hostDeviceId);
    const requester = await findDeviceByDeviceId(this.env, requesterDeviceId);
    if (!host || host.user_id !== user.id || host.kind !== "host" || host.revoked_at) {
      throw new Error("host not found");
    }
    if (!requester || requester.user_id !== user.id || requester.revoked_at) {
      throw new Error("requester device not found");
    }

    const existingPairing = await findActivePairing(this.env, user.id, host.id, requester.id);
    if (existingPairing) {
      const relayPresence = await relayPresenceForHost(this.env, host.device_id);
      return json({
        ok: true,
        status: "approved",
        host: publicHostRecord(
          host,
          true,
          existingPairing.paired_at,
          relayPresence?.online === true,
          relayPresence?.lastSeenAtUnixMs,
        ),
      });
    }

    const stalePending = await findPendingApproval(this.env, host.id, requester.id);
    if (stalePending) {
      const age = Date.now() - Date.parse(stalePending.created_at);
      if (age > APPROVAL_REQUEST_TTL_MS) {
        await markApprovalStatus(this.env, stalePending.id, "expired");
      } else {
        await this.pushApprovalRequestToHost(host.device_id, stalePending);
        return json({
          ok: true,
          status: "pending",
          request_id: stalePending.id,
        });
      }
    }

    const approval = await insertApprovalRequest(this.env, {
      ownerUserId: user.id,
      hostDeviceUuid: host.id,
      requesterDeviceUuid: requester.id,
      requesterDeviceId,
      requesterPublicKeyB64,
      requesterLabel,
    });

    await this.pushApprovalRequestToHost(host.device_id, approval);
    return json({
      ok: true,
      status: "pending",
      request_id: approval.id,
    });
  }

  private async handleApprovalStatusRequest(request: Request, url: URL): Promise<Response> {
    if (request.method !== "GET") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const requestId = url.searchParams.get("request_id") ?? "";
    if (!requestId) {
      throw new Error("request_id is required");
    }

    const approval = await findApprovalById(this.env, requestId);
    if (!approval || approval.owner_user_id !== user.id) {
      throw new Error("approval request not found");
    }

    if (approval.status === "pending" && Date.now() - Date.parse(approval.created_at) > APPROVAL_REQUEST_TTL_MS) {
      await markApprovalStatus(this.env, approval.id, "expired");
      return json({ ok: true, status: "expired" });
    }

    if (approval.status === "approved") {
      const host = await findDeviceByUuid(this.env, approval.host_device_uuid);
      const pairing = await findActivePairing(
        this.env,
        approval.owner_user_id,
        approval.host_device_uuid,
        approval.requester_device_uuid,
      );
      if (!host || !pairing) {
        throw new Error("approved host not found");
      }
      const relayPresence = await relayPresenceForHost(this.env, host.device_id);
      return json({
        ok: true,
        status: "approved",
        host: publicHostRecord(
          host,
          true,
          pairing.paired_at,
          relayPresence?.online === true,
          relayPresence?.lastSeenAtUnixMs,
        ),
      });
    }

    return json({
      ok: true,
      status: approval.status,
    });
  }

  private async handleControl(ws: WebSocket, message: ControlMessage): Promise<void> {
    const session = this.getSession(ws);
    if (!session?.authenticated || !session.deviceId) return;

    await this.evictExpiredState();

    switch (message.type) {
      case "create_link_code": {
        if (session.role !== "host") return;
        await this.createHostLinkCode(ws, session, message);
        return;
      }
      case "approval_decision": {
        if (session.role !== "host") return;
        await this.recordApprovalDecision(ws, session, message);
        return;
      }
      case "unlink_host": {
        if (session.role !== "host") return;
        await this.unlinkHost(ws, session);
        return;
      }
      case "ping":
        if (!sendJsonToOpenSocket(ws, { type: "pong", at: Date.now() })) this.unregisterPeer(ws);
        return;
      default:
        return;
    }
  }

  private async createHostLinkCode(
    ws: WebSocket,
    session: SessionAttachment,
    message: ControlMessage,
  ): Promise<void> {
    const deviceId = session.deviceId;
    const publicKeyB64 = session.publicKeyB64;
    if (!deviceId || !publicKeyB64) return;

    const hostLabel = stringField(message.host_label) || "This Mac";
    const hostMetadata = {
      signaling_url: stringField(message.signaling_url),
      turn_url: stringField(message.turn_url),
      turn_username: stringField(message.turn_username),
      turn_password: stringField(message.turn_password),
    } satisfies Record<string, JsonValue>;

    let code = "";
    let lastError: unknown = null;
    for (let attempt = 0; attempt < 6; attempt++) {
      code = generateLinkCode();
      try {
        await supabaseRest<HostLinkCodeRow[]>(this.env, `/host_link_codes`, {
          method: "POST",
          headers: { Prefer: "return=minimal" },
          body: JSON.stringify({
            code,
            host_device_id: deviceId,
            host_public_key_b64: publicKeyB64,
            host_label: hostLabel,
            host_metadata: hostMetadata,
            expires_at: futureIso(HOST_LINK_CODE_TTL_MS),
          }),
        });
        sendJsonToOpenSocket(ws, {
          type: "link_code_created",
          code,
          expires_at: futureIso(HOST_LINK_CODE_TTL_MS),
        });
        return;
      } catch (error) {
        lastError = error;
      }
    }

    sendJsonToOpenSocket(ws, {
      type: "link_code_error",
      reason: lastError instanceof Error ? lastError.message : "could not create code",
    });
  }

  private async recordApprovalDecision(
    ws: WebSocket,
    session: SessionAttachment,
    message: ControlMessage,
  ): Promise<void> {
    const deviceId = session.deviceId;
    if (!deviceId) return;

    const requestId = stringField(message.request_id);
    const approved = boolField(message.approved);
    if (!requestId) return;

    const host = await findDeviceByDeviceId(this.env, deviceId);
    if (!host || host.kind !== "host" || host.revoked_at) {
      sendJsonToOpenSocket(ws, { type: "approval_recorded", request_id: requestId, ok: false, reason: "host not linked" });
      return;
    }

    const approval = await findApprovalById(this.env, requestId);
    if (!approval || approval.host_device_uuid !== host.id || approval.status !== "pending") {
      sendJsonToOpenSocket(ws, { type: "approval_recorded", request_id: requestId, ok: false, reason: "approval request not found" });
      return;
    }

    if (approved) {
      await ensurePairing(this.env, {
        ownerUserId: approval.owner_user_id,
        hostDeviceUuid: approval.host_device_uuid,
        requesterDeviceUuid: approval.requester_device_uuid,
      });
      await markApprovalStatus(this.env, requestId, "approved");
    } else {
      await markApprovalStatus(this.env, requestId, "rejected");
    }

    sendJsonToOpenSocket(ws, {
      type: "approval_recorded",
      request_id: requestId,
      ok: true,
      status: approved ? "approved" : "rejected",
    });
  }

  private async unlinkHost(
    ws: WebSocket,
    session: SessionAttachment,
  ): Promise<void> {
    const deviceId = session.deviceId;
    if (!deviceId) return;

    try {
      const host = await findDeviceByDeviceId(this.env, deviceId);
      if (!host || host.kind !== "host" || host.revoked_at) {
        sendJsonToOpenSocket(ws, { type: "host_unlinked", ok: true, linked: false });
        sendJsonToOpenSocket(ws, { type: "host_identity", linked: false });
        return;
      }

      await supabaseRest<HostLinkCodeRow[]>(
        this.env,
        `/host_link_codes?host_device_id=eq.${encodeFilterValue(deviceId)}`,
        {
          method: "DELETE",
          headers: { Prefer: "return=minimal" },
        },
      );

      await supabaseRest<DeviceRow[]>(
        this.env,
        `/devices?id=eq.${encodeFilterValue(host.id)}`,
        {
          method: "DELETE",
          headers: { Prefer: "return=minimal" },
        },
      );
      sendJsonToOpenSocket(ws, { type: "host_unlinked", ok: true, linked: false });
      sendJsonToOpenSocket(ws, { type: "host_identity", linked: false });
    } catch (error) {
      sendJsonToOpenSocket(ws, {
        type: "host_unlinked",
        ok: false,
        reason: error instanceof Error ? error.message : "could not unlink host",
      });
    }
  }

  private async handleEnvelope(ws: WebSocket, raw: string, parsed: unknown): Promise<void> {
    const session = this.getSession(ws);
    if (!session?.authenticated || !session.deviceId) return;
    if (!isEnvelope(parsed)) return;

    if (parsed.fromDeviceId !== session.deviceId || !parsed.toDeviceId) {
      return;
    }

    await this.evictExpiredState();

    const destination = this.peers.get(parsed.toDeviceId);
    if (destination) {
      const authorized = await this.authorizeAccountEnvelopeToHost(session, destination, parsed);
      if (!authorized) return;
      if (sendToOpenSocket(destination, raw)) return;
      // The destination closed while authorization was in flight; queue the envelope
      // for its next connection like any other offline peer.
      this.unregisterPeer(destination);
    }

    const queue = this.offlineQueues.get(parsed.toDeviceId) ?? [];
    queue.push({ raw, enqueuedAt: Date.now() });
    while (queue.length > MAX_QUEUED_PER_PEER) queue.shift();
    this.offlineQueues.set(parsed.toDeviceId, queue);
    await this.persistOfflineQueues();
  }

  private async authorizeAccountEnvelopeToHost(
    session: SessionAttachment,
    destination: WebSocket,
    envelope: EnvelopeLike,
  ): Promise<boolean> {
    if (!session.deviceId || !session.publicKeyB64 || !envelope.toDeviceId) return false;
    if (session.role === "host") return true;

    const destinationSession = this.getSession(destination);
    if (destinationSession?.role !== "host") return true;
    const cacheKey = accountAuthorizationCacheKey(session.deviceId, envelope.toDeviceId);
    const cached = this.accountAuthorizationCache.get(cacheKey);
    if (
      cached &&
      cached.expiresAt > Date.now() &&
      cached.requesterPublicKeyB64 === session.publicKeyB64
    ) {
      if (cached.notifiedHostSessionIssuedAt !== destinationSession.issuedAt) {
        this.sendAccountDeviceAuthorized(destination, cached);
        cached.notifiedHostSessionIssuedAt = destinationSession.issuedAt;
      }
      return true;
    }

    const host = await findDeviceByDeviceId(this.env, envelope.toDeviceId);
    const requester = await findDeviceByDeviceId(this.env, session.deviceId);
    if (
      !host ||
      !requester ||
      host.kind !== "host" ||
      requester.kind === "host" ||
      host.revoked_at ||
      requester.revoked_at ||
      host.user_id !== requester.user_id ||
      requester.public_key_b64 !== session.publicKeyB64
    ) {
      return false;
    }

    const pairing = await ensurePairing(this.env, {
      ownerUserId: host.user_id,
      hostDeviceUuid: host.id,
      requesterDeviceUuid: requester.id,
      metadata: { approved_via: "same_account_auto" },
    });
    const cacheEntry: AccountAuthorizationCacheEntry = {
      requesterDeviceId: requester.device_id,
      requesterPublicKeyB64: requester.public_key_b64,
      requesterLabel: requester.label,
      pairedAt: pairing.paired_at,
      expiresAt: Date.now() + ACCOUNT_AUTH_CACHE_TTL_MS,
      notifiedHostSessionIssuedAt: destinationSession.issuedAt,
    };
    this.accountAuthorizationCache.set(cacheKey, cacheEntry);
    this.sendAccountDeviceAuthorized(destination, cacheEntry);
    return true;
  }

  private sendAccountDeviceAuthorized(
    hostSocket: WebSocket,
    authorization: AccountAuthorizationCacheEntry,
  ): void {
    sendJsonToOpenSocket(hostSocket, {
      type: "account_device_authorized",
      requester_device_id: authorization.requesterDeviceId,
      requester_public_key_b64: authorization.requesterPublicKeyB64,
      requester_label: authorization.requesterLabel,
      paired_at: authorization.pairedAt,
    });
  }

  private unregisterPeer(ws: WebSocket): void {
    const session = this.sessions.get(ws) ?? asAttachmentSocket(ws).deserializeAttachment();
    if (session?.deviceId && this.peers.get(session.deviceId) === ws) {
      this.peers.delete(session.deviceId);
    }
    this.sessions.delete(ws);
  }

  private async flushOfflineQueue(deviceId: string): Promise<void> {
    const destination = this.peers.get(deviceId);
    if (!destination) return;

    const queued = (this.offlineQueues.get(deviceId) ?? []).filter(
      (entry) => Date.now() - entry.enqueuedAt <= OFFLINE_QUEUE_TTL_MS,
    );

    if (queued.length === 0) {
      if (this.offlineQueues.delete(deviceId)) {
        await this.persistOfflineQueues();
      }
      return;
    }

    let delivered = 0;
    while (delivered < queued.length && sendToOpenSocket(destination, queued[delivered].raw)) {
      delivered += 1;
    }
    if (delivered < queued.length) {
      // The peer went away mid-flush; keep the undelivered rest for its next connection.
      this.unregisterPeer(destination);
      this.offlineQueues.set(deviceId, queued.slice(delivered));
    } else {
      this.offlineQueues.delete(deviceId);
    }
    await this.persistOfflineQueues();
  }

  private async sendHostIdentity(ws: WebSocket, deviceId: string): Promise<void> {
    try {
      const host = await findDeviceByDeviceId(this.env, deviceId);
      if (!host || host.kind !== "host" || host.revoked_at) {
        sendJsonToOpenSocket(ws, { type: "host_identity", linked: false });
        return;
      }
      const profile = await findProfileByUserId(this.env, host.user_id);
      sendJsonToOpenSocket(ws, {
        type: "host_identity",
        linked: true,
        user_id: host.user_id,
        email: profile?.email ?? "",
        display_name: profile?.display_name ?? "",
        avatar_url: profile?.avatar_url ?? "",
      });
    } catch {
      sendJsonToOpenSocket(ws, { type: "host_identity", linked: false });
    }
  }

  private async pushPendingApprovals(ws: WebSocket, hostDeviceId: string): Promise<void> {
    const host = await findDeviceByDeviceId(this.env, hostDeviceId);
    if (!host) return;

    const approvals = await supabaseRest<DeviceApprovalRequestRow[]>(
      this.env,
      `/device_approval_requests?host_device_uuid=eq.${encodeFilterValue(host.id)}&status=eq.pending&order=created_at.asc&select=*`,
    );

    for (const approval of approvals) {
      if (Date.now() - Date.parse(approval.created_at) > APPROVAL_REQUEST_TTL_MS) {
        await markApprovalStatus(this.env, approval.id, "expired");
        continue;
      }
      const pushed = sendJsonToOpenSocket(ws, {
        type: "approval_requested",
        request_id: approval.id,
        requester_device_id: approval.requester_device_id,
        requester_public_key_b64: approval.requester_public_key_b64,
        requester_label: approval.requester_label,
        requested_at: approval.created_at,
      });
      // Still-pending approvals are pushed again on the host's next connection.
      if (!pushed) return;
    }
  }

  private async pushApprovalRequestToHost(
    hostDeviceId: string,
    approval: DeviceApprovalRequestRow,
  ): Promise<void> {
    const hostSocket = this.peers.get(hostDeviceId);
    if (!hostSocket) return;
    const pushed = sendJsonToOpenSocket(hostSocket, {
      type: "approval_requested",
      request_id: approval.id,
      requester_device_id: approval.requester_device_id,
      requester_public_key_b64: approval.requester_public_key_b64,
      requester_label: approval.requester_label,
      requested_at: approval.created_at,
    });
    if (!pushed) this.unregisterPeer(hostSocket);
  }

  private async loadState(): Promise<void> {
    const queues =
      (await this.ctx.storage.get<Record<string, QueuedEnvelope[]>>(STORAGE_OFFLINE_QUEUES_KEY)) ??
      {};
    this.offlineQueues = new Map(Object.entries(queues));
  }

  private async persistOfflineQueues(): Promise<void> {
    await this.ctx.storage.put(STORAGE_OFFLINE_QUEUES_KEY, Object.fromEntries(this.offlineQueues));
  }

  private async evictExpiredState(): Promise<void> {
    const now = Date.now();
    let queuesChanged = false;

    for (const [deviceId, queue] of this.offlineQueues) {
      const filtered = queue.filter((entry) => now - entry.enqueuedAt <= OFFLINE_QUEUE_TTL_MS);
      if (filtered.length === 0) {
        this.offlineQueues.delete(deviceId);
        queuesChanged = true;
      } else if (filtered.length !== queue.length) {
        this.offlineQueues.set(deviceId, filtered);
        queuesChanged = true;
      }
    }

    for (const [key, authorization] of this.accountAuthorizationCache) {
      if (authorization.expiresAt <= now) {
        this.accountAuthorizationCache.delete(key);
      }
    }

    if (queuesChanged) await this.persistOfflineQueues();
  }

}

export class RelayHub extends DurableObject<Env> {
  private readonly sessions = new Map<WebSocket, RelaySessionAttachment>();
  private hostSocket: WebSocket | null = null;
  private readonly clientSockets = new Map<string, WebSocket>();
  private latestRemoteApps: JsonValue | null = null;
  private latestHello: JsonValue | null = null;
  private latestAgentSnapshots = new Map<string, JsonValue>();
  private lastHostSeenAt = 0;
  private lastHostSeenPersistedAt = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);

    this.ctx.blockConcurrencyWhile(async () => {
      await this.loadRelayState();
      for (const ws of this.ctx.getWebSockets()) {
        const attachment = asAttachmentSocket(ws).deserializeAttachment();
        if (!attachment || (attachment as RelaySessionAttachment).kind !== "relay") continue;
        const relayAttachment = attachment as RelaySessionAttachment;
        this.sessions.set(ws, relayAttachment);
        if (!relayAttachment.authenticated || !relayAttachment.deviceId) continue;
        if (relayAttachment.role === "host") {
          this.hostSocket = ws;
        } else {
          this.clientSockets.set(relayAttachment.deviceId, ws);
        }
      }
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({
        ok: true,
        service: "relay",
        hostOnline: this.hostSocket != null,
        clients: this.clientSockets.size,
        lastHostSeenAt: this.lastHostSeenAt,
      });
    }

    if (url.pathname !== "/relay") {
      return textResponse("Not found", { status: 404 });
    }

    const hostDeviceId = url.searchParams.get("host_device_id") ?? "";
    if (!hostDeviceId) {
      return json({ ok: false, error: "host_device_id is required" }, { status: 400 });
    }

    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return textResponse("Expected websocket upgrade", { status: 426 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const nonce = crypto.getRandomValues(new Uint8Array(32));
    const attachment: RelaySessionAttachment = {
      kind: "relay",
      authenticated: false,
      hostDeviceId,
      issuedAt: Date.now(),
      nonceB64: base64FromBytes(nonce),
    };

    this.ctx.acceptWebSocket(server);
    asAttachmentSocket(server).serializeAttachment(attachment);
    this.sessions.set(server, attachment);
    server.send(JSON.stringify({
      type: "server_hello",
      nonce: attachment.nonceB64,
      ttl_ms: NONCE_TTL_MS,
      version: VERSION,
      issued_at: attachment.issuedAt,
    }));

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const raw = typeof message === "string" ? message : new TextDecoder().decode(new Uint8Array(message));
    const session = this.getRelaySession(ws);
    if (!session) {
      ws.close(1011, "missing relay session");
      return;
    }

    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }

    if (!session.authenticated) {
      await this.handleRelayAuth(ws, parsed);
      return;
    }

    if (parsed.type === "relay_ping" || parsed.type === "ping") {
      if (session.role === "host") {
        await this.markHostSeen();
      }
      if (!sendJsonToOpenSocket(ws, { type: "relay_pong", at: Date.now() })) {
        await this.unregisterRelaySocket(ws);
      }
      return;
    }

    if (session.role === "host") {
      await this.handleHostRelayMessage(parsed);
      return;
    }

    await this.handleClientRelayMessage(ws, session, parsed);
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    await this.unregisterRelaySocket(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.unregisterRelaySocket(ws);
  }

  private getRelaySession(ws: WebSocket): RelaySessionAttachment | null {
    const inMemory = this.sessions.get(ws);
    if (inMemory) return inMemory;
    const restored = asAttachmentSocket(ws).deserializeAttachment();
    if (!restored || (restored as RelaySessionAttachment).kind !== "relay") return null;
    const attachment = restored as RelaySessionAttachment;
    this.sessions.set(ws, attachment);
    return attachment;
  }

  private async handleRelayAuth(ws: WebSocket, parsed: Record<string, unknown>): Promise<void> {
    if (parsed.type !== "client_auth") {
      ws.close(1008, "expected client_auth");
      return;
    }

    const session = this.getRelaySession(ws);
    if (!session) {
      ws.close(1011, "missing relay session");
      return;
    }
    if (Date.now() - session.issuedAt > NONCE_TTL_MS) {
      ws.close(1008, "auth nonce expired");
      return;
    }

    const deviceId = stringField(parsed.device_id);
    const publicKeyB64 = stringField(parsed.public_key);
    const signatureB64 = stringField(parsed.signature);
    const role = stringField(parsed.role) === "host" ? "host" : "client";
    if (!deviceId || !publicKeyB64 || !signatureB64) {
      ws.close(1008, "client_auth missing fields");
      return;
    }

    let publicKey: Uint8Array;
    let signature: Uint8Array;
    let nonce: Uint8Array;
    try {
      publicKey = bytesFromBase64(publicKeyB64);
      signature = bytesFromBase64(signatureB64);
      nonce = bytesFromBase64(session.nonceB64);
    } catch {
      ws.close(1008, "client_auth malformed");
      return;
    }

    if (!(await verifyEd25519(publicKey, nonce, signature))) {
      ws.close(1008, "signature verification failed");
      return;
    }
    if (deviceIdFromPublicKey(publicKey) !== deviceId) {
      ws.close(1008, "device_id does not match public_key");
      return;
    }

    let userId = "";
    if (role === "host") {
      if (deviceId !== session.hostDeviceId) {
        ws.close(1008, "host device mismatch");
        return;
      }
      const host = await findDeviceByDeviceId(this.env, deviceId);
      userId = host?.user_id ?? "";
    } else {
      const accessToken = stringField(parsed.access_token);
      if (!accessToken) {
        ws.close(1008, "access token is required");
        return;
      }
      const user = await resolveUserFromAccessToken(this.env, accessToken);
      const [host, requester] = await Promise.all([
        findDeviceByDeviceId(this.env, session.hostDeviceId),
        findDeviceByDeviceId(this.env, deviceId),
      ]);
      if (
        !host ||
        !requester ||
        host.kind !== "host" ||
        requester.kind === "host" ||
        host.revoked_at ||
        requester.revoked_at ||
        host.user_id !== user.id ||
        requester.user_id !== user.id ||
        requester.public_key_b64 !== publicKeyB64
      ) {
        ws.close(1008, "device is not authorized for this host");
        return;
      }
      userId = user.id;
    }

    // The Supabase checks above can take long enough for the socket to close, or for a
    // quick reconnect to replace it. A socket that is no longer open must never become
    // the registered host or client; its close callback may already have run.
    if (!isSocketOpen(ws)) {
      await this.unregisterRelaySocket(ws);
      return;
    }

    const updated: RelaySessionAttachment = {
      ...session,
      authenticated: true,
      deviceId,
      publicKeyB64,
      role,
      userId,
    };
    this.sessions.set(ws, updated);
    asAttachmentSocket(ws).serializeAttachment(updated);

    if (role === "host") {
      const previousHost = this.hostSocket;
      if (previousHost && previousHost !== ws) {
        previousHost.close(1000, "replaced by newer host relay");
        await this.unregisterRelaySocket(previousHost);
      }
      if (!isSocketOpen(ws)) {
        await this.unregisterRelaySocket(ws);
        return;
      }
      this.hostSocket = ws;
      await this.markHostSeen(true);
      await touchDeviceLastSeen(this.env, deviceId);
      if (!sendJsonToOpenSocket(ws, { type: "auth_ok", device_id: deviceId, at: Date.now() })) {
        // Closed while presence was being persisted, or replaced by a newer host relay
        // that has already taken over this.hostSocket.
        await this.unregisterRelaySocket(ws);
        return;
      }
      this.broadcastPresence(true);
      return;
    }

    const previous = this.clientSockets.get(deviceId);
    if (previous && previous !== ws) {
      previous.close(1000, "replaced by newer relay connection");
      await this.unregisterRelaySocket(previous);
    }
    if (!isSocketOpen(ws)) {
      await this.unregisterRelaySocket(ws);
      return;
    }
    this.clientSockets.set(deviceId, ws);
    if (
      !sendJsonToOpenSocket(ws, { type: "auth_ok", device_id: deviceId, at: Date.now() }) ||
      !this.replayCachedState(ws)
    ) {
      await this.unregisterRelaySocket(ws);
    }
  }

  private async handleHostRelayMessage(parsed: Record<string, unknown>): Promise<void> {
    await this.markHostSeen();
    switch (parsed.type) {
      case "relay_hello":
        this.latestHello = (parsed.hello as JsonValue) ?? null;
        await this.ctx.storage.put(STORAGE_RELAY_HELLO_KEY, this.latestHello);
        this.broadcastToClients(parsed);
        return;
      case "relay_remote_apps":
        this.latestRemoteApps = (parsed.remoteApps as JsonValue) ?? null;
        await this.ctx.storage.put(STORAGE_RELAY_REMOTE_APPS_KEY, this.latestRemoteApps);
        this.broadcastToClients(parsed);
        return;
      case "relay_agent_state": {
        const snapshot = parsed.snapshot as Record<string, JsonValue> | undefined;
        if (!snapshot || typeof snapshot.agentId !== "string" || !snapshot.agentId) return;
        const agentId = snapshot.agentId;
        this.latestAgentSnapshots.set(agentId, snapshot);
        this.broadcastToClients(parsed);
        await this.persistAgentSnapshot(agentId, snapshot);
        return;
      }
      case "relay_screen_frame":
        this.broadcastToClients(parsed);
        return;
      case "relay_message_detail": {
        // A reply to one client's request; never fanned out.
        const clientDeviceId = parsed.client_device_id;
        if (typeof clientDeviceId !== "string" || !clientDeviceId) return;
        const target = this.clientSockets.get(clientDeviceId);
        if (!target) return;
        if (!sendToOpenSocket(target, JSON.stringify(parsed))) await this.unregisterRelaySocket(target);
        return;
      }
      case "relay_pong":
        return;
      default:
        return;
    }
  }

  private async handleClientRelayMessage(
    ws: WebSocket,
    session: RelaySessionAttachment,
    parsed: Record<string, unknown>,
  ): Promise<void> {
    if (parsed.type !== "relay_command") return;
    const host = this.hostSocket;
    if (host) {
      const command = parsed.command as RelayCommandMessage | undefined;
      if (!command || typeof command !== "object") return;
      const forwarded = sendJsonToOpenSocket(host, {
        type: "relay_command",
        client_device_id: session.deviceId,
        command,
        at: Date.now(),
      });
      if (forwarded) {
        const acknowledged = sendJsonToOpenSocket(ws, {
          type: "relay_ack",
          message_id: typeof command.messageId === "string" ? command.messageId : "",
          at: Date.now(),
        });
        if (!acknowledged) await this.unregisterRelaySocket(ws);
        return;
      }
      // The host socket closed before its close callback ran; treat the host as offline.
      await this.unregisterRelaySocket(host);
    }

    const informed = sendJsonToOpenSocket(ws, {
      type: "relay_error",
      code: "host_offline",
      message: "Mac relay is offline.",
      at: Date.now(),
    });
    if (!informed) await this.unregisterRelaySocket(ws);
  }

  /** Replays cached host state to a freshly authenticated client; false if it closed midway. */
  private replayCachedState(ws: WebSocket): boolean {
    const frames: Record<string, unknown>[] = [
      {
        type: "relay_presence",
        online: this.hostSocket != null,
        last_seen_at: this.lastHostSeenAt,
      },
    ];
    if (this.latestHello) {
      frames.push({ type: "relay_hello", hello: this.latestHello, cached: true });
    }
    if (this.latestRemoteApps) {
      frames.push({
        type: "relay_remote_apps",
        remoteApps: this.latestRemoteApps,
        cached: true,
      });
    }
    for (const snapshot of this.latestAgentSnapshots.values()) {
      frames.push({ type: "relay_agent_state", snapshot, cached: true });
    }
    return frames.every((frame) => sendJsonToOpenSocket(ws, frame));
  }

  private broadcastPresence(online: boolean): void {
    this.broadcastToClients({
      type: "relay_presence",
      online,
      last_seen_at: this.lastHostSeenAt,
    });
  }

  private broadcastToClients(value: Record<string, unknown>): void {
    const raw = JSON.stringify(value);
    for (const ws of this.clientSockets.values()) {
      // Closed sockets are skipped here and removed by their close/error callbacks.
      sendToOpenSocket(ws, raw);
    }
  }

  private async unregisterRelaySocket(ws: WebSocket): Promise<void> {
    const session = this.sessions.get(ws) ?? this.getRelaySession(ws);
    if (session?.role === "host" && this.hostSocket === ws) {
      this.hostSocket = null;
      await this.markHostSeen(true);
      this.broadcastPresence(false);
      if (session.deviceId) {
        await touchDeviceLastSeen(this.env, session.deviceId);
      }
    }
    if (session?.role === "client" && session.deviceId && this.clientSockets.get(session.deviceId) === ws) {
      this.clientSockets.delete(session.deviceId);
    }
    this.sessions.delete(ws);
  }

  private async loadRelayState(): Promise<void> {
    this.latestHello = (await this.ctx.storage.get<JsonValue>(STORAGE_RELAY_HELLO_KEY)) ?? null;
    this.latestRemoteApps =
      (await this.ctx.storage.get<JsonValue>(STORAGE_RELAY_REMOTE_APPS_KEY)) ?? null;
    const snapshots =
      (await this.ctx.storage.get<Record<string, JsonValue>>(STORAGE_RELAY_AGENT_SNAPSHOTS_KEY)) ?? {};
    this.latestAgentSnapshots = new Map(Object.entries(snapshots));
    const perAgentSnapshots = await this.ctx.storage.list<JsonValue>({
      prefix: STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX,
    });
    for (const [key, snapshot] of perAgentSnapshots) {
      const agentId = decodeURIComponent(key.slice(STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX.length));
      if (agentId) this.latestAgentSnapshots.set(agentId, snapshot);
    }
    this.lastHostSeenAt =
      (await this.ctx.storage.get<number>(STORAGE_RELAY_LAST_HOST_SEEN_KEY)) ?? 0;
    this.lastHostSeenPersistedAt = this.lastHostSeenAt;
  }

  private async persistAgentSnapshot(
    agentId: string,
    snapshot: Record<string, JsonValue>,
  ): Promise<void> {
    const storageKey = `${STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX}${encodeURIComponent(agentId)}`;
    const compacted = compactRelayAgentSnapshot(snapshot as Record<string, CacheJsonValue>);
    try {
      await this.ctx.storage.put(storageKey, compacted as JsonValue);
    } catch (error) {
      console.error("Unable to persist relay agent snapshot", agentId, error);
    }
  }

  async alarm(): Promise<void> {
    if (this.hostSocket) {
      await this.ctx.storage.setAlarm(Date.now() + RELAY_PRESENCE_STALE_MS);
      return;
    }
    if (this.lastHostSeenAt > 0 && Date.now() - this.lastHostSeenAt >= RELAY_PRESENCE_STALE_MS) {
      this.broadcastPresence(false);
    }
  }

  private async markHostSeen(forcePersist = false): Promise<void> {
    const now = Date.now();
    this.lastHostSeenAt = now;
    if (forcePersist || now - this.lastHostSeenPersistedAt >= RELAY_LAST_SEEN_PERSIST_INTERVAL_MS) {
      this.lastHostSeenPersistedAt = now;
      await this.ctx.storage.put(STORAGE_RELAY_LAST_HOST_SEEN_KEY, now);
    }
    await this.ctx.storage.setAlarm(now + RELAY_PRESENCE_STALE_MS);
  }
}

function accountAuthorizationCacheKey(requesterDeviceId: string, hostDeviceId: string): string {
  return `${requesterDeviceId}->${hostDeviceId}`;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const origin = request.headers.get("origin");

    if (!isAllowedBrowserOrigin(origin, env)) {
      return json({ ok: false, error: "origin not allowed" }, { status: 403 });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: origin === null ? undefined : corsHeaders(origin),
      });
    }

    if (url.pathname.startsWith("/account/")) {
      const [accountKey, addressKey] = await Promise.all([
        accountRateLimitKey(request, url.pathname),
        accountAddressRateLimitKey(request, url.pathname),
      ]);
      const [accountLimited, addressLimited] = await Promise.all([
        isRateLimited(env.ACCOUNT_RATE_LIMITER, accountKey),
        isRateLimited(env.ACCOUNT_ADDRESS_RATE_LIMITER, addressKey),
      ]);
      if (accountLimited || addressLimited) {
        return responseWithCors(rateLimitedResponse(), origin);
      }
    } else if (
      (url.pathname === "/signal" || url.pathname === "/relay")
      && isWebSocketUpgrade(request)
    ) {
      const key = await upgradeRateLimitKey(request, url.pathname);
      if (await isRateLimited(env.UPGRADE_RATE_LIMITER, key)) {
        return rateLimitedResponse();
      }
    }

    let response: Response;
    if (url.pathname === "/health") {
      response = json({
        ok: true,
        service: "glasstunnel-signal-worker",
        appUrl: env.PUBLIC_APP_URL,
        version: VERSION,
      });
    } else if (url.pathname === "/push/vapid") {
      if (!env.VAPID_PUBLIC_KEY) {
        response = json({ ok: false, error: "vapid not configured" }, { status: 404 });
      } else {
        response = json({ public_key: env.VAPID_PUBLIC_KEY });
      }
    } else if (url.pathname === "/push/register") {
      response = json(
        { ok: true, stored: false, reason: "push migration pending" },
        { status: 202 },
      );
    } else if (url.pathname === "/relay") {
      const hostDeviceId = url.searchParams.get("host_device_id") ?? "";
      if (!hostDeviceId) {
        response = json({ ok: false, error: "host_device_id is required" }, { status: 400 });
      } else {
        const id = env.RELAY_HUB.idFromName(hostDeviceId);
        response = await env.RELAY_HUB.get(id).fetch(request);
      }
    } else if (url.pathname === "/signal" || url.pathname.startsWith("/account/")) {
      const id = env.SIGNALING_HUB.idFromName(GLOBAL_HUB_NAME);
      response = await env.SIGNALING_HUB.get(id).fetch(request);
    } else {
      response = json({ ok: false, error: "not found" }, { status: 404 });
    }

    return isWebSocketUpgrade(request) ? response : responseWithCors(response, origin);
  },
};
