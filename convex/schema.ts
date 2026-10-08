import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const nullableString = v.union(v.string(), v.null());
const authEmailKind = v.union(v.literal("password_reset"), v.literal("password_changed"));

export default defineSchema({
  /**
   * One row per account email (password reset link, password changed notice).
   * Drives the send throttles and records the delivery outcome. Holds no
   * address and no link: `userId` is the Better Auth user id. Pruned after
   * 7 days by the daily cron (email:pruneAuthEmails).
   */
  authEmails: defineTable({
    kind: authEmailKind,
    userId: v.string(),
    createdAt: v.number(),
    status: v.union(v.literal("queued"), v.literal("sent"), v.literal("failed")),
    attempts: v.number(),
    /** The provider's message id (Resend), never the response body. */
    providerMessageId: v.optional(v.string()),
    /** A short code such as `http_422` or `network`, never the response body. */
    error: v.optional(v.string()),
  })
    .index("by_kind_user_created", ["kind", "userId", "createdAt"])
    // The deployment-wide caps count one kind over the last hour and day.
    .index("by_kind_created", ["kind", "createdAt"])
    .index("by_created", ["createdAt"]),

  /**
   * Local lab only (AUTH_EMAIL_OUTBOX=lab on a loopback auth URL): emails the
   * lab would have sent, read back with `email:labOutbox`. Nothing is
   * delivered. Pruned after 1 day.
   */
  labEmailOutbox: defineTable({
    kind: authEmailKind,
    to: v.string(),
    subject: v.string(),
    text: v.string(),
    url: nullableString,
    createdAt: v.number(),
  })
    .index("by_to_created", ["to", "createdAt"])
    .index("by_created", ["createdAt"]),

  accountProfiles: defineTable({
    legacyUserId: v.string(),
    email: nullableString,
    displayName: nullableString,
    avatarUrl: nullableString,
    createdAt: v.string(),
    updatedAt: v.string(),
  }).index("by_legacy_user_id", ["legacyUserId"]),

  accountDevices: defineTable({
    legacyId: v.string(),
    legacyUserId: v.string(),
    deviceId: v.string(),
    publicKeyB64: v.string(),
    label: v.string(),
    kind: v.string(),
    platform: nullableString,
    appVersion: nullableString,
    lastSeenAt: nullableString,
    revokedAt: nullableString,
    metadata: v.any(),
    createdAt: v.string(),
    updatedAt: v.string(),
  })
    .index("by_legacy_id", ["legacyId"])
    .index("by_legacy_user_id", ["legacyUserId"])
    .index("by_device_id", ["deviceId"])
    .index("by_legacy_user_kind_created_at", ["legacyUserId", "kind", "createdAt"]),

  devicePairings: defineTable({
    legacyId: v.string(),
    ownerUserId: v.string(),
    hostDeviceUuid: v.string(),
    phoneDeviceUuid: v.string(),
    metadata: v.any(),
    pairedAt: v.string(),
    revokedAt: nullableString,
    updatedAt: v.string(),
  })
    .index("by_legacy_id", ["legacyId"])
    .index("by_owner_user_id", ["ownerUserId"])
    .index("by_owner_host_phone", ["ownerUserId", "hostDeviceUuid", "phoneDeviceUuid"])
    .index("by_phone_device_uuid", ["phoneDeviceUuid"])
    .index("by_host_device_uuid", ["hostDeviceUuid"]),

  pushSubscriptions: defineTable({
    legacyId: v.string(),
    legacyUserId: v.string(),
    deviceUuid: v.string(),
    endpoint: v.string(),
    p256dh: v.string(),
    auth: v.string(),
    userAgent: nullableString,
    metadata: v.any(),
    createdAt: v.string(),
    updatedAt: v.string(),
    lastSeenAt: v.string(),
    revokedAt: nullableString,
  })
    .index("by_legacy_id", ["legacyId"])
    .index("by_legacy_user_id", ["legacyUserId"])
    .index("by_device_uuid", ["deviceUuid"])
    .index("by_endpoint", ["endpoint"]),

  hostLinkCodes: defineTable({
    legacyId: v.string(),
    code: v.string(),
    hostDeviceId: v.string(),
    hostPublicKeyB64: v.string(),
    hostLabel: v.string(),
    hostMetadata: v.any(),
    createdAt: v.string(),
    expiresAt: v.string(),
    consumedAt: nullableString,
    claimedUserId: nullableString,
  })
    .index("by_legacy_id", ["legacyId"])
    .index("by_code", ["code"])
    .index("by_host_device_id", ["hostDeviceId"]),

  deviceApprovalRequests: defineTable({
    legacyId: v.string(),
    ownerUserId: v.string(),
    hostDeviceUuid: v.string(),
    requesterDeviceUuid: v.string(),
    requesterDeviceId: v.string(),
    requesterPublicKeyB64: v.string(),
    requesterLabel: v.string(),
    status: v.string(),
    metadata: v.any(),
    createdAt: v.string(),
    updatedAt: v.string(),
    respondedAt: nullableString,
  })
    .index("by_legacy_id", ["legacyId"])
    .index("by_host_status_created_at", ["hostDeviceUuid", "status", "createdAt"])
    .index("by_host_requester_status", ["hostDeviceUuid", "requesterDeviceUuid", "status"]),
});
