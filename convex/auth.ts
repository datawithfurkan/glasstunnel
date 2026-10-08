import { createClient, type GenericCtx } from "@convex-dev/better-auth";
import { convex, crossDomain } from "@convex-dev/better-auth/plugins";
import { isRunMutationCtx } from "@convex-dev/better-auth/utils";
import { betterAuth, type BetterAuthOptions } from "better-auth/minimal";
import { createAuthMiddleware, isAPIError } from "better-auth/api";
import { bearer } from "better-auth/plugins";
import type { BetterAuthPlugin } from "better-auth/types";
import bcrypt from "bcryptjs";
import { v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { DataModel } from "./_generated/dataModel";
// Migration helpers and token verification are internal: only the CLI
// (deploy key) and the Worker gateway in http.ts can call them.
import { internalMutation as mutation, internalQuery as query } from "./_generated/server";
import authConfig from "./auth.config";
import {
  appUrl,
  authBaseUrl,
  emailDeliveryMode,
  env,
  PASSWORD_RESET_TOKEN_SECONDS,
  passwordResetLink,
  type AuthEmailKind,
} from "./email";

const nullableString = v.union(v.string(), v.null());
const authUserImport = v.object({
  legacyUserId: v.string(),
  email: v.string(),
  name: v.string(),
  emailVerified: v.boolean(),
  image: nullableString,
  createdAt: v.number(),
  updatedAt: v.number(),
});
const authAccountImport = v.object({
  legacyUserId: v.string(),
  providerId: v.string(),
  accountId: v.string(),
  password: nullableString,
  createdAt: v.number(),
  updatedAt: v.number(),
});
const authUserResult = v.object({
  id: v.string(),
  email: nullableString,
  user_metadata: v.any(),
  /** Unix ms when the verified session expires; the relay caps its socket deadline by it. */
  session_expires_at: v.optional(v.number()),
});

type AdapterDoc = Record<string, any> & { _id: string };
type AdapterCtx = GenericCtx<DataModel> & {
  runQuery: (reference: any, args: any) => Promise<any>;
  runMutation?: (reference: any, args: any) => Promise<any>;
};

export const authComponent = createClient<DataModel>(components.betterAuth);

const SESSION_LIFETIME_SECONDS = 60 * 24 * 60 * 60;
const SESSION_REFRESH_AFTER_SECONDS = 24 * 60 * 60;

function trustedOrigins() {
  return [
    env("BETTER_AUTH_URL"),
    env("PUBLIC_APP_URL"),
    env("VITE_PUBLIC_APP_URL"),
    env("CONVEX_SITE_URL"),
  ].filter((value): value is string => Boolean(value));
}

function socialProviders() {
  return {
    ...(env("GOOGLE_CLIENT_ID") && env("GOOGLE_CLIENT_SECRET")
      ? {
          google: {
            clientId: env("GOOGLE_CLIENT_ID")!,
            clientSecret: env("GOOGLE_CLIENT_SECRET")!,
          },
        }
      : {}),
    ...(env("GITHUB_CLIENT_ID") && env("GITHUB_CLIENT_SECRET")
      ? {
          github: {
            clientId: env("GITHUB_CLIENT_ID")!,
            clientSecret: env("GITHUB_CLIENT_SECRET")!,
          },
        }
      : {}),
  };
}

/**
 * Hands one account email to email:queueAuthEmail (throttle, record, then a
 * scheduled delivery). Never throws and never logs the address or link: an
 * error that only existing accounts can hit would reveal which emails have
 * accounts, and the HTTP reply must stay identical for every address.
 */
async function queueAuthEmail(
  ctx: AdapterCtx,
  args: { kind: AuthEmailKind; userId: string; to: string; url: string | null },
) {
  try {
    if (!isRunMutationCtx(ctx)) {
      console.warn(`auth email ${args.kind} not queued: no mutation context`);
      return;
    }
    await ctx.runMutation(internal.email.queueAuthEmail, args);
  } catch (error) {
    console.warn(`auth email ${args.kind} not queued: ${error instanceof Error ? error.name : "unknown error"}`);
  }
}

/**
 * Password reset is on only when email can go out (Resend, or the local lab
 * outbox). Without `sendResetPassword`, Better Auth answers every reset
 * request with 400 RESET_PASSWORD_DISABLED, the same for every address.
 */
function passwordResetEmailOptions(ctx: AdapterCtx) {
  if (emailDeliveryMode() === "off") {
    return {};
  }
  return {
    // Better Auth's `url` points at the auth server's own callback; the email
    // links straight to the app instead, which posts the token back.
    sendResetPassword: async ({ user, token }: { user: { id: string; email: string }; token: string }) => {
      await queueAuthEmail(ctx, {
        kind: "password_reset",
        userId: user.id,
        to: user.email,
        url: passwordResetLink(token),
      });
    },
    onPasswordReset: async ({ user }: { user: { id: string; email: string } }) => {
      await queueAuthEmail(ctx, {
        kind: "password_changed",
        userId: user.id,
        to: user.email,
        url: null,
      });
    },
  };
}

const PASSWORD_RESET_REQUEST_PATH = "/request-password-reset";
/**
 * Every successful reset request answers no sooner than this after it started.
 *
 * It has to stay above the real work for a known address (a verification
 * token plus email:queueAuthEmail). With the floor removed, the local backend
 * answered known addresses in p50 77 ms / p95 89 ms and unknown ones in
 * p50 63 ms / p95 68 ms, round trip included (convex/README.md).
 *
 * It also has to stay small, because the wait is not free. The reply waits
 * inside a Convex HTTP action, so every held request keeps one slot of the
 * deployment's shared action and HTTP-action concurrency pool (64 on Convex's
 * free plan) for the whole floor. This endpoint needs no sign-in, so a client
 * that sends reset requests fast enough can fill the pool and delay everything
 * else that runs in it, including the Worker gateway (POST
 * /worker/account-plane, which the Worker needs for every account request and
 * device sign-in) and Better Auth routes such as get-session. Keeping all 64
 * slots busy with held replies takes about 64 / 0.25 s = 256 requests a second
 * at 250 ms, against about 80 a second at the earlier 800 ms. A lower floor
 * raises that cost; it does not remove it. Removing it needs a per-client
 * limit in front of this endpoint (the follow-up in convex/README.md,
 * "Password reset email").
 */
const PASSWORD_RESET_RESPONSE_FLOOR_MS = 250;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

/**
 * Makes POST /request-password-reset take the same time whether or not the
 * address has an account. A known address costs more work (a verification
 * token plus the email queue mutation) than an unknown one, which a client
 * could measure. The before hook notes when the request reached the endpoint;
 * the after hook holds every success reply until PASSWORD_RESET_RESPONSE_FLOOR_MS
 * has passed. Error replies (invalid email, reset disabled, untrusted origin)
 * are the same for every address and are not held. Server-side `auth.api`
 * calls carry no Request and are not held either.
 *
 * This removes one signal, not every one: sign-up (POST /sign-up/email)
 * answers 422 USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL for an address that has
 * an account, and the app says so, so account existence stays discoverable.
 */
function uniformPasswordResetTiming(): BetterAuthPlugin {
  const startedAt = new WeakMap<Request, number>();
  const isResetRequest = (context: { path?: string }) => context.path === PASSWORD_RESET_REQUEST_PATH;
  return {
    id: "glasstunnel-uniform-reset-timing",
    hooks: {
      before: [
        {
          matcher: isResetRequest,
          handler: createAuthMiddleware(async (context) => {
            if (context.request) {
              startedAt.set(context.request, Date.now());
            }
          }),
        },
      ],
      after: [
        {
          matcher: isResetRequest,
          handler: createAuthMiddleware(async (context) => {
            const started = context.request ? startedAt.get(context.request) : undefined;
            if (started === undefined || isAPIError(context.context.returned)) {
              return;
            }
            const remaining = started + PASSWORD_RESET_RESPONSE_FLOOR_MS - Date.now();
            if (remaining > 0) {
              await sleep(remaining);
            }
          }),
        },
      ],
    },
  };
}

export const createAuthOptions = (ctx: AdapterCtx) =>
  ({
    baseURL: authBaseUrl(),
    trustedOrigins: trustedOrigins(),
    database: authComponent.adapter(ctx),
    session: {
      expiresIn: SESSION_LIFETIME_SECONDS,
      updateAge: SESSION_REFRESH_AFTER_SECONDS,
    },
    // Errors before the per-flow errorCallbackURL is known (state checks,
    // provider denials) land in the app with a readable message instead of
    // the auth server's own page, whose "Go home" link is a 404.
    onAPIError: {
      errorURL: `${appUrl()}/?authError=1`,
    },
    emailAndPassword: {
      enabled: true,
      requireEmailVerification: false,
      password: {
        hash: async (password: string) => bcrypt.hash(password, 10),
        verify: async ({ password, hash }: { password: string; hash: string }) =>
          bcrypt.compare(password, hash),
      },
      // A reset signs the account out everywhere; reset links work once and
      // expire after an hour.
      revokeSessionsOnPasswordReset: true,
      resetPasswordTokenExpiresIn: PASSWORD_RESET_TOKEN_SECONDS,
      ...passwordResetEmailOptions(ctx),
    },
    socialProviders: socialProviders(),
    plugins: [
      bearer(),
      // The auth server (convex.site) and the app (app.glasstunnel.io) are
      // different sites: OAuth state is kept in the database and the session
      // reaches the app as a one-time token (?ott=) the app exchanges.
      crossDomain({ siteUrl: appUrl() }),
      convex({
        authConfig,
        jwt: {
          definePayload: ({ user }) => ({
            legacyUserId: typeof (user as any).userId === "string" ? (user as any).userId : user.id,
            email: user.email,
          }),
        },
      }),
      // Last, so its after hook also covers the other plugins' after hooks.
      uniformPasswordResetTiming(),
    ],
  }) satisfies BetterAuthOptions;

export const createAuth = (ctx: AdapterCtx) => betterAuth(createAuthOptions(ctx));

async function findUserByLegacyId(ctx: AdapterCtx, legacyUserId: string): Promise<AdapterDoc | null> {
  const importedUser = (await ctx.runQuery(components.betterAuth.adapter.findOne, {
    model: "user",
    where: [{ field: "userId", value: legacyUserId }],
  })) as AdapterDoc | null;

  if (importedUser) {
    return importedUser;
  }

  if (!looksLikeConvexId(legacyUserId)) {
    return null;
  }

  return (await ctx.runQuery(components.betterAuth.adapter.findOne, {
    model: "user",
    where: [{ field: "_id", value: legacyUserId }],
  })) as AdapterDoc | null;
}

function looksLikeConvexId(value: string) {
  return /^[a-z0-9]+$/.test(value) && value.length >= 20;
}

async function findUserByEmail(ctx: AdapterCtx, email: string): Promise<AdapterDoc | null> {
  return (await ctx.runQuery(components.betterAuth.adapter.findOne, {
    model: "user",
    where: [{ field: "email", value: email.trim().toLowerCase() }],
  })) as AdapterDoc | null;
}

async function listAccountsForAuthUser(ctx: AdapterCtx, authUserId: string): Promise<AdapterDoc[]> {
  const result = (await ctx.runQuery(components.betterAuth.adapter.findMany, {
    model: "account",
    where: [{ field: "userId", value: authUserId }],
    paginationOpts: { cursor: null, numItems: 100 },
  })) as { page?: AdapterDoc[] } | AdapterDoc[];

  return Array.isArray(result) ? result : result.page ?? [];
}

async function upsertAccount(ctx: AdapterCtx, account: typeof authAccountImport.type, authUserId: string) {
  if (!ctx.runMutation) {
    throw new Error("Cannot upsert auth accounts outside a mutation.");
  }

  const existing = (await ctx.runQuery(components.betterAuth.adapter.findOne, {
    model: "account",
    where: [
      { field: "accountId", value: account.accountId },
      { field: "providerId", value: account.providerId },
    ],
  })) as AdapterDoc | null;

  const data = {
    accountId: account.accountId,
    providerId: account.providerId,
    userId: authUserId,
    password: account.password,
    createdAt: account.createdAt,
    updatedAt: account.updatedAt,
  };

  if (existing) {
    await ctx.runMutation(components.betterAuth.adapter.updateOne, {
      input: {
        model: "account",
        where: [{ field: "_id", value: existing._id }],
        update: data,
      },
    });
    return;
  }

  await ctx.runMutation(components.betterAuth.adapter.create, {
    input: {
      model: "account",
      data,
    },
  });
}

function serializeAuthUser(user: AdapterDoc): typeof authUserResult.type {
  const legacyUserId = typeof user.userId === "string" && user.userId ? user.userId : user._id;
  const name = typeof user.name === "string" && user.name ? user.name : "Glasstunnel user";
  const image = typeof user.image === "string" && user.image ? user.image : null;

  return {
    id: legacyUserId,
    email: typeof user.email === "string" ? user.email : null,
    user_metadata: {
      name,
      full_name: name,
      avatar_url: image,
      provider: "convex",
      auth_user_id: user._id,
    },
  };
}

export const importUserBatch = mutation({
  args: {
    users: v.array(authUserImport),
    accounts: v.array(authAccountImport),
  },
  returns: v.object({
    usersCreated: v.number(),
    usersUpdated: v.number(),
    accountsUpserted: v.number(),
  }),
  handler: async (ctx, args) => {
    const accountsByLegacyUserId = new Map<string, Array<typeof authAccountImport.type>>();
    for (const account of args.accounts) {
      const list = accountsByLegacyUserId.get(account.legacyUserId) ?? [];
      list.push(account);
      accountsByLegacyUserId.set(account.legacyUserId, list);
    }

    let usersCreated = 0;
    let usersUpdated = 0;
    let accountsUpserted = 0;
    for (const user of args.users) {
      const existing = await findUserByLegacyId(ctx, user.legacyUserId);
      const data = {
        name: user.name,
        email: user.email.trim().toLowerCase(),
        emailVerified: user.emailVerified,
        image: user.image,
        createdAt: user.createdAt,
        updatedAt: user.updatedAt,
        userId: user.legacyUserId,
      };

      let authUser = existing;
      if (existing) {
        await ctx.runMutation(components.betterAuth.adapter.updateOne, {
          input: {
            model: "user",
            where: [{ field: "_id", value: existing._id }],
            update: data,
          },
        });
        usersUpdated += 1;
        authUser = await findUserByLegacyId(ctx, user.legacyUserId);
      } else {
        authUser = (await ctx.runMutation(components.betterAuth.adapter.create, {
          input: {
            model: "user",
            data,
          },
        })) as AdapterDoc;
        usersCreated += 1;
      }

      if (!authUser?._id) {
        throw new Error(`Could not import auth user ${user.legacyUserId}.`);
      }

      for (const account of accountsByLegacyUserId.get(user.legacyUserId) ?? []) {
        await upsertAccount(ctx, account, authUser._id);
        accountsUpserted += 1;
      }
    }

    return { usersCreated, usersUpdated, accountsUpserted };
  },
});

export const lookupEmailAuthState = query({
  args: { email: v.string() },
  returns: v.object({
    email: v.string(),
    state: v.union(
      v.literal("sign_up"),
      v.literal("sign_in"),
      v.literal("pending_verification"),
      v.literal("social_only"),
    ),
    providers: v.optional(v.array(v.string())),
  }),
  handler: async (ctx, args) => {
    const email = args.email.trim().toLowerCase();
    const user = await findUserByEmail(ctx, email);
    if (!user) {
      return { email, state: "sign_up" as const };
    }

    const accounts = await listAccountsForAuthUser(ctx, user._id);
    const providers = [...new Set(accounts.map((account) => String(account.providerId || "")).filter(Boolean))]
      .map((provider) => (provider === "credential" ? "email" : provider))
      .sort();

    if (!user.emailVerified) {
      return { email, state: "pending_verification" as const, providers };
    }

    if (providers.length > 0 && !providers.includes("email")) {
      return { email, state: "social_only" as const, providers };
    }

    return { email, state: "sign_in" as const, providers };
  },
});

export const verifyBearerToken = query({
  args: { token: v.string() },
  returns: v.union(authUserResult, v.null()),
  handler: async (ctx, args) => {
    const token = args.token.trim();
    if (!token) {
      return null;
    }

    const auth = createAuth(ctx);
    const session = await auth.api.getSession({
      headers: new Headers({ authorization: `Bearer ${token}` }),
    });
    if (!session?.user) {
      return null;
    }

    const expiresAt = new Date((session.session as any)?.expiresAt ?? NaN).getTime();
    return {
      ...serializeAuthUser({
        _id: session.user.id,
        userId: (session.user as any).userId,
        email: session.user.email,
        name: session.user.name,
        image: session.user.image,
      }),
      ...(Number.isFinite(expiresAt) ? { session_expires_at: expiresAt } : {}),
    };
  },
});

export const deleteUserByLegacyId = mutation({
  args: { legacyUserId: v.string() },
  returns: v.boolean(),
  handler: async (ctx, args) => {
    const user = await findUserByLegacyId(ctx, args.legacyUserId);
    if (!user) {
      return false;
    }

    await ctx.runMutation(components.betterAuth.adapter.deleteMany, {
      input: {
        model: "session",
        where: [{ field: "userId", value: user._id }],
      },
      paginationOpts: { cursor: null, numItems: 100 },
    });
    await ctx.runMutation(components.betterAuth.adapter.deleteMany, {
      input: {
        model: "account",
        where: [{ field: "userId", value: user._id }],
      },
      paginationOpts: { cursor: null, numItems: 100 },
    });
    await ctx.runMutation(components.betterAuth.adapter.deleteOne, {
      input: {
        model: "user",
        where: [{ field: "_id", value: user._id }],
      },
    });

    // Account email records (throttle state) and any lab outbox entries go
    // with the account.
    for (const kind of ["password_reset", "password_changed"] as const) {
      const rows = await ctx.db
        .query("authEmails")
        .withIndex("by_kind_user_created", (q) => q.eq("kind", kind).eq("userId", user._id))
        .take(200);
      for (const row of rows) {
        await ctx.db.delete(row._id);
      }
    }
    if (typeof user.email === "string" && user.email) {
      const address = user.email.trim().toLowerCase();
      const outbox = await ctx.db
        .query("labEmailOutbox")
        .withIndex("by_to_created", (q) => q.eq("to", address))
        .take(200);
      for (const row of outbox) {
        await ctx.db.delete(row._id);
      }
    }

    return true;
  },
});

export const importStats = query({
  args: {},
  returns: v.object({
    users: v.number(),
    accounts: v.number(),
    providers: v.array(v.string()),
  }),
  handler: async (ctx) => {
    const users = (await ctx.runQuery(components.betterAuth.adapter.findMany, {
      model: "user",
      paginationOpts: { cursor: null, numItems: 200 },
    })) as { page?: AdapterDoc[] };
    const accounts = (await ctx.runQuery(components.betterAuth.adapter.findMany, {
      model: "account",
      paginationOpts: { cursor: null, numItems: 200 },
    })) as { page?: AdapterDoc[] };

    return {
      users: users.page?.length ?? 0,
      accounts: accounts.page?.length ?? 0,
      providers: [
        ...new Set((accounts.page ?? []).map((account) => String(account.providerId || "")).filter(Boolean)),
      ].sort(),
    };
  },
});
