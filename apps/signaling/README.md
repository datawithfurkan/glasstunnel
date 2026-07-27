# glasstunnel signaling server

A tiny stateless WebSocket service that brokers WebRTC handshakes between a Mac host and account-linked devices, without ever seeing user content.

## What it does

1. Accepts WebSocket connections at `/signal`.
2. Each connection authenticates by presenting an ed25519 public key and signing a nonce issued by the server.
3. Envelopes addressed `from_device_id -> to_device_id` get forwarded if the destination is also connected; otherwise they are briefly queued (60 seconds) and delivered on reconnect.
4. Web Push subscriptions are forwarded to `/push/register` so the service can fire VAPID pushes to linked devices when the Mac reports `AGENT_STATUS_DONE` or `AGENT_STATUS_WAITING_INPUT`.

## What it does NOT do

- It does not decrypt content and does not need envelope payloads to route signaling. For Web Push only, it reads the `agentStateEvent` status metadata reported by the Mac.
- It stores nothing durable except (optionally) the browser's Web Push subscription, keyed by its public key.
- It has no Supabase-backed account API. Identity is device-scoped via ed25519 keys. The hosted account-first path lives in `apps/cloudflare-signal`.

## Run locally

```bash
cd apps/signaling
go run ./cmd/server
```

The server listens on `:8080` by default. Override with `-addr=:9090` or `PORT=9090`.

Config via environment:

- `GLASSTUNNEL_VAPID_PUBLIC` / `GLASSTUNNEL_VAPID_PRIVATE` - VAPID keys for Web Push. If unset, push is disabled and the server logs a warning but still works for signaling.
- `GLASSTUNNEL_VAPID_SUBJECT` - `mailto:you@example.com` or `https://yourdomain`.
- `GLASSTUNNEL_MAX_QUEUED_ENVELOPES` - per-device cap on buffered envelopes (default 256).
- `GLASSTUNNEL_NONCE_TTL_SECONDS` - auth nonce lifetime (default 30).

## Deploy

See `deploy/signaling/` for a Dockerfile and `deploy/compose.yml` for an all-in-one self-host stack with coturn.

## Self-host

A full self-host is one command:

```bash
cd deploy && docker compose up -d
```

That brings up the signaling server and a coturn TURN server. Point your Mac host and PWA at `ws://localhost:8080/signal` and `turn:localhost:3478` respectively via the settings UI.
