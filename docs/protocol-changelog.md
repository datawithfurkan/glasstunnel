# Protocol changelog

Every user-visible change to `packages/protocol/schema/glasstunnel.proto` goes here. Breaking changes bump the minor version of `PROTOCOL_VERSION`; additive changes bump the patch.

## 0.2.0 - breaking

- Removed direct device-link handshake messages. Account sign-in and host-linking are now the only supported onboarding path.

## 0.1.2 - additive

- Added optional screen-sharing quality on remote app action requests so browsers can ask the Mac host for either fast or readable screen relay frames.

## 0.1.1 - additive

- Added chunked file attachment batches for sending multiple files or photos from the web app to the Mac host in one prompt.

## 0.1.0 - initial

- Envelope/DataChannelMessage oneof skeleton.
- WebRTC signaling (SdpOffer/SdpAnswer/IceCandidate).
- Agent state and chat primitives.
- Grid layout primitives (1x1, 2x1, 1x2, 2x2).
- Quick reply enum (continue, try again, explain, commit, stop, approve, reject).
