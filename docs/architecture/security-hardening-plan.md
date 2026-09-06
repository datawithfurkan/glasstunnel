# Security Hardening Implementation Plan

> Execution: single driver using `superpowers:executing-plans`,
> `test-glasstunnel-locally`, and `human-in-loop-telegram`. No factory or subagents.

**Goal:** Deliver the existing security fixes, then verify access revocation,
host-owned control permissions, and content lifetime before designing full E2E
encryption or returning to product features.

**Architecture:** Keep the existing Swift host, React PWA, Cloudflare relay and
Supabase account model. Treat authentication, permission changes and revocation as
one cross-surface lifecycle. Use authenticated server/host decisions rather than
trusting browser UI state. Stage 5 is a design decision, not permission to invent
or deploy a new cryptographic protocol.

**Tech stack:** Swift/CryptoKit/WebRTC, TypeScript/React/Zustand, Cloudflare Workers
and Durable Objects, Supabase, Vitest, XCTest and Playwright.

**Spec:** [Security reconciliation](../security-reconciliation.md),
[security model](../security.md), [agent workflows](../agentic-workflows.md),
and [UI parity](../agent-ui-contract.md).

## Global Constraints

- This is finite staged execution, not an unattended goal loop.
- Preserve existing changes, other worktrees, the installed app and its account,
  Keychain, TCC permissions, and the unfinished 0.1.10 release branch.
- Use disposable local identities. Never test adversarial commands against a
  personal account or production infrastructure.
- Iterate locally; one consolidated review-branch push per completed stage.
- Honor protected-main checks and the required approving review. No administrator
  bypass, self-approval, force-push or weaker branch protection.
- Inspect one resulting CI run per push. A main merge may trigger the repository's
  separate automatic confirmation run; do not dispatch or rerun CI manually.
- Production deployment is a separate explicit approval point. Confirm an exact
  reviewed commit, surfaces, rollback reference and compatibility before dispatch.
- A failed check is investigated locally; two attempts without new evidence require
  a new diagnostic or a blocker record, not repeated retries.
- Telegram is for required human review, approval, credentials or permissions,
  not ordinary implementation/test failures.
- Raw traces, tokens, account data and screenshots stay outside public Git.
- A stage does not pass because documentation describes the intended protection.
  Evidence must demonstrate the actual boundary and its visible UI state.
- Low-level implementation contracts for stages 2-4 are finalized from the current
  reviewed baseline when that stage opens; do not pre-build later stages into the
  first patch. Their acceptance criteria below remain mandatory.

## Progress And Gates

| Stage | Current status | Exit gate |
| --- | --- | --- |
| 1. Existing patch | In progress: reviewed locally; preparing PR | Required review/checks, approved deployment and bounded verification |
| 2. Revocation | Queued | Active/new sessions denied across relay and WebRTC; UI confirmation is truthful |
| 3. Permissions | Queued | Host policy rejects unauthorized actions regardless of browser behavior |
| 4. Retention | Queued | Tested expiry/deletion and account-scoped cache behavior |
| 5. E2E design | Queued, design only | Maintainer approves the threat model and migration design |

Advance only when the current stage's gate passes. A human-gated stage stays open;
record the exact next action and send one Telegram message. While waiting, read
or refine downstream plans, but do not claim completion or start another product
feature. A later stage may be opened locally only if the maintainer explicitly
changes this sequence. Keep First-Run Activation paused and preserve its backlog.

## Stage 1: Deliver The Existing Patch

**Input:** local commit `70fa8051`, based on `8f7305fc`. No Mac implementation or
protocol schema changes in this patch.

**Files already changed:** `package.json`, `pnpm-lock.yaml`,
`apps/mobile-pwa/src/lib/store.ts`, `storePrivacy.test.ts`,
`apps/mobile-pwa/src/agents/TranscriptView.tsx`, `README.md`, `site/index.html`,
`scripts/security-privacy-audit.sh`, `docs/security.md`,
`docs/known-limitations.md`, `docs/current-loop-state.md`, and
`docs/security-reconciliation.md`.

- [x] Fetch upstream and verify no unrelated changes or merge conflicts.
- [x] Read the patch and inspect the existing session, cache and auth boundaries.
- [x] Verify GitHub protection and workflow triggers. `main` requires five checks
  and one approving review. Review branches run CI when a PR is opened, not on
  their ordinary branch push. Deploy uses `workflow_dispatch` only.
- [x] Refresh local validation for the exact review candidate:

```sh
pnpm agent:validate
pnpm install --frozen-lockfile
pnpm audit --audit-level low
pnpm build
pnpm test
pnpm lint
pnpm worker:typecheck
pnpm qa:security-privacy
pnpm qa:public-repo
git diff --check
```

Validation refreshed on 2026-09-06: frozen install, dependency audit (zero known
vulnerabilities), build, 267 workspace tests, lint, Worker and workspace typechecks,
and the security/privacy audit passed. The latter includes 34 targeted Swift
tests and the nine PWA privacy regressions. Public repository/ref and whitespace
checks passed. Browser evidence for the unchanged runtime patch is recorded in
`docs/security-reconciliation.md`; it was not repeated for this plan-only change.
Existing bundle-size and Node localStorage warnings remain non-failing.

- [ ] Commit this plan and handoff updates; push `codex/security-reconciliation`
  once and open a PR to `main`. Include prior browser evidence and current test
  results. State explicitly that hosted revocation and E2E are not implemented.
- [ ] Inspect the PR's single CI run. If it fails, diagnose the logs and reproduce
  locally before considering one corrective push. Do not rerun a successful job.
- [ ] Obtain the required review. The CLI uses the maintainer's GitHub account;
  that account cannot approve its own PR. Request an eligible independent
  reviewer through Telegram, never manufacture a second identity or bypass.
- [ ] Merge through the normal protected workflow after its gates pass.
- [ ] Obtain approval to deploy the exact merged SHA; record the current deployed
  web/Worker revisions first. The current Deploy workflow redeploys the PWA, site
  and Worker together. Do not assume Worker code is unchanged relative to what is
  actually deployed merely because this PR has no Worker source diff.
- [ ] Dispatch Deploy once for that SHA; inspect its result. Verify public security
  copy, app-shell/service-worker delivery and a non-destructive compatibility
  canary. No Mac release, signing, notarization or version bump is required here.
- [ ] Record PR, immutable CI/deploy URLs, exact SHA and canary result. Verify
  Dependabot state once after integration; indexing delay is not a reason to push.

**Acceptance:** the reviewed patch reaches users, the source and website describe
the real relay trust boundary, CI passes, rollback is recorded, and no claim is
made that a clean dependency audit proves complete product security.

## Stage 2: Authorization And Active-Session Revocation

**Inspect/modify:** `apps/cloudflare-signal/src/index.ts` (`upsertUserDevice`,
`ensurePairing`, `SignalingHub.authorizeAccountEnvelopeToHost`, `RelayHub` auth,
message routing and alarm), `apps/host-macos/Sources/Security/DeviceRegistry.swift`,
`apps/host-macos/Sources/Transport/SessionManager.swift`, `Session.swift`,
`RelayClient.swift`, `apps/host-macos/Sources/App/AppState.swift`,
`apps/host-macos/Sources/App/UI/AccessView.swift`,
`apps/mobile-pwa/src/transport/RelayConnection.ts`, and `src/lib/store.ts`.

**Tests:** extend `apps/cloudflare-signal/test/relayHub.test.ts`,
`apps/host-macos/Tests/GTSecurityTests/DeviceRegistryTests.swift`,
`apps/host-macos/Tests/GTTransportTests/SessionManagerTests.swift`,
`apps/mobile-pwa/src/lib/storePrivacy.test.ts`; add
`tests/e2e/account-revocation.spec.ts` for a disposable two-client journey.

- [ ] Specify one revocation operation and acknowledgement across Mac registry,
  account authorization, relay and WebRTC. Define pending/failure behavior before
  changing transport code. A same-device revocation must survive reconnect,
  registration, process restart and restoration from Durable Object attachments.
- [ ] Write failing tests for a connected client's next command and next content
  delivery after revocation, plus reconnection and cache replay. Use the existing
  test socket/Supabase helpers with disposable keys; assert no content or command
  reaches the revoked peer, not merely that a registry flag changed.
- [ ] Cover missing/revoked/wrong-owner host records and mismatched keys, expired
  authentication, stale authorization caches, hibernation, concurrent clients,
  and registration that would otherwise reset `revoked_at`.
- [ ] Persist denial before confirming revocation; close or invalidate affected
  sessions on every path and refuse further dispatch. Fail closed on unresolved
  authorization. Retain a durable deny/tombstone when removing a UI row would
  otherwise cause same-account auto-authorization to re-add that device.
- [ ] Make Access show pending, confirmed and retryable failure states. Make the
  affected browser leave the workspace with an access-lost explanation and stop
  automatic reconnect attempts that could restore stale content.
- [ ] Run targeted Worker, Swift and PWA tests, full Swift tests, and the new local
  account E2E. Inspect native Access UI only when deterministic tests cannot prove
  the state presentation. Preserve all personal permissions and installed apps.
- [ ] Review the diff and demonstrate both immediate local cutoff and the defined
  server acknowledgement. Follow stage 1's reviewed shipping gate. Any Mac binary
  publication is a separate approved release operation.

**Acceptance:** a revoked existing identity cannot read new/cached remote content
or execute another operation through any active or new session. UI confirmation
means the declared cutoff is acknowledged. Revoking a device is not advertised
as securing an account whose credentials an attacker still controls.

## Stage 3: Host-Owned Control Permissions

**Inspect/modify:** `apps/host-macos/Sources/Security/AutoLock.swift`,
`apps/host-macos/Sources/Transport/Session.swift`, `SessionManager.swift`,
`apps/host-macos/Sources/App/AppState.swift` and its Settings/Access views,
`apps/mobile-pwa/src/lib/store.ts`, `src/ui/TopBar.tsx`, and command surfaces.

**Tests:** `AutoLockTests.swift`, `SessionManagerTests.swift`,
`apps/mobile-pwa/src/lib/store.test.ts` and local account E2E.

- [ ] Inventory every remote action and classify observe/control/admin behavior.
  Include shell input, app launch, prompts, settings changes, attachments, clicks,
  clipboard-like input, stop/recovery and remote read-only changes.
- [ ] Add failing tests sending control actions through both relay and DataChannel
  while the host denies control. Include a modified browser attempting to relax
  read-only mode and two browsers with conflicting settings.
- [ ] Keep the Mac authoritative. A browser may request less access but cannot
  relax a host restriction. Validate at dispatch, including asynchronous actions
  that were queued before the permission changed.
- [ ] Reflect effective permissions in Mac and web controls with visible denied
  results. Do not silently discard commands or claim successful execution.
- [ ] Run targeted and full Swift tests, PWA build/test/lint, protocol checks if
  changed, and disposable-account command tests. Ship through the same gates.

**Acceptance:** hiding/disabling a web button is not the enforcement mechanism;
the host rejects the same unauthorized message sent directly over either transport.

## Stage 4: Bounded Content Lifetime

**Inspect/modify:** `apps/cloudflare-signal/src/relaySnapshotCache.ts`,
`RelayHub` persistence/alarm in `src/index.ts`,
`apps/mobile-pwa/src/lib/store.ts`, profile/cache controls, and `docs/security.md`.

**Tests:** `apps/cloudflare-signal/test/relaySnapshotCache.test.ts`,
`relayHub.test.ts`, `apps/mobile-pwa/src/lib/storePrivacy.test.ts`, and the local
account/offline-recovery journey.

- [ ] Propose exact retention durations and deletion semantics for operator and
  user review before deleting existing hosted data. Distinguish normal logout,
  local offline cache, device removal, account removal and provider backups.
- [ ] Write deterministic-clock tests for just-before/at/after expiry, restored
  Durable Objects, malformed or missing timestamps, and legacy stored snapshots.
- [ ] Key browser caches by account and host; deny cross-account restore. Test a
  stale asynchronous write racing with logout/removal so erased content cannot
  reappear. Keep expanded tool details out of persistent caches.
- [ ] Implement read-time expiry plus bounded background deletion, including while
  the host is offline. Do not rely solely on a size cap or future user traffic.
- [ ] Explain empty/expired/offline cache states in the PWA. Document which content
  is erased and which provider logs/backups are outside that guarantee.
- [ ] Run Worker runtime tests, PWA tests/build/lint and local offline E2E; review
  migration behavior before the approved deployment.

**Acceptance:** expired or wrong-account content is not returned; deletion is
bounded and verifiable, including after restart, without erasing unrelated users.

## Stage 5: E2E Architecture Decision, Not Implementation

**Create:** `docs/architecture/relay-e2e-design.md` after stages 2-4 pass.

- [ ] Define the threat model: what a compromised relay/operator may read, replace,
  replay or suppress; endpoint compromise and availability remain separate risks.
- [ ] Compare keeping the disclosed trusted relay with application-layer E2E using
  maintained protocols/libraries. Research current primary documentation, license,
  maintenance and Swift/browser interoperability; do not select home-grown crypto.
- [ ] Specify identity verification, key distribution/rotation, multi-device
  enrollment, revocation, recovery, encrypted offline state and metadata leakage.
- [ ] Specify capability negotiation and rollout across old/new PWA, Worker and
  Mac versions. Never silently downgrade a promised encrypted session to plaintext.
- [ ] Provide a migration/rollback plan, concrete test vectors and an independent
  security-review requirement. Estimate implementation scope from the chosen design.
- [ ] Present the decision and tradeoffs to the maintainer, then stop for approval.

**Acceptance:** an approved, testable design and migration plan. No encryption
rollout or claims change merely because a design document exists.

## Handoff Record

Update this section and `docs/current-loop-state.md` when a gate changes, not on
every check. Use the PR/check/deploy URLs as external evidence without creating
extra documentation-only CI runs while an approval is pending.

- Active stage: 1.
- Working branch: `codex/security-reconciliation`.
- Patch source: `70fa8051`; plan is a documentation-only descendant.
- Production authority: not yet granted for a specific deployment.
- Review authority: required GitHub approving review remains a real human gate.
- Local validation: passed for the security patch and this plan on 2026-09-06.
- Next action: commit the plan, open the review PR and inspect its one CI run;
  obtain the required independent approving review before merge.
- Later stages remain queued; no changes to their runtime behavior are claimed.
