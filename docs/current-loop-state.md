# Current loop state

Last updated: 2026-09-10.

The four hosted security stages are deployed at `0f98a93d`; their Mac side and
the 2026-09-10 review fixes ship in 0.1.10. The E2E design is deferred.

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
account details, absolute machine paths, and personal credentials out of Git.

The September security work (`docs/security-reconciliation.md`, stages 1-4 of
`docs/architecture/security-hardening-plan.md`) is merged and deployed to the
hosted surfaces at `0f98a93d`: truthful relay disclosure, acknowledged device
revocation, Mac-owned read-only control, and 24-hour cache replicas (the hosted
sweep removed 503 stale records on 2026-09-07). The Mac side of the revocation
and permission operations ships in 0.1.10; the installed development Mac runs an
unreleased 0.1.10 build from `1f980121`, and the public release is still 0.1.9.

The 2026-09-10 review of that work found four follow-ups, fixed on the
`security-followups` branch: relay clients renew their authorization on the open
socket instead of being closed every five minutes; cache deadlines are placed on
the phone's clock instead of trusting the relay's stamps; a removed phone can be
allowed again with a new link code generated on the Mac; and Mac-to-phone
signaling authorization is cached for two minutes instead of three database
reads per message. The E2E encryption design (`docs/architecture/relay-e2e-design.md`)
is deferred, not approved.

Next: release 0.1.10 from `main` after those fixes merge (rebuild, install and
upgrade smoke, re-record the agent-app and Mac-app evidence at the merged commit,
tag, GitHub release, Homebrew cask, deploy), then return to the product backlog.

Paused product-audit slice: First-Run Activation. Use
`docs/product-audit-backlog.md` as the durable queue. After completing the
active slice, record validation evidence there and mark the next queued slice
active so follow-up work does not depend on chat history.

## Working rule

Use local-first iteration and one consolidated push. Update the support matrix only
when current evidence changes a public claim.
