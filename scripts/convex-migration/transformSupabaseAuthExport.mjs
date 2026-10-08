function stringValue(value) {
  return typeof value === "string" ? value : String(value ?? "");
}

function nullableString(value) {
  if (value == null) return null;
  const text = stringValue(value).trim();
  return text || null;
}

function normalizedEmail(value) {
  return stringValue(value).trim().toLowerCase();
}

function timestampMs(value, fallback = 0) {
  const parsed = Date.parse(stringValue(value));
  return Number.isFinite(parsed) ? parsed : fallback;
}

function metadataString(metadata, keys) {
  for (const key of keys) {
    const value = metadata?.[key];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return null;
}

function deriveName(user) {
  const metadata = user.raw_user_meta_data ?? {};
  const identityMetadata = user.identities?.find((identity) => identity.identity_data)?.identity_data ?? {};
  const keys = ["full_name", "name", "given_name", "first_name", "preferred_username", "user_name", "username"];
  const email = normalizedEmail(user.email);
  return metadataString(metadata, keys) || metadataString(identityMetadata, keys) || email.split("@")[0] || "Glasstunnel user";
}

function identityAccountId(identity) {
  const data = identity.identity_data ?? {};
  const candidates = [data.sub, data.provider_id, data.user_id, identity.provider_id, identity.id];
  for (const candidate of candidates) {
    const value = nullableString(candidate);
    if (value) return value;
  }
  return null;
}

function compactAccounts(accounts) {
  const seen = new Set();
  return accounts
    .sort((left, right) =>
      `${left.legacyUserId}:${left.providerId}:${left.accountId}`.localeCompare(
        `${right.legacyUserId}:${right.providerId}:${right.accountId}`,
      ),
    )
    .filter((account) => {
      const key = `${account.legacyUserId}:${account.providerId}:${account.accountId}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

export function transformSupabaseAuthExport(input) {
  const users = (input.users ?? [])
    .filter((user) => nullableString(user.id) && normalizedEmail(user.email))
    .slice()
    .sort((left, right) => stringValue(left.id).localeCompare(stringValue(right.id)));
  const authUsers = [];
  const authAccounts = [];

  for (const user of users) {
    const legacyUserId = stringValue(user.id);
    const email = normalizedEmail(user.email);
    const createdAt = timestampMs(user.created_at);
    const updatedAt = timestampMs(user.updated_at, createdAt);

    authUsers.push({
      legacyUserId,
      email,
      name: deriveName(user),
      emailVerified: Boolean(user.email_confirmed_at || user.confirmed_at),
      image: nullableString(user.raw_user_meta_data?.avatar_url || user.raw_user_meta_data?.picture),
      createdAt,
      updatedAt,
    });

    const identities = user.identities ?? [];
    const hasEmailIdentity = identities.some((identity) => identity.provider === "email");
    if (user.encrypted_password && (hasEmailIdentity || identities.length === 0)) {
      authAccounts.push({
        legacyUserId,
        providerId: "credential",
        accountId: legacyUserId,
        password: user.encrypted_password,
        createdAt,
        updatedAt,
      });
    }

    for (const identity of identities) {
      const provider = nullableString(identity.provider)?.toLowerCase();
      if (!provider || provider === "email") continue;
      const accountId = identityAccountId(identity);
      if (!accountId) continue;
      const identityCreatedAt = timestampMs(identity.created_at, createdAt);
      authAccounts.push({
        legacyUserId,
        providerId: provider,
        accountId,
        password: null,
        createdAt: identityCreatedAt,
        updatedAt: timestampMs(identity.updated_at, identityCreatedAt),
      });
    }
  }

  return {
    users: authUsers,
    accounts: compactAccounts(authAccounts),
  };
}
