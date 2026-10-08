import assert from "node:assert/strict";
import test from "node:test";
import { transformSupabaseAuthExport } from "./transformSupabaseAuthExport.mjs";

test("transforms Supabase auth users into Better Auth import rows", () => {
  const transformed = transformSupabaseAuthExport({
    users: [
      {
        id: "user-1",
        email: "PERSON@EXAMPLE.COM",
        encrypted_password: "$2a$10$hash",
        email_confirmed_at: "2026-01-01T00:00:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z",
        updated_at: "2026-01-01T00:01:00.000Z",
        raw_user_meta_data: { name: "Person One", avatar_url: "https://example.com/avatar.png" },
        identities: [
          {
            id: "identity-email",
            provider: "email",
            provider_id: "user-1",
            identity_data: {},
            created_at: "2026-01-01T00:00:00.000Z",
            updated_at: "2026-01-01T00:01:00.000Z",
          },
          {
            id: "identity-google",
            provider: "google",
            provider_id: "google-sub",
            identity_data: { sub: "google-sub" },
            created_at: "2026-01-01T00:02:00.000Z",
            updated_at: "2026-01-01T00:03:00.000Z",
          },
        ],
      },
    ],
  });

  assert.deepEqual(transformed.users, [
    {
      legacyUserId: "user-1",
      email: "person@example.com",
      name: "Person One",
      emailVerified: true,
      image: "https://example.com/avatar.png",
      createdAt: Date.parse("2026-01-01T00:00:00.000Z"),
      updatedAt: Date.parse("2026-01-01T00:01:00.000Z"),
    },
  ]);
  assert.deepEqual(
    transformed.accounts.map((account) => ({
      legacyUserId: account.legacyUserId,
      providerId: account.providerId,
      accountId: account.accountId,
      hasPassword: Boolean(account.password),
    })),
    [
      { legacyUserId: "user-1", providerId: "credential", accountId: "user-1", hasPassword: true },
      { legacyUserId: "user-1", providerId: "google", accountId: "google-sub", hasPassword: false },
    ],
  );
});
