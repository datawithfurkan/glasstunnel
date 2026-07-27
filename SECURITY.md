# Security Policy

## Supported versions

Glasstunnel is pre-1.0. Only the tip of `main` is supported. Once v1.0 ships, this section will grow to list the last two stable minor versions.

## Security model

The hosted architecture, account/device trust model, data storage, logging commitments, and known security tradeoffs are documented in [`docs/security.md`](docs/security.md). Public product limitations are tracked in [`docs/known-limitations.md`](docs/known-limitations.md).

## Reporting a vulnerability

Please email **security@glasstunnel.io** with:

- A clear description of the vulnerability.
- Steps to reproduce (or a proof-of-concept).
- The versions of the Mac host app, mobile PWA, and signaling server you tested against.
- Your preferred contact for follow-up.

We aim to:

- Acknowledge within 72 hours.
- Provide a preliminary assessment within 7 days.
- Ship a fix for critical issues within 30 days.

Please do not open a public issue, pull request, or social media post about the vulnerability until we have had a chance to coordinate disclosure.

## Scope

In scope:

- Mac host app (`apps/host-macos`)
- Mobile PWA (`apps/mobile-pwa`)
- Signaling server (`apps/signaling`)
- Hosted Cloudflare/Supabase account and relay control plane configuration
- Shared crypto package (`packages/shared-crypto`)
- Protocol definitions (`packages/protocol`)
- Deployment configuration under `deploy/`

Out of scope:

- Third-party coding tools (Cursor, Claude Code, Codex, OpenCode) themselves.
- The underlying operating systems, browsers, or WebRTC stack.
- Issues that require a local attacker already on the user's machine with root privileges.
- Denial-of-service via brute traffic.

## What we consider a high-severity issue

- Ability for a non-paired device to receive content from a paired Mac.
- Ability for a third party to inject input into the Mac via the tunnel.
- Signaling server leakage of WebRTC SDP or ICE candidates to an unauthorized party.
- Bypass of the secret redaction layer.
- Bypass of the read-only mode toggle.
- TURN relay being able to see plaintext content.
- Key exfiltration from the Mac keychain or the phone WebAuthn credential.

## Bug bounty

We do not operate a formal bug bounty program. Please do not incur costs or perform
testing against accounts, devices, or infrastructure you do not own or have explicit
permission to test.

## Sensitive evidence

Do not include tokens, private keys, recovery codes, prompts, source code, email
addresses, device identifiers, absolute paths, or unredacted screen captures in a
public issue or pull request. Security reports may include encrypted attachments
after the maintainers provide a private transfer method.
