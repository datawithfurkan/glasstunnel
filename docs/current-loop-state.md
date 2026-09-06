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
Stage 1 passed: PR #32 merged the tested security patch at `da9a1bc3`;
Deploy run `34047515720` succeeded and the public Chromium/WebKit canary passed.
Stage 2 passed in source and hosted services: PR #33 merged at `c4acdc2a`, its
five required checks passed, Deploy `34057717088` succeeded, and isolated
Chromium/WebKit public canaries passed. Stage 3 passed in source and hosted
services: PR #34 merged at `cc3377b1`, all five checks passed in CI `34061166134`,
and Deploy `34061593757` plus public Chromium/WebKit canaries passed. The sole maintainer
explicitly authorized zero required contributor approvals on 2026-09-06. Keep
protected PRs, all five strict CI checks and the other branch protections; do not
repeat the independent-contributor approval blocker. Stage 4 is at its substantive
retention-policy decision, documented in `docs/architecture/content-retention-proposal.md`;
stage 5 is E2E design only and requires a separate decision before implementation.
Stage 1 PR/post-merge CI passed, and its live Dependabot check reported zero open
alerts on 2026-09-06. Stage 2-3 PR checks also passed. The
maintainer approved the proposed `da9a1bc3` rollout and instructed the driver to
continue routine planned steps without repeated approval requests. The next gate
is approval of the exact retention/deletion policy, not routine implementation,
test, commit or planned deployment actions.
The revocation local gate passed: 45 Worker tests, 452 Swift tests with
eight environment-gated skips, 242 PWA tests, and the disposable two-browser
revocation journey. The latter also exposed and verified a fix for cached
greetings incorrectly disabling an online composer's input. Wrangler
OAuth was restored on 2026-09-06 and read-only deployment queries passed for the
PWA, site and Worker. All three hosted security slices have shipped. The new Mac
revocation and permission operations are source-only until a coordinated binary release;
the installed/public 0.1.9 app has not been replaced.
See `docs/security-reconciliation.md` for the first pass's evidence and remaining
risks. Stage 3 validation: 462 Swift tests (eight environment skips),
244 PWA tests, 46 Worker tests, the adversarial two-browser permission/revocation
journey, ordinary account/Terminal checks and Chromium/WebKit fixtures. Host
restrictions persist and are shared by relay/DataChannel dispatch; browser
restrictions cannot affect another identity. The UI advertises this only on
matching hosts. Protected integration and hosted deployment passed; do not
equate those results with an updated public Mac binary.

Current working branch: `codex/security-retention`, based on `cc3377b1`.
The 24-hour offline-cache proposal and completed-stage evidence are retained
locally for the next slice without another documentation-only CI push. No
retention implementation or hosted cache deletion has occurred. Original chats,
project files, local attachments, account/device identities and denial tombstones
are excluded from the proposed cache purge. The local lab is stopped.
One deduplicated Telegram message requested the retention-policy decision on
2026-09-06 and was delivered. No other approval or authentication is pending.

Paused product-audit slice: First-Run Activation. Use
`docs/product-audit-backlog.md` as the durable queue. After completing the
active slice, record validation evidence there and mark the next queued slice
active so follow-up work does not depend on chat history.

## Working rule

Use local-first iteration and one consolidated push. Update the support matrix only
when current evidence changes a public claim.
