# Current loop state

Last updated: 2026-09-06.

## Baseline

- Product stage: pre-1.0 public-beta preparation.
- Supported: Mac Screen and scoped Terminal shell control.
- Preview: Codex desktop/CLI, Claude desktop, Claude Code, Cursor, Cursor Agent, Gemini CLI, and OpenCode.
- Experimental: generic window mirroring.
- Default development environment: account-first Local Test Lab.
- Default validation order: unit/static, Playwright fixtures, local account E2E,
  signed Mac app, then Simulator or hosted canaries only when earlier lanes cannot
  prove the behavior.
- Durable agent-factory foundation: locally verified and dormant by default.
  Activate it only for explicitly requested multi-session or multi-agent work;
  ordinary product tasks remain single-driver work.

## Current focus

Publish and stabilize the first honest public beta. The repository is public and the
signed, notarized `0.1.9` public beta release is available. Keep raw test artifacts, private
account details, absolute machine paths, and personal credentials out of Git. The next
product-development loop should start from the highest-impact remaining beta risk in
`docs/public-release-readiness.md` rather than replaying this release movement.

Security reconciliation takes priority over further product improvements. The
approved sequential roadmap is `docs/architecture/security-hardening-plan.md`.
Stage 1 is active: PR #32 merged the tested security patch at `da9a1bc3`;
production deployment and its canary are still pending. The sole maintainer
explicitly authorized zero required contributor approvals on 2026-09-06. Keep
protected PRs, all five strict CI checks and the other branch protections; do not
repeat the independent-contributor approval blocker. Stages 2-4 remain queued;
stage 5 is E2E design only and requires a separate decision before implementation.
Both PR and post-merge CI passed, and Dependabot reports zero open alerts. The
next release gate is Cloudflare deployment preflight/access and explicit production
approval, not GitHub contributor review. Local Wrangler currently lacks auth;
do not claim that the hosted patch has shipped.
See `docs/security-reconciliation.md` for the first pass's evidence and remaining
risks. After stage 1, the next security slice is authorization and active-session
revocation across the Mac, hosted relay and WebRTC. Do not
equate corrected privacy wording or a clean dependency audit with that slice
being implemented.

Paused product-audit slice: First-Run Activation. Use
`docs/product-audit-backlog.md` as the durable queue. After completing the
active slice, record validation evidence there and mark the next queued slice
active so follow-up work does not depend on chat history.

## Working rule

Use local-first iteration and one consolidated push. Update the support matrix only
when current evidence changes a public claim.
