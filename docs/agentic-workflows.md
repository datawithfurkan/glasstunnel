# Agentic Workflows

This repo is built by agents as much as by humans. The workflow below makes that explicit: one driver owns the task end to end, parallel agents are used only when they reduce risk or latency, and every visible behavior stays tied to product UI.

## Core Principles

- The driver owns the critical path. Do not delegate work that blocks the next local step.
- Every task starts with orientation: read `AGENTS.md`, this file, and the specific docs for the touched surface.
- Public-release work must also use `docs/current-loop-state.md`, `docs/public-release-readiness.md`, `docs/agent-app-support-matrix.md`, `docs/release-goal-loop-prompt.md`, and the latest entries in `docs/release-goal-loop-log.md`.
- If docs conflict, follow the source-of-truth order in `AGENTS.md`. Historical handovers and old evidence artifacts are context only.
- Product truth beats optimistic state. If the UI says `Ready`, `Connected`, `Live`, `Opened`, or `Done`, there must be an underlying acknowledgement or rendered/live signal.
- Use the smallest useful validation set, but make it explicit. When behavior crosses Mac, web, protocol, or relay boundaries, validate each touched surface.
- Keep changes focused. Broad refactors are acceptable only when they directly reduce task risk or remove real duplicated workflow.
- Never hide uncertainty. If a live device, browser session, signing identity, or hosted service was not tested, say so.

## Superpowers Usage

The Superpowers capability available to this repo is multi-agent orchestration. Use it as a workflow accelerator, not as a substitute for ownership.

Only spawn sub-agents when the task explicitly calls for delegated or parallel agent work. When using them:

- Start with a driver plan that names the immediate local task and the sidecar tasks.
- Use explorers for narrow codebase questions whose answers do not block the driver's next action.
- Use workers for disjoint file ownership. Give each worker exact files or modules, acceptance criteria, and verification commands.
- Tell every worker they are not alone in the codebase and must not revert edits made by others.
- Do not duplicate work between the driver and sub-agents.
- Close completed agents once their output is integrated.

Do not spawn sub-agents for:

- A one-file or docs-only change.
- Secrets, keychain, signing, or local-permission steps.
- UI testing that depends on the user's active desktop unless explicitly requested.
- Any task where the driver is immediately blocked on the delegated answer.

## Durable Agent Factory

Glasstunnel has three deliberately separate execution modes:

1. **Single driver** is the default for ordinary product work.
2. **Superpowers orchestration** is for explicitly requested parallel work that
   can finish inside one active task.
3. **Gas City plus Beads** is for explicitly requested durable work that must
   survive task boundaries, coordinate isolated workers, or preserve a graph of
   evidence and review state across sessions.

Do not activate the durable factory merely because a task is large. Use it only
when durable delegation is part of the request and the work can be split into
independently reviewable nodes. The factory remains dormant between runs and
must never operate as an unbounded background mutation loop.

The portable definition lives in `ops/agent-factory/`; mutable city, ledger,
lease, artifact, mirror, and worktree state lives outside the repository. Start
with:

```bash
pnpm factory:doctor
pnpm factory:bootstrap
pnpm factory:status
```

Every factory node must declare its objective, allowed files or surface,
acceptance criteria, validation, dependencies, resource leases, retry budget,
review requirement, and evidence. A worker owns one isolated external worktree
on a `codex/` branch. The planner may replan, but a failed node receives at most
two implementation attempts before it is blocked or rotated. Independent
review is required before integration.

Mac UI, Simulator, TCC, Keychain, notarization, production deploy, and other
exclusive or sensitive resources require their named lease. Signing,
notarization, deployment, permission changes, personal-account access, and
other human-only steps also require explicit human approval; use the Telegram
workflow instead of inventing a workaround. A lease is not production
authority.

Use the local test lab and deterministic checks as the inner loop. Workers do
not push. The integrator may prepare one reviewed branch or pull request only
after local evidence is green. Allow at most one resulting GitHub Actions run
for the completed batch unless a human explicitly authorizes more. Shut the
factory down with `pnpm factory:down`, preserving its ledger and backups for the
next session.

## Task Packet

Before implementing a non-trivial task, form this packet in your notes or handoff:

```text
Objective:
User-visible behavior:
Touched surfaces:
Primary files/modules:
Out of scope:
Validation:
Parallel work, if explicitly requested:
```

For worker sub-agents, use this stricter packet:

```text
You own:
You may read:
Do not edit:
Acceptance criteria:
Required verification:
Return:
```

## Operating Loop

1. Orient
   - Check `git status --short --branch`.
   - Read `AGENTS.md`, `docs/agent-ui-contract.md`, and the relevant app/package docs.
   - Inspect screenshots or attachments before acting on them.

2. Classify
   - Docs/process only.
   - Web/mobile UI.
   - Mac app UI or behavior.
   - Protocol/transport/relay.
   - Auth/security/deploy.
   - Cross-surface product behavior.

3. Plan
   - Identify the next local critical-path step.
   - Identify optional parallel sidecars only when explicitly authorized.
   - Name UI parity requirements before editing.

4. Implement
   - Prefer existing repo patterns.
   - Keep user-facing language consistent with `DESIGN.md`.
   - Update Mac and web UI together when behavior crosses those surfaces.
   - Update docs/runbooks when the workflow changes.

5. Validate
   - Run `pnpm agent:validate` to see surface-specific checks.
   - Run `pnpm agent:validate:run` when the recommended checks are appropriate for the current diff.
   - Add manual browser, Mac, or device verification when the code changes user-visible interaction.

6. Ship
   - Commit focused changes.
   - Push to `main` when that is the requested project flow.
   - Finish local validation before pushing. Use one consolidated push and one bounded CI/deploy inspection for the completed slice.
   - If CI fails, read the failing logs, reproduce the root cause locally, and make one focused corrective push.
   - Watch deploy only when the change should ship to hosted users. GitHub Actions and production deploys are confirmation layers, not test runners.

## Local-First Inner Loop

The account-first Local Test Lab is the default for cross-surface work. Read
`docs/dev-runbook.md`, then begin with:

```bash
pnpm lab:doctor
pnpm lab:test
```

Choose the cheapest lane that proves the change:

1. Unit/static checks.
2. Playwright fixture checks.
3. `pnpm lab:e2e` for real local auth, Worker relay, Swift host, and Terminal.
4. `pnpm lab:mac` for TCC, keychain, signing, and native lifecycle.
5. Codex Browser or iOS Simulator for a gap the deterministic lanes cannot
   prove.
6. One hosted canary after local work is green.

Playwright is the repeatable regression runner. Codex Browser is for
exploration and final acceptance. Playwright WebKit does not prove Mobile
Safari, and Simulator does not prove physical-device behavior. Do not request
physical-phone evidence unless the task explicitly requires it.

Never use a private account for automated checks. The lab owns a disposable
local identity and fixed loopback endpoints. Always call `pnpm lab:down` after
manual work; the E2E wrapper handles teardown itself.

## Validation Matrix

Use this as the default map. Add more checks when risk is higher.

| Surface                            | Minimum validation                                                                                                                                                             |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Docs/process only                  | `git diff --check`                                                                                                                                                             |
| Mobile PWA                         | `pnpm --filter=@glasstunnel/mobile-pwa lint`, `pnpm --filter=@glasstunnel/mobile-pwa test`, `pnpm --filter=@glasstunnel/mobile-pwa build`                                      |
| Site                               | `pnpm --filter=@glasstunnel/site build`                                                                                                                                        |
| Shared crypto                      | `pnpm --filter=@glasstunnel/shared-crypto build`, `pnpm --filter=@glasstunnel/shared-crypto test`                                                                              |
| Protocol schema/models             | `bash packages/protocol/scripts/gen.sh && git diff --quiet`, `pnpm --filter=@glasstunnel/protocol build`, `swift test --package-path apps/host-macos --filter GTProtocolTests` |
| Mac host                           | `swift test --package-path apps/host-macos`                                                                                                                                    |
| Go signaling                       | `cd apps/signaling && go build ./... && go vet ./... && go test ./...`                                                                                                         |
| Local lab/orchestration            | `pnpm lab:test`                                                                                                                                                                |
| Cloudflare Worker                  | `pnpm worker:typecheck`, `pnpm worker:test`, `pnpm worker:build`                                                                                                               |
| Account/relay/Terminal integration | `pnpm lab:e2e`                                                                                                                                                                 |
| Mobile WebKit fixture              | `pnpm lab:e2e:safari`                                                                                                                                                          |
| Root/workspace config              | `pnpm build`, `pnpm test`, `pnpm lint` when practical                                                                                                                          |
| UI behavior                        | Browser screenshot or precise visual state description                                                                                                                         |
| Mac permission/signing behavior    | Fresh app launch or explicit note explaining what could not be tested                                                                                                          |
| Deploy/CI                          | GitHub Actions run URL and conclusion                                                                                                                                          |

For broad release checks, run:

```bash
pnpm release:readiness
GT_RELEASE_READINESS_MOBILE=1 pnpm release:readiness
```

## UI Parity Gate

Before finishing any backend, protocol, adapter, auth, connection, command, file, status, or workflow change, answer:

- Does the user need a new or changed action, status, error, loading state, or confirmation?
- Does the Mac publish enough state for the web UI to be honest?
- Does the web UI show pending, success, failure, retry, unavailable, offline, or cached state clearly?
- Does the change require screenshots or manual test notes?

If yes, update the relevant UI in the same change or document why it is intentionally deferred.

## Handoff Template

Use this when a task is interrupted or handed to another agent:

```text
Branch/commit:
Goal:
What changed:
Files touched:
Commands run:
GitHub runs:
Known remaining risks:
Next concrete step:
Do not revert:
```

For durable factory work, also record:

```text
Workflow and node IDs:
Dependencies satisfied:
Leases acquired/released:
Attempts and failure class:
Review and integration evidence:
Human decisions still required:
Factory dormant-state check:
```

## Review Checklist

- The diff is focused on the stated task.
- The UI parity contract was considered.
- Tests match the touched surfaces.
- Generated files and protocol schema are in sync.
- Secrets and local environment values were not committed.
- Final notes say exactly what was verified and what was not.
