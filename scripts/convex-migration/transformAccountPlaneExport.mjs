function rows(input, table) {
  return Array.isArray(input?.[table]) ? input[table] : [];
}

function stringValue(value) {
  return typeof value === "string" ? value : String(value ?? "");
}

function nullableString(value) {
  return value == null ? null : stringValue(value);
}

function jsonValue(value, fallback = {}) {
  if (value == null) return fallback;
  if (typeof value !== "string") return value;
  const trimmed = value.trim();
  if (!trimmed || (!trimmed.startsWith("{") && !trimmed.startsWith("["))) return value;
  try {
    return JSON.parse(trimmed);
  } catch {
    return value;
  }
}

function compact(value) {
  if (Array.isArray(value)) return value.map((item) => compact(item));
  if (!value || typeof value !== "object") return value;

  const output = {};
  for (const [key, child] of Object.entries(value)) {
    if (child !== undefined) output[key] = compact(child);
  }
  return output;
}

function byId(left, right) {
  return stringValue(left.id ?? left.user_id).localeCompare(stringValue(right.id ?? right.user_id));
}

export function transformAccountPlaneExport(input) {
  const accountProfiles = rows(input, "profiles")
    .slice()
    .sort((left, right) => stringValue(left.user_id).localeCompare(stringValue(right.user_id)))
    .map((row) => ({
      legacyUserId: stringValue(row.user_id),
      email: nullableString(row.email),
      displayName: nullableString(row.display_name),
      avatarUrl: nullableString(row.avatar_url),
      createdAt: stringValue(row.created_at),
      updatedAt: stringValue(row.updated_at),
    }));

  const accountDevices = rows(input, "devices")
    .slice()
    .sort(byId)
    .map((row) => ({
      legacyId: stringValue(row.id),
      legacyUserId: stringValue(row.user_id),
      deviceId: stringValue(row.device_id),
      publicKeyB64: stringValue(row.public_key_b64),
      label: stringValue(row.label),
      kind: stringValue(row.kind),
      platform: nullableString(row.platform),
      appVersion: nullableString(row.app_version),
      lastSeenAt: nullableString(row.last_seen_at),
      revokedAt: nullableString(row.revoked_at),
      metadata: jsonValue(row.metadata),
      createdAt: stringValue(row.created_at),
      updatedAt: stringValue(row.updated_at),
    }));

  const devicePairings = rows(input, "device_pairings")
    .slice()
    .sort(byId)
    .map((row) => ({
      legacyId: stringValue(row.id),
      ownerUserId: stringValue(row.owner_user_id),
      hostDeviceUuid: stringValue(row.host_device_uuid),
      phoneDeviceUuid: stringValue(row.phone_device_uuid),
      metadata: jsonValue(row.metadata),
      pairedAt: stringValue(row.paired_at),
      revokedAt: nullableString(row.revoked_at),
      updatedAt: stringValue(row.updated_at),
    }));

  const pushSubscriptions = rows(input, "push_subscriptions")
    .slice()
    .sort(byId)
    .map((row) => ({
      legacyId: stringValue(row.id),
      legacyUserId: stringValue(row.user_id),
      deviceUuid: stringValue(row.device_uuid),
      endpoint: stringValue(row.endpoint),
      p256dh: stringValue(row.p256dh),
      auth: stringValue(row.auth),
      userAgent: nullableString(row.user_agent),
      metadata: jsonValue(row.metadata),
      createdAt: stringValue(row.created_at),
      updatedAt: stringValue(row.updated_at),
      lastSeenAt: stringValue(row.last_seen_at),
      revokedAt: nullableString(row.revoked_at),
    }));

  const hostLinkCodes = rows(input, "host_link_codes")
    .slice()
    .sort(byId)
    .map((row) => ({
      legacyId: stringValue(row.id),
      code: stringValue(row.code),
      hostDeviceId: stringValue(row.host_device_id),
      hostPublicKeyB64: stringValue(row.host_public_key_b64),
      hostLabel: stringValue(row.host_label),
      hostMetadata: jsonValue(row.host_metadata),
      createdAt: stringValue(row.created_at),
      expiresAt: stringValue(row.expires_at),
      consumedAt: nullableString(row.consumed_at),
      claimedUserId: nullableString(row.claimed_user_id),
    }));

  const deviceApprovalRequests = rows(input, "device_approval_requests")
    .slice()
    .sort(byId)
    .map((row) => ({
      legacyId: stringValue(row.id),
      ownerUserId: stringValue(row.owner_user_id),
      hostDeviceUuid: stringValue(row.host_device_uuid),
      requesterDeviceUuid: stringValue(row.requester_device_uuid),
      requesterDeviceId: stringValue(row.requester_device_id),
      requesterPublicKeyB64: stringValue(row.requester_public_key_b64),
      requesterLabel: stringValue(row.requester_label),
      status: stringValue(row.status),
      metadata: jsonValue(row.metadata),
      createdAt: stringValue(row.created_at),
      updatedAt: stringValue(row.updated_at),
      respondedAt: nullableString(row.responded_at),
    }));

  return compact({
    accountProfiles,
    accountDevices,
    devicePairings,
    pushSubscriptions,
    hostLinkCodes,
    deviceApprovalRequests,
  });
}
