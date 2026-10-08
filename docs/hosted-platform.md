# Hosted platform: Cloudflare and Convex

This document tracks the hosted Glasstunnel platform layout.

## Current hosted resources

- Cloudflare Pages project: `glasstunnel`
- Hosted PWA URLs:
  - `https://app.glasstunnel.io`
  - `https://glasstunnel.pages.dev`
- Signaling Worker: `glasstunnel-signal` on `signaling.glasstunnel.io`
- Convex project `glasstunnel-convex`:
  - Production deployment: `adorable-perch-596` (accounts, sign-in, account plane)
  - Development deployment: `whimsical-sockeye-495`
- Deploy workflow: `.github/workflows/deploy.yml` (manual; Convex first, then
  the Worker and the web surfaces)
- Auth email: Resend, sending domain `mail.glasstunnel.io` (region Ireland,
  eu-west-1). The Convex deployment sends password reset and password changed
  emails with `RESEND_API_KEY` and `AUTH_EMAIL_FROM` (see `convex/README.md`).
  Click and open tracking stay off so reset links are never rewritten.
- DNS: the `glasstunnel.io` zone is on Cloudflare (Namecheap is only the
  registrar). Mail forwarding for the main domain stays on Namecheap's MX and
  SPF records. Resend's records live on the `mail` subdomain:
  `resend._domainkey.mail` (DKIM TXT), `send.mail` and `rsend.mail` (CNAMEs,
  DNS only). `_dmarc` holds a monitoring-only policy (`p=none`).
- `www.glasstunnel.io` redirects permanently to `https://glasstunnel.io` with a
  Cloudflare redirect rule.

The Supabase project (`gdvqnyebglrimangddts`) is retired. Accounts moved to
Convex on 2026-09-29, and nothing in the product reads it since 2026-10-08.

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

- Cloudflare worker signaling is implemented with Durable Object WebSocket routing, nonce auth, bounded offline queues, and Convex-backed device registration, host claim codes, host listing, and approval requests through the shared-secret gateway.
- Push fanout is still pending on the Cloudflare worker. `/push/register` currently acknowledges with a migration-pending response while the Go signaling server remains the complete push implementation.

## Immediate next platform steps

1. Add GitHub repository secrets:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`
2. Let `CI` remain the quality gate, and run `Deploy` for a commit on `main`
   after its CI passes.
3. Migrate Web Push registration and VAPID fanout into `apps/cloudflare-signal`.
4. Keep TURN separate from Pages. TURN needs its own public hostname and relay
   infrastructure.
