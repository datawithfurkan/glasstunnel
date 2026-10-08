import { DurableObject } from "cloudflare:workers";
import { cacheRecord, validCacheRecord, type CacheRecord } from './contentRetention';
import { hostLabelFromInput, proposedHostLabel } from "./hostLabel";
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
  CONVEX_URL?: string;
  /** HTTP actions origin (https://<deployment>.convex.site); derived from CONVEX_URL when unset. */
  CONVEX_SITE_URL?: string;
  /** Shared secret for the Convex account-plane gateway (wrangler secret). */
  CONVEX_WORKER_SECRET?: string;
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
  /** The Mac app version a host reported in client_auth, when it is a version string. */
  appVersion?: string;
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
  deviceLabel?: string;
  pairedAt?: string;
  authorizationExpiresAt?: number;
  /** Set once the relay asked this browser to renew its account token in place. */
  reauthRequestedAt?: number;
  /** When a link code lifted an earlier removal of this browser on the Mac. */
  reauthorizedAt?: string;
  cacheRetentionVersion?: number;
  hostDeviceId: string;
  issuedAt: number;
  nonceB64: string;
}

// The account service verifies the token before this is used. Only its expiry is
// retained, never the bearer token. Reauthentication also bounds stale account decisions.
function relayAuthorizationDeadline(verifiedToken: string, user?: AccountUser): number {
  const maximum = Date.now() + 5 * 60_000;
  if (typeof user?.session_expires_at === "number" && Number.isFinite(user.session_expires_at)) {
    return Math.min(maximum, user.session_expires_at);
  }
  try {
    const payload = verifiedToken.split(".")[1];
    const claims = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/"))) as { exp?: number };
    return typeof claims.exp === "number" && Number.isFinite(claims.exp)
      ? Math.min(maximum, claims.exp * 1000) : maximum;
  } catch { return maximum; }
}

interface RelayCommandMessage {
  messageId?: string;
  atUnixMs?: number;
  body?: JsonValue;
}

interface QueuedEnvelope {
  raw: string;
  enqueuedAt: number;
  source?: Pick<SessionAttachment, "deviceId" | "publicKeyB64" | "role">;
}

interface AccountAuthorizationCacheEntry {
  requesterDeviceId: string;
  requesterPublicKeyB64: string;
  requesterLabel: string;
  pairedAt: string;
  expiresAt: number;
  notifiedHostSessionIssuedAt?: number;
  reauthorizedAt?: string;
}

interface HostEnvelopeAuthorization {
  expiresAt: number;
  hostPublicKeyB64: string;
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

/** A signed-in account, as the Convex token verifier reports it. */
interface AccountUser {
  id: string;
  email?: string | null;
  user_metadata?: Record<string, unknown> | null;
  /** Unix ms; Better Auth session tokens are opaque, so the verifier reports the expiry. */
  session_expires_at?: number;
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
  metadata?: Record<string, JsonValue> | null;
}

function pairingReauthorizedAt(pairing: DevicePairingRow | null | undefined): string | undefined {
  const value = pairing?.metadata?.reauthorized_at;
  return typeof value === "string" && value ? value : undefined;
}

class DeviceAuthorizationError extends Error {}

const CLAIMED_LINK_CODE_UNAVAILABLE_MESSAGE =
  "Linking didn't finish, and this code can't be used again. Show a new code on your Mac and enter it.";

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

/** A removal the signaling hub started and has not finished (see PENDING_REMOVAL_KEY_PREFIX). */
interface PendingRemoval {
  /** The account that asked for the removal. */
  userId: string;
  /** When the hub wrote the marker, just before it asked Convex. */
  at: number;
  /** When the hub's alarm next checks on it. Kept in memory only. */
  checkAt: number;
}

/** A stored pending-removal marker, or null when it is not one the hub wrote. */
function pendingRemovalFromStorage(value: unknown): PendingRemoval | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const { userId, at } = value as Record<string, unknown>;
  if (typeof userId !== "string" || !userId || typeof at !== "number" || !Number.isFinite(at)) return null;
  return { userId, at, checkAt: at + PENDING_REMOVAL_CHECK_INTERVAL_MS };
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
  /** When this Mac was added to the account (its account record was created). */
  addedAtUnixMs?: number;
  /** The Mac app version the Mac last reported; omitted when the server has none. */
  appVersion?: string;
}

/** A typed handle for one account-plane function behind the Convex gateway. */
interface GatewayRef<Kind extends "query" | "mutation", Args, Result> {
  readonly kind: Kind;
  readonly fn: string;
  readonly __types?: { args: Args; result: Result };
}

function gatewayRef<Kind extends "query" | "mutation", Args, Result>(fn: string): GatewayRef<Kind, Args, Result> {
  return { kind: undefined as unknown as Kind, fn };
}

/** A rejection the account plane reported on purpose (ConvexError code), not an outage. */
class AccountPlaneRejection extends Error {
  constructor(readonly code: string) {
    super(`account plane rejected the request: ${code}`);
    this.name = "AccountPlaneRejection";
  }
}

/** The account plane could not answer (misconfigured, unreachable, or failing). */
class AccountPlaneUnavailable extends Error {
  constructor(readonly code: string) {
    super("account service is temporarily unavailable");
    this.name = "AccountPlaneUnavailable";
  }
}

/** An account request refused with a specific status and a message the app can show. */
class AccountRequestError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = "AccountRequestError";
  }
}

/** The account service failed after a link code was claimed, so that code is spent. */
class ClaimedLinkCodeUnavailable extends Error {
  constructor() {
    super("link code claimed but linking did not finish");
    this.name = "ClaimedLinkCodeUnavailable";
  }
}

const convexAccountPlane = {
  findDeviceByDeviceId: gatewayRef<"query", { deviceId: string }, DeviceRow | null>("findDeviceByDeviceId"),
  findDeviceByUuid: gatewayRef<"query", { id: string }, DeviceRow | null>("findDeviceByUuid"),
  findProfileByUserId: gatewayRef<"query", { userId: string }, ProfileRow | null>("findProfileByUserId"),
  listHostDevicesForUser: gatewayRef<
    "query",
    { userId: string; limit?: number },
    DeviceRow[]
  >("listHostDevicesForUser"),
  listPairingsForRequester: gatewayRef<
    "query",
    { ownerUserId: string; requesterDeviceUuid: string; limit?: number },
    DevicePairingRow[]
  >("listPairingsForRequester"),
  findActivePairing: gatewayRef<
    "query",
    { ownerUserId: string; hostDeviceUuid: string; requesterDeviceUuid: string },
    DevicePairingRow | null
  >("findActivePairing"),
  hasRevokedPairing: gatewayRef<
    "query",
    { ownerUserId: string; hostDeviceUuid: string; requesterDeviceUuid: string },
    boolean
  >("hasRevokedPairing"),
  findPendingApproval: gatewayRef<
    "query",
    { hostDeviceUuid: string; requesterDeviceUuid: string },
    DeviceApprovalRequestRow | null
  >("findPendingApproval"),
  findApprovalById: gatewayRef<"query", { requestId: string }, DeviceApprovalRequestRow | null>("findApprovalById"),
  listPendingApprovalsByHost: gatewayRef<
    "query",
    { hostDeviceUuid: string; limit?: number },
    DeviceApprovalRequestRow[]
  >("listPendingApprovalsByHost"),
  upsertUserDevice: gatewayRef<
    "mutation",
    {
      userId: string;
      deviceId: string;
      publicKeyB64: string;
      label: string;
      kind: "host" | "phone" | "browser";
      platform?: string;
      appVersion?: string;
      metadata?: Record<string, JsonValue>;
    },
    DeviceRow
  >("upsertUserDevice"),
  touchDeviceLastSeen: gatewayRef<"mutation", { deviceId: string; appVersion?: string }, null>("touchDeviceLastSeen"),
  renameHostDevice: gatewayRef<
    "mutation",
    { userId: string; deviceId: string; label: string },
    DeviceRow
  >("renameHostDevice"),
  removeHostDevice: gatewayRef<"mutation", { userId: string; deviceId: string }, DeviceRow>("removeHostDevice"),
  insertApprovalRequest: gatewayRef<
    "mutation",
    {
      ownerUserId: string;
      hostDeviceUuid: string;
      requesterDeviceUuid: string;
      requesterDeviceId: string;
      requesterPublicKeyB64: string;
      requesterLabel: string;
    },
    DeviceApprovalRequestRow
  >("insertApprovalRequest"),
  markApprovalStatus: gatewayRef<
    "mutation",
    { requestId: string; status: DeviceApprovalRequestRow["status"] },
    null
  >("markApprovalStatus"),
  ensurePairing: gatewayRef<
    "mutation",
    {
      ownerUserId: string;
      hostDeviceUuid: string;
      requesterDeviceUuid: string;
      metadata?: Record<string, JsonValue>;
    },
    DevicePairingRow
  >("ensurePairing"),
  createHostLinkCode: gatewayRef<
    "mutation",
    {
      code: string;
      hostDeviceId: string;
      hostPublicKeyB64: string;
      hostLabel: string;
      hostMetadata: Record<string, JsonValue>;
      expiresAt: string;
    },
    null
  >("createHostLinkCode"),
  claimHostLinkCode: gatewayRef<
    "mutation",
    { code: string; claimedUserId: string },
    HostLinkCodeRow
  >("claimHostLinkCode"),
  deleteHostLinkCodesByHostDeviceId: gatewayRef<
    "mutation",
    { hostDeviceId: string; limit?: number },
    number
  >("deleteHostLinkCodesByHostDeviceId"),
  deleteDeviceByUuid: gatewayRef<"mutation", { id: string }, boolean>("deleteDeviceByUuid"),
  deleteRevokedPairings: gatewayRef<
    "mutation",
    { ownerUserId: string; hostDeviceUuid: string; requesterDeviceUuid: string },
    number
  >("deleteRevokedPairings"),
  revokePairing: gatewayRef<
    "mutation",
    {
      ownerUserId: string;
      hostDeviceUuid: string;
      requesterDeviceUuid: string;
      metadata?: Record<string, JsonValue>;
    },
    null
  >("revokePairing"),
};

const convexAuth = {
  verifyBearerToken: gatewayRef<"query", { token: string }, AccountUser | null>("verifyBearerToken"),
};

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
const STORAGE_RETENTION_ACTIVE_KEY = 'contentRetentionV1';
// The first page also includes three fixed keys; storage.delete permits 128.
const CACHE_CLEANUP_BATCH = 125;
/** Browsers are asked to renew their account token this long before the relay deadline. */
const RELAY_REAUTH_LEAD_MS = 60_000;
const RELAY_LAST_SEEN_PERSIST_INTERVAL_MS = 60_000;
const RELAY_PRESENCE_STALE_MS = 2 * 60_000;
/**
 * The Mac pings every 20 s. A host socket that stays OPEN through three missed
 * pings has lost its network path without a FIN; closing it flips presence for
 * every phone and lets the Mac's own reconnect replace it.
 */
const HOST_SILENCE_CLOSE_MS = 65_000;
/** Screen frames arrive twice a second; moving the alarm on each one is a storage write. */
const RELAY_ALARM_REFRESH_MIN_INTERVAL_MS = 5_000;
const MAX_RELAY_HOST_HEALTH_CHECKS = 24;
const LINK_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const RATE_LIMIT_RETRY_SECONDS = 60;
/** The one answer for a Mac outside the caller's account, whatever the reason. */
const MAC_NOT_FOUND_MESSAGE = "Mac not found";
/** A Mac app version as the Mac reports it, for example `0.1.10` or `0.1.11-beta.2`. */
const APP_VERSION_PATTERN = /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/;
/** host_identity reason when the account owner removed the Mac from another device. */
const HOST_REMOVED_IDENTITY_REASON = "removed_from_account";
/** Relay close for every socket of a Mac removed from its account. */
const HOST_REMOVED_CLOSE_CODE = 4003;
const HOST_REMOVED_CLOSE_REASON = "mac removed from account";
/**
 * The signaling hub remembers each Mac the account removed under this key
 * (value: the removal time), so a Mac that was offline at the time still
 * learns why it is unlinked. A link code claim of the Mac deletes the record.
 */
const REMOVED_HOST_KEY_PREFIX = "removed-host:";
const REMOVED_HOST_RETENTION_MS = 90 * 24 * 60 * 60_000;
/**
 * A removal whose outcome may still be unknown: the signaling hub writes
 * `pending-removal:<device id>` = {userId, at} before it asks Convex to remove
 * the Mac, and deletes it once the cleanup ran or the removal is known not to
 * have happened. If Convex's answer is lost, a retry by the same account or the
 * hub's alarm finishes the cleanup.
 */
const PENDING_REMOVAL_KEY_PREFIX = "pending-removal:";
/** The alarm checks a pending removal once it is this old, and again this long after each check. */
const PENDING_REMOVAL_CHECK_INTERVAL_MS = 60_000;
/** A pending removal whose Mac is still in an account after this long never happened; its marker goes. */
const PENDING_REMOVAL_MAX_AGE_MS = 60 * 60_000;
/** storage.delete accepts at most 128 keys per call. */
const STORAGE_DELETE_BATCH = 128;

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

/**
 * Maps a rename or removal refusal from the account plane to the reply the
 * app gets. `host_not_found` covers a missing Mac, another account's Mac, a
 * revoked row and a phone or browser alike, so the reply reveals nothing about
 * devices outside the caller's account. Outages pass through (503).
 */
function hostManagementError(error: unknown): unknown {
  if (!(error instanceof AccountPlaneRejection)) return error;
  if (error.code === "host_not_found") return new AccountRequestError(404, MAC_NOT_FOUND_MESSAGE);
  if (error.code === "invalid_label") return new AccountRequestError(400, "That name can't be used. Try a different one.");
  return new AccountRequestError(409, "Could not change this Mac. Refresh and try again.");
}

function appVersionFromInput(value: unknown): string | undefined {
  return typeof value === "string" && APP_VERSION_PATTERN.test(value) ? value : undefined;
}

/** A request body as an object; anything else (null, an array, a number) reads as empty. */
async function readJsonObject(request: Request): Promise<Record<string, unknown>> {
  const body: unknown = await request.json();
  return body && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : {};
}

/** The host_identity a linked Mac receives: its account and the account's name for the Mac. */
function linkedHostIdentity(host: DeviceRow, profile: ProfileRow | null, user?: AccountUser): Record<string, unknown> {
  return {
    type: "host_identity",
    linked: true,
    user_id: host.user_id,
    email: profile?.email ?? user?.email ?? "",
    display_name: profile?.display_name ?? (user ? userDisplayName(user) : ""),
    avatar_url: profile?.avatar_url ?? "",
    host_label: host.label,
  };
}

function convexSiteUrl(env: Env): string {
  const explicit = (env.CONVEX_SITE_URL ?? "").trim();
  if (explicit) return explicit.replace(/\/+$/, "");
  const cloud = (env.CONVEX_URL ?? "").trim().replace(/\/+$/, "");
  return cloud.endsWith(".convex.cloud") ? `${cloud.slice(0, -".convex.cloud".length)}.convex.site` : "";
}

const ACCOUNT_PLANE_TIMEOUT_MS = 15_000;

async function callAccountPlane<Result>(env: Env, fn: string, args: Record<string, unknown>): Promise<Result> {
  const site = convexSiteUrl(env);
  const secret = (env.CONVEX_WORKER_SECRET ?? "").trim();
  if (!site || !secret) {
    console.error("account plane is not configured (CONVEX_URL/CONVEX_SITE_URL or CONVEX_WORKER_SECRET missing)");
    throw new AccountPlaneUnavailable("not_configured");
  }
  let response: Response;
  let body: { ok?: boolean; value?: unknown; code?: unknown } | null;
  // A timer cleared on completion, not AbortSignal.timeout(): a pending timeout
  // would keep the Durable Object awake (and unable to hibernate) after the call.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), ACCOUNT_PLANE_TIMEOUT_MS);
  try {
    response = await fetch(`${site}/worker/account-plane`, {
      method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
      body: JSON.stringify({ fn, args }),
      signal: controller.signal,
    });
    body = (await response.json().catch(() => null)) as typeof body;
  } catch {
    console.error(`account plane ${fn} unreachable`);
    throw new AccountPlaneUnavailable("unreachable");
  } finally {
    clearTimeout(timeout);
  }
  if (response.ok && body?.ok === true) {
    return (body.value ?? null) as Result;
  }
  const code = typeof body?.code === "string" ? body.code : `http_${response.status}`;
  if (response.status === 409) throw new AccountPlaneRejection(code);
  // Function names and gateway codes stay in the Worker log, never in replies.
  console.error(`account plane ${fn} failed: ${code}`);
  throw new AccountPlaneUnavailable(code);
}

async function convexQuery<Args extends Record<string, unknown>, Result>(
  env: Env,
  reference: GatewayRef<"query", Args, Result>,
  args: Args,
): Promise<Result> {
  return callAccountPlane<Result>(env, reference.fn, args);
}

async function convexMutation<Args extends Record<string, unknown>, Result>(
  env: Env,
  reference: GatewayRef<"mutation", Args, Result>,
  args: Args,
): Promise<Result> {
  return callAccountPlane<Result>(env, reference.fn, args);
}

async function resolveAuthenticatedUser(env: Env, request: Request): Promise<AccountUser> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    throw new Error("missing bearer token");
  }
  return resolveUserFromAccessToken(env, token);
}

async function resolveUserFromAccessToken(env: Env, token: string): Promise<AccountUser> {
  const user = await convexQuery(env, convexAuth.verifyBearerToken, { token });
  if (!user) {
    throw new Error("auth 401");
  }
  return user;
}

async function readJsonBody<T>(request: Request): Promise<T> {
  return (await request.json()) as T;
}

async function findDeviceByDeviceId(env: Env, deviceId: string): Promise<DeviceRow | null> {
  return convexQuery(env, convexAccountPlane.findDeviceByDeviceId, { deviceId });
}

async function findDeviceByUuid(env: Env, id: string): Promise<DeviceRow | null> {
  return convexQuery(env, convexAccountPlane.findDeviceByUuid, { id });
}

async function findProfileByUserId(env: Env, userId: string): Promise<ProfileRow | null> {
  return convexQuery(env, convexAccountPlane.findProfileByUserId, { userId });
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
  try {
    const key = bytesFromBase64(input.publicKeyB64);
    if (key.length !== 32 || deviceIdFromPublicKey(key) !== input.deviceId) throw new Error();
  } catch { throw new DeviceAuthorizationError("device_id does not match public_key"); }

  const existing = await findDeviceByDeviceId(env, input.deviceId);
  if (existing && existing.user_id !== input.userId) {
    throw new Error("device belongs to another account");
  }
  if (existing && (existing.revoked_at || existing.public_key_b64 !== input.publicKeyB64 ||
      (existing.kind === "host") !== (input.kind === "host"))) {
    throw new DeviceAuthorizationError("device registration is not authorized");
  }

  // The mutation repeats these checks atomically, so a revocation or transfer
  // that lands after the lookup above cannot be overwritten.
  try {
    return await convexMutation(env, convexAccountPlane.upsertUserDevice, input);
  } catch (error) {
    if (error instanceof AccountPlaneRejection) {
      if (error.code === "device_belongs_to_another_account") {
        throw new Error("device belongs to another account");
      }
      throw new DeviceAuthorizationError("device registration is not authorized");
    }
    throw error;
  }
}

/**
 * Claims a link code for `claimedUserId`: the account plane finds the one
 * live row for the code and marks it used in a single transaction, so two
 * claims racing for the same code cannot both succeed. The losing claim gets
 * the same answer as a code that never existed.
 */
async function claimHostLinkCode(env: Env, code: string, claimedUserId: string): Promise<HostLinkCodeRow> {
  try {
    return await convexMutation(env, convexAccountPlane.claimHostLinkCode, { code, claimedUserId });
  } catch (error) {
    if (error instanceof AccountPlaneRejection) {
      if (error.code === "link_code_expired") throw new Error("link code expired");
      if (error.code === "link_code_not_found") throw new Error("link code not found");
    }
    throw error;
  }
}

async function touchDeviceLastSeen(env: Env, deviceId: string, appVersion?: string): Promise<void> {
  try {
    await convexMutation(env, convexAccountPlane.touchDeviceLastSeen, {
      deviceId,
      ...(appVersion ? { appVersion } : {}),
    });
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
  const addedAtUnixMs = intFromIso(row.created_at);
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
    pairedAtUnixMs: intFromIso(pairedAt) ?? addedAtUnixMs ?? Date.now(),
    ...(lastSeenAtUnixMs > 0 ? { lastSeenAtUnixMs } : {}),
    ...(addedAtUnixMs !== undefined ? { addedAtUnixMs } : {}),
    ...(row.app_version ? { appVersion: row.app_version } : {}),
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
    convexQuery(env, convexAccountPlane.listHostDevicesForUser, { userId, limit: 500 }),
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
  const pairings = await convexQuery(env, convexAccountPlane.listPairingsForRequester, {
    ownerUserId: userId,
    requesterDeviceUuid: requester.id,
    limit: 500,
  });
  const pairedAtByHost = new Map<string, string>();
  const revokedHosts = new Set<string>();
  for (const pairing of pairings) {
    if (pairing.revoked_at) revokedHosts.add(pairing.host_device_uuid);
    pairedAtByHost.set(pairing.host_device_uuid, pairing.paired_at);
  }

  return hosts.filter((host) => !revokedHosts.has(host.id)).map((host) =>
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
  return convexQuery(env, convexAccountPlane.findActivePairing, {
    ownerUserId,
    hostDeviceUuid,
    requesterDeviceUuid,
  });
}

async function hasRevokedPairing(
  env: Env,
  host: DeviceRow,
  requester: DeviceRow,
): Promise<boolean> {
  return convexQuery(env, convexAccountPlane.hasRevokedPairing, {
    ownerUserId: host.user_id,
    hostDeviceUuid: host.id,
    requesterDeviceUuid: requester.id,
  });
}

async function findPendingApproval(
  env: Env,
  hostDeviceUuid: string,
  requesterDeviceUuid: string,
): Promise<DeviceApprovalRequestRow | null> {
  return convexQuery(env, convexAccountPlane.findPendingApproval, {
    hostDeviceUuid,
    requesterDeviceUuid,
  });
}

async function findApprovalById(env: Env, requestId: string): Promise<DeviceApprovalRequestRow | null> {
  return convexQuery(env, convexAccountPlane.findApprovalById, { requestId });
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
  return convexMutation(env, convexAccountPlane.insertApprovalRequest, input);
}

async function markApprovalStatus(
  env: Env,
  requestId: string,
  status: DeviceApprovalRequestRow["status"],
): Promise<void> {
  await convexMutation(env, convexAccountPlane.markApprovalStatus, { requestId, status });
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
  try {
    return await convexMutation(env, convexAccountPlane.ensurePairing, input);
  } catch (error) {
    if (error instanceof AccountPlaneRejection) {
      throw new DeviceAuthorizationError(
        error.code === "access_revoked" ? "Access to this Mac was revoked." : "device pairing is not authorized",
      );
    }
    throw error;
  }
}

function userDisplayName(user: AccountUser): string {
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
  /** Last message from each host socket; the Mac pings every 20 s. */
  private readonly hostLastSeenAt = new Map<string, number>();
  private accountAuthorizationCache = new Map<string, AccountAuthorizationCacheEntry>();
  /** Positive Mac→browser envelope decisions; revocation clears the pair's entry. */
  private readonly hostEnvelopeAuthorizations = new Map<string, HostEnvelopeAuthorization>();
  private readonly revokedPairs = new Set<string>();
  /** Macs the account removed: device id -> removal time (removed-host:<id>, kept 90 days). */
  private readonly removedHosts = new Map<string, number>();
  /** Removals not finished yet: device id -> marker (pending-removal:<id>). */
  private readonly pendingRemovals = new Map<string, PendingRemoval>();
  /**
   * Orders a Mac's Sign Out against the host identity lookups that may tell it
   * it is linked. A counter, because a Worker's Date.now() stands still between
   * I/O events, so two events can share one millisecond.
   */
  private hostLinkClock = 0;
  /**
   * Macs signed out on the Mac (unlink_host): device id -> the clock tick when
   * the Sign Out started, moved on when its account rows are deleted. A host
   * identity lookup that started before that tick sends no linked:true. A link
   * code claim that links the Mac again clears it. In memory only: it matters
   * only while such a lookup is running.
   */
  private readonly hostUnlinkedSince = new Map<string, number>();
  /**
   * Sign Outs on the Mac still running, per device id. While one runs, no host
   * identity lookup sends linked:true, whenever that lookup started: the Sign
   * Out may delete the rows the lookup read, and its own linked:false follows.
   */
  private readonly hostUnlinksInProgress = new Map<string, number>();

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
    if (session.role === "host" && session.deviceId) {
      this.hostLastSeenAt.set(session.deviceId, Date.now());
    }

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
    await touchDeviceLastSeen(this.env, session.deviceId, session.role === "host" ? session.appVersion : undefined);
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

    const appVersion = role === "host" ? appVersionFromInput(parsed.app_version) : undefined;
    const updated: SessionAttachment = {
      authenticated: true,
      deviceId,
      publicKeyB64,
      role,
      ...(appVersion ? { appVersion } : {}),
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
        case "/account/hosts/rename":
          return await this.handleRenameHostRequest(request);
        case "/account/hosts/remove":
          return await this.handleRemoveHostRequest(request);
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
      if (error instanceof AccountRequestError) {
        return json({ ok: false, error: error.message }, { status: error.status });
      }
      if (error instanceof ClaimedLinkCodeUnavailable) {
        return json({ ok: false, error: CLAIMED_LINK_CODE_UNAVAILABLE_MESSAGE }, { status: 503 });
      }
      if (error instanceof AccountPlaneUnavailable) {
        return json({ ok: false, error: "Account service is temporarily unavailable. Try again." }, { status: 503 });
      }
      const status = error instanceof DeviceAuthorizationError ? 403 :
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

  /**
   * POST /account/hosts/rename {deviceId, label[, requesterDeviceId]}: names one
   * of the caller's Macs for every phone and browser of the account. The
   * ownership check runs inside the Convex mutation. A connected Mac receives
   * a fresh host_identity with the new host_label.
   */
  private async handleRenameHostRequest(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const body = await readJsonObject(request);
    const deviceId = stringField(body.deviceId);
    if (!deviceId) throw new AccountRequestError(400, "deviceId is required");
    // Convex's renameHostDevice applies the same rule (convex/hostLabel.ts);
    // this copy answers first with the message the app shows.
    const checked = hostLabelFromInput(body.label);
    if (!checked.ok) throw new AccountRequestError(400, checked.error);

    let host: DeviceRow;
    try {
      host = await convexMutation(this.env, convexAccountPlane.renameHostDevice, {
        userId: user.id,
        deviceId,
        label: checked.label,
      });
    } catch (error) {
      throw hostManagementError(error);
    }

    // The rename is committed: from here on nothing turns it into a failure.
    await this.pushLinkedHostIdentity(host, user);
    let record: PublicHostRecord;
    try {
      record = await this.hostRecordForAccount(user.id, host, stringField(body.requesterDeviceId));
    } catch {
      console.error("Mac rename: host record details unavailable; answering with the renamed record");
      record = publicHostRecord(host, true, null, false);
    }
    return json({ ok: true, host: record });
  }

  /**
   * POST /account/hosts/remove {deviceId}: removes one of the caller's Macs
   * from the account.
   *
   * First the Mac is looked up: unless it is the caller's active Mac (a host,
   * not revoked, in the caller's account) the answer is 404 "Mac not found"
   * and nothing else runs, so no other device can reach the cleanup below.
   * Then the hub stores a pending-removal marker and, in order: (1) Convex
   * deletes the Mac's device row, pairings, approval requests and link codes
   * in one mutation that checks ownership again; (2) this hub remembers the
   * removal for 90 days, tells a connected Mac it is no longer linked (reason
   * removed_from_account) and forgets the Mac's cached authorizations and
   * queued signaling; (3) the Mac's relay closes every socket and deletes its
   * cached content; then the marker goes. Once (1) succeeded the request
   * succeeds; a failure in (2) or (3) is logged.
   *
   * If the account plane does not answer (1), the Mac is looked up again: the
   * mutation may have committed and only its reply been lost. When the Mac's
   * row is gone, (2) and (3) run and the request succeeds. Otherwise it fails
   * with 503 and the marker stays: a later removal by the same account that
   * finds no row, or the hub's alarm (finishPendingRemovals), finishes it.
   */
  private async handleRemoveHostRequest(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ ok: false, error: "method not allowed" }, { status: 405 });
    }

    const user = await resolveAuthenticatedUser(this.env, request);
    const body = await readJsonObject(request);
    const deviceId = stringField(body.deviceId);
    if (!deviceId) throw new AccountRequestError(400, "deviceId is required");

    let host: DeviceRow | null;
    try {
      host = await findDeviceByDeviceId(this.env, deviceId);
    } catch (error) {
      throw hostManagementError(error);
    }
    if (!host) {
      // This account removed the Mac earlier and the answer was lost: its row
      // is gone, so that removal happened. Finish it instead of answering 404.
      const pending = this.pendingRemovals.get(deviceId);
      if (pending?.userId !== user.id) throw new AccountRequestError(404, MAC_NOT_FOUND_MESSAGE);
      console.error("Mac removal: finishing an earlier removal whose answer was lost");
      await this.finishHostRemoval(deviceId, pending);
      return json({ ok: true });
    }
    if (host.user_id !== user.id || host.kind !== "host" || host.revoked_at) {
      throw new AccountRequestError(404, MAC_NOT_FOUND_MESSAGE);
    }

    // Stored before Convex is asked, so a lost answer can still be finished.
    const pending = await this.rememberPendingRemoval(deviceId, user.id);
    try {
      await convexMutation(this.env, convexAccountPlane.removeHostDevice, { userId: user.id, deviceId });
    } catch (error) {
      if (!(error instanceof AccountPlaneUnavailable)) {
        // Refused (for example the Mac changed account meanwhile): nothing was removed.
        await this.forgetPendingRemoval(deviceId, pending);
        throw hostManagementError(error);
      }
      let current: DeviceRow | null;
      try {
        current = await findDeviceByDeviceId(this.env, deviceId);
      } catch {
        console.error("Mac removal: no answer from the account service, and the Mac could not be looked up again");
        throw error;
      }
      if (current) {
        console.error("Mac removal: no answer from the account service, and the Mac is still in an account");
        throw error;
      }
      // Committed, reply lost: a retry would find no Mac to remove.
      console.error("Mac removal: the account service's answer was lost after the Mac was removed; finishing the cleanup");
    }

    await this.finishHostRemoval(deviceId, pending);
    return json({ ok: true });
  }

  /**
   * Steps (2) and (3) of a removal Convex committed: the removal record, the
   * Mac told, signaling and relay cleanup. Then the removal's pending marker
   * goes (only `pending`, not a newer removal's marker).
   */
  private async finishHostRemoval(hostDeviceId: string, pending: PendingRemoval): Promise<void> {
    try {
      await this.forgetRemovedHost(hostDeviceId);
    } catch {
      console.error("Mac removal: signaling cleanup failed");
    }
    await this.clearHostRelay(hostDeviceId, "Mac removal");
    await this.forgetPendingRemoval(hostDeviceId, pending);
  }

  /** Stores a pending-removal marker, in memory at once and then in storage. */
  private async rememberPendingRemoval(hostDeviceId: string, userId: string): Promise<PendingRemoval> {
    const at = Date.now();
    const pending: PendingRemoval = { userId, at, checkAt: at + PENDING_REMOVAL_CHECK_INTERVAL_MS };
    this.pendingRemovals.set(hostDeviceId, pending);
    try {
      await this.ctx.storage.put(`${PENDING_REMOVAL_KEY_PREFIX}${hostDeviceId}`, { userId, at });
      await this.scheduleQueueCleanup();
    } catch {
      // The removal still runs; only a lost answer could not be finished later.
      console.error("Mac removal: pending removal not saved");
    }
    return pending;
  }

  /**
   * Deletes a Mac's pending-removal marker: `pending` only when it is still
   * the current one, or whichever marker there is when `pending` is omitted.
   */
  private async forgetPendingRemoval(hostDeviceId: string, pending?: PendingRemoval): Promise<void> {
    const current = this.pendingRemovals.get(hostDeviceId);
    if (!current || (pending && current !== pending)) return;
    this.pendingRemovals.delete(hostDeviceId);
    try {
      await this.ctx.storage.delete(`${PENDING_REMOVAL_KEY_PREFIX}${hostDeviceId}`);
      await this.scheduleQueueCleanup();
    } catch {
      // A marker left in storage returns on load and is checked again; a Mac
      // still in an account is never cleaned up by it.
      console.error("Mac removal: pending removal not cleared");
    }
  }

  /**
   * The alarm's part of a removal whose answer was lost. Each marker at least a
   * minute old is checked against Convex: no row means the removal committed,
   * so its cleanup runs and the marker goes; a row means it has not, and after
   * an hour the marker goes without cleanup; a failed lookup keeps the marker
   * for the next check a minute later. Never throws.
   */
  private async finishPendingRemovals(): Promise<void> {
    for (const [hostDeviceId, pending] of [...this.pendingRemovals]) {
      if (pending.checkAt > Date.now()) continue;
      // The next check, unless this one ends the marker. Set first, so an
      // alarm scheduled while this check runs does not come back at once.
      pending.checkAt = Date.now() + PENDING_REMOVAL_CHECK_INTERVAL_MS;
      try {
        let row: DeviceRow | null;
        try {
          row = await findDeviceByDeviceId(this.env, hostDeviceId);
        } catch {
          console.error("Mac removal: a pending removal could not be checked; trying again later");
          continue;
        }
        // Finished or replaced by a request while the lookup ran.
        if (this.pendingRemovals.get(hostDeviceId) !== pending) continue;
        if (!row) {
          console.error("Mac removal: finishing a removal whose answer was lost");
          await this.finishHostRemoval(hostDeviceId, pending);
        } else if (Date.now() - pending.at >= PENDING_REMOVAL_MAX_AGE_MS) {
          // Still in an account an hour later: Convex never removed it.
          await this.forgetPendingRemoval(hostDeviceId, pending);
        }
      } catch {
        console.error("Mac removal: a pending removal could not be finished; trying again later");
      }
    }
  }

  /**
   * The rename reply's host record, as the hosts list would show it to the
   * requesting browser. Without a requester the record follows the
   * account-first rule: the signed-in account can open its own Macs.
   */
  private async hostRecordForAccount(
    userId: string,
    host: DeviceRow,
    requesterDeviceId: string,
  ): Promise<PublicHostRecord> {
    let trusted = true;
    let pairedAt: string | null = null;
    if (requesterDeviceId) {
      const requester = await findDeviceByDeviceId(this.env, requesterDeviceId);
      if (!requester || requester.user_id !== userId || requester.kind === "host" || requester.revoked_at) {
        trusted = false;
      } else {
        const [pairing, revoked] = await Promise.all([
          findActivePairing(this.env, userId, host.id, requester.id),
          hasRevokedPairing(this.env, host, requester),
        ]);
        trusted = !revoked;
        pairedAt = pairing?.paired_at ?? null;
      }
    }
    const relayPresence = await relayPresenceForHost(this.env, host.device_id);
    return publicHostRecord(host, trusted, pairedAt, relayPresence?.online === true, relayPresence?.lastSeenAtUnixMs);
  }

  /**
   * Sends a connected Mac its current account identity and name. Never reports
   * it unlinked, and sends nothing unless the Mac is still this account's
   * linked Mac once the profile has loaded: the device is looked up again
   * after the profile, a removal remembered meanwhile wins, and so does a Sign
   * Out on the Mac that started or finished after this lookup began. So a
   * rename that races a removal, a Sign Out on the Mac or a re-link to another
   * account cannot leave the Mac believing it is linked.
   */
  private async pushLinkedHostIdentity(host: DeviceRow, user?: AccountUser): Promise<void> {
    if (!this.peers.has(host.device_id)) return;
    const lookupStartedAt = this.tickHostLinkClock();
    try {
      // In this order: the device lookup is the newest read when it answers.
      const profile = await findProfileByUserId(this.env, host.user_id);
      const current = await findDeviceByDeviceId(this.env, host.device_id);
      if (this.signedOutSince(host.device_id, lookupStartedAt)) return;
      if (!this.isLinkedHostRow(current) || current.user_id !== host.user_id) return;
      // Looked up again: the Mac may have reconnected while these loaded.
      const hostSocket = this.peers.get(host.device_id);
      if (!hostSocket || this.getSession(hostSocket)?.role !== "host") return;
      if (!sendJsonToOpenSocket(hostSocket, linkedHostIdentity(current, profile, user))) this.unregisterPeer(hostSocket);
    } catch {
      // The Mac shows the new name on its next connection.
      console.error("Mac rename: host identity update not delivered");
    }
  }

  /**
   * Step (2) of an account removal: remembers the removal (removed-host:<id>,
   * 90 days, so a Mac that was offline learns the reason when it reconnects),
   * tells a connected Mac it is no longer linked (reason removed_from_account),
   * and clears this hub's signaling state for it.
   */
  private async forgetRemovedHost(hostDeviceId: string): Promise<void> {
    // Remembered in memory before any await: a rename or a Mac reconnect that
    // is still waiting on the account plane sees it and sends no linked:true.
    const remembered = this.rememberRemovedHost(hostDeviceId);

    const hostSocket = this.peers.get(hostDeviceId);
    if (hostSocket && this.getSession(hostSocket)?.role === "host") {
      const notified = sendJsonToOpenSocket(hostSocket, {
        type: "host_identity",
        linked: false,
        reason: HOST_REMOVED_IDENTITY_REASON,
      });
      if (!notified) this.unregisterPeer(hostSocket);
    }

    try {
      await remembered;
    } catch {
      console.error("Mac removal: removal record not saved");
    }
    await this.forgetHostSignaling(hostDeviceId);
  }

  /**
   * Drops this hub's signaling state for a Mac that left its account (removed
   * by the account, or signed out on the Mac): cached envelope authorizations
   * between it and the account's browsers, and queued signaling to or from it,
   * so WebRTC signaling stops now rather than when the two-minute authorization
   * cache expires. Browser denials (revoked-pair:*) stay; they are not account
   * rows.
   */
  private async forgetHostSignaling(hostDeviceId: string): Promise<void> {
    const pairSuffix = `->${hostDeviceId}`;
    for (const key of [...this.accountAuthorizationCache.keys()]) {
      if (key.endsWith(pairSuffix)) this.accountAuthorizationCache.delete(key);
    }
    for (const key of [...this.hostEnvelopeAuthorizations.keys()]) {
      if (key.endsWith(pairSuffix)) this.hostEnvelopeAuthorizations.delete(key);
    }

    let queuesChanged = this.offlineQueues.delete(hostDeviceId);
    for (const [destination, queue] of this.offlineQueues) {
      const kept = queue.filter((entry) => entry.source?.deviceId !== hostDeviceId);
      if (kept.length === queue.length) continue;
      queuesChanged = true;
      if (kept.length) this.offlineQueues.set(destination, kept);
      else this.offlineQueues.delete(destination);
    }
    if (queuesChanged) await this.persistOfflineQueues();
  }

  /**
   * Step (3): asks the Mac's relay to close every socket with 4003 "mac removed
   * from account" and delete its cached content. The relay checks with Convex
   * first and refuses while the Mac is still linked, so a repeated or late
   * call is safe. Failures are logged without device or account details.
   */
  private async clearHostRelay(hostDeviceId: string, context: string): Promise<void> {
    try {
      const relay = this.env.RELAY_HUB.get(this.env.RELAY_HUB.idFromName(hostDeviceId));
      const response = await relay.fetch("https://relay.glasstunnel.internal/internal/host-removed", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ hostDeviceId }),
      });
      const result = (await response.json().catch(() => null)) as { ok?: boolean } | null;
      if (!response.ok || result?.ok !== true) {
        console.error(`${context}: relay cleanup not confirmed (HTTP ${response.status})`);
      }
    } catch {
      console.error(`${context}: relay cleanup unreachable`);
    }
  }

  /** Records, in memory at once and then in storage, that the account removed this Mac. */
  private async rememberRemovedHost(hostDeviceId: string): Promise<void> {
    const removedAt = Date.now();
    this.removedHosts.set(hostDeviceId, removedAt);
    await this.ctx.storage.put(`${REMOVED_HOST_KEY_PREFIX}${hostDeviceId}`, removedAt);
    await this.scheduleQueueCleanup();
  }

  /** A link code claim linked this Mac again, so its removal is no longer the reason it is unlinked. */
  private async forgetRemovalRecord(hostDeviceId: string): Promise<void> {
    if (!this.removedHosts.delete(hostDeviceId)) return;
    try {
      await this.ctx.storage.delete(`${REMOVED_HOST_KEY_PREFIX}${hostDeviceId}`);
      await this.scheduleQueueCleanup();
    } catch {
      // isLinkedHostRow ignores a record older than the Mac's new account row.
      console.error("Mac link: removal record not cleared");
    }
  }

  /**
   * Whether a remembered removal explains why this Mac is unlinked. A record
   * older than 90 days does not count, and neither does one older than the
   * Mac's current account row (`row`), which a later link created.
   */
  private removalRecordApplies(hostDeviceId: string, row?: DeviceRow | null): boolean {
    const removedAt = this.removedHosts.get(hostDeviceId);
    if (removedAt === undefined || Date.now() - removedAt >= REMOVED_HOST_RETENTION_MS) return false;
    const createdAt = row ? Date.parse(row.created_at) : NaN;
    return !(Number.isFinite(createdAt) && createdAt > removedAt);
  }

  private tickHostLinkClock(): number {
    this.hostLinkClock += 1;
    return this.hostLinkClock;
  }

  /** Marks a Sign Out on the Mac as starting, or as having deleted the Mac's account rows. */
  private markHostUnlinked(hostDeviceId: string): void {
    this.hostUnlinkedSince.set(hostDeviceId, this.tickHostLinkClock());
  }

  /**
   * Whether a Sign Out on the Mac started or deleted its rows after a host
   * identity lookup that began at `lookupStartedAt`: that lookup may have read
   * the Mac's rows before they were deleted, so it must not say linked:true.
   */
  private signedOutSince(hostDeviceId: string, lookupStartedAt: number): boolean {
    if ((this.hostUnlinksInProgress.get(hostDeviceId) ?? 0) > 0) return true;
    return (this.hostUnlinkedSince.get(hostDeviceId) ?? 0) > lookupStartedAt;
  }

  /** An active Mac row (a host, not revoked) that no remembered removal covers. */
  private isLinkedHostRow(row: DeviceRow | null | undefined): row is DeviceRow {
    return !!row && row.kind === "host" && !row.revoked_at && !this.removalRecordApplies(row.device_id, row);
  }

  /** host_identity for a Mac in no account, with the reason while its removal is remembered. */
  private unlinkedHostIdentity(hostDeviceId: string): Record<string, unknown> {
    return {
      type: "host_identity",
      linked: false,
      ...(this.removalRecordApplies(hostDeviceId) ? { reason: HOST_REMOVED_IDENTITY_REASON } : {}),
    };
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

    // Claim first, before anything else changes: the claim is one atomic
    // account-plane transaction, so of two requests racing for the same code
    // only one gets past this line and links the Mac or lifts a removal. The
    // claim is final; if a later step fails, the Mac has to show a new code.
    const linkCode = await claimHostLinkCode(this.env, code, user.id);
    try {
      return await this.linkClaimedHost(user, profile, linkCode, requesterDeviceId);
    } catch (error) {
      // The code is spent: "try again" with the same code can only fail.
      if (error instanceof AccountPlaneUnavailable) throw new ClaimedLinkCodeUnavailable();
      throw error;
    }
  }

  private async linkClaimedHost(
    user: AccountUser,
    profile: ProfileRow | null,
    linkCode: HostLinkCodeRow,
    requesterDeviceId: string,
  ): Promise<Response> {
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
    // The Mac is linked again: an earlier removal or Sign Out no longer
    // explains anything, and a removal still pending has nothing to finish.
    this.hostUnlinkedSince.delete(hostDevice.device_id);
    await this.forgetRemovalRecord(hostDevice.device_id);
    await this.forgetPendingRemoval(hostDevice.device_id);
    let pairing: DevicePairingRow | null = null;
    if (requesterDeviceId) {
      const requester = await findDeviceByDeviceId(this.env, requesterDeviceId);
      if (requester && requester.user_id === user.id && requester.kind !== "host" && !requester.revoked_at) {
        const reauthorizedAt = (await this.liftPairingDenial(hostDevice, requester)) ? isoNow() : undefined;
        pairing = await ensurePairing(this.env, {
          ownerUserId: user.id,
          hostDeviceUuid: hostDevice.id,
          requesterDeviceUuid: requester.id,
          metadata: { approved_via: "link_code_claim", ...(reauthorizedAt ? { reauthorized_at: reauthorizedAt } : {}) },
        });
        // Tell a connected Mac right away instead of waiting for this browser's
        // first envelope, so a removed phone reappears in Access after the claim.
        const hostPeer = this.peers.get(linkCode.host_device_id);
        if (hostPeer) {
          this.sendAccountDeviceAuthorized(hostPeer, {
            requesterDeviceId: requester.device_id,
            requesterPublicKeyB64: requester.public_key_b64,
            requesterLabel: requester.label,
            pairedAt: pairing.paired_at,
            expiresAt: Date.now() + ACCOUNT_AUTH_CACHE_TTL_MS,
            reauthorizedAt: pairingReauthorizedAt(pairing) ?? reauthorizedAt,
          });
        }
      }
    }

    const hostSocket = this.peers.get(linkCode.host_device_id);
    if (hostSocket) {
      // host_label is the account's name for the Mac: a name the owner chose
      // earlier survives this re-link (convex upsertUserDevice keeps it).
      const notified = sendJsonToOpenSocket(hostSocket, linkedHostIdentity(hostDevice, profile, user));
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
      case "revoke_device": {
        if (session.role !== "host") return;
        await this.revokeAccountDevice(ws, session, message);
        return;
      }
      case "ping":
        if (!sendJsonToOpenSocket(ws, { type: "pong", at: Date.now() })) this.unregisterPeer(ws);
        return;
      default:
        return;
    }
  }

  private async revokeAccountDevice(ws: WebSocket, session: SessionAttachment, message: ControlMessage): Promise<void> {
    const deviceId = stringField(message.device_id);
    const requestId = stringField(message.request_id);
    if (!deviceId || !requestId || !session.deviceId || !session.publicKeyB64) return;
    let ok = false;
    try {
      const host = await findDeviceByDeviceId(this.env, session.deviceId);
      if (!host || host.kind !== "host" || host.revoked_at || host.public_key_b64 !== session.publicKeyB64) {
        throw new DeviceAuthorizationError("host is not authorized");
      }
      const key = accountAuthorizationCacheKey(deviceId, host.device_id);
      this.revokedPairs.add(key);
      this.accountAuthorizationCache.delete(key);
      this.hostEnvelopeAuthorizations.delete(key);
      await this.ctx.storage.put(`revoked-pair:${key}`, true);
      for (const [destination, queue] of this.offlineQueues) {
        this.offlineQueues.set(destination, queue.filter((entry) => {
          try { return !this.isRevokedEnvelope(JSON.parse(entry.raw)); } catch { return false; }
        }));
      }
      await this.persistOfflineQueues();
      const relay = this.env.RELAY_HUB.get(this.env.RELAY_HUB.idFromName(host.device_id));
      const response = await relay.fetch("https://relay.glasstunnel.internal/internal/revoke-device", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ hostDeviceId: host.device_id, hostPublicKeyB64: session.publicKeyB64, deviceId }),
      });
      const result = await response.json() as { ok?: boolean };
      ok = response.ok && result.ok === true;
    } catch {
      // Keep the local denial and report an unconfirmed operation, never success.
    }
    sendJsonToOpenSocket(ws, {
      type: "device_revoked", request_id: requestId, device_id: deviceId, ok,
      ...(ok ? {} : { reason: "Could not confirm revocation. Retry on the Mac." }),
    });
  }

  private isRevokedEnvelope(value: unknown): boolean {
    if (!isEnvelope(value) || !value.fromDeviceId || !value.toDeviceId) return true;
    return this.revokedPairs.has(accountAuthorizationCacheKey(value.fromDeviceId, value.toDeviceId)) ||
      this.revokedPairs.has(accountAuthorizationCacheKey(value.toDeviceId, value.fromDeviceId));
  }

  private async createHostLinkCode(
    ws: WebSocket,
    session: SessionAttachment,
    message: ControlMessage,
  ): Promise<void> {
    const deviceId = session.deviceId;
    const publicKeyB64 = session.publicKeyB64;
    if (!deviceId || !publicKeyB64) return;

    // The Mac proposes its computer name; it is made to follow the account's
    // name rule here, so a newly linked Mac never lists hidden characters.
    const hostLabel = proposedHostLabel(message.host_label);
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
      const expiresAt = futureIso(HOST_LINK_CODE_TTL_MS);
      try {
        await convexMutation(this.env, convexAccountPlane.createHostLinkCode, {
          code,
          hostDeviceId: deviceId,
          hostPublicKeyB64: publicKeyB64,
          hostLabel,
          hostMetadata,
          expiresAt,
        });
        sendJsonToOpenSocket(ws, {
          type: "link_code_created",
          code,
          expires_at: expiresAt,
        });
        return;
      } catch (error) {
        lastError = error;
      }
    }

    sendJsonToOpenSocket(ws, {
      type: "link_code_error",
      reason: lastError instanceof AccountPlaneUnavailable
        ? "Account service is temporarily unavailable. Try again."
        : lastError instanceof Error ? lastError.message : "could not create code",
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
    // Before the first await: a rename or connect whose host identity lookup
    // is already running sees it and does not tell the Mac it is linked, and
    // none that starts while this Sign Out runs does either.
    this.markHostUnlinked(deviceId);
    this.hostUnlinksInProgress.set(deviceId, (this.hostUnlinksInProgress.get(deviceId) ?? 0) + 1);

    try {
      const host = await findDeviceByDeviceId(this.env, deviceId);
      // Already in no account (for example a retry after a lost reply): the
      // cleanup below still runs, and the relay checks with Convex first.
      if (host && host.kind === "host" && !host.revoked_at) {
        await convexMutation(this.env, convexAccountPlane.deleteHostLinkCodesByHostDeviceId, {
          hostDeviceId: deviceId,
          limit: 500,
        });
        // Also removes the Mac's pairings and approval requests.
        await convexMutation(this.env, convexAccountPlane.deleteDeviceByUuid, { id: host.id });
      }
      // Again now that the rows are gone: a lookup that began while they were
      // being deleted may still have read them.
      this.markHostUnlinked(deviceId);
      sendJsonToOpenSocket(ws, { type: "host_unlinked", ok: true, linked: false });
      sendJsonToOpenSocket(ws, { type: "host_identity", linked: false });
    } catch (error) {
      sendJsonToOpenSocket(ws, {
        type: "host_unlinked",
        ok: false,
        reason: error instanceof Error ? error.message : "could not unlink host",
      });
      return;
    } finally {
      const running = (this.hostUnlinksInProgress.get(deviceId) ?? 1) - 1;
      if (running > 0) this.hostUnlinksInProgress.set(deviceId, running);
      else this.hostUnlinksInProgress.delete(deviceId);
    }

    // The same signaling and relay cleanup as a removal from the account, so
    // the account's browsers lose access now and the relay's cached content is
    // deleted. Not the removal record or reason: the Mac's owner signed out here.
    try {
      await this.forgetHostSignaling(deviceId);
    } catch {
      console.error("Mac sign-out: signaling cleanup failed");
    }
    await this.clearHostRelay(deviceId, "Mac sign-out");
    // The Mac is in no account because it signed out, and the cleanup ran: a
    // removal still pending for it has nothing left to finish.
    await this.forgetPendingRemoval(deviceId);
  }

  private async handleEnvelope(ws: WebSocket, raw: string, parsed: unknown): Promise<void> {
    const session = this.getSession(ws);
    if (!session?.authenticated || !session.deviceId) return;
    if (!isEnvelope(parsed)) return;

    if (parsed.fromDeviceId !== session.deviceId || !parsed.toDeviceId) {
      return;
    }
    if (this.isRevokedEnvelope(parsed)) return;

    await this.evictExpiredState();

    let destination = this.peers.get(parsed.toDeviceId);
    if (destination && this.isSilentHost(parsed.toDeviceId, destination)) {
      // A host socket that stopped pinging has lost its path without a FIN.
      // Sending the phone's WebRTC ping into it would be "delivered" and lost;
      // close it and queue the envelope for the Mac's reconnect instead.
      try {
        destination.close(1001, "host silent");
      } catch {
        // Already closing.
      }
      this.unregisterPeer(destination);
      destination = undefined;
    }
    const authorized = await this.authorizeAccountEnvelopeToHost(session, destination, parsed);
    if (!authorized || this.isRevokedEnvelope(parsed)) return;
    if (destination) {
      if (sendToOpenSocket(destination, raw)) return;
      // The destination closed while authorization was in flight; queue the envelope
      // for its next connection like any other offline peer.
      this.unregisterPeer(destination);
    }

    if (this.isRevokedEnvelope(parsed)) return;
    const queue = this.offlineQueues.get(parsed.toDeviceId) ?? [];
    queue.push({ raw, enqueuedAt: Date.now(), source: {
      deviceId: session.deviceId, publicKeyB64: session.publicKeyB64, role: session.role,
    } });
    while (queue.length > MAX_QUEUED_PER_PEER) queue.shift();
    this.offlineQueues.set(parsed.toDeviceId, queue);
    await this.persistOfflineQueues();
  }

  private async authorizeAccountEnvelopeToHost(
    session: Pick<SessionAttachment, "deviceId" | "publicKeyB64" | "role">,
    destination: WebSocket | undefined,
    envelope: EnvelopeLike,
  ): Promise<boolean> {
    if (!session.deviceId || !session.publicKeyB64 || !envelope.toDeviceId) return false;
    if (session.role === "host") {
      // Agent updates and ICE candidates arrive many times a second; a positive
      // decision is reused for the same window as browser authorizations.
      const pairKey = accountAuthorizationCacheKey(envelope.toDeviceId, session.deviceId);
      const remembered = this.hostEnvelopeAuthorizations.get(pairKey);
      if (remembered && remembered.expiresAt > Date.now() && remembered.hostPublicKeyB64 === session.publicKeyB64) {
        return true;
      }
      const [host, requester] = await Promise.all([
        findDeviceByDeviceId(this.env, session.deviceId),
        findDeviceByDeviceId(this.env, envelope.toDeviceId),
      ]);
      const authorized = !!host && !!requester && host.kind === "host" && requester.kind !== "host" &&
        !host.revoked_at && !requester.revoked_at && host.user_id === requester.user_id &&
        host.public_key_b64 === session.publicKeyB64 && !(await hasRevokedPairing(this.env, host, requester));
      if (authorized && !this.revokedPairs.has(pairKey)) {
        this.hostEnvelopeAuthorizations.set(pairKey, {
          expiresAt: Date.now() + ACCOUNT_AUTH_CACHE_TTL_MS,
          hostPublicKeyB64: session.publicKeyB64,
        });
      }
      return authorized;
    }

    const destinationSession = destination ? this.getSession(destination) : null;
    const cacheKey = accountAuthorizationCacheKey(session.deviceId, envelope.toDeviceId);
    const cached = this.accountAuthorizationCache.get(cacheKey);
    if (
      cached &&
      cached.expiresAt > Date.now() &&
      cached.requesterPublicKeyB64 === session.publicKeyB64
    ) {
      if (destination && destinationSession && cached.notifiedHostSessionIssuedAt !== destinationSession.issuedAt) {
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

    if (await hasRevokedPairing(this.env, host, requester)) return false;

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
      notifiedHostSessionIssuedAt: destinationSession?.issuedAt,
      reauthorizedAt: pairingReauthorizedAt(pairing),
    };
    if (this.isRevokedEnvelope(envelope)) return false;
    this.accountAuthorizationCache.set(cacheKey, cacheEntry);
    if (destination) this.sendAccountDeviceAuthorized(destination, cacheEntry);
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
      ...(authorization.reauthorizedAt ? { reauthorized_at: authorization.reauthorizedAt } : {}),
    });
  }

  /**
   * A link code generated on the Mac is the explicit re-authorization gesture:
   * it lifts an earlier removal of this browser in the account records, in this
   * hub's denial list, and in the Mac's relay object. Returns true if a denial
   * existed, so the pairing can carry a `reauthorized_at` that the Mac compares
   * with its own tombstone.
   */
  private async liftPairingDenial(host: DeviceRow, requester: DeviceRow): Promise<boolean> {
    const revokedCount = await convexMutation(this.env, convexAccountPlane.deleteRevokedPairings, {
      ownerUserId: host.user_id,
      hostDeviceUuid: host.id,
      requesterDeviceUuid: requester.id,
    });
    if (revokedCount === 0) return false;
    const key = accountAuthorizationCacheKey(requester.device_id, host.device_id);
    this.revokedPairs.delete(key);
    this.accountAuthorizationCache.delete(key);
    this.hostEnvelopeAuthorizations.delete(key);
    await this.ctx.storage.delete(`revoked-pair:${key}`);
    const relay = this.env.RELAY_HUB.get(this.env.RELAY_HUB.idFromName(host.device_id));
    const response = await relay.fetch("https://relay.glasstunnel.internal/internal/restore-device", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ hostDeviceId: host.device_id, deviceId: requester.device_id }),
    });
    const result = await response.json() as { ok?: boolean };
    if (!response.ok || result.ok !== true) throw new Error("could not restore relay access for this device");
    return true;
  }

  private unregisterPeer(ws: WebSocket): void {
    const session = this.sessions.get(ws) ?? asAttachmentSocket(ws).deserializeAttachment();
    if (session?.deviceId && this.peers.get(session.deviceId) === ws) {
      this.peers.delete(session.deviceId);
      this.hostLastSeenAt.delete(session.deviceId);
    }
    this.sessions.delete(ws);
  }

  private isSilentHost(deviceId: string, ws: WebSocket): boolean {
    if (this.getSession(ws)?.role !== "host") return false;
    const seenAt = this.hostLastSeenAt.get(deviceId);
    // A host restored from hibernation has no record yet; trust it until it speaks.
    return seenAt !== undefined && Date.now() - seenAt >= HOST_SILENCE_CLOSE_MS;
  }

  private async flushOfflineQueue(deviceId: string): Promise<void> {
    const destination = this.peers.get(deviceId);
    if (!destination) return;

    const queued = this.offlineQueues.get(deviceId) ?? [];
    this.offlineQueues.delete(deviceId);
    for (const entry of queued) {
      if (!entry.source || !this.freshEnvelope(entry)) continue;
      try {
        const envelope: unknown = JSON.parse(entry.raw);
        if (!isEnvelope(envelope) || this.isRevokedEnvelope(envelope) || entry.source.deviceId !== envelope.fromDeviceId) continue;
        if (!(await this.authorizeAccountEnvelopeToHost(entry.source, destination, envelope)) || this.isRevokedEnvelope(envelope) || !this.freshEnvelope(entry)) continue;
        if (!sendToOpenSocket(destination, entry.raw)) {
          const remaining = this.offlineQueues.get(deviceId) ?? [];
          remaining.push(entry);
          this.offlineQueues.set(deviceId, remaining.slice(-MAX_QUEUED_PER_PEER));
        }
      } catch {
        // Legacy/malformed or no-longer-authorized signaling is not replayed.
      }
    }
    await this.persistOfflineQueues();
  }

  private async sendHostIdentity(ws: WebSocket, deviceId: string): Promise<void> {
    let identity: Record<string, unknown> | null;
    try {
      identity = await this.currentHostIdentity(deviceId);
    } catch {
      identity = this.unlinkedHostIdentity(deviceId);
    }
    if (identity) sendJsonToOpenSocket(ws, identity);
  }

  /**
   * The host_identity a Mac that just signed in to signaling should get: linked
   * with its account and name, or unlinked (with reason removed_from_account
   * while the hub remembers that the account removed it). The device is looked
   * up again after the profile, so a removal, a Sign Out or a re-link that
   * lands meanwhile is never answered with linked:true for the old account. A
   * Sign Out on the Mac that started or finished after this lookup began is
   * answered unlinked, as the Mac asked. Null when a re-link to another
   * account already told the Mac.
   */
  private async currentHostIdentity(deviceId: string): Promise<Record<string, unknown> | null> {
    const lookupStartedAt = this.tickHostLinkClock();
    const host = await findDeviceByDeviceId(this.env, deviceId);
    if (!this.isLinkedHostRow(host)) return this.unlinkedHostIdentity(deviceId);
    // In this order: the second device lookup is the newest read when it answers.
    const profile = await findProfileByUserId(this.env, host.user_id);
    const current = await findDeviceByDeviceId(this.env, deviceId);
    if (this.signedOutSince(deviceId, lookupStartedAt)) return this.unlinkedHostIdentity(deviceId);
    if (!this.isLinkedHostRow(current)) return this.unlinkedHostIdentity(deviceId);
    if (current.user_id !== host.user_id) return null;
    return linkedHostIdentity(current, profile);
  }

  private async pushPendingApprovals(ws: WebSocket, hostDeviceId: string): Promise<void> {
    const host = await findDeviceByDeviceId(this.env, hostDeviceId);
    if (!host) return;

    const approvals = await convexQuery(this.env, convexAccountPlane.listPendingApprovalsByHost, {
      hostDeviceUuid: host.id,
      limit: 500,
    });

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
    const denied = await this.ctx.storage.list<boolean>({ prefix: "revoked-pair:" });
    for (const key of denied.keys()) this.revokedPairs.add(key.slice("revoked-pair:".length));
    const removed = await this.ctx.storage.list<unknown>({ prefix: REMOVED_HOST_KEY_PREFIX });
    for (const [key, removedAt] of removed) {
      // An unreadable record counts as expired, so the next eviction deletes it.
      const at = typeof removedAt === "number" && Number.isFinite(removedAt) ? removedAt : 0;
      this.removedHosts.set(key.slice(REMOVED_HOST_KEY_PREFIX.length), at);
    }
    const pending = await this.ctx.storage.list<unknown>({ prefix: PENDING_REMOVAL_KEY_PREFIX });
    const unreadable: string[] = [];
    for (const [key, value] of pending) {
      const marker = pendingRemovalFromStorage(value);
      if (marker) this.pendingRemovals.set(key.slice(PENDING_REMOVAL_KEY_PREFIX.length), marker);
      else unreadable.push(key);
    }
    // Not a marker this hub wrote: it names no account, so nothing can finish it.
    for (let start = 0; start < unreadable.length; start += STORAGE_DELETE_BATCH) {
      await this.ctx.storage.delete(unreadable.slice(start, start + STORAGE_DELETE_BATCH));
    }
    const queues =
      (await this.ctx.storage.get<Record<string, QueuedEnvelope[]>>(STORAGE_OFFLINE_QUEUES_KEY)) ??
      {};
    this.offlineQueues = new Map(Object.entries(queues));
  }

  private async persistOfflineQueues(): Promise<void> {
    if (this.offlineQueues.size) {
      await this.ctx.storage.put(STORAGE_OFFLINE_QUEUES_KEY, Object.fromEntries(this.offlineQueues));
    } else {
      await this.ctx.storage.delete(STORAGE_OFFLINE_QUEUES_KEY);
    }
    await this.scheduleQueueCleanup();
  }

  async cacheMaintenance(options: { dryRun: boolean }) {
    if (typeof options?.dryRun !== 'boolean') throw new Error('dryRun is required');
    const stored = await this.ctx.storage.get<Record<string, QueuedEnvelope[]>>(STORAGE_OFFLINE_QUEUES_KEY);
    const entries = Object.values(stored ?? {}).flat();
    const invalid = entries.filter((entry) => !this.freshEnvelope(entry)).length;
    if (!options.dryRun) {
      await this.evictExpiredState();
      await this.persistOfflineQueues();
      await this.ctx.storage.delete('retentionCleanupFailures');
    }
    return { scanned: entries.length, invalid, fresh: entries.length - invalid,
      deleted: options.dryRun ? 0 : invalid, cursor: null, active: true,
      cleanupFailures: await this.ctx.storage.get<number>('retentionCleanupFailures') ?? 0,
      nextAlarmAt: await this.ctx.storage.getAlarm() };
  }

  private freshEnvelope(entry: QueuedEnvelope, now = Date.now()): boolean {
    return !!entry && Number.isSafeInteger(entry.enqueuedAt) && entry.enqueuedAt > 0 &&
      entry.enqueuedAt <= now && now - entry.enqueuedAt < OFFLINE_QUEUE_TTL_MS;
  }

  /**
   * Sets the alarm for the next queued envelope or removal record to expire,
   * or the next pending removal to check, whichever comes first.
   */
  private async scheduleQueueCleanup(): Promise<void> {
    let at = Infinity;
    for (const queue of this.offlineQueues.values()) {
      for (const entry of queue) at = Math.min(at, this.freshEnvelope(entry) ? entry.enqueuedAt + OFFLINE_QUEUE_TTL_MS : Date.now());
    }
    for (const removedAt of this.removedHosts.values()) at = Math.min(at, removedAt + REMOVED_HOST_RETENTION_MS);
    for (const pending of this.pendingRemovals.values()) at = Math.min(at, pending.checkAt);
    if (Number.isFinite(at)) await this.ctx.storage.setAlarm(at);
    else await this.ctx.storage.deleteAlarm();
  }

  async alarm(): Promise<void> {
    // Removals whose answer was lost. Their failures are not cache-cleanup
    // failures: each marker stays and is checked again a minute later.
    await this.finishPendingRemovals();
    try {
      await this.evictExpiredState();
      // A prior failed write may already have pruned memory. Persist even when
      // this retry finds no additional changes, so disk catches up as well.
      await this.persistOfflineQueues();
      await this.ctx.storage.delete('retentionCleanupFailures');
    } catch {
      const failures = (await this.ctx.storage.get<number>('retentionCleanupFailures') ?? 0) + 1;
      await this.ctx.storage.put('retentionCleanupFailures', failures);
      await this.ctx.storage.setAlarm(Date.now() + Math.min(15 * 60_000, 30_000 * 2 ** Math.min(failures, 5)));
      console.error('Signaling cache cleanup failed; retry scheduled');
    }
  }

  private async evictExpiredState(): Promise<void> {
    const now = Date.now();
    let queuesChanged = false;

    for (const [deviceId, queue] of this.offlineQueues) {
      const filtered = Array.isArray(queue) ? queue.filter((entry) => this.freshEnvelope(entry, now)) : [];
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

    const expiredRemovals: string[] = [];
    for (const [hostDeviceId, removedAt] of this.removedHosts) {
      if (now - removedAt >= REMOVED_HOST_RETENTION_MS) expiredRemovals.push(hostDeviceId);
    }
    for (let start = 0; start < expiredRemovals.length; start += STORAGE_DELETE_BATCH) {
      const batch = expiredRemovals.slice(start, start + STORAGE_DELETE_BATCH);
      await this.ctx.storage.delete(batch.map((hostDeviceId) => `${REMOVED_HOST_KEY_PREFIX}${hostDeviceId}`));
      for (const hostDeviceId of batch) this.removedHosts.delete(hostDeviceId);
    }

    if (queuesChanged) await this.persistOfflineQueues();
    else await this.scheduleQueueCleanup();
  }

}

export class RelayHub extends DurableObject<Env> {
  private readonly sessions = new Map<WebSocket, RelaySessionAttachment>();
  private hostSocket: WebSocket | null = null;
  private readonly clientSockets = new Map<string, WebSocket>();
  private readonly revokedDevices = new Set<string>();
  private latestRemoteApps: CacheRecord<JsonValue> | null = null;
  private latestHello: CacheRecord<JsonValue> | null = null;
  private latestAgentSnapshots = new Map<string, CacheRecord<JsonValue>>();
  private retentionActivated = false;
  private cleanupAt = Infinity;
  private cleanupCursor: string | undefined;
  private lastHostSeenAt = 0;
  private lastHostSeenPersistedAt = 0;
  private alarmScheduledAt = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);

    this.ctx.blockConcurrencyWhile(async () => {
      await this.loadRelayState();
      const denied = await this.ctx.storage.list<boolean>({ prefix: "revoked-device:" });
      for (const key of denied.keys()) this.revokedDevices.add(key.slice("revoked-device:".length));
      for (const ws of this.ctx.getWebSockets()) {
        const attachment = asAttachmentSocket(ws).deserializeAttachment();
        if (!attachment || (attachment as RelaySessionAttachment).kind !== "relay") continue;
        const relayAttachment = attachment as RelaySessionAttachment;
        this.sessions.set(ws, relayAttachment);
        if (!relayAttachment.authenticated || !relayAttachment.deviceId) continue;
        if (relayAttachment.role === "client" && this.revokedDevices.has(relayAttachment.deviceId)) {
          ws.close(4003, "access revoked");
          this.sessions.delete(ws);
          continue;
        }
        if (this.closeExpiredClient(ws, relayAttachment)) continue;
        if (relayAttachment.role === "host") {
          this.hostSocket = ws;
        } else {
          this.clientSockets.set(relayAttachment.deviceId, ws);
        }
      }
      if (Number.isFinite(this.cleanupAt)) await this.scheduleAlarm(this.cleanupAt, true);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    // These paths are only reachable through the namespace binding. The public
    // Worker forwards /relay and /account/*, never /internal/*.
    if (url.pathname === "/internal/revoke-device" && request.method === "POST") {
      return this.revokeDevice(request);
    }
    if (url.pathname === "/internal/restore-device" && request.method === "POST") {
      return this.restoreDevice(request);
    }
    if (url.pathname === "/internal/host-removed" && request.method === "POST") {
      return this.hostRemoved(request);
    }
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
      try { await this.handleRelayAuth(ws, parsed); }
      catch {
        if (isSocketOpen(ws)) ws.close(1008, "authorization unavailable");
        await this.unregisterRelaySocket(ws);
      }
      return;
    }

    if (this.closeExpiredClient(ws, session)) return;

    if (!isSocketOpen(ws) || (session.role === "client" && this.revokedDevices.has(session.deviceId ?? ""))) {
      if (isSocketOpen(ws)) ws.close(4003, "access revoked");
      await this.unregisterRelaySocket(ws);
      return;
    }

    if (session.role === "client" && parsed.type === "relay_reauth") {
      await this.handleClientReauth(ws, session, parsed);
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
    let deviceLabel: string | undefined;
    let pairedAt: string | undefined;
    let authorizationExpiresAt: number | undefined;
    let reauthorizedAt: string | undefined;
    if (role === "host") {
      if (deviceId !== session.hostDeviceId) {
        ws.close(1008, "host device mismatch");
        return;
      }
      const host = await findDeviceByDeviceId(this.env, deviceId);
      if (!host || host.kind !== "host" || host.revoked_at ||
          !host.user_id || host.public_key_b64 !== publicKeyB64) {
        ws.close(1008, "host is not authorized");
        return;
      }
      userId = host.user_id;
    } else {
      const accessToken = stringField(parsed.access_token);
      if (!accessToken) {
        ws.close(1008, "access token is required");
        return;
      }
      const user = await resolveUserFromAccessToken(this.env, accessToken);
      authorizationExpiresAt = relayAuthorizationDeadline(accessToken, user);
      if (authorizationExpiresAt <= Date.now()) {
        ws.close(4001, "authentication expired");
        return;
      }
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
      if (await hasRevokedPairing(this.env, host, requester)) {
        ws.close(4003, "access revoked");
        return;
      }
      userId = user.id;
      deviceLabel = requester.label;
      pairedAt = requester.created_at;
      reauthorizedAt = pairingReauthorizedAt(await findActivePairing(this.env, host.user_id, host.id, requester.id));
    }

    // Authentication yielded to database I/O; revocation may have completed
    // meanwhile, including before this socket had an authenticated attachment.
    if (role === "client" && this.revokedDevices.has(deviceId)) {
      if (isSocketOpen(ws)) ws.close(4003, "access revoked");
      await this.unregisterRelaySocket(ws);
      return;
    }

    // The account checks above can take long enough for the socket to close, or for a
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
      deviceLabel,
      pairedAt,
      authorizationExpiresAt,
      reauthRequestedAt: undefined,
      reauthorizedAt,
      cacheRetentionVersion: parsed.cache_retention_version === 1 ? 1 : undefined,
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
      for (const client of this.clientSockets.values()) {
        const authorized = this.getRelaySession(client);
        if (authorized && !this.closeExpiredClient(client, authorized)) this.notifyHostOfClient(authorized);
      }
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
    this.notifyHostOfClient(updated);
    if (
      !sendJsonToOpenSocket(ws, { type: "auth_ok", device_id: deviceId, at: Date.now() }) ||
      !this.replayCachedState(ws)
    ) {
      await this.unregisterRelaySocket(ws);
    }
    await this.scheduleAlarm(authorizationExpiresAt ?? Date.now() + 60_000, true);
  }

  private notifyHostOfClient(session: RelaySessionAttachment): void {
    if (!this.hostSocket || !session.deviceId || this.revokedDevices.has(session.deviceId)) return;
    sendJsonToOpenSocket(this.hostSocket, {
      type: "account_device_authorized", requester_device_id: session.deviceId,
      requester_public_key_b64: session.publicKeyB64,
      requester_label: session.deviceLabel ?? "Signed-in device", paired_at: session.pairedAt,
      ...(session.reauthorizedAt ? { reauthorized_at: session.reauthorizedAt } : {}),
    });
  }

  /**
   * Renews a browser's relay authorization on the open socket. The deadline is
   * the same one the initial auth applied (token expiry, at most five minutes),
   * so the account and device checks run again without the socket dropping.
   */
  private async handleClientReauth(
    ws: WebSocket,
    session: RelaySessionAttachment,
    parsed: Record<string, unknown>,
  ): Promise<void> {
    const accessToken = stringField(parsed.access_token);
    const deviceId = session.deviceId;
    if (!accessToken || !deviceId || !session.publicKeyB64) {
      if (isSocketOpen(ws)) ws.close(1008, "access token is required");
      await this.unregisterRelaySocket(ws);
      return;
    }
    let expiresAt: number;
    let reauthorizedAt: string | undefined;
    try {
      const user = await resolveUserFromAccessToken(this.env, accessToken);
      expiresAt = relayAuthorizationDeadline(accessToken, user);
      const [host, requester] = await Promise.all([
        findDeviceByDeviceId(this.env, session.hostDeviceId),
        findDeviceByDeviceId(this.env, deviceId),
      ]);
      const authorized = expiresAt > Date.now() && user.id === session.userId && !!host && !!requester &&
        host.kind === "host" && requester.kind !== "host" && !host.revoked_at && !requester.revoked_at &&
        host.user_id === user.id && requester.user_id === user.id && requester.public_key_b64 === session.publicKeyB64;
      if (!authorized || !host || !requester) {
        if (isSocketOpen(ws)) ws.close(4001, "authentication expired");
        await this.unregisterRelaySocket(ws);
        return;
      }
      if (this.revokedDevices.has(deviceId) || (await hasRevokedPairing(this.env, host, requester))) {
        if (isSocketOpen(ws)) ws.close(4003, "access revoked");
        await this.unregisterRelaySocket(ws);
        return;
      }
      reauthorizedAt = pairingReauthorizedAt(await findActivePairing(this.env, host.user_id, host.id, requester.id));
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("auth ")) {
        if (isSocketOpen(ws)) ws.close(4001, "authentication expired");
        await this.unregisterRelaySocket(ws);
        return;
      }
      // The account service was unreachable: keep the current deadline and let
      // the browser retry before it passes.
      if (!sendJsonToOpenSocket(ws, { type: "relay_reauth_failed", retry: true, at: Date.now() })) {
        await this.unregisterRelaySocket(ws);
      }
      return;
    }
    if (!isSocketOpen(ws)) {
      await this.unregisterRelaySocket(ws);
      return;
    }
    const current = this.sessions.get(ws) ?? session;
    const updated: RelaySessionAttachment = {
      ...current, authorizationExpiresAt: expiresAt, reauthRequestedAt: undefined, reauthorizedAt,
    };
    this.sessions.set(ws, updated);
    asAttachmentSocket(ws).serializeAttachment(updated);
    if (!sendJsonToOpenSocket(ws, { type: "relay_reauth_ok", expires_at: expiresAt, at: Date.now() })) {
      await this.unregisterRelaySocket(ws);
      return;
    }
    await this.scheduleAlarm(expiresAt - RELAY_REAUTH_LEAD_MS, true);
  }

  /** Asks a browser to renew before its deadline; expired sockets still close on time. */
  private requestClientReauth(ws: WebSocket, session: RelaySessionAttachment, now: number): void {
    if (session.role !== "client" || !session.authenticated || session.reauthRequestedAt) return;
    const expiresAt = session.authorizationExpiresAt ?? 0;
    if (expiresAt <= now || expiresAt - now > RELAY_REAUTH_LEAD_MS) return;
    const updated: RelaySessionAttachment = { ...session, reauthRequestedAt: now };
    this.sessions.set(ws, updated);
    asAttachmentSocket(ws).serializeAttachment(updated);
    sendJsonToOpenSocket(ws, { type: "relay_reauth_required", expires_at: expiresAt, at: now });
  }

  private closeExpiredClient(ws: WebSocket, session: RelaySessionAttachment): boolean {
    if (session.role !== "client" || !session.authenticated ||
        (session.authorizationExpiresAt ?? 0) > Date.now()) return false;
    if (isSocketOpen(ws)) ws.close(4001, "authentication expired");
    if (session.deviceId && this.clientSockets.get(session.deviceId) === ws) this.clientSockets.delete(session.deviceId);
    this.sessions.delete(ws);
    return true;
  }

  private async handleHostRelayMessage(parsed: Record<string, unknown>): Promise<void> {
    await this.markHostSeen();
    switch (parsed.type) {
      case "relay_hello":
        this.latestHello = cacheRecord((parsed.hello as JsonValue) ?? null);
        await this.ctx.storage.put(STORAGE_RELAY_HELLO_KEY, this.latestHello);
        this.cleanupAt = Math.min(this.cleanupAt, this.latestHello.expiresAt);
        await this.scheduleAlarm(this.cleanupAt);
        this.broadcastToClients({ ...parsed, cache: this.cacheTiming(this.latestHello), cached: false });
        return;
      case "relay_remote_apps":
        this.latestRemoteApps = cacheRecord((parsed.remoteApps as JsonValue) ?? null);
        await this.ctx.storage.put(STORAGE_RELAY_REMOTE_APPS_KEY, this.latestRemoteApps);
        this.cleanupAt = Math.min(this.cleanupAt, this.latestRemoteApps.expiresAt);
        await this.scheduleAlarm(this.cleanupAt);
        this.broadcastToClients({ ...parsed, cache: this.cacheTiming(this.latestRemoteApps), cached: false });
        return;
      case "relay_agent_state": {
        const snapshot = parsed.snapshot as Record<string, JsonValue> | undefined;
        if (!snapshot || typeof snapshot.agentId !== "string" || !snapshot.agentId) return;
        if ("client_device_id" in parsed) {
          // Host permission replies are private to the requesting browser, never cached.
          const id = parsed.client_device_id;
          if (typeof id !== "string" || !id || this.revokedDevices.has(id)) return;
          const target = this.clientSockets.get(id);
          if (!target) return;
          const session = this.getRelaySession(target);
          if (!session || this.closeExpiredClient(target, session)) return;
          if (!sendToOpenSocket(target, JSON.stringify(parsed))) await this.unregisterRelaySocket(target);
          return;
        }
        const agentId = snapshot.agentId;
        const record = cacheRecord(compactRelayAgentSnapshot(snapshot as Record<string, CacheJsonValue>) as JsonValue);
        await this.ctx.storage.put(`${STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX}${encodeURIComponent(agentId)}`, record);
        this.latestAgentSnapshots.set(agentId, record);
        this.cleanupAt = Math.min(this.cleanupAt, record.expiresAt);
        await this.scheduleAlarm(this.cleanupAt);
        this.broadcastToClients({ ...parsed, cache: this.cacheTiming(record), cached: false });
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
        if (!target || this.revokedDevices.has(clientDeviceId)) return;
        const session = this.getRelaySession(target);
        if (!session || this.closeExpiredClient(target, session)) return;
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
    if (!isSocketOpen(ws) || this.revokedDevices.has(session.deviceId ?? "")) return;
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
    if (this.revokedDevices.has(this.getRelaySession(ws)?.deviceId ?? "")) return false;
    const frames: Record<string, unknown>[] = [
      {
        type: "relay_presence",
        online: this.hostSocket != null,
        last_seen_at: this.lastHostSeenAt,
      },
    ];
    if (validCacheRecord(this.latestHello)) {
      frames.push({ type: "relay_hello", hello: this.latestHello.data, cached: true, cache: this.cacheTiming(this.latestHello) });
    }
    if (validCacheRecord(this.latestRemoteApps)) {
      frames.push({
        type: "relay_remote_apps",
        remoteApps: this.latestRemoteApps.data,
        cached: true,
        cache: this.cacheTiming(this.latestRemoteApps),
      });
    }
    for (const record of this.latestAgentSnapshots.values()) {
      if (validCacheRecord(record)) frames.push({ type: "relay_agent_state", snapshot: record.data, cached: true, cache: this.cacheTiming(record) });
    }
    if (this.getRelaySession(ws)?.cacheRetentionVersion === 1) frames.push(this.cacheManifest());
    return frames.every((frame) => sendJsonToOpenSocket(ws, frame));
  }

  private cacheTiming(record: CacheRecord) {
    // remainingMs lets a browser place the deadline on its own clock; the
    // absolute stamps are the relay's clock and may run ahead of the phone's.
    return {
      version: record.version, receivedAt: record.receivedAt, expiresAt: record.expiresAt,
      remainingMs: Math.max(0, record.expiresAt - Date.now()),
    };
  }

  private cacheManifest(): Record<string, unknown> {
    return { type: 'relay_cache_manifest',
      hello: validCacheRecord(this.latestHello), remoteApps: validCacheRecord(this.latestRemoteApps),
      agentIds: [...this.latestAgentSnapshots].filter(([, value]) => validCacheRecord(value)).map(([id]) => id),
    };
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
    for (const [deviceId, ws] of this.clientSockets) {
      if (this.revokedDevices.has(deviceId)) continue;
      const session = this.getRelaySession(ws);
      if (!session || this.closeExpiredClient(ws, session)) continue;
      // Closed sockets are skipped here and removed by their close/error callbacks.
      sendToOpenSocket(ws, raw);
    }
  }

  private async revokeDevice(request: Request): Promise<Response> {
    try {
      const body = await readJsonBody<Record<string, unknown>>(request);
      const hostDeviceId = stringField(body.hostDeviceId);
      const deviceId = stringField(body.deviceId);
      const [host, requester] = await Promise.all([
        findDeviceByDeviceId(this.env, hostDeviceId),
        findDeviceByDeviceId(this.env, deviceId),
      ]);
      if (!host || host.kind !== "host" || host.revoked_at ||
          host.public_key_b64 !== stringField(body.hostPublicKeyB64) ||
          !requester || requester.kind === "host" || requester.user_id !== host.user_id ||
          !this.ctx.id.equals(this.env.RELAY_HUB.idFromName(hostDeviceId))) {
        return json({ ok: false, error: "revocation is not authorized" }, { status: 403 });
      }

      this.revokedDevices.add(deviceId);
      for (const [ws, session] of this.sessions) {
        if (session.role !== "client" || session.deviceId !== deviceId) continue;
        if (isSocketOpen(ws)) ws.close(4003, "access revoked");
        await this.unregisterRelaySocket(ws);
      }
      // Durable denial is established before the account acknowledgement. A
      // database outage leaves access denied and the host can retry confirmation.
      await this.ctx.storage.put(`revoked-device:${deviceId}`, true);
      await convexMutation(this.env, convexAccountPlane.revokePairing, {
        ownerUserId: host.user_id,
        hostDeviceUuid: host.id,
        requesterDeviceUuid: requester.id,
        metadata: { revoked_via: "host" },
      });
      return json({ ok: true, device_id: deviceId });
    } catch {
      return json({ ok: false, error: "Could not confirm revocation. Retry on the Mac." }, { status: 503 });
    }
  }

  /** Internal binding only: a link-code claim lifts this browser's relay denial. */
  private async restoreDevice(request: Request): Promise<Response> {
    try {
      const body = await readJsonBody<Record<string, unknown>>(request);
      const hostDeviceId = stringField(body.hostDeviceId);
      const deviceId = stringField(body.deviceId);
      if (!hostDeviceId || !deviceId || !this.ctx.id.equals(this.env.RELAY_HUB.idFromName(hostDeviceId))) {
        return json({ ok: false, error: "restore is not authorized" }, { status: 403 });
      }
      const [host, requester] = await Promise.all([
        findDeviceByDeviceId(this.env, hostDeviceId),
        findDeviceByDeviceId(this.env, deviceId),
      ]);
      if (!host || host.kind !== "host" || host.revoked_at || !requester || requester.kind === "host" ||
          requester.revoked_at || requester.user_id !== host.user_id) {
        return json({ ok: false, error: "restore is not authorized" }, { status: 403 });
      }
      this.revokedDevices.delete(deviceId);
      await this.ctx.storage.delete(`revoked-device:${deviceId}`);
      return json({ ok: true, device_id: deviceId });
    } catch {
      return json({ ok: false, error: "Could not restore relay access." }, { status: 503 });
    }
  }

  /**
   * Internal binding only: the account owner removed this Mac from the
   * account. Refused unless this object is that Mac's relay and the account
   * plane no longer lists the Mac as an active host, so it can never wipe the
   * relay of a linked Mac (including one re-linked in the meantime).
   *
   * Closes every socket, browsers first and then the Mac, with 4003
   * "mac removed from account". The Mac reconnects like any unlinked Mac and
   * is refused until it is linked again. Then deletes the cached hello, apps
   * and agent snapshots. Browser denials (revoked-device:*) and the retention
   * marker stay, so a re-linked Mac starts clean and publishes fresh content.
   */
  private async hostRemoved(request: Request): Promise<Response> {
    try {
      const body = await readJsonObject(request);
      const hostDeviceId = stringField(body.hostDeviceId);
      if (!hostDeviceId || !this.ctx.id.equals(this.env.RELAY_HUB.idFromName(hostDeviceId))) {
        return json({ ok: false, error: "removal is not authorized" }, { status: 403 });
      }
      const host = await findDeviceByDeviceId(this.env, hostDeviceId);
      if (host && host.kind === "host" && !host.revoked_at) {
        // Linked again before this ran. Browsers signed in to an account that
        // no longer has the Mac lose access now, not at their next renewal.
        const closed = await this.closeRelaySockets(
          (session) => session?.role === "client" && session.authenticated && session.userId !== host.user_id,
        );
        return json({ ok: false, error: "this Mac is still linked", closed }, { status: 409 });
      }

      const closed = await this.closeRelaySockets(() => true);
      const deleted = await this.deleteCachedContent();
      return json({ ok: true, closed, deleted });
    } catch {
      return json({ ok: false, error: "Could not clear this Mac's relay." }, { status: 503 });
    }
  }

  /**
   * Closes the matching sockets (authenticated or still authenticating) with
   * the removal close, browsers before the Mac so none sees a presence change
   * first, and forgets them. Returns how many were open.
   */
  private async closeRelaySockets(matches: (session: RelaySessionAttachment | null) => boolean): Promise<number> {
    const sockets = this.ctx.getWebSockets().filter((ws) => matches(this.getRelaySession(ws)));
    const isHost = (ws: WebSocket) => this.getRelaySession(ws)?.role === "host";
    let closed = 0;
    for (const ws of [...sockets.filter((ws) => !isHost(ws)), ...sockets.filter(isHost)]) {
      if (isSocketOpen(ws)) {
        try {
          ws.close(HOST_REMOVED_CLOSE_CODE, HOST_REMOVED_CLOSE_REASON);
          closed += 1;
        } catch {
          // Already closing.
        }
      }
      await this.unregisterRelaySocket(ws);
    }
    return closed;
  }

  /** Deletes every cache record this relay keeps for replay, in memory and in storage. */
  private async deleteCachedContent(): Promise<number> {
    this.latestHello = null;
    this.latestRemoteApps = null;
    this.latestAgentSnapshots.clear();
    let deleted = await this.ctx.storage.delete([
      STORAGE_RELAY_HELLO_KEY,
      STORAGE_RELAY_REMOTE_APPS_KEY,
      STORAGE_RELAY_AGENT_SNAPSHOTS_KEY,
    ]);
    for (;;) {
      const page = await this.ctx.storage.list({ prefix: STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX, limit: CACHE_CLEANUP_BATCH });
      if (page.size === 0) break;
      const removed = await this.ctx.storage.delete([...page.keys()]);
      if (removed === 0) throw new Error("relay cache deletion made no progress");
      deleted += removed;
    }
    this.cleanupAt = Infinity;
    this.cleanupCursor = undefined;
    return deleted;
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
    this.retentionActivated = (await this.ctx.storage.get(STORAGE_RETENTION_ACTIVE_KEY)) === true;
    let cursor: string | undefined;
    let hasRecords = false;
    do {
      const page = await this.cachePage(cursor);
      for (const [key, value] of page.entries) {
        hasRecords = true;
        if (this.validStoredCopy(key, value)) {
          const record = value as CacheRecord<JsonValue>;
          if (key === STORAGE_RELAY_HELLO_KEY) this.latestHello = record;
          else if (key === STORAGE_RELAY_REMOTE_APPS_KEY) this.latestRemoteApps = record;
          else this.latestAgentSnapshots.set((record.data as { agentId: string }).agentId, record);
          this.cleanupAt = Math.min(this.cleanupAt, record.expiresAt);
        } else if (this.retentionActivated) {
          this.cleanupAt = Date.now();
        }
      }
      cursor = page.cursor;
    } while (cursor);
    if (!hasRecords && !this.retentionActivated) {
      // Newly created objects need no legacy migration. Existing replicas stay
      // unreadable until the operator's inventory-then-apply sweep visits them.
      this.retentionActivated = true;
      await this.ctx.storage.put(STORAGE_RETENTION_ACTIVE_KEY, true);
    }
    this.lastHostSeenAt =
      (await this.ctx.storage.get<number>(STORAGE_RELAY_LAST_HOST_SEEN_KEY)) ?? 0;
    this.lastHostSeenPersistedAt = this.lastHostSeenAt;
  }

  private validStoredCopy(key: string, value: unknown): value is CacheRecord<JsonValue> {
    if (!validCacheRecord(value) || key === STORAGE_RELAY_AGENT_SNAPSHOTS_KEY) return false;
    if (key === STORAGE_RELAY_HELLO_KEY || key === STORAGE_RELAY_REMOTE_APPS_KEY) return true;
    const data = value.data as { agentId?: unknown } | null;
    return !!data && typeof data.agentId === 'string' && !!data.agentId &&
      key === `${STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX}${encodeURIComponent(data.agentId)}`;
  }

  private async cachePage(cursor?: string) {
    if (cursor !== undefined && !cursor.startsWith(STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX)) throw new Error('Invalid cache cursor');
    const agents = await this.ctx.storage.list<unknown>({ prefix: STORAGE_RELAY_AGENT_SNAPSHOT_PREFIX, limit: CACHE_CLEANUP_BATCH, startAfter: cursor });
    const entries = cursor ? new Map<string, unknown>() : await this.ctx.storage.get<unknown>([
      STORAGE_RELAY_HELLO_KEY, STORAGE_RELAY_REMOTE_APPS_KEY, STORAGE_RELAY_AGENT_SNAPSHOTS_KEY,
    ]);
    for (const [key, value] of agents) entries.set(key, value);
    return { entries, cursor: agents.size === CACHE_CLEANUP_BATCH ? [...agents.keys()].at(-1) : undefined };
  }

  // RPC only: not forwarded by the public fetch handler. Returns counts and an
  // opaque pagination cursor, never payloads. The operator inventories all pages
  // before applying, and retains its resumable ledger outside the public repo.
  async cacheMaintenance(options: { dryRun: boolean; cursor?: string }) {
    // Only KV awaits occur here. Durable Object storage input gates serialize
    // these reads/deletes with host publications without resetting the object
    // on a recoverable cleanup error.
    if (typeof options?.dryRun !== 'boolean') throw new Error('dryRun is required');
    const page = await this.cachePage(options.cursor);
    const invalid = [...page.entries].filter(([key, value]) => !this.validStoredCopy(key, value)).map(([key]) => key);
    let deleted = 0;
    if (!options.dryRun) {
      if (invalid.length) deleted = await this.ctx.storage.delete(invalid);
      if (!page.cursor) {
        this.retentionActivated = true;
        await this.ctx.storage.put(STORAGE_RETENTION_ACTIVE_KEY, true);
      }
      this.pruneMemory();
      this.cleanupAt = page.cursor ? Date.now() + 1_000 : this.nextCacheExpiry();
      if (Number.isFinite(this.cleanupAt)) await this.scheduleAlarm(this.cleanupAt, true);
    }
    return { scanned: page.entries.size, invalid: invalid.length, fresh: page.entries.size - invalid.length, deleted, cursor: page.cursor ?? null,
      active: this.retentionActivated, cleanupFailures: await this.ctx.storage.get<number>('retentionCleanupFailures') ?? 0,
      nextAlarmAt: await this.ctx.storage.getAlarm() };
  }

  private pruneMemory(): void {
    if (!validCacheRecord(this.latestHello)) this.latestHello = null;
    if (!validCacheRecord(this.latestRemoteApps)) this.latestRemoteApps = null;
    for (const [id, record] of this.latestAgentSnapshots) if (!validCacheRecord(record)) this.latestAgentSnapshots.delete(id);
  }

  private nextCacheExpiry(): number {
    return Math.min(this.latestHello?.expiresAt ?? Infinity, this.latestRemoteApps?.expiresAt ?? Infinity,
      ...[...this.latestAgentSnapshots.values()].map((record) => record.expiresAt));
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    this.alarmScheduledAt = 0;
    this.pruneMemory();
    if (this.retentionActivated && this.cleanupAt <= now) {
      try {
        const result = await this.cacheMaintenance({ dryRun: false, cursor: this.cleanupCursor });
        this.cleanupCursor = result.cursor ?? undefined;
        await this.ctx.storage.delete('retentionCleanupFailures');
      } catch {
        const failures = (await this.ctx.storage.get<number>('retentionCleanupFailures') ?? 0) + 1;
        await this.ctx.storage.put('retentionCleanupFailures', failures);
        this.cleanupAt = now + Math.min(15 * 60_000, 30_000 * 2 ** Math.min(failures, 5));
        console.error('Relay cache cleanup failed; retry scheduled');
      }
    } else if (!this.retentionActivated) {
      this.cleanupAt = this.nextCacheExpiry();
    }
    for (const ws of this.clientSockets.values()) {
      const session = this.getRelaySession(ws);
      if (session?.cacheRetentionVersion === 1 && !this.closeExpiredClient(ws, session)) sendJsonToOpenSocket(ws, this.cacheManifest());
    }
    for (const [ws, session] of this.sessions) this.requestClientReauth(ws, session, now);
    for (const [ws, session] of this.sessions) this.closeExpiredClient(ws, session);
    const host = this.hostSocket;
    if (host) {
      const silentMs = now - this.lastHostSeenAt;
      if (this.lastHostSeenAt > 0 && silentMs >= HOST_SILENCE_CLOSE_MS) {
        // Phones would otherwise keep seeing the Mac online while their screen
        // start requests are forwarded into a dead socket and acknowledged.
        try {
          host.close(1001, "host silent");
        } catch {
          // Already closing.
        }
        await this.unregisterRelaySocket(host);
        if (Number.isFinite(this.cleanupAt)) await this.scheduleAlarm(this.cleanupAt, true);
        return;
      }
      await this.scheduleAlarm(now + Math.max(1_000, HOST_SILENCE_CLOSE_MS - silentMs), true);
      return;
    }
    if (this.lastHostSeenAt > 0 && now - this.lastHostSeenAt >= RELAY_PRESENCE_STALE_MS) {
      this.broadcastPresence(false);
    }
    if (this.clientSockets.size || Number.isFinite(this.cleanupAt)) await this.scheduleAlarm(now + 5 * 60_000, true);
    else await this.ctx.storage.deleteAlarm();
  }

  private async markHostSeen(forcePersist = false): Promise<void> {
    const now = Date.now();
    this.lastHostSeenAt = now;
    if (forcePersist || now - this.lastHostSeenPersistedAt >= RELAY_LAST_SEEN_PERSIST_INTERVAL_MS) {
      this.lastHostSeenPersistedAt = now;
      await this.ctx.storage.put(STORAGE_RELAY_LAST_HOST_SEEN_KEY, now);
    }
    const horizon = this.hostSocket ? HOST_SILENCE_CLOSE_MS : RELAY_PRESENCE_STALE_MS;
    await this.scheduleAlarm(now + horizon, forcePersist);
  }

  /** Moves the alarm, skipping the storage write when it moved moments ago. */
  private async scheduleAlarm(at: number, force = false): Promise<void> {
    at = Math.min(at, this.cleanupAt);
    if (this.hostSocket) at = Math.min(at, this.lastHostSeenAt + HOST_SILENCE_CLOSE_MS);
    for (const session of this.sessions.values()) {
      if (session.role !== "client" || !session.authenticated) continue;
      const expiresAt = session.authorizationExpiresAt ?? Date.now();
      at = Math.min(at, session.reauthRequestedAt ? expiresAt : expiresAt - RELAY_REAUTH_LEAD_MS);
    }
    if (
      !force &&
      this.alarmScheduledAt > 0 &&
      Math.abs(at - this.alarmScheduledAt) < RELAY_ALARM_REFRESH_MIN_INTERVAL_MS
    ) {
      return;
    }
    this.alarmScheduledAt = at;
    await this.ctx.storage.setAlarm(at);
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
