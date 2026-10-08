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
| Hosted account API | HTTPS and Better Auth session tokens (Convex) | Account/device records and API request content |
| Account email (Resend) | HTTPS to Resend; onward delivery uses whatever TLS the recipient's mail server offers | Recipient address, subject, and full body, including a live single-use password reset link valid for 1 hour. Resend keeps sent messages in its logs and dashboard; restrict Resend account and dashboard access like the Convex dashboard. The recipient's mail provider sees the same message |
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

The PWA supports Google, GitHub, and email/password sign-in through Better Auth
on Convex. Passwords entered in the PWA are submitted to the Convex auth server;
the Worker verifies session tokens through a server-to-server gateway that
requires a shared secret. Every account query and mutation is internal, so a
browser cannot call them directly. Google and GitHub sign-in return a one-time
token that the PWA exchanges only when it matches a nonce stored when that
sign-in started, which blocks login CSRF. Sessions last 60 days. Do not describe
the product as OTP-only or claim its client never handles a password.

Forgotten passwords are reset by email, and only when the Convex deployment has
an email provider configured (Resend: `RESEND_API_KEY` and `AUTH_EMAIL_FROM`).
Without one, every reset request is refused the same way and the app points
people to Google or GitHub sign-in. A reset request gets the same answer
whether or not the address has an account, and in about the same time: the
auth server holds every successful reply until 250 ms after the request reached
it, which hides the extra work for a real account while that work stays under
250 ms (on the local backend it answered in under 90 ms at p95). This removes
one way to learn whether an address has an account, not every way: sign-up
answers `USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL` for an address that has an
account, and the app says so. Treat account existence as discoverable. The hold
also has a cost: each held reply occupies a slot in the Convex deployment's
shared action and HTTP-action concurrency pool, so a flood of reset requests,
which need no sign-in, can delay account requests and session checks for
everyone. A 250 ms hold makes that flood more expensive than a longer hold
would; it does not prevent it.

Reset emails are throttled per account (one per 2 minutes, three per 24 hours)
and across the deployment (15 per hour and 40 per 24 hours). "Password
changed" notices are limited to three per account per 24 hours, without the
2-minute wait, and have their own deployment cap (20 per 24 hours); a reset
past that cap still completes but sends no notice. A completed reset
invalidates every other reset link the account was sent.
The deployment-wide caps are shared, so anyone who knows real account
addresses can use them up without creating an account and block reset emails
for everyone until they free up. Email verification at sign-up would not
prevent that. The planned fix is a per-client limit keyed on a client IP the
service can trust, for example by routing reset requests through the
Cloudflare Worker, which sees `CF-Connecting-IP` and has Rate Limiting
bindings; it is not built yet.

The link opens the app with a single-use token that expires after 1 hour. The
app removes the token from the address bar as soon as it reads it and keeps it
only in memory and that tab's session storage. The token is in the link's query
string, so the first page request still carries it to the app host. Setting a
new password ends every session of the account and emails a "password changed"
notice unless that cap is reached. Glasstunnel's own email records keep no
address or link, but the link is not held by Glasstunnel alone. Inside Convex,
Better Auth's verification record and the scheduled delivery job's arguments
hold the token, so Convex dashboard access can read a live link. Resend
receives and logs the address and the whole message, including the live link,
and the recipient's mail provider receives it too (see the table above). See
`convex/README.md` for throttles and retention.

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
Sign-in, sign-up and password reset requests go from the PWA straight to the
Convex auth server (`/api/auth/*`), not through the Worker, so these limits do
not cover them; the reset email throttles above are enforced in Convex.

## Content And Credential Storage

- **Mac:** the host identity is stored in the system Keychain; the local device
  registry is in Application Support. Deleting the app bundle does not erase that
  per-user state. Use Sign Out to unlink the Mac; do not treat Trash as credential
  revocation. Received attachments and coding-agent history can remain on the Mac.
- **Browser:** device keys and the selected Mac are stored in IndexedDB. The
  account session token and a snapshot of the signed-in account are stored in
  localStorage and removed on sign-out. Offline workspace snapshots,
  including recent chat content, are also cached in IndexedDB. Expanded tool detail
  is held in memory, scoped by agent/message and cleared with connection/session
  teardown. The September 7 hosted PWA scopes each offline copy by account
  and Mac, checks a per-item deadline of at most 24 hours, and clears the relevant
  copies on sign-out, account switch, revocation and forgetting a Mac. Profile's
  **Clear offline copies** erases this browser's copies, not server copies;
  a connected Mac can publish fresh content afterward. Browser suspension/closure
  delays physical deletion until execution resumes; expired copies are rejected
  before restoration. Storage failures are not secure-erasure guarantees.
- **Hosted Cloudflare/Convex control plane:** Convex holds account and device
  records, reachable only through the Worker's shared-secret gateway. Cloudflare
  Durable Object
  storage persists host hello/app state and recent-message snapshots for offline
  replay. The September 7 hosted Worker gives each accepted host publication a
  24-hour maximum replica lifetime. Viewer reads, replays and heartbeats do not
  renew that deadline. Expired or unverifiable legacy copies cannot be replayed.
  Persistent alarms remove active storage keys in bounded batches even when no
  client is connected, with content-free failure counters and backoff. The
  healthy-service cleanup target is 15 minutes after expiry, not an outage-proof
  guarantee. See `ops/cache-retention/README.md` for activation and sweep evidence.
  Removing a Mac from the account, or Sign Out on the Mac, deletes that Mac's
  relay copies right away (see Renaming And Removing A Mac). For each Mac
  removed from its account, the signaling hub keeps the Mac's device id and the
  removal time for 90 days, so the Mac can be told why it is unlinked when it
  next connects. Linking the Mac again deletes that record, and the hub's cleanup
  alarm deletes it after 90 days. While a removal runs, the hub also keeps a
  pending-removal marker (the Mac's device id, the account id and the time). It
  is deleted when the removal finishes, after an hour when the removal never
  happened, or when the Mac signs out or is linked again; while the account
  service cannot be reached, it stays until a check succeeds.
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
- **Account email (Resend):** Resend stores each sent password reset email and
  "password changed" notice (address, subject, body, and for a reset the link)
  in its logs under Resend's own retention. A reset link stops working once it
  is used or after 1 hour, but anyone who reads it from those logs within that
  hour can reset the password. Convex keeps a send record per email for 7 days
  without the address or link; the token itself sits in Better Auth's
  verification record and the delivery job's arguments.

A fresh Mac publication can contain older source messages: this is a replica
lifetime, not deletion 24 hours after a message was written. Original chats,
project files, received Mac attachments, identities and revocation tombstones are
not part of cache cleanup. Old PWA versions must reload to adopt browser expiry.
Cloudflare SQLite Durable Object point-in-time recovery can retain earlier storage
for 30 days. Active-key deletion does not promise immediate provider-backup erasure;
provider logs and Convex backups need separate operational verification.

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
its own removal before it lifts its tombstone. A link code works once. The Worker
claims it in one Convex transaction before it links the Mac or pairs the browser,
so when two claims of the same code race, from one account or two, only one
succeeds; a claim that fails after that point still uses up the code. Nothing else restores a removed
phone; it must otherwise use a new browser identity, which appears as a new
device to approve. Revocation cannot cancel
a command already executing in a coding app, retract received content, or invalidate
every account session. Same-account onboarding can authorize a new browser
identity, so a compromised account requires account-level recovery as well.

Signed signaling envelopes carry IDs and timestamps, but signature verification
alone does not provide a complete application replay policy. The hosted JSON
command path also needs its own replay/authorization analysis. Neither the local
unlock UI nor an encrypted transport should be advertised as solving these gaps.

For an urgent loss of trust, stop the Mac host or disable its network access, then
review account sessions and device authorization. Revocation cannot retract content
already received by a browser or operator.

## Renaming And Removing A Mac

Reviewed against source on 2026-10-08. Each Mac in **Your Macs** has a menu with
Rename, Details and Remove from account. The account is the trust unit for
these actions: any signed-in session of the account can rename or remove any of
its Macs, including a browser that one of those Macs revoked. This is an
accepted product decision: a Mac's revocation ends that browser's access to the
Mac, it does not sign the browser out of the account. Nothing here can reach
another account's Mac. The Worker sends the account and the device id to one
Convex mutation, which checks that the device is this account's active Mac
inside the same transaction as the change. A removal also looks the device up
first and goes no further unless it is this account's active Mac. A missing
device, another account's Mac, a revoked row and a phone or browser all get the
same `404 Mac not found`, so the reply reveals nothing about devices outside
the account.

**Rename** changes the name every phone and browser of the account lists the Mac
as, and the Mac shows it as its account name. The name rule is the same in the
PWA, the Worker and Convex: the name is normalized to Unicode NFC and trimmed,
then it must be 1 to 40 code points with no control characters, no line or
paragraph separators (U+2028, U+2029), no bidi controls (U+202A to U+202E,
U+2066 to U+2069, U+200E, U+200F) and none of the invisible U+200B, U+2060 and
U+FEFF. So two names cannot look the same while differing only in hidden
characters, and a name cannot reorder the text around it. The zero width joiner
and non-joiner (U+200D, U+200C) are allowed for emoji sequences and for scripts
such as Persian. Convex stores the normalized name. A connected Mac receives the
new name at once. Before sending it, the Worker loads the account profile and
then looks the Mac up again, and it sends nothing when a Sign Out on the Mac
started or finished after those lookups began. So a rename that overlaps a
removal, a Sign Out on the Mac or a link to another account never tells the Mac
it is linked. Once the name is
stored the rename succeeds, even if the details the reply adds (pairing date,
online state) cannot be loaded. A renamed Mac keeps its name when the same
account links it again. When it is linked to another account it starts with the
name the Mac proposes (its computer name). The Worker makes that name follow the
same rule when the Mac asks for a link code: it normalizes it to NFC, turns line
breaks and tabs into spaces, removes the other forbidden characters, cuts it to
40 code points without splitting a character, and uses "This Mac" when nothing
is left. A name stored before this rule existed is shown as it is; the web app
ignores hidden characters when it looks for duplicate names and leaves them out
of the Rename field. Names are account metadata: Convex stores them, and
every device of the account and the hosted service can read them.

**Remove from account** first looks the Mac up. Unless it is the caller's
active Mac (a host device, not revoked, in the caller's account), the Worker
answers `404 Mac not found` and does nothing else, so no request can run the
cleanup below for another account's Mac, a phone or browser, or a device in no
account.
Then the signaling hub stores a pending-removal marker,
`pending-removal:<device id>` with the account id and the time, and the removal
takes effect in this order:

1. Convex deletes the Mac's device row, every pairing and approval request that
   points at it, and its link codes, in one transaction that checks again that
   the Mac is the caller's active Mac.
2. The signaling hub records the removal: the Mac's device id and the time,
   under `removed-host:<device id>`, kept for 90 days. It tells a connected Mac
   that it was removed (`host_identity` with `linked: false` and
   `reason: removed_from_account`), and it drops its cached envelope
   authorizations and queued signaling for the Mac, so WebRTC signaling between
   the Mac and the account's browsers stops at once instead of within the
   two-minute authorization cache. The Mac signs out of the account, shows that
   it was removed, and ends its live phone sessions.
3. The Mac's relay closes every socket, browsers first and then the Mac, with
   close code 4003 and reason `mac removed from account`, and deletes its
   cached hello, app list and agent snapshots. A browser that reconnects, and
   the Mac's own relay connection, are refused while the Mac is in no account.
   The relay checks with Convex first and refuses to clear a Mac that is still
   linked. If the Mac was already linked to another account by then, browsers
   of the old account are still closed.

Then the hub deletes the pending-removal marker.

A Mac that is offline or reconnecting during the removal gets the same
`host_identity` with `reason: removed_from_account` when it next connects to
signaling, as long as the hub's record exists. It then behaves as if it had
been told at once: it ends its phone sessions, signs out of the account and
shows the removal notice, also after a relaunch. Once the owner dismisses the
notice, it stays hidden when the hub reports the same removal again on a later
connection, until the Mac is linked again. The record lasts 90 days, until the hub's cleanup alarm
deletes it, or until a link code claim links the Mac again. A link removes the
record right away, and a record older than the Mac's current account row is
ignored. A Mac reconnecting while a removal is in progress is never told it is
linked: the Worker loads the account profile and then looks the Mac up again,
and the removal record wins.

The request succeeds once step 1 succeeded. If Convex refuses step 1 (for
example because the Mac left the account in the meantime), nothing was removed:
the marker is deleted and the answer is the refusal, such as `404 Mac not
found`. If Convex does not answer step 1 (a timeout or an outage), the Worker
looks the Mac up again. If the Mac's row is gone, the removal was committed and
only the answer was lost: the Worker runs steps 2 and 3, deletes the marker and
answers 200. Otherwise, when the row is still there or the second lookup fails
as well, it answers 503, changes nothing else and keeps the marker. A kept
marker is finished in one of two ways:

- A later removal of the same Mac by the same account that finds no row
  answers 200 and runs steps 2 and 3, because the earlier removal happened. A
  removal by any other account gets `404 Mac not found` and runs no cleanup.
- The hub's alarm checks each marker once it is a minute old (a younger one may
  still belong to a running request), and again every minute. If Convex no
  longer lists the Mac, the alarm runs steps 2 and 3 and deletes the marker. If
  Convex still lists the Mac an hour after the marker was written, the removal
  never happened: the marker is deleted and nothing else changes. If Convex
  cannot be reached, the marker stays for the next check.

A Sign Out on the Mac and a link code claim that links the Mac again also
delete the marker: the Mac's state is then explained by them, and Sign Out runs
the cleanup itself. A removal that is repeated after it finished answers 404
and runs no cleanup. Failures in steps 2 and 3 are logged without device or
account details, and the request still succeeds. Then the Mac learns it was
removed at its next signaling connection if the record was saved, and otherwise
only that it is in no account. Browsers lose relay access at their next renewal (within
five minutes, close code 4001), and the relay's cached content stays until its
24-hour deadline. No one can read it in that time unless the Mac is linked
again, in which case the new account's browsers can be sent it.

**Sign Out on the Mac** deletes the same account rows in Convex. Then the Worker
runs the same signaling cleanup and relay step as a removal: the hub drops its
cached authorizations and queued signaling for the Mac, and the relay closes
every socket with 4003 `mac removed from account` and deletes its cached
content. So the account's browsers lose access at once, not at their next
renewal. Sign Out does not write a removal record and sends no removal reason,
because the person at the Mac chose it. A Sign Out that is retried after a lost
answer, when the Mac is already in no account, still runs this cleanup.
Browsers get the same relay close as for a removal, so a browser that had the
Mac open also says "This Mac was removed from your account." after a Sign Out
on the Mac. While a Sign Out runs, the hub remembers in memory when it started,
and again when the Mac's account rows are deleted. A rename, or a connection of
the Mac to signaling, whose host identity lookup began before the later of
those moments, or that finishes while the Sign Out is still running, does not
tell the Mac it is linked: the rename sends nothing and the connection is told
the Mac is not linked. The Sign Out sends its own "not linked" when it ends. A link code claim that links the
Mac again clears this.

The web app waits up to 45 seconds for a rename or removal to answer (the
Worker gives each account-service call up to 15 seconds, and a removal makes
several in a row). When a removal gets no answer in that time, or the
connection drops, it loads the list of Macs again, waiting up to 15 seconds for
that list (no answer counts as not confirmed). If the Mac is no longer
listed, the removal happened: the web app finishes it as usual and shows
"Removed <name> from your account." Otherwise it shows the connection error,
and trying again is safe.

To use a removed Mac again, link it from the Mac with a new link code. Removal
does not lift browser denials. The relay's and signaling hub's denials and the
Mac's own tombstones stay. Because removal deletes the revoked pairing rows, a
link code claimed later no longer finds a denial to lift, so a browser that the
Mac revoked stays refused after the Mac is linked again. It needs a new browser
identity, which appears as a new device. Mac binaries without the removal
notice keep an established WebRTC session open until it ends. Relay and
signaling access end regardless of the Mac version.

**Details** shows the Mac's status, last seen time, when it was added to the
account, the Mac app version when the Mac reported one at signaling sign-in,
and the first 12 characters of the device id (a value derived from the Mac's
public key, not a secret) with a copy button for the whole id.

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
- Renaming and removing a Mac: `convex/accountPlane.ts` (`renameHostDevice`,
  `removeHostDevice`), the name rule in `convex/hostLabel.ts` and
  `apps/cloudflare-signal/src/hostLabel.ts`, and the Worker's
  `/account/hosts/rename`, `/account/hosts/remove` and `unlink_host` handling in
  `apps/cloudflare-signal/src/index.ts`.
- Focused reconciliation status: [security-reconciliation.md](security-reconciliation.md).

Self-hosting changes who operates the service; it does not add encryption or fix
protocol limitations by itself. See [self-hosting.md](self-hosting.md).
Report vulnerabilities privately using [SECURITY.md](../SECURITY.md).
