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

## Managing Macs

Signed-in browsers manage the account's Macs through two endpoints. Both take
`Authorization: Bearer <session token>` and answer `404 {ok:false, error:"Mac not found"}`
for any device that is not the caller's active Mac, whatever the reason. Any
signed-in session of the account can use them for any of the account's Macs,
including a browser that one of those Macs revoked: a Mac's revocation is not an
account sign-out (an accepted product decision, see `docs/security.md`).

- `POST /account/hosts/rename {deviceId, label, requesterDeviceId?}` answers
  `200 {ok:true, host}` with the renamed host record. The name rule is in
  `src/hostLabel.ts` (Convex applies the same rule from `convex/hostLabel.ts`,
  and `test/hostLabel.test.ts` checks that both agree): the name is normalized
  to NFC and trimmed, then refused with `400` and `Enter a name.` when empty,
  `Remove hidden characters from the name.` when it contains a control
  character, U+2028 or U+2029, a bidi control (U+202A to U+202E, U+2066 to
  U+2069, U+200E, U+200F) or the invisible U+200B, U+2060 or U+FEFF, and
  `Use 40 characters or fewer.` when it has more than 40 code points. U+200D
  and U+200C are allowed. The normalized name is stored. With
  `requesterDeviceId` the record's `trusted` and `pairedAtUnixMs` match the
  hosts list for that browser; without it the record follows the account-first
  rule (`trusted: true`). If those details cannot be loaded after the rename is
  stored, the reply is still `200` with the renamed record, `trusted: true`,
  `online: false` and `pairedAtUnixMs` set to when the Mac was added. A
  connected Mac receives a fresh `host_identity` with the new `host_label`,
  but only if a new lookup of the Mac, made after the profile has loaded,
  still shows it as this account's linked Mac, the hub has no removal record
  for it, no Sign Out on the Mac is still running, and no Sign Out on the Mac
  started or deleted its rows after these lookups began. A rename that races a
  removal, a Sign Out on the Mac or a link to another account never sends
  `linked: true`; a Sign Out that was already running sends its own
  `linked: false` when it finishes.
  The name a Mac proposes for itself (`host_label` in `create_link_code`, its
  computer name) is made to follow the same rule instead of being refused
  (`proposedHostLabel` in `src/hostLabel.ts`): NFC, line breaks and tabs turned
  into spaces, other forbidden characters removed, trimmed, cut to 40 code
  points without splitting a character, and `This Mac` when nothing is left.
- `POST /account/hosts/remove {deviceId}` first looks the device up and
  answers `404 Mac not found` without calling Convex's `removeHostDevice`
  unless it is the caller's active Mac (`kind` host, not revoked, `user_id`
  equal to the caller). So no other device ever reaches the cleanup below.
  The hub then stores a pending-removal marker
  (`pending-removal:<deviceId>` = `{userId, at}`) and calls
  `removeHostDevice`, which checks ownership again. The answer is
  `200 {ok:true}` once Convex removed the Mac's device row, pairings, approval
  requests and link codes. The signaling hub then stores a removal record
  (`removed-host:<deviceId>` holding the removal time), sends a connected Mac
  `{type:"host_identity", linked:false, reason:"removed_from_account"}`, drops
  its cached authorizations and queued envelopes for the Mac, calls the Mac's
  relay at `POST /internal/host-removed {hostDeviceId}`, and deletes the
  marker. The relay closes every socket with code `4003` and reason
  `mac removed from account` and deletes its cached hello, app list and agent
  snapshots. It refuses with `409` while Convex still lists the Mac as linked;
  then it closes only browsers of other accounts. Failures after the Convex
  step are logged and do not fail the request. A refusal from Convex deletes
  the marker and is answered as such (`404 Mac not found` for a Mac that left
  the account meanwhile). If Convex does not answer the removal (a timeout or
  an outage), the Worker looks the Mac up again: when its row is gone it
  finishes the steps above and answers `200`. Otherwise (the row is still
  there, or this lookup fails too) it answers `503` and keeps the marker. Log
  lines name the step, never the device or the account. The web app waits up
  to 45 s for an answer; without one it loads `/account/hosts` again, and a Mac
  no longer listed counts as removed.

The removal record makes the reason survive reconnects. While it exists,
every `host_identity` the hub sends that Mac on connect is
`{linked:false, reason:"removed_from_account"}`. A Mac that was offline during
the removal learns why it is unlinked. The record is kept 90 days and then
deleted by the hub's cleanup alarm (the same alarm that expires queued
envelopes; the hub also prunes on load). A link-code claim that links the Mac
again deletes it. A record older than the Mac's current account row is
ignored, so a failed delete cannot hide a later link. On connect, the hub loads
the profile and then looks the Mac up again, and never sends `linked: true` for
a Mac with a removal record, one whose new lookup is missing, revoked or owned
by another account, or one whose Sign Out started or deleted its rows after
these lookups began (that Mac is told it is not linked).

The pending-removal marker finishes a removal whose answer was lost. A later
`POST /account/hosts/remove` for the same device by the same account that
finds no row answers `200`, runs the cleanup and deletes the marker, because
the earlier removal happened; any other account still gets `404`. The hub's
alarm (the same alarm as above, scheduled for each marker's next check) checks
every marker at least one minute old, and again every minute: no row means the
removal committed, so the alarm runs the cleanup and deletes the marker; a row
that is still there an hour after the marker was written means it never
happened, so the marker is deleted without cleanup; a failed lookup keeps the
marker for the next check. A Sign Out on the Mac (after its own cleanup) and a
link-code claim that links the Mac again delete the marker. Markers survive
eviction; one that is not `{userId, at}` is deleted on load.

The Mac's own Sign Out (`unlink_host` on signaling) deletes the Mac's link
codes and device row in Convex, answers `host_unlinked`, and then runs the same
signaling cleanup and `/internal/host-removed` call as a removal. The account's
browsers lose relay access at once (4003 `mac removed from account`) and the
relay's cache is deleted. It writes no removal record and sends no removal
reason. A retried Sign Out for a Mac that is already in no account still runs
the cleanup. Before its first account-service call, and again once the rows are
deleted, the hub notes the Sign Out in memory against a counter (a Worker's
`Date.now()` does not move between I/O events). A rename or connect whose
identity lookup began before the latest note sends no `linked: true`; a
link-code claim that links the Mac again clears the note.

Every linked `host_identity` (on connect, after a link-code claim, after a
rename) carries `host_label`, the account's name for the Mac. The Mac app
sends its `CFBundleShortVersionString` as `app_version` in its signaling
`client_auth` (the lab harness has none and omits it); the Worker records it and host
records include `appVersion` when known, plus `addedAtUnixMs` (when the Mac
was added to the account).

Like `/internal/revoke-device` and `/internal/restore-device`,
`/internal/host-removed` is reachable only through the `RELAY_HUB` binding: the
public Worker forwards only `/relay` and `/account/*`.

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
happens only through the Deploy workflow (after Convex and before the web
app, so a new PWA never calls an older Worker), never as part of a local test
command.

Production endpoints:

- App: `https://app.glasstunnel.io`
- Signaling: `wss://signaling.glasstunnel.io/signal`

Production allows `https://app.glasstunnel.io` and applies a generous limit of
120 requests per minute per account or upgrade key, plus 600 account requests
per minute per connecting address. These limits are an abuse guard, not an
authentication boundary or a billing meter.
