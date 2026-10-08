# Glasstunnel Convex Backend

Convex holds Glasstunnel's accounts. It runs sign-in (Better Auth, as a Convex
component) and stores the account plane:

- `accountProfiles`
- `accountDevices`
- `devicePairings`
- `hostLinkCodes`
- `deviceApprovalRequests`
- `pushSubscriptions` (not used yet; push has not moved off the Mac relay path)

The Cloudflare Worker (`apps/cloudflare-signal`) stays the WebSocket signaling
and relay layer. It is the only client of the account plane.

## What is reachable from the internet

Every query and mutation is internal. A browser, or anyone holding only the
deployment URL, cannot call them. The deployment exposes two HTTP surfaces on
`https://<deployment>.convex.site`:

- `/api/auth/*`: Better Auth (email and password, Google, GitHub, session checks).
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
