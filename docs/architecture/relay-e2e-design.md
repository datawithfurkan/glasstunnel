# Relay E2E Design And Decision

Date: 2026-09-07. Source reviewed: `0f98a93d`.
Status: proposal for maintainer review, not an implemented or audited protocol.
Stages 1-4 of the security plan have passed their hosted gates. The public 0.1.9
Mac binary still lacks the newer host permission/revocation operations.

## Recommendation

Keep the current trusted-relay disclosure until a separately reviewed E2E path
ships. First coordinate delivery of the already-tested Mac security changes.
Then authorize a bounded, local-only interoperability spike for **MLS with a
shared Rust implementation**, initially one two-member group per Mac/controller
pair. OpenMLS is the leading candidate, not a dependency selected for production.
Do not build a custom ratchet or combine primitives into a new protocol.

This recommendation is an engineering judgment: pair isolation fits targeted
command responses, avoids sharing one controller's private replies with another,
and allows one controller's loss of trust to be handled independently. It costs
extra host encryption and storage per controller. Benchmark that tradeoff rather
than assuming group broadcasting is necessary for a personal remote-control app.

**One product decision is essential:** the first E2E target can protect against a
compromised relay/account service only while the Mac and browser code delivery
remain trusted. A malicious operator that also replaces the PWA JavaScript can
read plaintext at that endpoint. Protecting against that stronger adversary needs
independently trusted controller distribution, such as a signed native client or
independently operated client origin. A PWA badge, CSP, SRI or non-exportable key
alone cannot supply that distribution boundary. This follows from the browser's
same-origin/script trust model, not a weakness fixed by selecting a different
cipher. [WebCrypto security considerations](https://www.w3.org/TR/webcrypto/#security-considerations)

## Current Boundaries

- `packages/shared-crypto/src/index.ts` and Mac `DeviceKey.swift` provide Ed25519
  signatures, not relay payload encryption. The short `gt-` device identifier is
  derived from eight key bytes; it must not become a security verification code.
- `SessionManager.authorizeAccountDevice` accepts server-authorized device keys.
  That is incompatible with a promise that a malicious account/relay operator
  cannot enroll a new controller. E2E enrollment must change this trust decision.
- Relay JSON is dispatched separately from signed signaling envelopes. Encrypting
  one transcript field leaves commands, attachments, titles and JPEG fallback
  exposed. The protection boundary must precede every relay content dispatch.
- Stage 4 limits relay/browser replica age. It does not encrypt those replicas,
  erase provider backups or delete original coding-app history.

## Threat Model

| Adversary or event | Proposed guarantee and limit |
| --- | --- |
| Relay or Supabase operator reads stored/forwarded data | Only encrypted application payloads; account/routing metadata remains visible. |
| Relay substitutes keys, injects messages or invents same-account devices | No enrollment or command authority without independently verified endpoint credentials and host approval. |
| Relay reorders, duplicates, delays or replays traffic | Authenticated state processing plus application freshness/deduplication; no repeated command execution. |
| Relay suppresses traffic or partitions clients | Detect stale/unavailable state; no availability guarantee and no plaintext fallback. |
| One controller is compromised | It can access its authorized content. Stop its pair and revoke it without distributing another controller's secrets. Previously received content cannot be recovered. |
| Mac, coding agent, browser runtime or delivered PWA is compromised | Outside the initial endpoint-trusted guarantee. Remote command capability makes endpoint integrity essential. |
| Old backup or browser storage is restored | Reject stale membership/command state or require verified re-enrollment; never reuse an unsafe sending state. |

Forward secrecy and post-compromise recovery depend on correct key updates,
deletion and endpoint recovery, not merely enabling an E2E flag. MLS supplies a
standard protocol for asynchronous group key establishment; the application must
still define identity, authorization and delivery behavior.
[RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html),
[MLS architecture](https://www.rfc-editor.org/rfc/rfc9750.html)

## Candidate Comparison

Primary repositories and releases were checked on 2026-09-07. Release activity is
maintenance evidence, not an independent security audit or a guarantee of support.

| Candidate | Verified facts | Glasstunnel assessment |
| --- | --- | --- |
| Keep trusted relay | Already implemented, with disclosed plaintext processing and bounded retention. | Valid interim product, but does not meet an operator-blind content goal. |
| OpenMLS | MIT; Rust MLS implementation; release 0.9.0 published August 25. Apple ARM is tested upstream; WASM, Apple Intel and iOS are listed as built but not tested. | Preferred feasibility candidate. Swift FFI, browser storage and actual Chromium/WebKit interoperability are work, not ready-made guarantees. |
| Wire CoreCrypto | GPL-3.0; Rust core with Swift and WASM/TypeScript build paths; release 10.5.0 published September 4. | Strong integration reference/candidate. Review distribution obligations against this Apache-2.0 repository before adoption; do not silently change the project's license. |
| libsignal | AGPLv3; Swift and TypeScript wrappers; release 0.102.0 published September 3. Upstream explicitly does not support outside use; TypeScript uses a Node bridge. | Not the default PWA choice. A TypeScript API does not prove a browser implementation. |
| Noise | Standardized framework for interactive authenticated channels, not a complete multi-device/offline product. | Alternative if scope becomes live-only. Library/binding selection and durable offline behavior would need another evaluated design. |

Sources: [OpenMLS support matrix](https://github.com/openmls/openmls),
[0.9.0 release](https://github.com/openmls/openmls/releases/tag/openmls-v0.9.0),
[OpenMLS WASM requirements](https://book.openmls.tech/user_manual/wasm.html),
[Wire CoreCrypto](https://github.com/wireapp/core-crypto),
[10.5.0 release](https://github.com/wireapp/core-crypto/releases/tag/v10.5.0),
[libsignal scope/license](https://github.com/signalapp/libsignal),
[0.102.0 release](https://github.com/signalapp/libsignal/releases/tag/v0.102.0),
[Noise framework](https://noiseprotocol.org/noise.html).

The proposed OpenMLS spike must pin a release, inspect its advisory/audit scope
and transitive licenses, and disable content/key debugging and draft extensions.
Upstream security policy covers the library, not our FFI, storage provider or
application protocol. [OpenMLS security policy](https://github.com/openmls/openmls/blob/main/SECURITY.md)

## Proposed Endpoint And Message Contract

These are product requirements for the spike and external review, not a new wire
specification to implement without approval.

1. **Enrollment:** account login discovers a Mac but cannot confer cryptographic
   control. Require Mac-side approval and comparison/scanning of full endpoint-key
   bindings over an independent channel. Bind fresh MLS credentials to the verified
   identities. Do not auto-trust existing account pairings or convert/reuse signing
   private keys as encryption keys. Exact enrollment proof and encoding require
   review; do not invent a short authentication-string algorithm.
2. **Pair isolation:** create a two-member group for each approved Mac/controller
   relationship. Pin full credentials, role and group context locally. Reject
   added members, external joins or credential replacement not allowed by host
   policy. Initially the Mac serializes membership changes; a controller cannot
   authorize another controller. Additional Macs require separate approval.
3. **Inner payload:** include version, action/content type, sender, recipient,
   request ID, session context, creation/expiry and payload in authenticated
   application data. The exact encoded bytes and limits become shared fixtures.
   Verify sender membership and host policy before dispatch, not a claimed JSON
   sender ID. Deduplicate commands durably before execution; uncertain completion
   is shown to the user instead of automatically replaying an unsafe command.
4. **Outer relay:** only opaque routing/group handles, protocol version, size and
   storage deadline are needed. Encrypt prompts, transcripts, app/project names,
   paths, model selections, targeted errors, attachments and JPEG fallback chunks.
   Treat all outer values as untrusted hints; authenticate corresponding inner
   scope/deadlines. Keep transport authentication, quotas and size limits.
5. **WebRTC:** carry SDP/fingerprint bindings through the verified encrypted
   relationship before accepting media/DataChannel peers. DTLS-SRTP still protects
   media; it does not independently verify a user-approved identity. DataChannel
   dispatch must use the same authorization/replay contract as relay dispatch.
   [WebRTC security architecture](https://www.rfc-editor.org/rfc/rfc8827.html)
6. **Rotation and revocation:** use library-supported state transitions; the spike
   must validate explicit update/deletion policies. Proposed evaluation defaults:
   update the epoch for each new authenticated session and at least once per
   24 hours while connected; retain no past receive epoch beyond the offline
   lifetime; never reuse a consumed KeyPackage. Identity-key replacement requires
   verified re-enrollment rather than an account-server instruction. The review
   may tighten these defaults before implementation. Local revocation closes the pair,
   blocks dispatch and stops new ciphertext to that controller immediately. Keep
   denial tombstones outside expiring content. Recovery from endpoint compromise
   requires a clean endpoint and fresh verified credentials, not password reset
   alone. A stolen account must not enroll a replacement identity automatically.

## Offline State And Recovery

- Keep the approved 24-hour replica ceiling. The server sees ciphertext with a
  server-assigned TTL; endpoints also enforce authenticated content deadlines.
  A malicious server cannot be forced to delete ciphertext or metadata.
- Store encrypted local replica records with a per-install storage key and scoped
  account/Mac state. Mac keys belong in Keychain. Browser key wrapping/storage
  must be validated in the spike; WebCrypto does not guarantee hardware-backed
  persistence or secure erasure. Keys accessible to the same origin do not protect
  against malicious code running there.
- Persist cryptographic state transitions atomically with send/receive bookkeeping.
  Coordinate tabs with one state owner and durable revisions. A restored old
  database must not reuse sending keys/nonces. If continuity cannot be established,
  re-enroll instead of guessing. Do not copy current stage 4 cache JSON as ratchet
  state or assume an IndexedDB transaction spans the Swift boundary.
- MLS ciphertexts may need earlier group state, while the current relay stores
  replaceable latest snapshots. The spike must prove a bounded per-pair message
  journal with required state transitions, or explicitly require a live Mac to
  send a new snapshot after a gap. Do not drop intermediate messages and assume
  any old client can decrypt the newest one. Set count/byte/age bounds and stop
  sending on unsafe receiver-state exhaustion.
- Default recovery is **re-enroll from the trusted Mac**, with no cloud key escrow.
  Losing browser keys loses its offline history; the Mac can publish fresh source
  state. Account password recovery does not decrypt old replicas. A backup/recovery
  key feature would be another product/security decision.
- Logout removes that browser's scoped content and cryptographic state; control
  enrollment must be explicitly revoked if the intended action is device removal.
  Cache clearing must not erase active protocol state and cause nonce reuse.

## Compatibility, UI And Rollback

| Situation | Required behavior |
| --- | --- |
| Old Mac with new PWA | Honest legacy/trusted-relay label; no E2E badge. |
| New Mac with legacy controller | Only a separately permitted legacy relationship; never send protected-pair content on its plaintext route. |
| Verified E2E pair with capability stripped or invalid ciphertext | Fail closed with update/reconnect or verification action; never retry plaintext. |
| New key, lost storage or group-state mismatch | Verification/re-enrollment required, with no silent trust reset. |
| Mac offline and valid ciphertext available | Read-only cached state with explicit deadline; no queued remote control by default. |
| Ciphertext expired or required epoch missing | Explain that the Mac must reconnect; no stale transcript or false success. |

Rollout: first ship an inert versioned relay envelope, then a signed Mac candidate
and PWA behind an opt-in tested capability. Enroll disposable pairs before a small
consenting beta. Old unverified pairings stay legacy, never automatically become
verified. Before enabling E2E on a pair, inventory/purge its old plaintext relay
and browser replicas using the cache-only policy, and explain the provider-backup
limit. Originals on the Mac are not migrated or deleted.

Rollback keeps encrypted storage and the protected-pair minimum version. Disable
the feature or require an update if the chosen library/runtime breaks. Never
restore a plaintext relay route or an older sending-state backup to make a
protected connection work. Re-enrollment is safer than cryptographic-state rewind.

Metadata remains: account identifiers, routing relationships, IPs, traffic timing,
lengths and online/offline activity. Encryption does not provide anonymity. No
server-side transcript search, summary, redaction or content inspection is possible
for protected payloads without changing the promise; these belong at endpoints.

## Concrete Validation Gate

Pin the upstream fixture revision and checksum. Run at least
`crypto-basics.json`, `key-schedule.json`, `message-protection.json`, `welcome.json`,
`transcript-hashes.json` and `storage-stability.json` through the chosen core.
These files exist in the [OpenMLS vector directory](https://github.com/openmls/openmls/tree/main/openmls/test_vectors).
They have **not** been executed by this design task.

Add shared deterministic application fixtures with these explicit scenarios:

| Fixture | Expected result |
| --- | --- |
| Mac A/controller B round trip; Unicode prompt and binary attachment | Identical authenticated bytes across Swift and Chromium/WebKit WASM; no plaintext in relay capture. |
| Same-account attacker C substitutes a key or adds itself | Pairing fails without host approval; no content or command dispatch. |
| Replay `command-001` within a session, after reconnect, and after restart | One execution at most; replay acknowledged/rejected without executing twice. |
| Modify recipient, request ID, ciphertext or group context | Authentication/authorization failure, zero execution. |
| Revoke B, then restore its earlier session/storage and reconnect | B receives no new content and cannot control A; independently approved C is unaffected. |
| Deliver offline ciphertext just before/at/after its 24-hour deadline | Valid before; rejected at/after. Reads do not refresh TTL. |
| Omit a required epoch transition, reorder delivery, duplicate a commit | Bounded recovery or explicit live resync, never plaintext fallback. |
| Crash after advancing sender state but before network send; crash before/after command effect | No nonce reuse; deduplicated result or explicit uncertain outcome. |
| Two browser tabs race a send, logout and database restore | One durable state owner; no resurrected cache or reused sender state. |
| Relay changes SDP fingerprint or strips encrypted capability | Peer setup fails; no media/control sent to the substituted endpoint. |
| Old/new endpoint matrix and upgrade rollback | Honest legacy state or fail-closed protected state, never silent downgrade. |

Benchmark 1, 4 and 8 controllers per Mac, slow/offline receivers, reconnect bursts,
maximum supported attachment sizes and screen fallback. Record CPU, memory, WASM
download/startup, command latency and bounded storage growth. Reject the candidate
if acceptable behavior requires disabling verification or enabling draft crypto.

## Work Packages And Decision

1. **Local feasibility, 2-3 focused engineering days (estimate):** pin and inspect
   OpenMLS, build one narrow Rust boundary for Swift/WASM, run vectors and a
   two-endpoint/restart pilot. No production credentials, hosting or paid CI loop.
   Stop with measured findings if browser/native storage or build support fails.
2. **Integration, provisional 3-6 engineering weeks:** enrollment, durable state,
   every transport payload, cache journal, migration and visible recovery. Re-estimate
   from the spike; this is not a delivery promise or a single automatic goal loop.
3. **Independent review and controlled beta:** external protocol/integration review,
   negative tests and remediation before an E2E public claim. Obtain approval for
   review spending, Mac signing/publication and production rollout separately.

Expected ownership: a new narrow shared crypto core; protocol framing; Mac
Security/Transport and Access UI; PWA transport/storage/enrollment UI; Worker
opaque routing/expiry; lab interoperability and adversarial tests. Adapter behavior
and source chats/files are out of scope. Do not expand `shared-crypto` with
hand-written encryption while library feasibility is unresolved.

**Requested approval:** accept the endpoint-trusted threat model, Mac-approved
enrollment and re-enrollment recovery, and authorize only the bounded local MLS
feasibility stage. A stronger malicious-web-publisher requirement instead needs a
separate controller-distribution decision first. No dependency, wire format,
production rollout, review spending or encryption claim is approved by this file.
