import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const nullableString = v.union(v.string(), v.null());

export default defineSchema({
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
    .index("by_phone_device_uuid", ["phoneDeviceUuid"]),

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
