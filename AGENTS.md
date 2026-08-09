# Glasstunnel Agent Instructions

Never hesitate to do more work when that is the right way to deliver the best result.
Always do the maximum useful work needed to finalize the task well.

## Operating Loop

For any non-trivial task, read `docs/agentic-workflows.md` and use its task packet, validation matrix, and handoff rules.
For release-readiness or goal-loop work, also read `docs/public-release-readiness.md`, `docs/agent-app-support-matrix.md`, `docs/release-goal-loop-prompt.md`, and `docs/release-goal-loop-log.md`.

## Source Of Truth Order

Use this order when repo docs disagree:

1. `AGENTS.md`, `docs/agentic-workflows.md`, and `docs/agent-ui-contract.md`.
2. Current focused loop state: `docs/current-loop-state.md`, then any focused loop contract named by the task.
3. Release gates and claims: `docs/public-release-readiness.md`, `docs/agent-app-support-matrix.md`, and `docs/known-limitations.md`.
4. Surface-specific runbooks such as `docs/mobile-qa.md`, `docs/dev-runbook.md`, `docs/remote-terminal-and-app-launch.md`, and adapter docs.
5. Append-only evidence and historical logs.

Historical handovers, old evidence artifacts, and earlier process-log entries are context only. Do not use them to override current code, current support-matrix rows, or current loop-state guidance.

Default loop:

1. Check `git status --short --branch`.
2. Read the docs that govern the touched surface.
3. Identify Mac, web, protocol, relay, auth, deploy, and documentation impacts before editing.
4. Make focused changes that preserve product behavior outside the task.
5. Run `pnpm agent:validate` to choose checks, then run the relevant commands.
6. Commit and push to `main` when the task is complete and the project flow calls for it.
7. Check GitHub Actions after pushing. If CI fails, read the logs and fix the root cause.

## Superpowers Workflow

Use Superpowers multi-agent orchestration only when the task explicitly calls for delegated or parallel agent work.

- Keep one driver responsible for the critical path.
- Use explorer agents for narrow, independent codebase questions.
- Use worker agents only with disjoint file ownership, clear acceptance criteria, and required verification.
- Tell workers they are not alone in the codebase and must not revert edits made by others.
- Do not spawn agents for one-file changes, secrets/keychain/signing work, or tasks where the driver is blocked on the delegated answer.

The detailed rules and prompt templates live in `docs/agentic-workflows.md`.

## Durable Agent Factory

Use the Gas City and Beads factory only when the user explicitly requests
long-running, delegated, multi-session, or multi-agent execution. Ordinary
tasks remain single-driver work, and in-session parallel work continues to use
the Superpowers workflow above.

- The factory is opt-in and dormant by default. Never enable continuous
  mutation or unattended production operation.
- Run `pnpm factory:doctor` before activation and follow
  `ops/agent-factory/README.md` for bootstrap, status, recovery, and shutdown.
- All mutable factory state, ledgers, artifacts, and worker worktrees stay
  outside the primary checkout.
- Workers use isolated `codex/` branches and external worktrees. They never
  push or merge `main` directly.
- Production deploys, signing, notarization, Keychain access, TCC changes, and
  personal accounts remain human-gated even when the factory is active.
- Keep retries bounded, acquire the declared resource leases, use Telegram for
  genuine human blockers, and rotate or replan after repeated failure.
- Finish local validation before one consolidated push and one bounded CI
  inspection. GitHub Actions are confirmation, not the inner test loop.

## Attachments

Always inspect user-provided attachments carefully before answering or acting on them.
Image attachments and screenshots must be checked in detail every time. Do not infer, skip, or pretend to have reviewed them.
When a screenshot shows UI state, mention the relevant visible state explicitly before drawing conclusions.

## UI Parity Contract

Glasstunnel is a product, not just a transport layer. Any backend, protocol, adapter, auth, connection, command, file, status, or workflow change must be reflected in the user-facing UI where it affects behavior.

Before finishing a code change, check whether it changes or introduces:

- A user action, button, state, error, loading phase, or confirmation.
- A Mac app behavior that needs corresponding web/mobile wording or controls.
- A web/mobile behavior that needs corresponding Mac app status, affordance, or settings.
- A protocol/backend event that should be visible as progress, success, failure, reconnect, offline, unavailable, or cached state.

If yes, update the relevant Mac and web UI in the same change unless there is a documented reason not to.

For the full checklist, read `docs/agent-ui-contract.md`.
