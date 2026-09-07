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
- Use protected PRs with all five strict status checks. On 2026-09-06 the sole
  maintainer explicitly authorized zero required contributor approvals. Review
  the diff and evidence before merging; do not fabricate an independent review.
  Keep conversation resolution, linear history, and force-push/deletion blocks.
  No administrator bypass or further protection change without authorization.
- Inspect one resulting CI run per push. A main merge may trigger the repository's
  separate automatic confirmation run; do not dispatch or rerun CI manually.
- On 2026-09-06 the maintainer approved the proposed `da9a1bc3` production rollout
  and instructed the driver to continue necessary steps in this plan without
  asking again for routine actions. Confirm exact commits, surfaces, rollback
  references and compatibility before each planned deployment. Escalate only
  genuinely new decisions, unavailable access or a material change in risk;
  this is not authority for unrelated releases, destructive data changes or E2E
  implementation.
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
| 1. Existing patch | Complete; deployed and verified 2026-09-06 | Protected PR/checks, approved deployment and bounded verification |
| 2. Revocation | Complete in source and hosted services; Mac binary publication remains separate | Active/new sessions denied across relay and WebRTC; UI confirmation is truthful |
| 3. Permissions | Complete in source and hosted services; Mac binary publication remains separate | Host policy rejects unauthorized actions regardless of browser behavior |
| 4. Retention | Local gates passed 2026-09-07; protected rollout and hosted sweep pending | Tested expiry/deletion and account-scoped cache behavior |
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
- [x] Verify GitHub protection and workflow triggers. `main` requires five checks;
  the original one-review rule was changed to zero by explicit maintainer decision
  below. Review branches run CI when a PR is opened, not on their ordinary branch
  push. Deploy uses `workflow_dispatch` only.
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

- [x] Commit this plan and handoff updates; push `codex/security-reconciliation`
  once and open a PR to `main`. Include prior browser evidence and current test
  results. State explicitly that hosted revocation and E2E are not implemented.
- [x] Inspect the PR's single CI run. If it fails, diagnose the logs and reproduce
  locally before considering one corrective push. Do not rerun a successful job.
- [x] Resolve the review-policy gate. Telegram reached the maintainer, who
  confirmed sole ownership and explicitly removed the requirement for another
  contributor approval. Set only `required_approving_review_count` to zero;
  verify all five strict checks and the other protections remain unchanged.
- [x] Merge through the normal protected workflow after its gates pass.
  [PR #32](https://github.com/datawithfurkan/glasstunnel/pull/32) merged at
  `da9a1bc3659b33e480219e53226976eaef38d9ff`. Its five checks passed in
  [PR CI](https://github.com/datawithfurkan/glasstunnel/actions/runs/34042442055).
- [x] Obtain approval to deploy the exact merged SHA; record the current deployed
  web/Worker revisions first. The current Deploy workflow redeploys the PWA, site
  and Worker together. Do not assume Worker code is unchanged relative to what is
  actually deployed merely because this PR has no Worker source diff.
- [x] Dispatch Deploy once for that SHA; inspect its result. Verify public security
  copy, app-shell/service-worker delivery and a non-destructive compatibility
  canary. No Mac release, signing, notarization or version bump is required here.
- [x] Record PR, immutable CI/deploy URLs, exact SHA and canary result. Verify
  Dependabot state once after integration; indexing delay is not a reason to push.

After merge, the live Dependabot API reported zero open alerts on 2026-09-06.
This confirms advisory cleanup, not completion of the remaining security stages.

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

### Stage 2 Task Packet

- Objective: make an explicit Mac-side device revocation override same-account
  automatic trust for that Mac, including active sessions and reconnects.
- User-visible behavior: the Mac cuts off local access first, shows confirmation
  pending until the relay/account denial is durable, and offers a retry after
  failure. The browser clears the workspace, exits to its Mac list and stops
  reconnecting after an access-revoked close (4003). Other Macs are unaffected.
- Authority: a signed host signaling connection requests revocation. The Worker
  verifies the registered host key, role and account ownership. Its per-host
  RelayHub persists a denial tombstone before acknowledgement and records the
  revoked account pairing. The signaling path must retain/filter the same deny
  decision, including cached authorizations and queued envelopes.
- Local persistence: removing a device row must not delete its denial. No API
  here re-enables a revoked identity implicitly; account registration must not
  reset revocation or overwrite an existing host identity.
- Cross-surface files: Worker auth/routing, Mac registry/session manager/Access,
  PWA connection/store and focused tests. No protocol-schema or new crypto work.
- Validation: failing-then-passing Worker boundary tests, Swift registry/session
  and UI state tests, PWA privacy tests, a disposable two-browser local journey,
  then the existing compatibility lane. No personal account or installed app.
- Out of scope: permission policy (stage 3), content retention (stage 4), E2E
  implementation, and a new Mac binary publication. Stage 2 stays open until
  the complete cutoff and truthful acknowledgement are demonstrated.
- Current evidence: invalid/missing/revoked relay host records, revoked pairing
  reconnects, registration identity overwrite, concurrent registration revocation,
  browser access-loss behavior, and RelayHub cutoff/authentication races have
  focused local coverage. This is partial evidence, not the stage exit gate.

- [x] Specify one revocation operation and acknowledgement across Mac registry,
  account authorization, relay and WebRTC. Define pending/failure behavior before
  changing transport code. A same-device revocation must survive reconnect,
  registration, process restart and restoration from Durable Object attachments.
- [x] Write failing tests for a connected client's next command and next content
  delivery after revocation, plus reconnection and cache replay. Use the existing
  test socket/Supabase helpers with disposable keys; assert no content or command
  reaches the revoked peer, not merely that a registry flag changed.
- [x] Cover missing/revoked/wrong-owner host records and mismatched keys, expired
  authentication, stale authorization caches, hibernation, concurrent clients,
  and registration that would otherwise reset `revoked_at`.
- [x] Persist denial before confirming revocation; close or invalidate affected
  sessions on every path and refuse further dispatch. Fail closed on unresolved
  authorization. Retain a durable deny/tombstone when removing a UI row would
  otherwise cause same-account auto-authorization to re-add that device.
- [x] Make Access show pending, confirmed and retryable failure states. Make the
  affected browser leave the workspace with an access-lost explanation and stop
  automatic reconnect attempts that could restore stale content.
- [x] Run targeted Worker, Swift and PWA tests, full Swift tests, and the new local
  account E2E. Inspect native Access UI only when deterministic tests cannot prove
  the state presentation. Preserve all personal permissions and installed apps.
- [x] Review the diff and demonstrate both immediate local cutoff and the defined
  server acknowledgement. Follow stage 1's reviewed shipping gate. Any Mac binary
  publication is a separate approved release operation.

**Acceptance:** a revoked existing identity cannot read new/cached remote content
or execute another operation through any active or new session. UI confirmation
means the declared cutoff is acknowledged. Revoking a device is not advertised
as securing an account whose credentials an attacker still controls.

### Stage 2 Local Evidence (2026-09-06)

- Worker: 45 runtime tests pass, including real signed WebSocket authentication,
  revocation races, failed database writes/retry, hibernation with revoked/expired
  attachments, offline signaling and per-Mac denial. Typecheck/build passed.
- Mac: 452 tests pass with eight environment-gated skips. Focused tests cover local
  persistence, removal tombstones, stopped DataChannel dispatch, relay dispatch,
  offline/unconfirmed revocation, upload isolation and Access status presentation.
- PWA: 242 tests pass, including 13 privacy cases covering revoked-session cleanup
  and ordinary expiry recovery. Build and lint pass.
- `node scripts/lab/e2e.mjs revocation`: passed with disposable local Supabase,
  Worker, Swift host and two independent Chromium browsers. The first browser loses
  its composer and host entry after Mac acknowledgement; the second still executes
  a marker command. Markers use split arguments so an echoed command cannot satisfy
  the output assertion, and use a newly created, lab-owned Terminal session.
  Reload cannot restore the revoked host. The existing account
  Terminal and desktop/mobile fixture lanes also passed.
- Inspected the local phone screenshot: clear revocation notice, no workspace or
  composer, and no remaining host entry. Raw image stays ignored. Native Access
  presentation is covered by deterministic state tests, not a new personal-app launch.
- A restart test initially held an unconsumed response body, preventing runtime
  eviction; draining it fixed the test without skipping hibernation. An early full
  Swift run had one failure while Terminal E2E was also running; isolated final
  full runs passed. Avoid overlapping those native test lanes.
- New relay-only browser trust notifications and immediate reconnect after host
  linking preserve first-link behavior with strict host-record authorization.
- The isolated two-browser test exposed an existing cached-greeting bug: after
  online presence arrived, replaying the greeting incorrectly added an offline
  error and disabled the composer until fresh output arrived. A failing unit
  regression confirmed the cause; preserving online presence fixed both the
  deterministic test and the real two-browser journey. No speculative Terminal
  adapter changes were made. Status-only test evidence stays in ignored artifacts.
- Partial relay uploads are keyed by device plus transfer ID and removed on local
  revocation. Already persisted attachment files are not erased by this operation.
- Publication limitation: no version bump, binary release, installed-app replacement,
  Keychain/TCC reset or personal account mutation. The 0.1.9 public binary still
  needs a separately coordinated release before the new Mac action reaches users.

## Stage 3: Host-Owned Control Permissions

### Stage 3 Task Packet

- Objective: a browser cannot relax the Mac's read-only restriction or change
  another browser's voluntary restriction. Enforce policy at command dispatch.
- User-visible behavior: persist the Mac Settings restriction and publish it to
  connected browsers; show effective read-only status and disable mutation
  controls. Rejected forged requests receive a visible explanation.
- Authority: AutoLock owns host policy plus per-device voluntary restrictions;
  both relay and DataChannel consult the same effective decision. Host policy
  is changed only by the local Mac. An additive optional Hello field advertises
  the host restriction; absent fields do not claim enforcement on older hosts.
- Action inventory: input/prompts/quick replies, attachments, pointer events,
  input-request answers, interrupt, target selection/rename, model settings and
  app lifecycle actions are control. Message detail and existing streams are
  observation. Heartbeat and video delivery hints are transport maintenance;
  obsolete grid/redaction updates remain non-operative. Screen stop is not an
  exception to read-only control policy. Idle-lock recovery behavior is unchanged.
- Validation: adversarial relay/DataChannel tests, two-client isolation, queued
  dispatch regression, optional-field compatibility, web permission states and
  disposable local account E2E. Full Swift plus touched surface checks follow.
- Out of scope: manual lock redesign, retention, installed app replacement,
  release/signing/TCC and E2E encryption.

**Inspect/modify:** `apps/host-macos/Sources/Security/AutoLock.swift`,
`apps/host-macos/Sources/Transport/Session.swift`, `SessionManager.swift`,
`apps/host-macos/Sources/App/AppState.swift` and its Settings/Access views,
`apps/mobile-pwa/src/lib/store.ts`, `src/ui/TopBar.tsx`, and command surfaces.

**Tests:** `AutoLockTests.swift`, `SessionManagerTests.swift`,
`apps/mobile-pwa/src/lib/store.test.ts` and local account E2E.

- [x] Inventory every remote action and classify observe/control/admin behavior.
  Include shell input, app launch, prompts, settings changes, attachments, clicks,
  clipboard-like input, stop/recovery and remote read-only changes.
- [x] Add failing tests sending control actions through both relay and DataChannel
  while the host denies control. Include a modified browser attempting to relax
  read-only mode and two browsers with conflicting settings.
- [x] Keep the Mac authoritative. A browser may request less access but cannot
  relax a host restriction. Validate at dispatch, including asynchronous actions
  that were queued before the permission changed.
- [x] Reflect effective permissions in Mac and web controls with visible denied
  results. Do not silently discard commands or claim successful execution.
- [x] Run targeted and full Swift tests, PWA build/test/lint, protocol checks if
  changed, and disposable-account command tests. Ship through the same gates.

**Acceptance:** hiding/disabling a web button is not the enforcement mechanism;
the host rejects the same unauthorized message sent directly over either transport.

### Stage 3 Local Evidence (2026-09-06)

- Seven adversarial transport tests pass after reproducing the host-policy override
  and cross-browser interference. Both transports recheck queued dispatch. An
  exhaustive action classifier makes new protocol cases choose an access boundary.
- Full Swift: 462 tests, eight environment-gated skips, zero failures. Includes
  persisted Settings, host-policy notifications and optional Hello compatibility.
- PWA: 244 tests pass, including a failing-then-passing legacy-host regression.
  Permission updates are sent only when a host advertises the new capability;
  older hosts cannot be accidentally placed in global read-only mode by this PWA.
- Worker: 46 tests pass; targeted denial snapshots reach only the intended client
  and are not persisted as shared app state. Worker typecheck and dry build pass.
- The local two-browser permission/revocation journey passed. Both browsers saw
  the Mac restriction, all relevant controls disabled, and only the forged-request
  sender saw its denial. The forged command produced no execution marker. Clearing
  Mac policy restored input; one browser's voluntary restriction left the other
  able to run a marker. Revocation still removed only the revoked browser's access.
- Inspected the ignored phone screenshot: readable host-policy banner, disabled
  composer/session controls, preserved Terminal output and a visible denial.
  No personal account, installed app, TCC, Keychain or screen capture was changed.
- Ordinary account/Terminal, desktop/mobile Chromium fixtures and mobile WebKit
  fixtures passed. PWA build/lint, protocol generation/build, lab unit tests,
  security/privacy and public audits, and whitespace validation passed.
- Protected PR #34 merged at `cc3377b1c2cbb283aadde58ec1eeb351048ce22c`;
  the tree equals tested `73314330`. All five checks passed in CI `34061166134`.
  Deploy `34061593757` passed for both hosted jobs. Isolated Chromium/WebKit
  shell and reload canaries passed without page errors; public PWA/site,
  service worker and signaling health returned 200. Service worker remains
  `public, no-cache, must-revalidate`. Deployment IDs appear in the handoff below.
  A new Mac release is separate; source/hosted integration is not binary delivery.

## Stage 4: Bounded Content Lifetime

The concrete decision and migration proposal is
[`content-retention-proposal.md`](content-retention-proposal.md). Recommended:
24-hour offline replica lifetime, account-scoped browser caches, clearing on
sign-out/removal, and discarding legacy copies with unverifiable age/ownership.
This does not delete original chats or files. Policy approval was received on
2026-09-07. Runtime implementation and local validation are active; hosted
deletion has not yet occurred.
One deduplicated Telegram policy-decision notification was delivered on
2026-09-06. There is no repeated authentication or routine approval gate.

**Inspect/modify:** `apps/cloudflare-signal/src/relaySnapshotCache.ts`,
`RelayHub` persistence/alarm in `src/index.ts`,
`apps/mobile-pwa/src/lib/store.ts`, profile/cache controls, and `docs/security.md`.

**Tests:** `apps/cloudflare-signal/test/relaySnapshotCache.test.ts`,
`relayHub.test.ts`, `apps/mobile-pwa/src/lib/storePrivacy.test.ts`, and the local
account/offline-recovery journey.

- [x] Propose exact retention durations and deletion semantics for operator and
  user review before deleting existing hosted data. Distinguish normal logout,
  local offline cache, device removal, account removal and provider backups.
- [x] Write deterministic-clock tests for just-before/at/after expiry, restored
  Durable Objects, malformed or missing timestamps, and legacy stored snapshots.
- [x] Key browser caches by account and host; deny cross-account restore. Test a
  stale asynchronous write racing with logout/removal so erased content cannot
  reappear. Keep expanded tool details out of persistent caches.
- [x] Implement read-time expiry plus bounded background deletion, including while
  the host is offline. Do not rely solely on a size cap or future user traffic.
- [x] Explain empty/expired/offline cache states in the PWA. Document which content
  is erased and which provider logs/backups are outside that guarantee.
- [x] Run Worker runtime tests, PWA tests/build/lint and local offline E2E; review
  migration behavior before the approved deployment.

**Acceptance:** expired or wrong-account content is not returned; deletion is
bounded and verifiable, including after restart, without erasing unrelated users.

### Stage 4 Task Packet And Local Evidence (2026-09-07)

- Objective: enforce the approved replica lifetime without altering original
  chats/files, identities, credentials, attachment files or denial tombstones.
- Surfaces: Worker persistent/read-time expiry and count-only operator RPC;
  account/Mac-scoped browser storage, expiry feedback, Profile clearing and
  sign-out lifecycle. Protocol timing/manifest fields are additive and negotiated.
  No new Mac control is appropriate for a browser-local cache action; host payloads
  remain compatible and the installed/public 0.1.9 binary is unchanged.
- 64 Worker tests, 261 PWA tests, 52 lab unit tests and three operator CLI tests
  pass. Workspace typecheck/build, PWA lint/build and shell syntax pass. Worker
  tests include restart, no-peer alarm deletion, pagination, legacy records,
  preserved tombstones and an injected cleanup failure followed by recovery.
- The real local two-account retention journey passes: isolated Supabase auth,
  Worker relay and Swift Terminal; browser-clock expiry, reload/reconnect,
  browser clearing, sign-out and a second account in the same browser profile.
  No production identity was used. Raw artifacts remain ignored.
- Inspected mobile screenshots: Profile confirms clearing and possible live
  refilling; an expired workspace contains no transcript and explains the retry.
  The test found a real logout race: login UI preceded saved-session cleanup.
  Pending/retry UI and regression tests now cover cleanup completion, stale auth
  events, failed storage deletion and preservation of other-account copies.
- 24 desktop/mobile Chromium and mobile WebKit fixtures passed against an isolated
  local PWA server. These are browser-engine tests, not physical iPhone evidence.
- Docker's VM became read-only during validation, preventing local Supabase startup.
  One Telegram escalation was delivered. The maintainer explicitly approved a
  Docker Desktop restart; it restored the test database/gateway to healthy state.
  No volumes or containers were deleted as part of that restart. Ordinary lab
  test resets affect only the disposable Glasstunnel test database.
- Ordinary account/Terminal and two-browser permission/revocation compatibility
  checks passed. The security/privacy audit (including targeted Swift policy and
  redaction checks), 617-file public-repository audit and whitespace check passed.
  Final protected integration, exact-SHA deploy and inventory/apply/verify remain
  the exit gate. Hosted cache deletion has not occurred. Stage 5 remains queued.

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

- Active stage: 4 approved implementation/validation. Stages 1-3 passed in source and hosted services. The public
  Mac binary still needs a separately coordinated release for the new host code.
- Working branch: `codex/security-retention`, from the tested stage 3 merge.
  Retention runtime changes, regression tests and the bounded migration operator
  are local; production deletion remains pending the inventory gate.
- Stage 2 merged source: `c4acdc2a62c4e43a67d4d653a8d907340a1706ed` via
  [PR #33](https://github.com/datawithfurkan/glasstunnel/pull/33). The merged tree
  exactly matches tested candidate `db998a2c`. All five protected checks passed
  in [PR CI](https://github.com/datawithfurkan/glasstunnel/actions/runs/34057336269).
- Production authority: the maintainer approved the proposed `da9a1bc3` rollout
  and routine continuation of this plan on 2026-09-06. Do not repeat that approval.
- Review authority: sole maintainer authorized zero contributor approvals;
  protected PRs and the five strict checks remain required.
- Local validation: passed for the security patch and this plan on 2026-09-06.
- Main CI: all five checks passed in the automatic post-merge confirmation,
  not a manually dispatched rerun:
  https://github.com/datawithfurkan/glasstunnel/actions/runs/34042927618
- Authentication: restored on 2026-09-06 using normal `wrangler login` with
  automatic browser opening and `--use-keyring`. The maintainer approved in
  Chrome. Account/user read, Pages and Worker-script scopes were requested;
  no credential values belong in this document. Read-only queries succeeded
  in separate CLI invocations. Earlier manually opened requests exceeded
  Wrangler's two-minute callback window; do not reuse their expired links.
- Deployment rollback baseline: before the rollout, production Pages records were PWA
  `4b447db0-75ea-4114-9a5b-284c1d4604f0` and site
  `2a0532e8-e4cc-4cbe-9292-2e2590a37fe0`, both source `44b8cb9`.
  The latest Worker deployment is `f2a0cda9-09c5-4089-a298-032b8f51fc81`,
  with 100% on version `c9deee67-e744-426a-a1c8-6dadaa567061`.
  These records match the timing of successful GitHub Deploy run `33844017476`.
  Recheck the active deployment immediately before any later rollback or release.
  Compared with that source revision, the candidate has no Worker/protocol
  source changes. No production mutation was made during authentication.
- Deployment: one dispatch for `da9a1bc3` succeeded:
  https://github.com/datawithfurkan/glasstunnel/actions/runs/34047515720
  PWA deployment `e0bc7bd0-f769-42ae-a7f3-1beb0a602c80` and site deployment
  `6c592a78-39ff-4323-8202-4b9d31b2a4ca` both report source `da9a1bc`.
  Worker deployment `46a2def2-dbb4-41f4-80b9-8d4bb6818adb` routes 100% to
  version `c7c5fb3d-5ef9-4da6-94ee-bd49f940154c`.
- Hosted canary: public PWA, site, service worker and signaling health returned
  HTTP 200. The PWA now serves `index-Cj-USp59.js`; the app shell and service
  worker retain `public, no-cache, must-revalidate`. Isolated mobile-viewport
  Chromium and WebKit contexts verified the relay disclosure, signed-out PWA
  rendering and reload, with zero page errors. No personal login, command,
  account mutation, Mac release or permission change was used.
- Stage 2 deployment: one dispatch for `c4acdc2a` succeeded in
  [Deploy](https://github.com/datawithfurkan/glasstunnel/actions/runs/34057717088).
  Production PWA `0ee8454e-8b06-45ff-9376-53cd2a018d84` and site
  `a95835e0-4d9a-42a4-bb54-deea91d8868c` report source `c4acdc2`.
  Worker traffic is 100% version `77737edb-4944-455d-8951-b4dd261e8e5b`.
  Immediate rollback references are the stage 1 deployments above. Isolated
  Chromium/WebKit mobile-view shell and reload checks passed with no page errors;
  service worker and signaling health returned 200, with service worker caching
  still `public, no-cache, must-revalidate`. No personal account was used.
- Stage 3 source: `cc3377b1c2cbb283aadde58ec1eeb351048ce22c`, normal protected
  [PR #34](https://github.com/datawithfurkan/glasstunnel/pull/34), with all five
  checks in [CI](https://github.com/datawithfurkan/glasstunnel/actions/runs/34061166134)
  passing. One consolidated review-branch push, no successful workflow rerun.
- Stage 3 hosted delivery:
  [Deploy](https://github.com/datawithfurkan/glasstunnel/actions/runs/34061593757)
  succeeded. PWA `78b3cc2f-80b9-42bb-b4d9-d4cc45673d39` and site
  `54f220ed-b496-4dd7-b68e-45287c598b7f` both report `cc3377b`; Worker traffic
  is 100% `e270b0d9-bae4-473f-a195-f1b5b05344a2`. The immediately preceding
  stage 2 deployment IDs above were freshly checked as rollback references.
  No storage migration, retention purge, Mac release or installed-app change.
- Next action: finish the approved stage 4 local
  deterministic-clock, cache-isolation and offline tests before one reviewed
  rollout. The lab is stopped. No routine approval or Cloudflare login is needed.
  Stage 5 remains queued and design-only. Do not bypass either substantive gate.
