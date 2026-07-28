# Glasstunnel security model

## Threat model

Glasstunnel is designed to let a developer see their Mac's local coding agents from their phone. The threat model reflects that:

- **In scope:** a malicious network attacker on any hop between phone and Mac (including the signaling server). A malicious browser extension on an already-trusted phone. An attacker who learns the phone's device ID but not its private key. Infrastructure operators at `glasstunnel.io` (including the authors).
- **Out of scope:** an attacker with physical access to the unlocked Mac. An attacker with root on the Mac. An attacker with the phone in hand, unlocked, after the PWA is authenticated. Supply-chain attacks against the coding agents themselves.

## Properties we provide

| Property                                   | How                                                                                    |
| ------------------------------------------ | -------------------------------------------------------------------------------------- |
| Mac and phone authenticate to each other   | Ed25519 device keys generated on first launch, exchanged through the account host-claim flow |
| Signaling envelopes are sender-authenticated | Clients sign outbound envelopes and verify inbound envelopes against the paired device key |
| Signaling server cannot read content       | All media + DataChannel traffic is DTLS-SRTP encrypted end-to-end                      |
| TURN relay cannot read content             | Same DTLS-SRTP E2E; TURN sees ciphertext only                                          |
| Unlinked devices cannot receive content    | Hub routes envelopes by `to_device_id`; Mac side checks the device registry and signatures too |
| Phone must biometric-unlock before use     | WebAuthn gate on every cold start                                                      |
| Mac-side read-only toggle hard-disables input  | Read-only bit is enforced inside `Session.handleDataChannelMessage` before dispatch    |
| Common secrets never leave the Mac         | `SecretRedactor` runs on all outbound text before WebRTC send                          |
| Lost devices can be revoked                | `DeviceRegistry.revoke()` moves a device to blacklist; Mac drops envelopes from it     |

## Account-first trust model

When using the hosted control plane (Supabase + Cloudflare Workers), the trust flow is:

1. **Account creation:** The user signs up via Supabase Auth (email + OTP). Supabase stores the account profile; Glasstunnel never sees the password.
2. **Host linking:** The Mac app generates a single-use link code and sends it to the Cloudflare Worker. The worker stores the code in Supabase with a 5-minute TTL.
3. **Host claim:** The signed-in phone presents the link code. The worker verifies the code, then creates a `host_devices` row associating the Mac's `device_id` with the user's account.
4. **Device authorization:** A signed-in browser device on the same account is authorized by the control plane and added to the Mac's `DeviceRegistry`.
5. **Ongoing access:** All subsequent sessions require both account authentication (Supabase JWT) and device-level Ed25519 mutual auth. Revoking a device on the Mac immediately blocks that device, regardless of account status.

The account layer is the required discovery and authorization path. The security boundary remains device-level Ed25519 trust after account authorization.

## Crypto primitives

- **Device identity:** Ed25519 signatures. Provided by Apple's CryptoKit (Swift), `@noble/ed25519` (TypeScript), and Go's stdlib `crypto/ed25519`.
- **Channel encryption:** DTLS 1.2 + SRTP. Provided by Google's WebRTC stack.

No new primitives. No hand-rolled crypto. No Glasstunnel-operated TLS endpoint sees WebRTC media or DataChannel plaintext.

## Data storage

- **Mac:** host private key in the system Keychain (generic password, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Paired-device public keys + labels in `~/Library/Application Support/Glasstunnel/devices.json`.
- **Phone:** phone keypair in IndexedDB via `idb-keyval`. WebAuthn biometric credential stored by the browser / platform keychain.
- **Local Go signaling server:** no durable account data. Offline envelopes live in memory briefly. Web Push subscriptions may be stored when push is enabled.
- **Hosted Cloudflare/Supabase control plane:** Supabase stores account profiles, device public keys, host link codes, device pairings, and approval requests. It does not store captured content, prompts, chats, or media.
- **TURN server:** coturn uses in-memory long-term credentials. No logging of user content; only metered bytes-per-session.

## Secret redaction

`SecretRedactor` runs on every outbound chat message and every captured PTY output. Defaults cover:

- AWS access keys (`AKIA…`) and secret-access-key assignments
- Google API keys (`AIza…`)
- GitHub PAT/OAuth/server tokens (`ghp_…`, `gho_…`, `ghs_…`)
- OpenAI keys (`sk-…`), Anthropic keys (`sk-ant-…`), Stripe secret keys (`sk_live_…`)
- JWT tokens (`eyJ…eyJ…`)
- SSH private-key blocks
- `Authorization: Bearer …` headers
- Assignment lines whose variable name includes SECRET/TOKEN/PASSWORD/API_KEY/PRIVATE_KEY

Matches are replaced with `<redacted:NAME>`. Users can extend the pattern list in Settings. Redaction is **one-way**: once a match is replaced, the phone never sees the original bytes.

Redaction is best-effort. It will miss anything that doesn't match the default patterns and custom patterns the user has added. Security-critical workflows should pair redaction with `Read-only mode`.

## Attack resistance

### Replay

Every envelope carries `envelope_id` (UUID) + `sent_at_unix_ms`. Both clients authenticate their WebSocket connection by signing a server nonce, and then sign each outbound envelope with the same device key.

We do not currently reject time-skewed envelopes or keep an envelope replay cache — this is a deliberate tradeoff because mobile clocks on LTE drift and the signaling layer only carries setup/control traffic. Replay-to-impersonate is mitigated by device signatures, channel-level DTLS, and by the fact that content lives on the WebRTC channel, not the envelope.

### Man-in-the-middle at signaling

The signaling server can drop, delay, replay, or shuffle envelopes. It cannot forge accepted envelopes between linked devices because clients verify envelope signatures against the trusted key learned from the account host-claim flow.

### Evil-twin server

If the user types a malicious signaling URL in Settings before linking the Mac, that host could MITM the handshake in theory. In practice:

1. Account linking needs a short-lived code generated by the real Mac.
2. A malicious server cannot produce a valid `auth_ok` response without the private key.
3. The browser stores the host public key at host-claim time and verifies host-origin envelopes against it later.

### Compromised phone

If the phone is stolen and unlocked, the attacker gets full access to the tunnel until you revoke from the Mac side (`Devices` tab). That's by design; device revocation is fast (< 1s) and effective immediately.

## Logging and telemetry

The Mac app uses Apple's unified logging for operational events such as remote-app actions and adapter lifecycle changes. Reviewed log calls do not intentionally include captured screen content, prompts, chats, or Terminal output; error descriptions are marked private where they are logged. The PWA may write a local browser-console warning when push registration fails, and the Cloudflare Worker logs relay-snapshot persistence failures for operational diagnosis.

The repository does not include an analytics SDK, a crash-reporting SDK, a crash-reporting Settings toggle, or a Glasstunnel telemetry-ingestion endpoint. Operating systems, browsers, and hosting providers may still produce their own diagnostic or request logs according to the user's device settings and the deployment's provider configuration.

## What about the signaling server operators?

The public service uses Cloudflare, Supabase, and TURN infrastructure. Those services necessarily process operational metadata needed to route and secure connections, such as network addresses, request timing, account/device lifecycle records, and relay byte counts. The application is designed so that captured content and WebRTC DataChannel content remain end-to-end encrypted and are not available to the signaling or TURN services.

- The hosted control plane does not receive plaintext WebRTC user content.
- We do not log captured content, prompts, chats, media, SDP bodies, or ICE candidates.
- The Go signaling server may inspect the `agentStateEvent` status metadata needed for Web Push. The Cloudflare worker currently treats push fanout as pending.
- The repository does not define a universal provider-log retention period. Self-hosters control their own logging and retention; hosted-service retention is an operational configuration that must be reviewed separately from this source-code audit.

If you don't trust us (which is a perfectly reasonable position), the self-hosting path is one `docker compose up` away. See [`docs/self-hosting.md`](self-hosting.md).

## Reporting a vulnerability

See [`SECURITY.md`](../SECURITY.md) at the repo root.
