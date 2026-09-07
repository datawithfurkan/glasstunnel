# Security Reconciliation

Started: 2026-09-06. Baseline: `8f7305fc`.

This is the initial reconciliation evidence, not current deployment status.
Subsequent stages 1-4 shipped in source/hosted services by 2026-09-07; the newer
Mac security code still awaits a binary release. Use
[current loop state](current-loop-state.md) and the
[security hardening plan](architecture/security-hardening-plan.md) for the active
gate, rollout evidence and E2E design decision. Historical local-only statements
below describe this initial pass.

## Task Packet

- Objective: reconcile dependency security, hosted transport/privacy claims, and
  browser content lifetime before further product development.
- User-visible behavior: chat details must not survive a session/account boundary;
  public descriptions must distinguish WebRTC from the hosted content relay.
- Touched surfaces: JS dependency graph, PWA session/transcript state, public site
  copy, security documentation and audit checks.
- Out of scope: 0.1.10 publication, signing/notarization, production deployment,
  new encryption protocols, adapter redesign, factory activation, personal accounts.
- Validation: focused failing/passing PWA tests; dependency audit; workspace
  build/test/lint; Worker type/runtime/build tests; security/privacy and public
  repository audits; diff review. Browser fixtures if changed rendering warrants it.
- Execution: single driver, local-first. Preserve other worktrees and the installed
  app. No hosted CI until the completed batch has local validation.

## Sequence

1. Baseline alignment: complete. Clean primary main fast-forwarded 17 commits;
   the pending release branch and all other worktrees were left untouched.
2. Dependencies: complete locally. Patched alerts #47-53 with fast-uri 3.1.6,
   browserslist 4.28.7 and postcss-selector-parser 6.1.3. Overrides stay within
   affected major versions. Installed the frozen lockfile before checking the
   resolved dependency graph. The npm audit reports no known vulnerabilities.
3. Browser content boundaries: complete for this slice. Expanded details are
   scoped by agent and message, cleared with workspace teardown, and protected
   against stale transport callbacks. Account loss/switching drops the previous
   connection before asynchronous registration; failed remote logout still clears
   local content. Session synchronization checks freshness after host persistence.
   Nine focused regression tests cover these boundaries.
4. Security truth: complete for the inspected paths. Corrected README, site,
   security model and known limitations. Removed false requirements from the audit;
   added actual device-key/signature and browser-content boundary tests. These
   checks do not prove immediate hosted revocation or application-layer encryption.
5. Verification and handoff: complete for this local slice. No production change,
   release, signing operation, or GitHub Actions run was initiated. The broader
   security queue below remains open.

## Initial Evidence

- GitHub reports four fast-uri alerts patched by 3.1.6, two browserslist alerts
  patched by 4.28.7, and one postcss-selector-parser 6.x alert patched by 6.1.3.
- The hosted relay handles parsed content and persists recent-message snapshots.
  WebRTC transport encryption does not protect that separate relay content path
  from infrastructure operators.
- The PWA's expanded-message cache is keyed only by message ID and has no reset
  accompanying existing session teardown paths.
- The local lab doctor passed. No owned lab manifest was present; an existing
  listener on the Supabase port belongs to pre-existing state and was not stopped.

## Next Security Queue

Complete these in order before returning to the product-audit queue. Each item
needs a separate focused task packet and negative tests; do not silently treat
documentation changes as implementation.

1. **Authorization and active-session revocation.** Trace the Mac registry,
   Supabase device ownership, hosted relay sessions, and WebRTC session lifetime
   as one lifecycle. Make revoked or removed devices lose access on existing as
   well as new connections, including after Durable Object hibernation. Verify
   host registration/revocation checks and prevent old connections from continuing
   to publish content or execute commands after authorization changes. Keep the
   Access UI truthful about pending, confirmed and failed revocation.
2. **Host-owned control permissions.** Define which read-only/lock settings are
   user convenience and which are security policy. Enforce security policy on
   the host for every action, independent of browser controls, with multiple-client
   and forged-command tests. Do not advertise a per-device administrator policy
   until one exists.
3. **Content lifetime.** Establish a bounded hosted snapshot retention/deletion
   policy and account-scoped browser cache lifecycle. Cover logout, removed Macs,
   offline recovery and stale asynchronous writes. Current changes clear live
   browser content; they do not implement secure erasure of IndexedDB snapshots.
4. **Application-layer end-to-end encryption decision.** Decide explicitly whether
   the hosted relay remains a trusted content processor. An E2E design needs peer
   authentication, key rotation, multi-device onboarding, revocation, recovery and
   compatibility work; WebRTC alone does not encrypt the separate JSON/JPEG path.

These are code-inspection findings and missing guarantees, not evidence of a
known breach. Live adversarial testing and an independent security review have
not been performed in this pass. Do not restore the superseded privacy claims.

## Local Verification

- `pnpm install --frozen-lockfile`, `pnpm audit --audit-level low`: passed.
- `pnpm build`, `pnpm test`, `pnpm lint`: passed. Final tests covered 238 PWA,
  22 Worker and 7 shared-crypto cases. The final PWA build and the nine new
  privacy tests also passed after the session-freshness guard was added.
- `pnpm qa:security-privacy`: passed, including local registry, redaction,
  device-key/signature, session-routing, Settings and browser-boundary tests.
- `pnpm qa:public-repo`, `pnpm qa:public-remote-refs`, `git diff --check`: passed.
- `pnpm worker:typecheck`: passed; workspace build/test also covered the Worker.
- `pnpm agent:validate`: used to select changed-surface checks.
- Existing mobile fixture suite: 16 tests passed across Chromium and WebKit.
  Browser fixture checks do not prove real account revocation or physical Safari.
- Site: desktop 1440 x 1000 and mobile 393 x 852; security/FAQ text rendered,
  disclosure opened, no page/console errors or horizontal overflow. Playwright
  used because the Browser plugin/skill was not available in this session.
- Temporary loopback servers only; no signed app, personal account, TCC or
  Keychain state changed. Both owned servers were stopped after testing and their
  ports verified free. Raw screenshots remain outside Git.
- Existing warnings remain: the PWA main bundle exceeds Vite's 500 kB warning
  threshold, and Node emits a localStorage test-runner warning. Neither failed
  the checks; neither was hidden by relaxing validation.

## Advisory Sources

- [fast-uri advisory and affected versions](https://github.com/advisories/GHSA-5jgf-p345-68v8)
- [browserslist memory exhaustion](https://github.com/advisories/GHSA-c83g-rgw3-j3cx)
- [browserslist custom-statistics handling](https://github.com/advisories/GHSA-73wf-gq98-2v4g)
- [postcss-selector-parser recursion](https://github.com/advisories/GHSA-w9m9-85wc-3x92)

## Shipping Boundary

Moving hosted content to application-layer end-to-end encryption requires a
separate protocol/key-management design and compatibility plan. Correcting claims
does not implement that protection. Hosted content retention and revocation also
need explicit bounded guarantees backed by tests before they are advertised.

This batch is local until coordinated publication. No protected-branch bypass,
production deploy, release tag or notarization submission is part of this task.
GitHub alerts and the public website will not reflect the patch until the normal
reviewed integration and deployment steps have completed.
