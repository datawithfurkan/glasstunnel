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

## Validation

```bash
pnpm worker:typecheck
pnpm worker:test
pnpm worker:build
```

`worker:test` uses Cloudflare's Vitest pool and a test-specific Wrangler
configuration. It runs in real `workerd` without loading `.dev.vars` or cloud
credentials. `worker:build` is a dry run and does not deploy.

Use manual `wrangler dev` only for Worker-only debugging. Prefer the lab for
account, PWA, relay, or host behavior.

## Deployment

Production configuration is in `wrangler.jsonc`. Deployment requires the
documented Cloudflare, Supabase, and VAPID environment values and must happen
through the explicit release workflow, never as part of a local test command.

Production endpoints:

- App: `https://app.glasstunnel.io`
- Signaling: `wss://signaling.glasstunnel.io/signal`
