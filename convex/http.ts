import { httpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { authComponent, createAuth } from "./auth";

declare const process: { env: Record<string, string | undefined> };

const http = httpRouter();

authComponent.registerRoutes(http, createAuth, {
  cors: {
    allowedHeaders: [
      "authorization",
      "content-type",
      "better-auth-cookie",
      "x-better-auth-forwarded-host",
      "x-better-auth-forwarded-proto",
    ],
    exposedHeaders: ["set-auth-token", "set-auth-jwt", "set-better-auth-cookie"],
  },
});

/**
 * The only door into the account plane. The Cloudflare Worker calls it with
 * `Authorization: Bearer <WORKER_CONVEX_SECRET>`; every function behind it is
 * internal, so nothing here is reachable from a browser or with only a
 * deployment URL. Server-to-server only: no CORS headers.
 */
const QUERIES = {
  findDeviceByDeviceId: internal.accountPlane.findDeviceByDeviceId,
  findDeviceByUuid: internal.accountPlane.findDeviceByUuid,
  findProfileByUserId: internal.accountPlane.findProfileByUserId,
  listHostDevicesForUser: internal.accountPlane.listHostDevicesForUser,
  listPairingsForRequester: internal.accountPlane.listPairingsForRequester,
  findActivePairing: internal.accountPlane.findActivePairing,
  hasRevokedPairing: internal.accountPlane.hasRevokedPairing,
  findPendingApproval: internal.accountPlane.findPendingApproval,
  findApprovalById: internal.accountPlane.findApprovalById,
  listPendingApprovalsByHost: internal.accountPlane.listPendingApprovalsByHost,
  getUnconsumedHostLinkCode: internal.accountPlane.getUnconsumedHostLinkCode,
  verifyBearerToken: internal.auth.verifyBearerToken,
} as const;

const MUTATIONS = {
  upsertUserDevice: internal.accountPlane.upsertUserDevice,
  touchDeviceLastSeen: internal.accountPlane.touchDeviceLastSeen,
  insertApprovalRequest: internal.accountPlane.insertApprovalRequest,
  markApprovalStatus: internal.accountPlane.markApprovalStatus,
  ensurePairing: internal.accountPlane.ensurePairing,
  createHostLinkCode: internal.accountPlane.createHostLinkCode,
  consumeHostLinkCode: internal.accountPlane.consumeHostLinkCode,
  deleteHostLinkCodesByHostDeviceId: internal.accountPlane.deleteHostLinkCodesByHostDeviceId,
  deleteDeviceByUuid: internal.accountPlane.deleteDeviceByUuid,
  deleteRevokedPairings: internal.accountPlane.deleteRevokedPairings,
  revokePairing: internal.accountPlane.revokePairing,
} as const;

const encoder = new TextEncoder();

/** Compares two secrets without leaking their common prefix length through timing. */
function secretsMatch(provided: string, expected: string): boolean {
  const a = encoder.encode(provided);
  const b = encoder.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

http.route({
  path: "/worker/account-plane",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const expected = (process.env.WORKER_CONVEX_SECRET ?? "").trim();
    if (expected.length < 32) {
      return reply(503, { ok: false, code: "gateway_not_configured" });
    }
    const provided = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!provided || !secretsMatch(provided, expected)) {
      return reply(401, { ok: false, code: "unauthorized" });
    }

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return reply(400, { ok: false, code: "bad_request" });
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return reply(400, { ok: false, code: "bad_request" });
    }
    const { fn: rawFn, args: rawArgs } = body as { fn?: unknown; args?: unknown };
    if (rawArgs !== undefined && (!rawArgs || typeof rawArgs !== "object" || Array.isArray(rawArgs))) {
      return reply(400, { ok: false, code: "bad_request" });
    }
    const fn = typeof rawFn === "string" ? rawFn : "";
    const args = (rawArgs ?? {}) as Record<string, unknown>;

    try {
      if (Object.hasOwn(QUERIES, fn)) {
        const value = await ctx.runQuery(QUERIES[fn as keyof typeof QUERIES] as any, args as any);
        return reply(200, { ok: true, value: value ?? null });
      }
      if (Object.hasOwn(MUTATIONS, fn)) {
        const value = await ctx.runMutation(MUTATIONS[fn as keyof typeof MUTATIONS] as any, args as any);
        return reply(200, { ok: true, value: value ?? null });
      }
      return reply(404, { ok: false, code: "unknown_function" });
    } catch (error) {
      if (error instanceof ConvexError) {
        const data = error.data as { code?: unknown } | string;
        const code = typeof data === "object" && data && typeof data.code === "string" ? data.code : "rejected";
        return reply(409, { ok: false, code });
      }
      // Never log the error object: argument validation errors echo the
      // arguments, which can include session tokens.
      console.error(`account-plane ${fn} failed: ${error instanceof Error ? error.name : "unknown"}`);
      return reply(500, { ok: false, code: "internal" });
    }
  }),
});

export default http;
