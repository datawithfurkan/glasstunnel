# Self-hosting Glasstunnel

Glasstunnel currently has two self-hosting profiles. They are not interchangeable.

## Account-first local environment

The Local Test Lab is the supported way to run the complete account-first product on
one development Mac. It starts local Supabase, the Cloudflare Worker under `workerd`,
the PWA, and an optional isolated Swift host without production credentials.

Prerequisites are macOS, Node.js 22+, pnpm 9+, Docker Desktop, Supabase CLI, Xcode
command-line tools, and Playwright Chromium/WebKit.

```bash
pnpm install
pnpm exec playwright install chromium webkit
pnpm lab:doctor
pnpm lab:up:host
pnpm lab:e2e
pnpm lab:down
```

All generated credentials and runtime state stay in ignored local storage. See
`docs/dev-runbook.md` for commands and cleanup guarantees.

## Lightweight signaling and TURN

`deploy/compose.yml` runs the standalone Go signaling service plus coturn. This is
useful for transport development and device-key deployments, but it does **not**
provide the hosted Supabase account, link-code, or device-approval plane.

Prerequisites:

- A host with a public IPv4 address for TURN.
- Docker with Compose.
- Firewall access for TCP/UDP 3478 and UDP 49160-49200.
- TLS termination for any internet-facing WebSocket endpoint.

```bash
git clone https://github.com/datawithfurkan/glasstunnel.git
cd glasstunnel/deploy
cp .env.example .env
# Replace TURN_PASSWORD and review every value before exposure.
docker compose --env-file .env -f compose.yml up -d
```

The signaling health endpoint is `GET /health`. Never commit the resulting `.env`.
For public use, terminate signaling as `wss://`, use a strong unique TURN password,
restrict management access, monitor bandwidth, and keep Docker images patched.

## Production account-first deployment

The hosted product uses:

- Cloudflare Pages for `apps/mobile-pwa`.
- Cloudflare Workers and Durable Objects for `apps/cloudflare-signal`.
- Supabase Auth and the migrations under `supabase/migrations`.
- A separately operated TURN service for WebRTC fallback.

A production fork needs its own Cloudflare account/project/routes, Supabase project,
OAuth providers, domains, TURN service, and the following deployment values:

- PWA build: `VITE_PUBLIC_APP_URL`, `VITE_SIGNALING_URL`, `VITE_SUPABASE_URL`,
  `VITE_SUPABASE_ANON_KEY`.
- Worker secret/config: `PUBLIC_APP_URL`, `SUPABASE_URL`,
  `ALLOWED_ORIGINS`, `SUPABASE_SERVICE_ROLE_KEY`, and optional
  `VAPID_PUBLIC_KEY`.
- GitHub release deployment: `CLOUDFLARE_API_TOKEN` and
  `CLOUDFLARE_ACCOUNT_ID` if using the included manual workflow.

Do not reuse the checked-in production Cloudflare account ID, route, or project name
in a fork. Copy `apps/cloudflare-signal/wrangler.jsonc`, replace those identifiers,
set `ALLOWED_ORIGINS` to the exact comma-separated browser origins you operate,
choose unique Rate Limiting binding namespace IDs, apply both Supabase migrations,
configure authentication redirect URLs, and deploy the PWA and Worker from your own
account.

Turnkey production self-hosting is still Preview. The repository provides the code
and repeatable local environment, but not an automated installer for domains, OAuth,
Cloudflare, Supabase, TURN, monitoring, backups, or upgrades. Contributions that make
this path safer and more reproducible are welcome.
