# Cloudflare Signaling Worker

This package is Glasstunnel's account-first control plane on Cloudflare Workers
and Durable Objects. It provides signaling, authenticated host registration,
link codes, device access, approval requests, and bounded offline forwarding.

Push registration and VAPID fanout have not yet migrated to this Worker.

## Local Development

Use the root Local Test Lab so the Worker receives generated local Supabase
credentials without touching developer or production secrets:

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
fake Supabase (see `test/relayHub.test.ts`). `worker:build` is a dry run and
does not deploy.

Use manual `wrangler dev` only for Worker-only debugging. Prefer the lab for
account, PWA, relay, or host behavior.

## Deployment

Production configuration is in `wrangler.jsonc`. Deployment requires the
documented Cloudflare, Supabase, and VAPID environment values and must happen
through the explicit release workflow, never as part of a local test command.

Production endpoints:

- App: `https://app.glasstunnel.io`
- Signaling: `wss://signaling.glasstunnel.io/signal`

Production allows `https://app.glasstunnel.io` and applies a generous limit of
120 requests per minute per account or upgrade key, plus 600 account requests
per minute per connecting address. These limits are an abuse guard, not an
authentication boundary or a billing meter.
