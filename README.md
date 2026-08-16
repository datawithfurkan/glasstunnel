# Glasstunnel

**See your local AI coding agents from your phone. Keep the context. Keep the Mac at home.**

Glasstunnel is an open-source tunnel from a Mac running local AI coding agents to a mobile PWA. Your agent keeps running in its original local context — no token burn re-indexing on a cloud VM, no half-synced GitHub state, no "wait, what was my project again?" from a remote agent.

Walk away from your desk. Check in from the subway. Send a prompt. Come home to a finished task.

## Why this exists

Cloud coding agents (Cursor Background Agents, Codex Cloud, Claude Code Web, Devin, Factory) are great for starting fresh tasks. They are painful when you've already spent two hours at your desk loading context into a local agent and you just want to peek at it from your phone. Glasstunnel bridges that gap without moving your code, your secrets, or your context off your machine.

## Architecture

```
Mac at home                    glasstunnel.io                 Phone anywhere
-----------                    --------------                 --------------
host-macos app     <-------->  signaling (Go)       <-------> mobile-pwa
  ScreenCaptureKit             coturn (TURN)                    React + Vite
  Tool adapters                Web Push (VAPID)                 WebRTC peer
  WebRTC peer                  OR
                               Cloudflare Workers +
                               Durable Objects +
                               Supabase (account plane)

              <--------- WebRTC E2E (DTLS-SRTP) --------->
```

- **Mac host app** — Swift/SwiftUI, discovers local agent apps, exposes them as remote apps, wraps CLI agents in a PTY, watches GUI agents via the Accessibility API, and streams to your phone over WebRTC.
- **Signaling + TURN** — Two options:
  - **Self-hosted:** Small Go WebSocket service + coturn. One `docker compose up`.
  - **Hosted:** Cloudflare Workers with Durable Objects for WebSocket state, Supabase for accounts/devices. The account plane handles sign-in, host linking, and device approvals.
- **Mobile PWA** — Installable React web app. Sign in to your account, choose a linked Mac, unlock with Face ID, and send prompts. Get push notifications when an agent finishes or needs input.

Everything between Mac and phone is end-to-end encrypted via WebRTC DTLS-SRTP. The signaling server sees routing metadata and WebRTC setup/control messages, but not your code, chats, prompts, or media.

## Status

Pre-1.0 public beta. The account-first product journey, Mac Screen, scoped
Terminal control, Developer ID signing, Apple notarization, Gatekeeper launch,
and production permission/auth relaunch flow have release evidence. The signed,
notarized `0.1.6` public beta release is available through GitHub Releases and Homebrew.

The public-beta support tiers are:

- **Supported:** Mac Screen and the scoped Terminal shell path.
- **Preview:** Codex desktop, Codex CLI, Cursor, Cursor Agent, Gemini CLI, and OpenCode.
- **Experimental:** Claude Code and generic window mirroring.

Preview and Experimental paths are included for testing and contribution, not
promised as release-ready. Codex is the next candidate for Supported status.
Check [`docs/known-limitations.md`](docs/known-limitations.md) and
[`docs/agent-app-support-matrix.md`](docs/agent-app-support-matrix.md) for the
current evidence and open gaps.

## Install the public beta

```bash
# Add the Glasstunnel tap and install the Mac app
brew tap datawithfurkan/glasstunnel https://github.com/datawithfurkan/glasstunnel
brew install --cask datawithfurkan/glasstunnel/glasstunnel

# Launch it and complete the required permission onboarding
open -a Glasstunnel
```

To install a newer published build later:

```bash
brew update
brew upgrade --cask datawithfurkan/glasstunnel/glasstunnel
```

After the Mac app opens:

1. Grant Screen Recording and Accessibility when the onboarding asks for them.
2. Sign in or create an account in the Mac app.
3. On your phone, open `https://app.glasstunnel.io` in Safari or Chrome.
4. Sign in with the same account.
5. Select your linked Mac and open an available remote app or Mac Screen.
6. Add the PWA to your Home Screen if your browser offers it.

## Develop locally

```bash
# Clone
git clone https://github.com/datawithfurkan/glasstunnel
cd glasstunnel

# Install toolchain prereqs
#   - macOS 14+ with Xcode 15+
#   - Node 22+ and pnpm 9+
#   - Go 1.26.5+
#   - protoc (for codegen)
#   - Docker Desktop and the Supabase CLI (for the full local lab)

# Install JS dependencies
pnpm install

# Inspect prerequisites without changing the machine
pnpm lab:doctor

# Start disposable local Supabase, Worker, PWA, and isolated Mac host
pnpm lab:up:host

# Run the authenticated mobile journey, then clean up owned services
pnpm lab:e2e
pnpm lab:down
```

The lab never needs a personal account or production credentials. See
[`docs/dev-runbook.md`](docs/dev-runbook.md) for focused commands and
[`docs/self-hosting.md`](docs/self-hosting.md) for deployment boundaries.

Agent-assisted workflow:

```bash
pnpm agent:validate      # print validation commands for the current diff
pnpm agent:validate:run  # run the recommended validation commands
pnpm release:readiness   # run broad local public-release checks
```

Agents and contributors should read [`AGENTS.md`](AGENTS.md), [`docs/agentic-workflows.md`](docs/agentic-workflows.md), and [`docs/agent-ui-contract.md`](docs/agent-ui-contract.md) before non-trivial changes. Release-loop work should also use [`docs/public-release-readiness.md`](docs/public-release-readiness.md), [`docs/agent-app-support-matrix.md`](docs/agent-app-support-matrix.md), and [`docs/release-goal-loop-prompt.md`](docs/release-goal-loop-prompt.md).

## Repository layout

```
apps/
  host-macos/       Swift/SwiftUI Mac host app
  mobile-pwa/       React + Vite mobile PWA
  signaling/        Go WebSocket signaling server
packages/
  protocol/         Protobuf schemas + generated types
  shared-crypto/    ed25519 helpers (Swift + TS)
deploy/             Docker/compose for self-hosting signaling + coturn
docs/               Docs (self-hosting, security, per-adapter compatibility)
site/               Marketing site
```

## Privacy note

Do not attach raw screens, prompts, source code, account identifiers, tokens, or
absolute local paths to issues. Release evidence in this repository is deliberately
limited to sanitized summaries; raw test output stays in ignored local storage.

## License

Apache License 2.0. See [LICENSE](LICENSE).

The core of glasstunnel will stay Apache 2.0 forever. Future commercial offerings (hosted Pro tier, enterprise features) live outside this repo.

## Security

Found a vulnerability? Email security@glasstunnel.io. See [SECURITY.md](SECURITY.md) for the disclosure policy and [`docs/security.md`](docs/security.md) for the trust model, hosted architecture, and data-handling details.

## Contributing

Contributions welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first.
