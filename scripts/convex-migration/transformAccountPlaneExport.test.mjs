import assert from "node:assert/strict";
import test from "node:test";
import { transformAccountPlaneExport } from "./transformAccountPlaneExport.mjs";

function assertNoUndefined(value, path = "root") {
  if (value === undefined) {
    assert.fail(`${path} must not be undefined`);
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoUndefined(item, `${path}[${index}]`));
    return;
  }

  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      assertNoUndefined(child, `${path}.${key}`);
    }
  }
}

test("transforms Supabase account-plane rows into Convex import tables", () => {
  const transformed = transformAccountPlaneExport({
    profiles: [
      {
        user_id: "user-1",
        email: "person@example.com",
        display_name: null,
        avatar_url: "https://example.com/avatar.png",
        created_at: "2026-01-01T00:00:00.000Z",
        updated_at: "2026-01-01T00:01:00.000Z",
      },
    ],
    devices: [
      {
        id: "device-row-1",
        user_id: "user-1",
        device_id: "host-device",
        public_key_b64: "public-key",
        label: "Studio Mac",
        kind: "host",
        platform: "macOS",
        app_version: null,
        last_seen_at: "2026-01-01T00:02:00.000Z",
        revoked_at: null,
        metadata: { signaling_url: "https://relay.example" },
        created_at: "2026-01-01T00:00:00.000Z",
        updated_at: "2026-01-01T00:02:00.000Z",
      },
    ],
    device_pairings: [
      {
        id: "pairing-1",
        owner_user_id: "user-1",
        host_device_uuid: "device-row-1",
        phone_device_uuid: "device-row-2",
        metadata: { approved_via: "link_code_claim" },
        paired_at: "2026-01-01T00:03:00.000Z",
        revoked_at: null,
        updated_at: "2026-01-01T00:03:00.000Z",
      },
    ],
    host_link_codes: [
      {
        id: "code-1",
        code: "ABC123",
        host_device_id: "host-device",
        host_public_key_b64: "public-key",
        host_label: "Studio Mac",
        host_metadata: {},
        created_at: "2026-01-01T00:04:00.000Z",
        expires_at: "2026-01-01T00:14:00.000Z",
        consumed_at: null,
        claimed_user_id: null,
      },
    ],
    push_subscriptions: [
      {
        id: "push-1",
        user_id: "user-1",
        device_uuid: "device-row-2",
        endpoint: "https://push.example",
        p256dh: "p256dh",
        auth: "auth",
        user_agent: null,
        metadata: {},
        created_at: "2026-01-01T00:05:00.000Z",
        updated_at: "2026-01-01T00:05:00.000Z",
        last_seen_at: "2026-01-01T00:05:00.000Z",
        revoked_at: null,
      },
    ],
    device_approval_requests: [
      {
        id: "approval-1",
        owner_user_id: "user-1",
        host_device_uuid: "device-row-1",
        requester_device_uuid: "device-row-2",
        requester_device_id: "phone-device",
        requester_public_key_b64: "phone-public-key",
        requester_label: "Phone",
        status: "pending",
        metadata: {},
        created_at: "2026-01-01T00:06:00.000Z",
        updated_at: "2026-01-01T00:06:00.000Z",
        responded_at: null,
      },
    ],
  });

  assertNoUndefined(transformed);
  assert.deepEqual(transformed.accountProfiles, [
    {
      legacyUserId: "user-1",
      email: "person@example.com",
      displayName: null,
      avatarUrl: "https://example.com/avatar.png",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:01:00.000Z",
    },
  ]);
  assert.equal(transformed.accountDevices[0].legacyId, "device-row-1");
  assert.equal(transformed.accountDevices[0].deviceId, "host-device");
  assert.deepEqual(transformed.devicePairings[0].metadata, { approved_via: "link_code_claim" });
  assert.equal(transformed.hostLinkCodes[0].claimedUserId, null);
  assert.equal(transformed.pushSubscriptions[0].revokedAt, null);
  assert.equal(transformed.deviceApprovalRequests[0].status, "pending");
});
