# Glasstunnel Security Model

Reviewed against source on 2026-09-07. This describes the current public beta;
it is not an independent security certification.

## Trust Boundary

The hosted service is a trusted content processor. **Hosted relay content is not
end-to-end encrypted.** Cloudflare Workers/Durable Objects can read prompts, chat
and tool output, agent state, remote commands, attachment data, and JPEG screen
fallback frames carried through that relay.

WebRTC media is end-to-end encrypted between the Mac and browser. A TURN relay
forwards encrypted WebRTC packets. This protection applies to WebRTC traffic,
not to content sent separately through the hosted WebSocket relay.

| Path | Protection | What infrastructure can access |
| --- | --- | --- |
| WebRTC media | DTLS-SRTP between peers | Signaling/transport metadata; TURN forwards ciphertext |
| WebRTC DataChannel | SCTP over DTLS between peers | Transport metadata, not channel plaintext |
| Hosted content relay | HTTPS/WSS transport encryption to Cloudflare | The JSON content it receives, forwards, and caches |
| Hosted account API | HTTPS and Supabase account authentication | Account/device records and API request content |
| Local test lab | Loopback HTTP/WS | Disposable local test data; not suitable as an internet-facing deployment |

A trusted infrastructure operator or compromised hosted control plane can access
relay content and influence relay commands and device authorization. The current
hosted architecture does not protect against that operator. Device-key signatures
do not add application-layer encryption to the relay.

In scope for hardening are unauthorized cross-account access, device-key theft,
input authorization, browser session isolation, replay/abuse handling, and content
exposure beyond these declared boundaries. An unlocked compromised Mac, malicious
code in an authenticated browser profile, or a compromised coding agent can defeat
protections at those endpoints.

## Account And Device Authentication

The PWA supports Supabase-backed OAuth and email/password flows. Passwords entered
in the PWA are submitted to Supabase Auth; the Worker verifies account access
tokens. Do not describe the product as OTP-only or claim its client never handles
a password.

The Mac and browser generate Ed25519 device keys. WebSocket clients prove possession
by signing a short-lived server nonce. Browser relay authentication additionally
checks the account token and device/host records for matching ownership and
revocation state at connection time. The host authenticates using its device key;
it does not send a browser account token.

The signed signaling-envelope path verifies signatures against trusted device keys.
Hosted relay commands are a separate JSON protocol trusted through the authenticated
server connection; they are not individually verified as signed phone envelopes by
the Mac. Account discovery and server-origin authorization therefore remain part
of the trust boundary.

A custom signaling URL must belong to an operator the user trusts. A server
`auth_ok` response is not cryptographic proof of the server's device identity.
HTTPS/WSS certificate validation authenticates the configured service endpoint.

## Hosted Request Boundary

The Worker rejects browser requests whose Origin does not exactly match a configured
application origin. Approved CORS responses echo that origin and include
`Vary: Origin`. Native clients may omit Origin. Origin checking is an additional
browser restriction, not authentication.

Cloudflare Rate Limiting bindings apply account API and WebSocket-upgrade limits.
Account limits use an endpoint/token-digest bucket and a higher-capacity connecting-
address bucket; tokens are not stored in rate-limit keys. Rejections return HTTP
429 with Retry-After. These are request/upgrade controls, not a claim of complete
per-message abuse protection or a guarantee about every deployment's quotas.

## Content And Credential Storage

- **Mac:** the host identity is stored in the system Keychain; the local device
  registry is in Application Support. Deleting the app bundle does not erase that
  per-user state. Use Sign Out to unlink the Mac; do not treat Trash as credential
  revocation. Received attachments and coding-agent history can remain on the Mac.
- **Browser:** device keys and the selected Mac are stored in IndexedDB. Supabase
  persists its session through its browser client. Offline workspace snapshots,
  including recent chat content, are also cached in IndexedDB. Expanded tool detail
  is held in memory, scoped by agent/message and cleared with connection/session
  teardown. The September 7 hosted PWA scopes each offline copy by account
  and Mac, checks a per-item deadline of at most 24 hours, and clears the relevant
  copies on sign-out, account switch, revocation and forgetting a Mac. Profile's
  **Clear offline copies** erases this browser's copies, not server copies;
  a connected Mac can publish fresh content afterward. Browser suspension/closure
  delays physical deletion until execution resumes; expired copies are rejected
  before restoration. Storage failures are not secure-erasure guarantees.
- **Hosted Cloudflare/Supabase control plane:** Supabase holds account and device
  records, linking/pairing data and approval requests. Cloudflare Durable Object
  storage persists host hello/app state and recent-message snapshots for offline
  replay. The September 7 hosted Worker gives each accepted host publication a
  24-hour maximum replica lifetime. Viewer reads, replays and heartbeats do not
  renew that deadline. Expired or unverifiable legacy copies cannot be replayed.
  Persistent alarms remove active storage keys in bounded batches even when no
  client is connected, with content-free failure counters and backoff. The
  healthy-service cleanup target is 15 minutes after expiry, not an outage-proof
  guarantee. See `ops/cache-retention/README.md` for activation and sweep evidence.
- **Relay frames/detail:** the current Worker forwards JPEG frames and expanded
  message-detail replies without explicitly persisting those payloads. Recent
  transcript snapshots can still contain portions of the same text.
- **Go signaling:** offline envelopes are queued temporarily in memory; Web Push
  subscriptions may be stored when enabled. Hosted signaling also uses Durable
  Object storage for queued envelopes. Its 60-second logical deadline is checked
  before forwarding and maintained by a persistent cleanup alarm in the September 7
  hosted Worker. The legacy Go implementation is unchanged by this policy.
- **TURN:** handles encrypted WebRTC packets and operational connection metadata.
  Its logging and credential retention depend on the deployment configuration.

A fresh Mac publication can contain older source messages: this is a replica
lifetime, not deletion 24 hours after a message was written. Original chats,
project files, received Mac attachments, identities and revocation tombstones are
not part of cache cleanup. Old PWA versions must reload to adopt browser expiry.
Cloudflare SQLite Durable Object point-in-time recovery can retain earlier storage
for 30 days. Active-key deletion does not promise immediate provider-backup erasure;
provider logs and Supabase backups need separate operational verification.

The approved hosted inventory/apply/verify sweep passed on 2026-09-07: 183
objects inspected, 503 expired/unverifiable cache records removed and six fresh
records preserved. All objects reported active retention with zero invalid records
or cleanup failures at verification. Exact source/deployment evidence is in the
[security hardening plan](architecture/security-hardening-plan.md).

## Redaction And Remote Controls

`SecretRedactor` applies best-effort pattern matching to supported outbound
transcript text, tool titles and expanded message detail. Defaults include common
API-token patterns, bearer headers, JWTs, private-key blocks and secret-like
assignments. Matching text is replaced with labeled redaction placeholders.

Redaction is not a guarantee that secrets never leave the Mac. It does not sanitize
screen pixels, arbitrary uploaded attachments, all metadata, or every possible
secret format. In particular, phone-origin input traversing the relay reaches the
server before any Mac-side processing. Do not send or display production
credentials through the tunnel.

The September 2026 source makes the Mac Settings read-only switch authoritative
and persistent. Relay and WebRTC dispatch reject prompts, attachments, pointer
input, input answers, interrupts, target/model changes and app lifecycle actions
when the Mac restricts control, including work queued before the restriction.
Existing streams and message-detail reads remain available. A browser can restrict
its own control, but cannot relax the Mac setting or change another browser's
restriction. Denials are visible only to the requesting browser.

**Mac binaries before 0.1.10 do not contain this permission boundary.**
Updated browsers expose the per-browser switch only when a matching host advertises
the policy; they do not send permission updates to legacy hosts. This is not a
complete per-device administrator policy, account reauthentication, or cancellation
of operations already executing in a coding app. Idle-lock behavior is unchanged.

The browser unlock screen uses a platform authenticator when available and can
fall back to a confirmation tap. It is a local UI gate, not mandatory Face ID on
every cold start or server-enforced reauthentication.

## Revocation And Replay Limitations

The September 2026 source adds acknowledged device revocation across the Mac,
hosted relay and signaling paths. **Mac binaries before 0.1.10 do not contain
this operation.** Source integration and a hosted deployment do not update an
installed Mac; binary publication is a separate release step.

With the matching Mac/Worker/PWA versions, Revoke Access stops that device's local
WebRTC session and further host command dispatch. The Mac shows confirmation
pending until the server persists its denial and revokes the account pairing.
Failure leaves local access blocked and offers a retry; do not assume hosted
delivery is cut off until confirmation. Removing a device hides its row but keeps
the denial. Restarts, cached authorization and re-registering the same identity
must not restore it. A revoked browser clears its active workspace and stops
automatic reconnects; another authorized browser can continue.

Relay clients renew their authorization on the open socket at token expiry or
after five minutes, whichever is earlier: the relay asks about a minute before
the deadline, the browser answers with a current account token, and the relay
repeats the account, device and pairing checks before extending the deadline. A
browser that does not renew in time is closed at the deadline (close code 4001)
and reconnects. This bounds stale account decisions, not the network latency of
an explicit revocation. There is no supported sub-second guarantee.

Removal is reversible only through the Mac's owner: a new link code generated on
that Mac and entered on the phone lifts the account denial, clears the relay and
signaling denials, and reports a re-authorization time that the Mac compares with
its own removal before it lifts its tombstone. Nothing else restores a removed
phone; it must otherwise use a new browser identity, which appears as a new
device to approve. Revocation cannot cancel
a command already executing in a coding app, retract received content, or invalidate
every Supabase account session. Same-account onboarding can authorize a new browser
identity, so a compromised account requires account-level recovery as well.

Signed signaling envelopes carry IDs and timestamps, but signature verification
alone does not provide a complete application replay policy. The hosted JSON
command path also needs its own replay/authorization analysis. Neither the local
unlock UI nor an encrypted transport should be advertised as solving these gaps.

For an urgent loss of trust, stop the Mac host or disable its network access, then
review account sessions and device authorization. Revocation cannot retract content
already received by a browser or operator.

## Logging And Telemetry

The Mac uses Apple's unified logging for operational events. The PWA can write
browser-console warnings and the Worker logs relay persistence failures. Do not
assume every operational identifier, error description or provider log is redacted.
Avoid collecting raw diagnostic logs without reviewing them for private data.

The repository does not include an analytics SDK, a crash-reporting SDK, a crash-
reporting Settings toggle, or a Glasstunnel telemetry-ingestion endpoint. Operating
systems, browsers, and hosting providers may still produce their own diagnostic or
request logs. Provider retention and access controls require operational review.

## Source Map And Follow-Up

- Relay authentication, content handling and storage:
  `apps/cloudflare-signal/src/index.ts`, `relaySnapshotCache.ts`.
- Mac relay command routing and local controls:
  `apps/host-macos/Sources/Transport/SessionManager.swift`.
- Transcript redaction:
  `apps/host-macos/Sources/Transport/RemoteAppController.swift`.
- Browser sessions, offline snapshots and expanded detail:
  `apps/mobile-pwa/src/lib/store.ts`, `UnlockScreen.tsx`.
- Focused reconciliation status: [security-reconciliation.md](security-reconciliation.md).

Self-hosting changes who operates the service; it does not add encryption or fix
protocol limitations by itself. See [self-hosting.md](self-hosting.md).
Report vulnerabilities privately using [SECURITY.md](../SECURITY.md).
