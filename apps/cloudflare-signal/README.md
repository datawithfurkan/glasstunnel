# Cloudflare Signaling Worker

This package is Glasstunnel's account-first control plane on Cloudflare Workers
and Durable Objects. It provides signaling, authenticated host registration,
link codes, device access, approval requests, and bounded offline forwarding.

Push registration and VAPID fanout have not yet migrated to this Worker.

## Local Development

Use the root Local Test Lab so the Worker talks to a local Convex backend with
generated lab-only secrets, without touching developer or production secrets:

```bash
pnpm lab:up
pnpm lab:status
pnpm lab:down
```

The lab runs Wrangler on `127.0.0.1:8787`, stores Durable Object state in the
ignored lab cache, and writes a mode-`0600` generated env file. It does not
overwrite `apps/cloudflare-signal/.dev.vars`.

Browser requests are accepted only from the exact origins in
`ALLOWED_ORIGINS` (a comma-separated list). Native clients that do not send an
`Origin` header remain supported and must still pass the normal account and
device-key authentication. The local lab writes its PWA origin automatically.

The Worker also uses separate Cloudflare Rate Limiting bindings for account API
requests and WebSocket upgrade attempts. Account keys are scoped by endpoint and
a digest of the bearer token, with a higher-capacity address bucket that stops
token rotation from bypassing the guard. Requests without bearer tokens use the
connecting address for both account buckets. Upgrade keys are scoped by endpoint
and connecting address. Raw bearer tokens are never placed in rate-limit keys.

## Account Plane

Accounts, devices, pairings, link codes, and approval requests live in Convex
(`convex/`). Every Convex function is internal; the Worker reaches them through
one HTTP gateway on the deployment's `.convex.site` origin:

```text
POST {CONVEX_SITE_URL}/worker/account-plane
Authorization: Bearer {CONVEX_WORKER_SECRET}
{"fn": "<allowlisted function>", "args": {...}}
```

Bearer tokens from the app are Better Auth session tokens; the Worker verifies
them through the same gateway (`verifyBearerToken`) and caps relay
authorization at the session's expiry.

Configuration:

- `CONVEX_URL` and `CONVEX_SITE_URL` (vars in `wrangler.jsonc`). The site URL is
  derived from `CONVEX_URL` when unset.
- `CONVEX_WORKER_SECRET` (a Worker secret). It must equal the deployment's
  `WORKER_CONVEX_SECRET`.

The Worker fails closed: without the secret, or when Convex is unreachable,
account requests answer `503` and relay auth is refused. A gateway rejection
(for example `access_revoked`) becomes a `403`. Function names and gateway
codes stay in the Worker log and never appear in replies.

## Validation

```bash
pnpm worker:typecheck
pnpm worker:test
pnpm worker:build
```

`worker:test` uses Cloudflare's Vitest pool and a test-specific Wrangler
configuration. It runs in real `workerd` without loading `.dev.vars` or cloud
credentials. Tests never reach the network: `test/setup.ts` fails any outbound
`fetch` fast, and tests that exercise account or relay auth stub `fetch` with a
fake Convex gateway that mirrors `convex/accountPlane.ts` (see
`test/relayHub.test.ts`). `worker:build` is a dry run and
does not deploy.

Use manual `wrangler dev` only for Worker-only debugging. Prefer the lab for
account, PWA, relay, or host behavior.

## Deployment

Production configuration is in `wrangler.jsonc`. Deployment requires the
Cloudflare credentials and the `CONVEX_WORKER_SECRET` Worker secret, and
happens only through the Deploy workflow (after Convex), never as part of a
local test command.

Production endpoints:

- App: `https://app.glasstunnel.io`
- Signaling: `wss://signaling.glasstunnel.io/signal`

Production allows `https://app.glasstunnel.io` and applies a generous limit of
120 requests per minute per account or upgrade key, plus 600 account requests
per minute per connecting address. These limits are an abuse guard, not an
authentication boundary or a billing meter.
