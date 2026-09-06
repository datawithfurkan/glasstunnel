# Glasstunnel Security Model

Reviewed against source on 2026-09-06. This describes the current public beta;
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
  teardown. Sign-out clears the active workspace; it is not a secure erase of all
  browser storage or previously received content.
- **Hosted Cloudflare/Supabase control plane:** Supabase holds account and device
  records, linking/pairing data and approval requests. Cloudflare Durable Object
  storage persists host hello/app state and recent-message snapshots for offline
  replay. Each compacted agent snapshot has a size bound, but there is currently
  no documented automatic content-expiry deadline.
- **Relay frames/detail:** the current Worker forwards JPEG frames and expanded
  message-detail replies without explicitly persisting those payloads. Recent
  transcript snapshots can still contain portions of the same text.
- **Go signaling:** offline envelopes are queued temporarily in memory; Web Push
  subscriptions may be stored when enabled. Hosted signaling also uses Durable
  Object storage for queued envelopes.
- **TURN:** handles encrypted WebRTC packets and operational connection metadata.
  Its logging and credential retention depend on the deployment configuration.

Do not interpret bounded snapshot size as a retention policy. Hosted backup,
deletion, and provider-log retention need separate operational verification.

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

Read-only mode blocks several input-dispatch paths, but is session-level behavior,
not an immutable administrator policy or a complete per-device permission system.
Its coverage of every action and resistance to remote setting changes must be
validated before stronger claims are made.

The browser unlock screen uses a platform authenticator when available and can
fall back to a confirmation tap. It is a local UI gate, not mandatory Face ID on
every cold start or server-enforced reauthentication.

## Revocation And Replay Limitations

Local device revocation updates the Mac registry and affects device-trust checks.
Do not assume it immediately closes every existing WebRTC/content-relay connection
or invalidates all hosted authorization. The hosted relay currently authenticates
a client at connection time; end-to-end active-session revocation needs additional
implementation and cross-surface tests. There is no supported sub-second revocation
guarantee.

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
