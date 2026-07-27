# Release goal loop

Use this contract for long-running public-release work. There is no repository-level
character limit for Codex goal prompts; keep durable state in the canonical docs
rather than duplicating it in every prompt.

## Prompt

```text
Goal: Move Glasstunnel one measurable step toward a safe public beta.

Work from the repository root. Use the local test skill and the configured
human-in-the-loop Telegram skill.

Read AGENTS.md, docs/current-loop-state.md, docs/public-release-readiness.md,
docs/agent-app-support-matrix.md, docs/known-limitations.md, and the latest entry in
docs/release-goal-loop-log.md. Check git status before editing.

Select exactly one highest-impact incomplete release gate. Prefer engine,
correctness, security, lifecycle, and repeatable test work over cosmetic UI changes.
Use the cheapest proving lane: unit/static checks, Playwright fixtures, local account
E2E, signed Mac app, then Simulator or hosted canaries only when earlier lanes cannot
prove the behavior. Never use a private account for automated tests.

Avoid stale loops. Do not retry the same failing method twice without a new
hypothesis, diagnostic, environment, or test. If a slice needs human-only auth,
Keychain, TCC, CAPTCHA, account approval, or GUI action, send one concise Telegram
blocker notification with the exact safe action; never include secrets or private
content. Rotate to independent work while waiting when useful.

Each iteration must end in one concrete outcome: a passing test, verified manual
pass, blocker-narrowing diagnostic, or documentation change that prevents an
overclaim. Keep Preview and Experimental integrations at their current tier until
repeatable real-app evidence proves the whole promised scope.

Keep raw screenshots, traces, transcripts, account identifiers, and absolute local
paths in ignored local storage. Commit only privacy-reviewed summaries. Run
pnpm agent:validate and the checks it selects. Run pnpm qa:public-repo before the
final commit. Iterate and commit locally; make one consolidated push at the end,
then inspect one bounded CI run. Production deploy is manual.

Update the release gate, support matrix, and process log only when their state
changes. Finish with focus, gate moved, changes, validation, manual evidence,
remaining risk, next recommended focus, commit, and CI result.
```

## Stale-loop guard

Stop or rotate when two attempts produce no new evidence. Record what was tried, the
remaining uncertainty, and the cheapest next experiment. A long run is successful
because it narrows release risk, not because it consumes time.

## Human-action boundary

Do not reset permissions, delete user apps/data, alter signing credentials, change
repository visibility, rewrite history, or deploy production without an explicit
task and approval. Use `pnpm notify:telegram:blocker` only for a concrete human action
that prevents progress.
