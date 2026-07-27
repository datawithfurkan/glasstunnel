# Cloudflare + Supabase rollout

This document tracks the hosted Glasstunnel platform layout.

## Current hosted resources

- Cloudflare Pages project: `glasstunnel`
- Hosted PWA URLs:
  - `https://app.glasstunnel.io`
  - `https://glasstunnel.pages.dev`
- GitHub auto-deploy workflow: `.github/workflows/deploy.yml`
- Supabase project: `Glass Tunnel`
- Supabase project ref: `gdvqnyebglrimangddts`

## Recommended public hostnames

- `glasstunnel.io` -> marketing / homepage
- `app.glasstunnel.io` -> phone web app
- `signaling.glasstunnel.io` -> realtime signaling worker
- `turn.glasstunnel.io` -> TURN service

## DNS decision

There are two valid Cloudflare Pages setups:

1. Full Cloudflare zone
   Use this when moving the whole product onto Cloudflare. This is the
   recommended long-term setup for Glasstunnel.

   - Add `glasstunnel.io` as a zone in Cloudflare.
   - Update the domain nameservers at Namecheap to the Cloudflare nameservers.
   - After the zone is active, attach `glasstunnel.io` and/or
     `app.glasstunnel.io` to the Pages project in Cloudflare.

2. External DNS subdomain
   Use this only if you want to avoid a nameserver move temporarily.

   - Keep Namecheap as the authoritative DNS provider.
   - Add `app.glasstunnel.io` as a custom domain in the Pages project.
   - Create the required CNAME at Namecheap pointing to `glasstunnel.pages.dev`.

Notes:

- Cloudflare requires the apex domain (`glasstunnel.io`) to be a Cloudflare
  zone. Apex Pages on external DNS is not the right path.
- Subdomains can be attached to Pages without moving the whole zone, but that
  is a temporary compromise rather than the preferred end-state for this
  project.

## Current platform status

- Cloudflare worker signaling is implemented with Durable Object WebSocket routing, nonce auth, bounded offline queues, Supabase-backed device registration, host claim codes, host listing, and approval requests.
- Push fanout is still pending on the Cloudflare worker. `/push/register` currently acknowledges with a migration-pending response while the Go signaling server remains the complete push implementation.

## Immediate next platform steps

1. Add GitHub repository secrets:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`
2. Let `CI` remain the quality gate, and let `Deploy` run after successful
   `main` builds.
3. Migrate Web Push registration and VAPID fanout into `apps/cloudflare-signal`.
4. Keep TURN separate from Pages. TURN needs its own public hostname and relay
   infrastructure.
