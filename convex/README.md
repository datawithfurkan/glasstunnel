# Glasstunnel Convex Backend

Convex holds Glasstunnel's accounts. It runs sign-in (Better Auth, as a Convex
component) and stores the account plane:

- `accountProfiles`
- `accountDevices`
- `devicePairings`
- `hostLinkCodes`
- `deviceApprovalRequests`
- `pushSubscriptions` (not used yet; push has not moved off the Mac relay path)
- `authEmails` (account email records: throttles and delivery outcome)
- `labEmailOutbox` (local lab only)

The Cloudflare Worker (`apps/cloudflare-signal`) stays the WebSocket signaling
and relay layer. It is the only client of the account plane.

## What is reachable from the internet

Every query and mutation is internal. A browser, or anyone holding only the
deployment URL, cannot call them. The deployment exposes two HTTP surfaces on
`https://<deployment>.convex.site`:

- `/api/auth/*`: Better Auth (email and password, Google, GitHub, session
  checks, password reset).
- `POST /worker/account-plane`: the Worker's gateway. It requires
  `Authorization: Bearer <WORKER_CONVEX_SECRET>`, accepts only an allowlisted
  function name, and answers `401` without the secret. Rejections such as
  `access_revoked` come back as `409` with a code; nothing else is echoed.

## Environment

Set these on the deployment (Convex dashboard, or `npx convex env set`):

| Name | Purpose |
| --- | --- |
| `BETTER_AUTH_SECRET` | Signs sessions. Random, at least 32 bytes. |
| `PUBLIC_APP_URL` | The web app origin, for example `https://app.glasstunnel.io`. Sign-in returns here. |
| `BETTER_AUTH_URL` | Optional. Defaults to the deployment's `.convex.site` URL. |
| `WORKER_CONVEX_SECRET` | Gateway secret, at least 32 characters. The Worker holds the same value as `CONVEX_WORKER_SECRET`. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Google sign-in. |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | GitHub sign-in. |
| `RESEND_API_KEY` | Secret. A Resend API key with **sending access only**, restricted to the sending domain. Turns on password reset email. |
| `AUTH_EMAIL_FROM` | The sender, on the domain verified in Resend, for example `Glasstunnel <no-reply@mail.glasstunnel.io>`. Required with `RESEND_API_KEY`. |
| `AUTH_EMAIL_OUTBOX` | Lab only. `lab` keeps account emails in the `labEmailOutbox` table instead of sending them. Ignored unless the auth URL (`BETTER_AUTH_URL`, else `CONVEX_SITE_URL`) is `127.0.0.1`, `localhost`, or `[::1]`. Never set it on a cloud deployment. |

The OAuth apps must list these redirect URLs exactly:

```text
https://<deployment>.convex.site/api/auth/callback/google
https://<deployment>.convex.site/api/auth/callback/github
```

## How sign-in reaches the app

The auth server and the app are different sites, so the app never relies on
cookies. Email sign-in returns the session token in the `set-auth-token`
header. Google and GitHub return to the app with a one-time token (`?ott=`)
that the app exchanges for the session token. The app only exchanges a
one-time token that comes back with the nonce it stored when it started that
sign-in (`gtAuthFlow`), which blocks login CSRF. Sessions last 60 days.

## Password reset email

The sign-in screen's "Forgot password?" posts the email to
`POST /api/auth/request-password-reset` (`{ email }`). When the address has an
account, Better Auth creates a single-use token that expires in 1 hour and
`convex/auth.ts` queues an email whose link opens the app directly:

```text
${PUBLIC_APP_URL}/?resetPassword=1&token=<token>
```

The app reads the token, removes it from the address bar, and posts
`{ newPassword, token }` to `POST /api/auth/reset-password`. A reset signs the
account out on every device (`revokeSessionsOnPasswordReset`) and queues a
"Your Glasstunnel password was changed" notice to the same address.

A Mac that starts sign-in opens the app at `?linkCode=<code>&authProvider=email`,
but the reset email opens another tab without that code. "Forgot password?"
therefore moves the code out of the address bar into `localStorage`
(`gt.pending-link-code`, 10 minutes, the link code's own lifetime), together
with the email typed so far. When the reset request is sent, that tab binds
the code to the address the reset is for. The code goes back into an address
bar only when a tab of this browser signs in itself (email and password,
sign-up, or a Google/GitHub return to that tab) to an account with exactly
that email (any case). The hosts screen then claims it as usual, and the
stored copy is removed, so no other tab can restore it. A tab that only
follows another tab's sign-in, a reload, a session refresh, or a sign-in to
any other account never gets it; it expires on its own. "Back to sign in" only
returns to the sign-in form, prefilled with that address when the tab has none
typed. A claim or a sign-out clears the stored code.

The reset reply never says whether an account exists: a known and an unknown
address both get `200 { status: true }` with the same body, and nothing in the
email path throws. An account that so far signs in only with Google or GitHub
can also use a reset link; Better Auth then adds an email password to that
account.

The reply also takes about the same time. A known address costs more work
than an unknown one (Better Auth stores a verification token, then
`email:queueAuthEmail` runs), which a client could otherwise measure. The
`glasstunnel-uniform-reset-timing` plugin in `convex/auth.ts` holds every
successful reply to `POST /api/auth/request-password-reset` until 250 ms after
the request reached the endpoint (`PASSWORD_RESET_RESPONSE_FLOOR_MS`), with a
before hook that notes the start and an after hook that waits out the rest.
Error replies (an invalid email, reset disabled, an untrusted origin) are the
same for every address and are not held, and no other route is affected.

The floor hides the difference only while the real work stays under it.
Measured on the local backend on 2026-10-08: 15 known and 15 unknown addresses,
requested one at a time and alternating, each known address a fresh account so
that every request queued an email; round trip on loopback:

| Floor | Known address, p50 / p95 | Unknown address, p50 / p95 |
| --- | --- | --- |
| Removed for the measurement | 77 / 89 ms | 63 / 68 ms |
| 250 ms | 268 / 269 ms | 265 / 269 ms |

A cloud deployment adds its own latency, so check the margin there before
relying on it, and keep `email:queueAuthEmail` small (two bounded index reads,
one or two inserts, one scheduled job).

The floor is not free, which is why it is 250 ms and not longer. The wait runs
inside the HTTP action, so each held reply keeps one slot of the deployment's
shared action and HTTP-action concurrency pool (64 on Convex's free plan) for
the whole floor. The endpoint needs no sign-in, so a client that sends reset
requests fast enough can fill that pool and delay everything else that runs in
it: the Worker gateway (`POST /worker/account-plane`, needed for every account
request and device sign-in) and Better Auth routes such as `get-session`.
Keeping all 64 slots busy with held replies takes about 256 requests a second
at 250 ms, against about 80 a second at 800 ms. A shorter floor raises the cost
of that attack; only a per-client limit in front of the endpoint (see the
follow-up below) takes it away.

The reset reply and the floor remove one way to learn whether an address has
an account, not every way. `POST /api/auth/sign-up/email` answers
`422 USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL` for an address that already has an
account, and the app then says "That email already has an account. Sign in
instead." Treat account existence as discoverable.

Email goes out only when delivery is configured:

| Mode | When | What happens |
| --- | --- | --- |
| Resend | `RESEND_API_KEY` and `AUTH_EMAIL_FROM` are both set | `email:queueAuthEmail` records the email and schedules `email:deliverAuthEmail`, which posts to the Resend API with the record id as the `Idempotency-Key`. HTTP 429, 5xx, or a network failure is retried once after 60 seconds. |
| Lab outbox | `AUTH_EMAIL_OUTBOX=lab` on a loopback auth URL (wins over Resend) | Nothing is sent. The email is stored in `labEmailOutbox`; the lab reads it with `convex run email:labOutbox '{"to":"..."}'`. |
| Off | Neither | Password reset is disabled. Better Auth answers every reset request with `400 RESET_PASSWORD_DISABLED` (the same for every address) and the app tells people to sign in with Google or GitHub. |

Throttles, applied in `email:queueAuthEmail`. An email over a limit is skipped
silently (the HTTP reply and its timing do not change) and a short warning
without the address is logged, for example
`auth email password_reset skipped: hourly limit reached`:

- Per account and email kind: three per rolling 24 hours. Reset emails also
  wait 2 minutes between sends; "password changed" notices do not, so a second
  reset made right after the first still reports itself.
- A completed reset deletes every other reset link the account was sent
  (`auth:revokePasswordResetLinks`, run from `onPasswordReset`), so an older
  email cannot change the password again.
- Across all accounts, per email kind:
  - reset emails: 15 per rolling hour and 40 per rolling 24 hours;
  - "password changed" notices: 20 per rolling 24 hours.

  Resend's free plan allows 100 emails a day, shared with other projects on
  the same Resend account, and both kinds count against it. In the worst case
  these caps send 40 + 20 = 60 account emails a day, which leaves 40 for
  everything else. Each count is one read of an index that stops at the cap
  (3 rows per account, at most 40 across accounts), so no read grows with
  traffic.
- The notice cap can drop a notice. Once 20 notices went out in 24 hours, a
  further reset still completes and still signs the account out everywhere,
  but no "password changed" email is sent for it.

Residual risk: the caps across accounts are shared by everyone, and anyone who
knows real account addresses can use them up without creating a single
account. Three requests for each of five addresses fill the hourly reset cap
within minutes; fourteen addresses fill the daily one (over at least three
hours, because of the hourly cap). While a cap is reached nobody gets a reset
email (for up to an hour after the hourly cap, up to 24 hours after the daily
cap), and the app still shows its usual "If an account exists for that email,
we sent a link to reset your password", so the person asking is not told.
Each of those requests also sends the real owner an unwanted reset email, at
most three a day per account. Requests for addresses without an account send
no email and do not count.

Email verification at sign-up does not fix this. It would keep reset emails
away from addresses nobody confirmed, but the addresses of real, confirmed
accounts work just as well for using up the caps. The durable fix is a
per-client limit keyed on a client IP the service can trust. **Follow-up, not
built yet:** route reset requests through the Cloudflare Worker, which sees
`CF-Connecting-IP` and already has Rate Limiting bindings for account
requests, and limit them per client address there before they reach Convex.
That would also stop one client from filling the concurrency pool described
above. It would not stop someone using many client addresses, so the caps
across accounts stay as the backstop.

Records and retention:

- `authEmails` holds kind, Better Auth user id, time, status
  (`queued`, `sent`, `failed`), attempts, the Resend message id, and a short
  error code such as `http_422`. It never holds an address, a link, or a
  provider response body. Rows are deleted after 7 days.
- `labEmailOutbox` entries are deleted after 1 day.
- The daily cron `prune account email records` (`email:pruneAuthEmails`, in
  `convex/crons.ts`) does both in batches of 200.
- `auth:deleteUserByLegacyId` also deletes the account's `authEmails` rows and
  lab outbox entries.
- The scheduled delivery job carries the record id and the reset link (single
  use, 1 hour). It looks the address up again when it runs. Logs carry the
  email kind and an HTTP status at most.
- Resend is a third party that does receive the address, the subject, and the
  whole message, including the live reset link, and keeps them in its sending
  logs and dashboard under its own retention. Treat access to the Resend
  account and dashboard like access to the Convex dashboard, and keep the API
  key limited to sending. Keep Resend's click and open tracking off so links
  are never rewritten.

Better Auth's own rate limiter is left at its defaults. It counts in memory,
which does not hold across Convex isolates, so the throttles above are the
limit to rely on. The app still shows a "Too many reset requests" message if
it ever gets HTTP 429.

## Link codes

A Mac shows a link code (`hostLinkCodes`, 10 minutes) and a signed-in browser
claims it through the Worker (`POST /account/claim-host-code`). The claim is
`accountPlane:claimHostLinkCode`: one mutation that finds the code's single
unconsumed, unexpired row and marks it used by the claiming account. Convex
runs mutations as serializable transactions, so when two claims for the same
code race (from one account or two), exactly one succeeds and the other gets
`link_code_not_found`. An expired code gets `link_code_expired`, and two live
rows for one code are refused as `link_code_not_found`. The Worker claims the
code before it links the Mac or pairs the browser, so the claim is final: if a
later step fails (for example, the Mac already belongs to another account),
the code stays used and the Mac has to show a new one.

## Deploying

Production deploys only through the Deploy workflow, which deploys Convex
first, then the Worker and the web app. It refuses to run unless the deploy key
belongs to the production deployment and the gateway secret is set.

For local work, `pnpm lab:up` runs these functions on a local Convex backend
(anonymous local mode, `127.0.0.1:3210` and `3211`) with lab-only secrets. It
never touches a cloud deployment.

## Migration helpers

`auth:importUserBatch`, `auth:deleteUserByLegacyId`, and the scripts under
`scripts/convex-migration/` moved the original accounts into Convex while
keeping their user ids. They are internal and need a deploy key or the local
admin CLI.
