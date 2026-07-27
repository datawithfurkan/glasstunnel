# Contributing to Glasstunnel

Thank you for considering a contribution. Glasstunnel is Apache 2.0 licensed and community-first.

## Ground rules

1. Be kind. This is a developer tool that sits between a user's machine and their phone — the community values trust, so trust-building behavior is non-negotiable.
2. File an issue before opening a large PR. We want to avoid throwing away good work because the direction was off.
3. One logical change per PR. Small PRs get reviewed fast.
4. New code lands with tests. Swift tests via `swift test`, TypeScript via Vitest, Go via `go test`.
5. Never commit secrets or private test evidence. Run `pnpm qa:public-repo` before opening a PR.

## Project scope

Glasstunnel is a tunnel. It is not a cloud IDE, not a code-sharing tool, not a pair-programming tool, and not a chat-with-another-human tool. PRs that expand the core scope in those directions will probably be declined. Adapters, per-agent UI improvements, security hardening, and platform ports are always welcome.

## Development setup

Prereqs:

- macOS 14+
- Xcode 15+
- Node 22+ and pnpm 9+
- Go 1.22+
- protoc
- Docker Desktop and the Supabase CLI for account-first integration tests

```bash
git clone https://github.com/datawithfurkan/glasstunnel
cd glasstunnel
pnpm install
pnpm lab:doctor
```

`lab:doctor` is read-only and prints any missing prerequisite. The default full
stack is disposable and does not use personal or production credentials:

```bash
pnpm lab:up:host
pnpm lab:e2e
pnpm lab:down
```

## Agentic workflow

Glasstunnel uses agent-assisted development as a first-class workflow. Before a non-trivial change, read:

- `AGENTS.md`
- `docs/agentic-workflows.md`
- `docs/agent-ui-contract.md`
- `DESIGN.md` when UI is touched

Useful commands:

```bash
pnpm agent:validate      # print validation commands for the current diff
pnpm agent:validate:run  # run the recommended validation commands
pnpm release:readiness   # run broad local public-release checks
pnpm qa:mobile:ios       # run the iOS Simulator Safari smoke test
pnpm qa:public-repo      # scan tracked files for secrets/private metadata
```

For large tasks, keep one driver responsible for the critical path. Use parallel sub-agents only for independent exploration, disjoint implementation ownership, or verification that can run while the driver continues non-overlapping work. Every delegated task should name owned files/modules, acceptance criteria, and required verification.

When a change affects behavior that users see, update the Mac and web UI together unless the reason not to is documented in the PR or commit notes.

Release-readiness work must update `docs/public-release-readiness.md` and `docs/agent-app-support-matrix.md` when a gate or app support status changes.

## Public-release readiness

Glasstunnel is mobile-first. Changes that affect the mobile PWA, connected workspace, screen sharing, auth, remote app state, or user-visible Mac behavior should include the relevant checks from `docs/agentic-workflows.md` plus any manual verification needed to prove the user flow.

Before claiming a release gate is complete:

1. Run `pnpm agent:validate` and the recommended checks for the diff.
2. Run `pnpm release:readiness` for broad release-impacting changes.
3. Run `pnpm qa:mobile:ios` for mobile UI changes when CoreSimulator is available.
4. Record real-device limitations honestly in `docs/public-release-readiness.md`.
5. Update `docs/agent-app-support-matrix.md` only with real app evidence, including date, environment, app version, result, and follow-up issues.

Do not describe an adapter as release-ready from unit tests alone. Codex, Cursor, Claude Code, OpenCode, Terminal, and Mac Screen each need real local-app or real-device verification before public support claims are updated.

Use `docs/dev-runbook.md` for the Local Test Lab and targeted test lanes. The Go
signaling server remains available for lightweight transport development, but the
account-first Local Test Lab is the default product environment.

## Writing a new adapter

Adapters live in `apps/host-macos/Sources/Adapters/`. Every adapter implements the `AgentAdapter` protocol:

- `observeState()` — an async stream of `AgentState` updates
- `sendInput(_ text: String)` — deliver user input to the agent
- `interrupt()` — request the agent to stop its current action
- `detectDone()` — agent-done signal source

Before opening a PR with a new adapter:

1. Add a doc at `docs/adapters/<tool-name>.md` explaining what you read from the tool and what assumptions you make about its local state.
2. Include a compatibility matrix (tool version x adapter version).
3. Gracefully degrade to mirror + keyboard if the assumed state cannot be found.

## Security

Found a security issue? Do not open a public issue. Email security@glasstunnel.io. Read [SECURITY.md](SECURITY.md).

## Commit messages

Use conventional-commits-lite:

- `feat(host): add OpenCode adapter`
- `fix(pwa): recover from dropped WebRTC connection`
- `docs: explain TURN self-hosting`
- `refactor(signaling): extract rendezvous into package`

## CI

GitHub Actions runs validation on every PR. Production deployment is a separate,
manual release action and is never triggered by a contributor PR.

The validation workflow includes:

- Swift build + tests (macos-latest)
- Mobile PWA build + Vitest (ubuntu-latest)
- Signaling go build + tests (ubuntu-latest)
- Protobuf codegen diff check

Green CI is required to merge.

## Pull request checklist

- Explain the user-visible behavior and support-tier impact.
- Include focused tests and the output of `pnpm agent:validate`.
- Update Mac and web UI together when the UI parity contract applies.
- Confirm `pnpm qa:public-repo` passes.
- Keep raw browser traces, screenshots, transcripts, and local evidence out of Git.
