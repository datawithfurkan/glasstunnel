// Internal only: the Cloudflare Worker reaches these through the
// shared-secret gateway in http.ts. Nothing here is callable from a browser.
import { ConvexError, v } from "convex/values";
import { components } from "./_generated/api";
import { internalMutation as mutation, internalQuery as query } from "./_generated/server";
import type { Doc } from "./_generated/dataModel";

const nullableString = v.union(v.string(), v.null());
const metadataValue = v.any();

const profileRow = v.object({
  user_id: v.string(),
  email: nullableString,
  display_name: nullableString,
  avatar_url: nullableString,
});

const deviceKind = v.union(v.literal("host"), v.literal("phone"), v.literal("browser"));

const deviceRow = v.object({
  id: v.string(),
  user_id: v.string(),
  device_id: v.string(),
  public_key_b64: v.string(),
  label: v.string(),
  kind: deviceKind,
  platform: nullableString,
  app_version: nullableString,
  last_seen_at: nullableString,
  revoked_at: nullableString,
  metadata: metadataValue,
  created_at: v.string(),
  updated_at: v.string(),
});

const pairingRow = v.object({
  id: v.string(),
  owner_user_id: v.string(),
  host_device_uuid: v.string(),
  phone_device_uuid: v.string(),
  paired_at: v.string(),
  revoked_at: nullableString,
  metadata: metadataValue,
});

const approvalStatus = v.union(
  v.literal("pending"),
  v.literal("approved"),
  v.literal("rejected"),
  v.literal("expired"),
  v.literal("cancelled"),
);

const approvalRow = v.object({
  id: v.string(),
  owner_user_id: v.string(),
  host_device_uuid: v.string(),
  requester_device_uuid: v.string(),
  requester_device_id: v.string(),
  requester_public_key_b64: v.string(),
  requester_label: v.string(),
  status: approvalStatus,
  metadata: metadataValue,
  created_at: v.string(),
  updated_at: v.string(),
  responded_at: nullableString,
});

const hostLinkCodeRow = v.object({
  id: v.string(),
  code: v.string(),
  host_device_id: v.string(),
  host_public_key_b64: v.string(),
  host_label: v.string(),
  host_metadata: metadataValue,
  created_at: v.string(),
  expires_at: v.string(),
  consumed_at: nullableString,
  claimed_user_id: nullableString,
});

const pairScope = v.object({
  ownerUserId: v.string(),
  hostDeviceUuid: v.string(),
  requesterDeviceUuid: v.string(),
});

function nowIso(): string {
  return new Date().toISOString();
}

function generatedLegacyId(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
  const uuid = `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex
    .slice(6, 8)
    .join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10, 16).join("")}`;
  return `${prefix}:${uuid}`;
}

function asKind(value: string): "host" | "phone" | "browser" {
  if (value === "host" || value === "phone" || value === "browser") return value;
  throw new Error(`unsupported device kind: ${value}`);
}

function profileToRow(doc: Doc<"accountProfiles">): typeof profileRow.type {
  return {
    user_id: doc.legacyUserId,
    email: doc.email,
    display_name: doc.displayName,
    avatar_url: doc.avatarUrl,
  };
}

function deviceToRow(doc: Doc<"accountDevices">): typeof deviceRow.type {
  return {
    id: doc.legacyId,
    user_id: doc.legacyUserId,
    device_id: doc.deviceId,
    public_key_b64: doc.publicKeyB64,
    label: doc.label,
    kind: asKind(doc.kind),
    platform: doc.platform,
    app_version: doc.appVersion,
    last_seen_at: doc.lastSeenAt,
    revoked_at: doc.revokedAt,
    metadata: doc.metadata,
    created_at: doc.createdAt,
    updated_at: doc.updatedAt,
  };
}

function pairingToRow(doc: Doc<"devicePairings">): typeof pairingRow.type {
  return {
    id: doc.legacyId,
    owner_user_id: doc.ownerUserId,
    host_device_uuid: doc.hostDeviceUuid,
    phone_device_uuid: doc.phoneDeviceUuid,
    paired_at: doc.pairedAt,
    revoked_at: doc.revokedAt,
    metadata: doc.metadata,
  };
}

function approvalToRow(doc: Doc<"deviceApprovalRequests">): typeof approvalRow.type {
  return {
    id: doc.legacyId,
    owner_user_id: doc.ownerUserId,
    host_device_uuid: doc.hostDeviceUuid,
    requester_device_uuid: doc.requesterDeviceUuid,
    requester_device_id: doc.requesterDeviceId,
    requester_public_key_b64: doc.requesterPublicKeyB64,
    requester_label: doc.requesterLabel,
    status: doc.status as typeof approvalStatus.type,
    metadata: doc.metadata,
    created_at: doc.createdAt,
    updated_at: doc.updatedAt,
    responded_at: doc.respondedAt,
  };
}

function hostLinkCodeToRow(doc: Doc<"hostLinkCodes">): typeof hostLinkCodeRow.type {
  return {
    id: doc.legacyId,
    code: doc.code,
    host_device_id: doc.hostDeviceId,
    host_public_key_b64: doc.hostPublicKeyB64,
    host_label: doc.hostLabel,
    host_metadata: doc.hostMetadata,
    created_at: doc.createdAt,
    expires_at: doc.expiresAt,
    consumed_at: doc.consumedAt,
    claimed_user_id: doc.claimedUserId,
  };
}

export const findDeviceByDeviceId = query({
  args: { deviceId: v.string() },
  returns: v.union(deviceRow, v.null()),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("accountDevices")
      .withIndex("by_device_id", (q) => q.eq("deviceId", args.deviceId))
      .first();
    return doc ? deviceToRow(doc) : null;
  },
});

export const findDeviceByUuid = query({
  args: { id: v.string() },
  returns: v.union(deviceRow, v.null()),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("accountDevices")
      .withIndex("by_legacy_id", (q) => q.eq("legacyId", args.id))
      .first();
    return doc ? deviceToRow(doc) : null;
  },
});

export const findProfileByUserId = query({
  args: { userId: v.string() },
  returns: v.union(profileRow, v.null()),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("accountProfiles")
      .withIndex("by_legacy_user_id", (q) => q.eq("legacyUserId", args.userId))
      .first();
    if (doc) return profileToRow(doc);
    // Accounts created after the Supabase migration have no profile row; the
    // Better Auth user carries the same fields. Imported users are matched by
    // their legacy id, newer ones by the Better Auth id the Worker sees.
    const byLegacy = (await ctx.runQuery(components.betterAuth.adapter.findOne, {
      model: "user",
      where: [{ field: "userId", value: args.userId }],
    })) as Record<string, unknown> | null;
    const user =
      byLegacy ??
      (/^[a-z0-9]{20,}$/.test(args.userId)
        ? ((await ctx.runQuery(components.betterAuth.adapter.findOne, {
            model: "user",
            where: [{ field: "_id", value: args.userId }],
          })) as Record<string, unknown> | null)
        : null);
    if (!user) return null;
    const text = (value: unknown) => (typeof value === "string" && value ? value : null);
    return {
      user_id: args.userId,
      email: text(user.email),
      display_name: text(user.name),
      avatar_url: text(user.image),
    };
  },
});

export const listHostDevicesForUser = query({
  args: { userId: v.string(), limit: v.optional(v.number()) },
  returns: v.array(deviceRow),
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(Math.trunc(args.limit ?? 100), 1), 500);
    const docs = await ctx.db
      .query("accountDevices")
      .withIndex("by_legacy_user_kind_created_at", (q) =>
        q.eq("legacyUserId", args.userId).eq("kind", "host"),
      )
      .order("desc")
      .filter((q) => q.eq(q.field("revokedAt"), null))
      .take(limit);
    return docs.map(deviceToRow);
  },
});

export const listPairingsForRequester = query({
  args: { ownerUserId: v.string(), requesterDeviceUuid: v.string(), limit: v.optional(v.number()) },
  returns: v.array(pairingRow),
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(Math.trunc(args.limit ?? 200), 1), 500);
    const docs = await ctx.db
      .query("devicePairings")
      .withIndex("by_phone_device_uuid", (q) => q.eq("phoneDeviceUuid", args.requesterDeviceUuid))
      .filter((q) => q.eq(q.field("ownerUserId"), args.ownerUserId))
      .take(limit);
    return docs.map(pairingToRow);
  },
});

export const findActivePairing = query({
  args: pairScope,
  returns: v.union(pairingRow, v.null()),
  handler: async (ctx, args) => {
    const docs = await ctx.db
      .query("devicePairings")
      .withIndex("by_owner_host_phone", (q) =>
        q
          .eq("ownerUserId", args.ownerUserId)
          .eq("hostDeviceUuid", args.hostDeviceUuid)
          .eq("phoneDeviceUuid", args.requesterDeviceUuid),
      )
      .take(20);
    const doc = docs.find((row) => row.revokedAt === null);
    return doc ? pairingToRow(doc) : null;
  },
});

export const hasRevokedPairing = query({
  args: pairScope,
  returns: v.boolean(),
  handler: async (ctx, args) => {
    const docs = await ctx.db
      .query("devicePairings")
      .withIndex("by_owner_host_phone", (q) =>
        q
          .eq("ownerUserId", args.ownerUserId)
          .eq("hostDeviceUuid", args.hostDeviceUuid)
          .eq("phoneDeviceUuid", args.requesterDeviceUuid),
      )
      .take(20);
    return docs.some((row) => row.revokedAt !== null);
  },
});

export const findPendingApproval = query({
  args: { hostDeviceUuid: v.string(), requesterDeviceUuid: v.string() },
  returns: v.union(approvalRow, v.null()),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("deviceApprovalRequests")
      .withIndex("by_host_requester_status", (q) =>
        q
          .eq("hostDeviceUuid", args.hostDeviceUuid)
          .eq("requesterDeviceUuid", args.requesterDeviceUuid)
          .eq("status", "pending"),
      )
      .first();
    return doc ? approvalToRow(doc) : null;
  },
});

export const findApprovalById = query({
  args: { requestId: v.string() },
  returns: v.union(approvalRow, v.null()),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("deviceApprovalRequests")
      .withIndex("by_legacy_id", (q) => q.eq("legacyId", args.requestId))
      .first();
    return doc ? approvalToRow(doc) : null;
  },
});

export const listPendingApprovalsByHost = query({
  args: { hostDeviceUuid: v.string(), limit: v.optional(v.number()) },
  returns: v.array(approvalRow),
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(Math.trunc(args.limit ?? 100), 1), 500);
    const docs = await ctx.db
      .query("deviceApprovalRequests")
      .withIndex("by_host_status_created_at", (q) =>
        q.eq("hostDeviceUuid", args.hostDeviceUuid).eq("status", "pending"),
      )
      .order("asc")
      .take(limit);
    return docs.map(approvalToRow);
  },
});

export const upsertUserDevice = mutation({
  args: {
    userId: v.string(),
    deviceId: v.string(),
    publicKeyB64: v.string(),
    label: v.string(),
    kind: deviceKind,
    platform: v.optional(v.string()),
    appVersion: v.optional(v.string()),
    metadata: v.optional(metadataValue),
  },
  returns: deviceRow,
  handler: async (ctx, args) => {
    const at = nowIso();
    const existing = await ctx.db
      .query("accountDevices")
      .withIndex("by_device_id", (q) => q.eq("deviceId", args.deviceId))
      .first();
    if (existing) {
      if (existing.legacyUserId !== args.userId) {
        throw new ConvexError({ code: "device_belongs_to_another_account" });
      }
      if (
        existing.revokedAt !== null ||
        existing.publicKeyB64 !== args.publicKeyB64 ||
        (existing.kind === "host") !== (args.kind === "host")
      ) {
        throw new ConvexError({ code: "device_registration_not_authorized" });
      }
      await ctx.db.patch(existing._id, {
        label: args.label,
        platform: args.platform ?? null,
        appVersion: args.appVersion ?? null,
        metadata: args.metadata ?? {},
        lastSeenAt: at,
        updatedAt: at,
      });
      const updated = await ctx.db.get(existing._id);
      if (!updated || updated.revokedAt !== null) {
        throw new ConvexError({ code: "device_registration_not_authorized" });
      }
      return deviceToRow(updated);
    }

    const id = await ctx.db.insert("accountDevices", {
      legacyId: generatedLegacyId("convex-device"),
      legacyUserId: args.userId,
      deviceId: args.deviceId,
      publicKeyB64: args.publicKeyB64,
      label: args.label,
      kind: args.kind,
      platform: args.platform ?? null,
      appVersion: args.appVersion ?? null,
      lastSeenAt: at,
      revokedAt: null,
      metadata: args.metadata ?? {},
      createdAt: at,
      updatedAt: at,
    });
    const inserted = await ctx.db.get(id);
    if (!inserted) throw new Error("device insert failed");
    return deviceToRow(inserted);
  },
});

export const touchDeviceLastSeen = mutation({
  args: { deviceId: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("accountDevices")
      .withIndex("by_device_id", (q) => q.eq("deviceId", args.deviceId))
      .first();
    if (doc) {
      const at = nowIso();
      await ctx.db.patch(doc._id, { lastSeenAt: at, updatedAt: at });
    }
    return null;
  },
});

export const insertApprovalRequest = mutation({
  args: {
    ownerUserId: v.string(),
    hostDeviceUuid: v.string(),
    requesterDeviceUuid: v.string(),
    requesterDeviceId: v.string(),
    requesterPublicKeyB64: v.string(),
    requesterLabel: v.string(),
  },
  returns: approvalRow,
  handler: async (ctx, args) => {
    const pending = await ctx.db
      .query("deviceApprovalRequests")
      .withIndex("by_host_requester_status", (q) =>
        q
          .eq("hostDeviceUuid", args.hostDeviceUuid)
          .eq("requesterDeviceUuid", args.requesterDeviceUuid)
          .eq("status", "pending"),
      )
      .first();
    if (pending) return approvalToRow(pending);
    const at = nowIso();
    const id = await ctx.db.insert("deviceApprovalRequests", {
      legacyId: generatedLegacyId("convex-approval"),
      ownerUserId: args.ownerUserId,
      hostDeviceUuid: args.hostDeviceUuid,
      requesterDeviceUuid: args.requesterDeviceUuid,
      requesterDeviceId: args.requesterDeviceId,
      requesterPublicKeyB64: args.requesterPublicKeyB64,
      requesterLabel: args.requesterLabel,
      status: "pending",
      metadata: {},
      createdAt: at,
      updatedAt: at,
      respondedAt: null,
    });
    const inserted = await ctx.db.get(id);
    if (!inserted) throw new Error("approval insert failed");
    return approvalToRow(inserted);
  },
});

export const markApprovalStatus = mutation({
  args: { requestId: v.string(), status: approvalStatus },
  returns: v.null(),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("deviceApprovalRequests")
      .withIndex("by_legacy_id", (q) => q.eq("legacyId", args.requestId))
      .first();
    if (doc) {
      const at = nowIso();
      await ctx.db.patch(doc._id, {
        status: args.status,
        updatedAt: at,
        respondedAt: at,
      });
    }
    return null;
  },
});

export const ensurePairing = mutation({
  args: { ...pairScope.fields, metadata: v.optional(metadataValue) },
  returns: pairingRow,
  handler: async (ctx, args) => {
    const [host, requester] = await Promise.all([
      ctx.db.query("accountDevices").withIndex("by_legacy_id", (q) => q.eq("legacyId", args.hostDeviceUuid)).first(),
      ctx.db.query("accountDevices").withIndex("by_legacy_id", (q) => q.eq("legacyId", args.requesterDeviceUuid)).first(),
    ]);
    if (
      !host ||
      !requester ||
      host.kind !== "host" ||
      requester.kind === "host" ||
      host.legacyUserId !== args.ownerUserId ||
      requester.legacyUserId !== args.ownerUserId ||
      host.revokedAt !== null ||
      requester.revokedAt !== null
    ) {
      throw new ConvexError({ code: "pairing_not_authorized" });
    }
    const existing = await ctx.db
      .query("devicePairings")
      .withIndex("by_owner_host_phone", (q) =>
        q
          .eq("ownerUserId", args.ownerUserId)
          .eq("hostDeviceUuid", args.hostDeviceUuid)
          .eq("phoneDeviceUuid", args.requesterDeviceUuid),
      )
      .take(20);
    if (existing.some((row) => row.revokedAt !== null)) {
      throw new ConvexError({ code: "access_revoked" });
    }
    const active = existing.find((row) => row.revokedAt === null);
    if (active) return pairingToRow(active);

    const at = nowIso();
    const id = await ctx.db.insert("devicePairings", {
      legacyId: generatedLegacyId("convex-pairing"),
      ownerUserId: args.ownerUserId,
      hostDeviceUuid: args.hostDeviceUuid,
      phoneDeviceUuid: args.requesterDeviceUuid,
      metadata: args.metadata ?? { approved_via: "native_prompt" },
      pairedAt: at,
      revokedAt: null,
      updatedAt: at,
    });
    const inserted = await ctx.db.get(id);
    if (!inserted) throw new Error("pairing insert failed");
    return pairingToRow(inserted);
  },
});

export const createHostLinkCode = mutation({
  args: {
    code: v.string(),
    hostDeviceId: v.string(),
    hostPublicKeyB64: v.string(),
    hostLabel: v.string(),
    hostMetadata: metadataValue,
    expiresAt: v.string(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const at = nowIso();
    const now = Date.now();
    const clash = await ctx.db
      .query("hostLinkCodes")
      .withIndex("by_code", (q) => q.eq("code", args.code))
      .filter((q) => q.eq(q.field("consumedAt"), null))
      .take(20);
    if (clash.some((row) => Date.parse(row.expiresAt) > now)) {
      throw new ConvexError({ code: "link_code_taken" });
    }
    await ctx.db.insert("hostLinkCodes", {
      legacyId: generatedLegacyId("convex-host-code"),
      code: args.code,
      hostDeviceId: args.hostDeviceId,
      hostPublicKeyB64: args.hostPublicKeyB64,
      hostLabel: args.hostLabel,
      hostMetadata: args.hostMetadata,
      createdAt: at,
      expiresAt: args.expiresAt,
      consumedAt: null,
      claimedUserId: null,
    });
    return null;
  },
});

/**
 * Claims a link code for one account. Finding the code and marking it used
 * happen in this one mutation, and Convex runs mutations as serializable
 * transactions, so of two claims racing for the same code (from one account
 * or two) exactly one succeeds; the other sees the code used and gets
 * `link_code_not_found`. The claim is final: the Worker makes it before it
 * links the Mac or pairs the browser, so a claim that fails after this point
 * still uses up the code and the Mac has to show a new one.
 *
 * Returns the claimed row. Throws ConvexError
 * - `link_code_not_found`: no unconsumed, unexpired row for the code, or two
 *   of them (an ambiguous claim is refused).
 * - `link_code_expired`: no live row, but an unconsumed one that expired.
 */
export const claimHostLinkCode = mutation({
  args: { code: v.string(), claimedUserId: v.string() },
  returns: hostLinkCodeRow,
  handler: async (ctx, args) => {
    const unconsumed = await ctx.db
      .query("hostLinkCodes")
      .withIndex("by_code", (q) => q.eq("code", args.code))
      .filter((q) => q.eq(q.field("consumedAt"), null))
      .take(20);
    const now = Date.now();
    const live = unconsumed.filter((row) => Date.parse(row.expiresAt) > now);
    if (live.length === 1) {
      await ctx.db.patch(live[0]._id, {
        consumedAt: nowIso(),
        claimedUserId: args.claimedUserId,
      });
      const claimed = await ctx.db.get(live[0]._id);
      if (!claimed) throw new Error("link code claim failed");
      return hostLinkCodeToRow(claimed);
    }
    if (live.length === 0 && unconsumed.length > 0) {
      throw new ConvexError({ code: "link_code_expired" });
    }
    throw new ConvexError({ code: "link_code_not_found" });
  },
});

export const deleteHostLinkCodesByHostDeviceId = mutation({
  args: { hostDeviceId: v.string(), limit: v.optional(v.number()) },
  returns: v.number(),
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(Math.trunc(args.limit ?? 100), 1), 500);
    const docs = await ctx.db
      .query("hostLinkCodes")
      .withIndex("by_host_device_id", (q) => q.eq("hostDeviceId", args.hostDeviceId))
      .take(limit);
    for (const doc of docs) await ctx.db.delete(doc._id);
    return docs.length;
  },
});

export const deleteDeviceByUuid = mutation({
  args: { id: v.string() },
  returns: v.boolean(),
  handler: async (ctx, args) => {
    const doc = await ctx.db
      .query("accountDevices")
      .withIndex("by_legacy_id", (q) => q.eq("legacyId", args.id))
      .first();
    if (!doc) return false;
    // Supabase cascaded these through foreign keys; keep the same shape so an
    // unlinked Mac leaves no pairings or approvals pointing at it.
    const [asHost, asPhone, approvals] = await Promise.all([
      ctx.db.query("devicePairings").withIndex("by_host_device_uuid", (q) => q.eq("hostDeviceUuid", args.id)).take(500),
      ctx.db.query("devicePairings").withIndex("by_phone_device_uuid", (q) => q.eq("phoneDeviceUuid", args.id)).take(500),
      ctx.db
        .query("deviceApprovalRequests")
        .withIndex("by_host_status_created_at", (q) => q.eq("hostDeviceUuid", args.id))
        .take(500),
    ]);
    for (const row of [...asHost, ...asPhone, ...approvals]) await ctx.db.delete(row._id);
    await ctx.db.delete(doc._id);
    return true;
  },
});

export const deleteRevokedPairings = mutation({
  args: pairScope,
  returns: v.number(),
  handler: async (ctx, args) => {
    const docs = await ctx.db
      .query("devicePairings")
      .withIndex("by_owner_host_phone", (q) =>
        q
          .eq("ownerUserId", args.ownerUserId)
          .eq("hostDeviceUuid", args.hostDeviceUuid)
          .eq("phoneDeviceUuid", args.requesterDeviceUuid),
      )
      .take(100);
    const revoked = docs.filter((doc) => doc.revokedAt !== null);
    for (const doc of revoked) await ctx.db.delete(doc._id);
    return revoked.length;
  },
});

export const revokePairing = mutation({
  args: { ...pairScope.fields, metadata: v.optional(metadataValue) },
  returns: v.null(),
  handler: async (ctx, args) => {
    const at = nowIso();
    // Same scope as the Supabase-era PATCH: every pairing between this Mac and
    // this browser, even one created while the Mac belonged to another account.
    const docs = await ctx.db
      .query("devicePairings")
      .withIndex("by_phone_device_uuid", (q) => q.eq("phoneDeviceUuid", args.requesterDeviceUuid))
      .filter((q) => q.eq(q.field("hostDeviceUuid"), args.hostDeviceUuid))
      .take(100);
    const hasRevoked = docs.some((doc) => doc.ownerUserId === args.ownerUserId && doc.revokedAt !== null);
    if (!hasRevoked) {
      await ctx.db.insert("devicePairings", {
        legacyId: generatedLegacyId("convex-pairing"),
        ownerUserId: args.ownerUserId,
        hostDeviceUuid: args.hostDeviceUuid,
        phoneDeviceUuid: args.requesterDeviceUuid,
        metadata: args.metadata ?? { revoked_via: "host" },
        pairedAt: at,
        revokedAt: at,
        updatedAt: at,
      });
    }
    for (const doc of docs) {
      if (doc.revokedAt === null) await ctx.db.patch(doc._id, { revokedAt: at, updatedAt: at });
    }
    return null;
  },
});
