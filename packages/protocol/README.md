# @glasstunnel/protocol

Source of truth for the glasstunnel wire protocol.

- `schema/glasstunnel.proto` — the canonical protobuf schema.
- `src/index.ts` — hand-written TypeScript types that mirror the schema (used until ts-proto generation is wired in).
- `scripts/gen.sh` — regenerates Swift / TypeScript / Go bindings from the `.proto` file. Gracefully skips languages whose plugins are not installed.

Two categories of message:

- **Envelope** — what the signaling server brokers. The payload is authenticated by the sender's ed25519 key; the server routes by device id and never reads content.
- **DataChannelMessage** — what flows over the encrypted WebRTC DataChannel between the Mac host and the phone. Never touches the server.

If you change the schema, bump `PROTOCOL_VERSION` in `src/index.ts` and add a migration note to `docs/protocol-changelog.md`.
