# Current loop state

Last updated: 2026-07-27.

## Baseline

- Product stage: pre-1.0 public-beta preparation.
- Supported: Mac Screen and scoped Terminal shell control.
- Preview: Codex desktop/CLI, Cursor, Cursor Agent, Gemini CLI, and OpenCode.
- Experimental: Claude Code and generic window mirroring.
- Default development environment: account-first Local Test Lab.
- Default validation order: unit/static, Playwright fixtures, local account E2E,
  signed Mac app, then Simulator or hosted canaries only when earlier lanes cannot
  prove the behavior.

## Current focus

Prepare a privacy-safe, understandable public repository. Keep raw test artifacts,
private account details, absolute machine paths, and personal credentials out of
Git. The sanitized history and dependency-security gate are complete. Repository
visibility remains an explicit maintainer decision; the next product-development
loop should start from the highest-impact open gate in
`docs/public-release-readiness.md` rather than replaying historical logs.

## Working rule

Use local-first iteration and one consolidated push. Update the support matrix only
when current evidence changes a public claim.
