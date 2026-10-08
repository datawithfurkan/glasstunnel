// Account emails: the password reset link and the "password changed" notice.
//
// Better Auth calls into convex/auth.ts, which queues each email here through
// `queueAuthEmail` (throttle + record). Delivery then runs in a scheduled
// action, so the sign-in request never waits on the email provider.
//
// Delivery modes (see emailDeliveryMode):
// - "resend": RESEND_API_KEY and AUTH_EMAIL_FROM are set. Sent with Resend.
// - "lab": AUTH_EMAIL_OUTBOX=lab on a loopback auth URL (the local test lab).
//   Nothing is sent; the email lands in `labEmailOutbox`.
// - "off": neither. convex/auth.ts then leaves password reset disabled.
//
// Privacy: `authEmails` rows hold no address and no link. Logs carry the
// email kind and an HTTP status at most, never an address, token, or link.

import { v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalAction, internalMutation, internalQuery } from "./_generated/server";

declare const process: { env: Record<string, string | undefined> };

export type AuthEmailKind = "password_reset" | "password_changed";
export type EmailDeliveryMode = "resend" | "lab" | "off";
export type AuthEmailContent = { subject: string; text: string; html: string };

/** Reset links work once and expire after this many seconds (Better Auth `resetPasswordTokenExpiresIn`). */
export const PASSWORD_RESET_TOKEN_SECONDS = 60 * 60;

const SECOND_MS = 1000;
const MINUTE_MS = 60 * SECOND_MS;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

/** Per account and kind: one email per 2 minutes, three per rolling 24 hours. */
const PER_ACCOUNT_COOLDOWN_MS = 2 * MINUTE_MS;
const PER_ACCOUNT_DAILY_LIMIT = 3;
/**
 * Across every account, per kind. Resend's free plan allows 100 emails a day,
 * shared with other projects on the same Resend account, and both kinds count
 * against it:
 * - password_reset: 15 per rolling hour and 40 per rolling 24 hours.
 * - password_changed: 20 per rolling 24 hours. Each notice follows a completed
 *   reset, but without its own cap 40 resets a day could add 40 notices.
 * Worst case 40 + 20 = 60 account emails a day, which leaves 40 of the quota.
 * Anyone who knows real account addresses can use these caps up without
 * creating an account (convex/README.md, "Residual risk").
 */
const GLOBAL_LIMITS: Record<AuthEmailKind, { hourly: number | null; daily: number }> = {
  password_reset: { hourly: 15, daily: 40 },
  password_changed: { hourly: null, daily: 20 },
};

const DELIVERY_MAX_ATTEMPTS = 2;
const DELIVERY_RETRY_DELAY_MS = 60 * SECOND_MS;
const DELIVERY_TIMEOUT_MS = 15 * SECOND_MS;
const RESEND_ENDPOINT = "https://api.resend.com/emails";

const AUTH_EMAIL_RETENTION_MS = 7 * DAY_MS;
const LAB_OUTBOX_RETENTION_MS = DAY_MS;
const LAB_OUTBOX_READ_LIMIT = 20;
const PRUNE_BATCH_SIZE = 200;

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);

const authEmailKind = v.union(v.literal("password_reset"), v.literal("password_changed"));
const nullableString = v.union(v.string(), v.null());
const labOutboxEntry = v.object({
  kind: authEmailKind,
  to: v.string(),
  subject: v.string(),
  text: v.string(),
  url: nullableString,
  createdAt: v.number(),
});

export function env(name: string) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** The Better Auth server origin (the deployment's `.convex.site` URL unless overridden). */
export function authBaseUrl() {
  return env("BETTER_AUTH_URL") || env("CONVEX_SITE_URL");
}

/** The web app. OAuth and reset links return here. */
export function appUrl() {
  return (env("PUBLIC_APP_URL") || "https://app.glasstunnel.io").replace(/\/+$/, "");
}

function isLoopbackUrl(value: string | undefined) {
  if (!value) {
    return false;
  }
  try {
    return LOOPBACK_HOSTS.has(new URL(value).hostname);
  } catch {
    return false;
  }
}

/**
 * How account emails go out on this deployment. The lab outbox wins over
 * Resend so a developer machine with a real key never mails lab accounts, and
 * it is ignored unless the auth server itself is on a loopback address.
 */
export function emailDeliveryMode(): EmailDeliveryMode {
  if (env("AUTH_EMAIL_OUTBOX") === "lab" && isLoopbackUrl(authBaseUrl())) {
    return "lab";
  }
  if (env("RESEND_API_KEY") && env("AUTH_EMAIL_FROM")) {
    return "resend";
  }
  return "off";
}

/** The link in the reset email opens the app directly; the app posts the token to /api/auth/reset-password. */
export function passwordResetLink(token: string) {
  return `${appUrl()}/?resetPassword=1&token=${encodeURIComponent(token)}`;
}

export function escapeHtml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const FONT_STACK = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const FOOTER_TEXT = "Sent by Glasstunnel to the email address on your account.";
/** Light-mode colors, set inline so clients that drop <style> still get them. */
const LINK_COLOR = "#0062cc";
const MUTED_COLOR = "#6b7280";
/**
 * Dark-mode colors for clients that honour prefers-color-scheme (Apple Mail,
 * iOS Mail, Outlook for Mac). `!important` is what lets a stylesheet rule
 * beat the inline light defaults.
 */
const DARK_MODE_STYLE = [
  "<style>",
  ":root{color-scheme:light dark;}",
  "@media (prefers-color-scheme: dark){",
  ".gt-link{color:#6cb4ff !important;}",
  ".gt-muted{color:#a1a1aa !important;}",
  "}",
  "</style>",
].join("\n");

/**
 * A plain, single-column layout. Body text keeps the mail client's own colors
 * so it reads in light and dark mode; links and the small print carry a light
 * color inline and a lighter one in dark mode (DARK_MODE_STYLE).
 */
function emailLayout(subject: string, bodyHtml: string) {
  return [
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<meta name="color-scheme" content="light dark">',
    '<meta name="supported-color-schemes" content="light dark">',
    `<title>${escapeHtml(subject)}</title>`,
    DARK_MODE_STYLE,
    "</head>",
    `<body style="margin:0;padding:24px 16px;font-family:${FONT_STACK};font-size:16px;line-height:1.5;">`,
    '<div style="max-width:480px;margin:0 auto;">',
    '<p style="margin:0 0 24px;font-size:18px;font-weight:600;">Glasstunnel</p>',
    bodyHtml,
    `<p class="gt-muted" style="margin:32px 0 0;font-size:13px;color:${MUTED_COLOR};">${escapeHtml(FOOTER_TEXT)}</p>`,
    "</div>",
    "</body>",
    "</html>",
  ].join("\n");
}

/** A link in body text: the light color inline, the dark one from DARK_MODE_STYLE. */
function textLink(href: string, label: string, extraStyle = "") {
  return `<a class="gt-link" href="${href}" style="color:${LINK_COLOR};${extraStyle}">${label}</a>`;
}

function paragraph(html: string) {
  return `<p style="margin:0 0 16px;">${html}</p>`;
}

export function passwordResetEmail(link: string): AuthEmailContent {
  const subject = "Reset your Glasstunnel password";
  const text = [
    subject,
    "",
    "Someone asked to reset the password for the Glasstunnel account that uses this email address.",
    "",
    "Choose a new password:",
    link,
    "",
    "The link works once and expires in 1 hour.",
    "",
    "If you didn't ask for this, ignore this email. Nothing changes and your password stays the same.",
    "",
    FOOTER_TEXT,
  ].join("\n");
  const href = escapeHtml(link);
  const html = emailLayout(
    subject,
    [
      paragraph("Someone asked to reset the password for the Glasstunnel account that uses this email address."),
      `<p style="margin:24px 0;"><a href="${href}" style="display:inline-block;padding:12px 20px;border-radius:8px;background:${LINK_COLOR};color:#ffffff;font-weight:600;text-decoration:none;">Choose a new password</a></p>`,
      paragraph("The link works once and expires in 1 hour."),
      paragraph("If you didn't ask for this, ignore this email. Nothing changes and your password stays the same."),
      `<p class="gt-muted" style="margin:24px 0 0;font-size:13px;color:${MUTED_COLOR};">If the button doesn't work, paste this link into your browser:<br>${textLink(href, href, "word-break:break-all;")}</p>`,
    ].join("\n"),
  );
  return { subject, text, html };
}

export function passwordChangedEmail(): AuthEmailContent {
  const subject = "Your Glasstunnel password was changed";
  const app = appUrl();
  const text = [
    subject,
    "",
    "The password for the Glasstunnel account that uses this email address was just changed. Every device that was signed in to this account has been signed out.",
    "",
    "If this was you, sign in again with your new password. There's nothing else to do.",
    "",
    `If it wasn't you, reset your password right away: open Glasstunnel at ${app}, choose "Forgot password?" on the sign-in screen, and use the link we email you.`,
    "",
    FOOTER_TEXT,
  ].join("\n");
  const appHref = escapeHtml(app);
  const html = emailLayout(
    subject,
    [
      paragraph(
        "The password for the Glasstunnel account that uses this email address was just changed. Every device that was signed in to this account has been signed out.",
      ),
      paragraph("If this was you, sign in again with your new password. There's nothing else to do."),
      paragraph(
        `<strong>If it wasn't you, reset your password right away:</strong> open Glasstunnel at ${textLink(appHref, appHref)}, choose &ldquo;Forgot password?&rdquo; on the sign-in screen, and use the link we email you.`,
      ),
    ].join("\n"),
  );
  return { subject, text, html };
}

/** The email for a queued row, or null when a reset email has no link to carry. */
export function authEmailContent(kind: AuthEmailKind, url: string | null): AuthEmailContent | null {
  if (kind === "password_reset") {
    return url ? passwordResetEmail(url) : null;
  }
  return passwordChangedEmail();
}

function normalizeAddress(address: string) {
  return address.trim().toLowerCase();
}

/**
 * Throttles, records, and queues one account email. Never throws for an
 * over-limit request: it skips silently so the HTTP reply is the same for
 * every address. In lab mode the email goes to `labEmailOutbox` and nothing
 * is delivered; with Resend, `deliverAuthEmail` runs right after commit.
 *
 * Runs inside the auth request, so it stays small: at most two bounded
 * index reads (3 rows, then at most 40), one or two inserts, and one
 * scheduled job.
 */
export const queueAuthEmail = internalMutation({
  args: {
    kind: authEmailKind,
    userId: v.string(),
    to: v.string(),
    url: nullableString,
  },
  returns: v.union(v.literal("queued"), v.literal("throttled"), v.literal("disabled"), v.literal("invalid")),
  handler: async (ctx, args): Promise<"queued" | "throttled" | "disabled" | "invalid"> => {
    const mode = emailDeliveryMode();
    if (mode === "off") {
      return "disabled";
    }
    const userId = args.userId.trim();
    const to = normalizeAddress(args.to);
    const url = args.kind === "password_reset" ? args.url : null;
    if (!userId || !to || (args.kind === "password_reset" && !url)) {
      console.warn(`auth email ${args.kind} skipped: missing recipient or link`);
      return "invalid";
    }

    // Each count reads its index newest first and stops at the cap: `cap`
    // rows are enough to tell whether the cap is reached, so no read grows
    // with traffic.
    const now = Date.now();
    const recentForAccount = await ctx.db
      .query("authEmails")
      .withIndex("by_kind_user_created", (q) =>
        q.eq("kind", args.kind).eq("userId", userId).gt("createdAt", now - DAY_MS),
      )
      .order("desc")
      .take(PER_ACCOUNT_DAILY_LIMIT);
    const newest = recentForAccount[0];
    if (
      recentForAccount.length >= PER_ACCOUNT_DAILY_LIMIT ||
      (newest && newest.createdAt > now - PER_ACCOUNT_COOLDOWN_MS)
    ) {
      console.warn(`auth email ${args.kind} skipped: per-account limit reached`);
      return "throttled";
    }

    // When fewer than the daily cap come back, they are every email of this
    // kind from the last 24 hours, so the hourly count comes from the same rows.
    const limits = GLOBAL_LIMITS[args.kind];
    const recentOfKind = await ctx.db
      .query("authEmails")
      .withIndex("by_kind_created", (q) => q.eq("kind", args.kind).gt("createdAt", now - DAY_MS))
      .order("desc")
      .take(limits.daily);
    if (recentOfKind.length >= limits.daily) {
      console.warn(`auth email ${args.kind} skipped: daily limit reached`);
      return "throttled";
    }
    if (limits.hourly !== null) {
      const lastHour = recentOfKind.filter((row) => row.createdAt > now - HOUR_MS).length;
      if (lastHour >= limits.hourly) {
        console.warn(`auth email ${args.kind} skipped: hourly limit reached`);
        return "throttled";
      }
    }

    if (mode === "lab") {
      const content = authEmailContent(args.kind, url);
      if (!content) {
        return "invalid";
      }
      await ctx.db.insert("authEmails", {
        kind: args.kind,
        userId,
        createdAt: now,
        status: "sent",
        attempts: 1,
      });
      await ctx.db.insert("labEmailOutbox", {
        kind: args.kind,
        to,
        subject: content.subject,
        text: content.text,
        url,
        createdAt: now,
      });
      return "queued";
    }

    const emailId = await ctx.db.insert("authEmails", {
      kind: args.kind,
      userId,
      createdAt: now,
      status: "queued",
      attempts: 0,
    });
    // The scheduled job carries the row id and the link (which works once and
    // expires in an hour). The address is looked up again at delivery time.
    await ctx.scheduler.runAfter(0, internal.email.deliverAuthEmail, { emailId, url, attempt: 1 });
    return "queued";
  },
});

export const getAuthEmailForDelivery = internalQuery({
  args: { emailId: v.id("authEmails") },
  returns: v.union(
    v.object({
      kind: authEmailKind,
      userId: v.string(),
      status: v.union(v.literal("queued"), v.literal("sent"), v.literal("failed")),
    }),
    v.null(),
  ),
  handler: async (ctx, args) => {
    const row = await ctx.db.get(args.emailId);
    return row ? { kind: row.kind, userId: row.userId, status: row.status } : null;
  },
});

export const recordAuthEmailDelivery = internalMutation({
  args: {
    emailId: v.id("authEmails"),
    status: v.union(v.literal("queued"), v.literal("sent"), v.literal("failed")),
    attempts: v.number(),
    providerMessageId: v.optional(v.string()),
    error: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const row = await ctx.db.get(args.emailId);
    if (!row) {
      return null;
    }
    await ctx.db.patch(args.emailId, {
      status: args.status,
      attempts: args.attempts,
      providerMessageId: args.providerMessageId,
      error: args.error,
    });
    return null;
  },
});

type DeliveryResult = { status: number; providerMessageId?: string };

/** The provider's message id, when the reply carries a plausible one. Nothing else is read or kept. */
async function readProviderMessageId(response: Response): Promise<string | undefined> {
  try {
    const body = (await response.json()) as { id?: unknown } | null;
    const id = body && typeof body.id === "string" ? body.id : "";
    return /^[A-Za-z0-9_-]{1,128}$/.test(id) ? id : undefined;
  } catch {
    return undefined;
  }
}

async function sendWithResend(
  emailId: Id<"authEmails">,
  apiKey: string,
  message: { from: string; to: string; subject: string; text: string; html: string },
): Promise<DeliveryResult> {
  const controller = typeof AbortController === "function" ? new AbortController() : undefined;
  const timer = controller ? setTimeout(() => controller.abort(), DELIVERY_TIMEOUT_MS) : undefined;
  try {
    const response = await fetch(RESEND_ENDPOINT, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
        // Resend drops a repeat with the same key, so the retry cannot send twice.
        "idempotency-key": emailId,
      },
      body: JSON.stringify({
        from: message.from,
        to: [message.to],
        subject: message.subject,
        text: message.text,
        html: message.html,
      }),
      signal: controller?.signal,
    });
    if (!response.ok) {
      return { status: response.status };
    }
    return { status: response.status, providerMessageId: await readProviderMessageId(response) };
  } catch {
    return { status: 0 };
  } finally {
    if (timer !== undefined) {
      clearTimeout(timer);
    }
  }
}

async function recipientAddress(ctx: { runQuery: (reference: any, args: any) => Promise<any> }, userId: string) {
  const user = (await ctx.runQuery(components.betterAuth.adapter.findOne, {
    model: "user",
    where: [{ field: "_id", value: userId }],
  })) as { email?: unknown } | null;
  return user && typeof user.email === "string" && user.email.trim() ? user.email.trim() : null;
}

/** Sends one queued email with Resend. Retries once, a minute later, on HTTP 429, 5xx, or a network failure. */
export const deliverAuthEmail = internalAction({
  args: {
    emailId: v.id("authEmails"),
    url: nullableString,
    attempt: v.number(),
  },
  returns: v.null(),
  handler: async (ctx, args): Promise<null> => {
    const record = async (
      status: "queued" | "sent" | "failed",
      extra: { providerMessageId?: string; error?: string } = {},
    ) => {
      await ctx.runMutation(internal.email.recordAuthEmailDelivery, {
        emailId: args.emailId,
        status,
        attempts: args.attempt,
        ...extra,
      });
    };

    const email: { kind: AuthEmailKind; userId: string; status: "queued" | "sent" | "failed" } | null =
      await ctx.runQuery(internal.email.getAuthEmailForDelivery, { emailId: args.emailId });
    if (!email || email.status !== "queued") {
      return null;
    }

    const apiKey = env("RESEND_API_KEY");
    const from = env("AUTH_EMAIL_FROM");
    if (emailDeliveryMode() !== "resend" || !apiKey || !from) {
      console.warn(`auth email ${email.kind} not sent: delivery is not configured`);
      await record("failed", { error: "not_configured" });
      return null;
    }

    const content = authEmailContent(email.kind, args.url);
    const to = await recipientAddress(ctx, email.userId);
    if (!content || !to) {
      console.warn(`auth email ${email.kind} not sent: ${content ? "no recipient" : "no link"}`);
      await record("failed", { error: content ? "no_recipient" : "no_link" });
      return null;
    }

    const result = await sendWithResend(args.emailId, apiKey, { from, to, ...content });
    if (result.status >= 200 && result.status < 300) {
      await record("sent", { providerMessageId: result.providerMessageId });
      return null;
    }

    const error = result.status === 0 ? "network" : `http_${result.status}`;
    const retryable = result.status === 0 || result.status === 429 || result.status >= 500;
    if (retryable && args.attempt < DELIVERY_MAX_ATTEMPTS) {
      console.warn(`auth email ${email.kind} delivery will retry: ${error}`);
      await record("queued", { error });
      await ctx.scheduler.runAfter(DELIVERY_RETRY_DELAY_MS, internal.email.deliverAuthEmail, {
        emailId: args.emailId,
        url: args.url,
        attempt: args.attempt + 1,
      });
      return null;
    }

    console.warn(`auth email ${email.kind} delivery failed: ${error}`);
    await record("failed", { error });
    return null;
  },
});

/**
 * Local lab only: the newest emails (at most 20) addressed to `to`. Returns
 * an empty list on any deployment that is not in lab outbox mode.
 */
export const labOutbox = internalQuery({
  args: { to: v.string() },
  returns: v.array(labOutboxEntry),
  handler: async (ctx, args) => {
    if (emailDeliveryMode() !== "lab") {
      return [];
    }
    const to = normalizeAddress(args.to);
    const rows = await ctx.db
      .query("labEmailOutbox")
      .withIndex("by_to_created", (q) => q.eq("to", to))
      .order("desc")
      .take(LAB_OUTBOX_READ_LIMIT);
    return rows.map((row) => ({
      kind: row.kind,
      to: row.to,
      subject: row.subject,
      text: row.text,
      url: row.url,
      createdAt: row.createdAt,
    }));
  },
});

/**
 * Deletes email records older than 7 days and lab outbox entries older than
 * 1 day, in bounded batches. Runs daily (convex/crons.ts) and reschedules
 * itself while a batch comes back full.
 */
export const pruneAuthEmails = internalMutation({
  args: {},
  returns: v.object({ authEmails: v.number(), labEmailOutbox: v.number() }),
  handler: async (ctx): Promise<{ authEmails: number; labEmailOutbox: number }> => {
    const now = Date.now();
    const staleEmails = await ctx.db
      .query("authEmails")
      .withIndex("by_created", (q) => q.lt("createdAt", now - AUTH_EMAIL_RETENTION_MS))
      .take(PRUNE_BATCH_SIZE);
    for (const row of staleEmails) {
      await ctx.db.delete(row._id);
    }
    const staleOutbox = await ctx.db
      .query("labEmailOutbox")
      .withIndex("by_created", (q) => q.lt("createdAt", now - LAB_OUTBOX_RETENTION_MS))
      .take(PRUNE_BATCH_SIZE);
    for (const row of staleOutbox) {
      await ctx.db.delete(row._id);
    }
    if (staleEmails.length === PRUNE_BATCH_SIZE || staleOutbox.length === PRUNE_BATCH_SIZE) {
      await ctx.scheduler.runAfter(0, internal.email.pruneAuthEmails, {});
    }
    return { authEmails: staleEmails.length, labEmailOutbox: staleOutbox.length };
  },
});
