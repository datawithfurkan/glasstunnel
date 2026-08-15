# Product Audit Backlog

Last updated: 2026-08-15.

This is the public-safe working backlog for the product audit. It summarizes
actionable items without committing raw local audit artifacts. Use this file as
the queue for product-hardening loops: finish the active slice, record evidence,
then mark the next highest-priority queued slice active.

## Status Values

- `active`: the current implementation slice.
- `queued`: verified enough to schedule, but not yet started.
- `verified`: fixed and validated; include evidence.
- `deferred`: intentionally postponed; include reason.
- `rejected`: checked against current code and not applicable; include reason.

## Slice Order

1. Connection Recovery Reliability.
2. Mobile Interaction Fitness.
3. First-Run Activation.
4. Supported Feature Coverage.
5. Performance And Polish.

## Verified Slice: Connection Recovery Reliability

Goal: mobile resume, focus, and network events must not thrash the relay, leak
superseded sockets, or bypass reconnect backoff when the Mac is offline.

| ID | Finding | Evidence | Status | Required validation | Evidence record |
| --- | --- | --- | --- | --- | --- |
| P0-1 | Concurrent recovery triggers can start overlapping reconnects. | CODE | verified | Lifecycle storm test proves one recovery/start path. | `src/lib/store.test.ts`: concurrent `recoverConnection` calls return one promise and create one relay. |
| P0-2 | Superseded relay startup can leave a connected orphan socket. | CODE | verified | Stale relay startup test proves disconnect on early return. | `src/lib/store.test.ts`: stale relay receives `disconnect()` when a newer start wins. |
| P0-3 | Incidental lifecycle events can bypass reconnect backoff. | CODE | verified | Backoff test proves focus/resume cannot restart during a pending timer. | `src/lib/store.test.ts`: `page-resume` does not create a new relay while reconnect timer is pending. |
| P1-4 | Browser `online` event force-restarts a healthy session. | CODE | verified | Lifecycle test proves `online` uses the healthy-session guard. | `src/app/lifecycleRecovery.test.ts`: `network-online` produces `forceRestart: false`; App debounces lifecycle bursts. |

Validation evidence for this slice:

- `pnpm --filter @glasstunnel/mobile-pwa test -- src/lib/store.test.ts src/app/lifecycleRecovery.test.ts`
- `pnpm --filter @glasstunnel/mobile-pwa test`
- `pnpm --filter @glasstunnel/mobile-pwa lint`
- `pnpm --filter @glasstunnel/mobile-pwa build`
- `pnpm lab:e2e` was attempted but local Supabase could not be started; `pnpm lab:status`
  and `pnpm lab:down` confirmed no owned Glasstunnel services remained running.

## Active Slice: Mobile Interaction Fitness

| ID | Finding | Evidence | Status | Required validation | Evidence record |
| --- | --- | --- | --- | --- | --- |
| P1-5 | Mobile touch targets are below the 44px product target. | MEASURED | active | Mobile viewport sweep for visible buttons. | Pending |
| P1-6 | Composer layout is not keyboard-aware. | NEEDS-DEVICE | active | Simulator Safari or local WebKit evidence with keyboard/focus notes. | Pending |
| P1-7 | Overflowing app strip hides supported features without enough affordance. | MEASURED | active | Fixture assertion that overflow is discoverable and reachable. | Pending |
| P2-10 | Viewport meta disables user scaling on engines that honor it. | CODE | active | Build plus viewport meta assertion. | Pending |
| P2-12 | Duplicate identity/status chrome consumes mobile vertical space. | OBSERVED | active | Mobile fixture screenshots or DOM assertions. | Pending |

## Queued: First-Run Activation

| ID | Finding | Evidence | Status | Required validation | Evidence record |
| --- | --- | --- | --- | --- | --- |
| P1-8 | Empty Mac list does not give a path to install the Mac app. | OBSERVED | queued | Hosts-empty fixture includes download/Homebrew path. | Pending |
| P1-9 | Offline recovery instruction can truncate the actionable text. | MEASURED | queued | 320/375/430px fixture assertions for alert text. | Pending |
| P2-11 | Absolute local paths are shown inconsistently in UI. | OBSERVED | queued | Path-format unit/fixture tests prove home-directory abbreviation. | Pending |

## Queued: Supported Feature Coverage

| ID | Finding | Evidence | Status | Required validation | Evidence record |
| --- | --- | --- | --- | --- | --- |
| P2-13 | Go `push` and `cmd/server` packages need focused tests. | BUILD | queued | Go unit tests for push validation and server route behavior. | Pending |
| P2-14 | Swift screen and hook adapters need focused tests. | BUILD | queued | Swift tests for screen adapter and hook listener input handling. | Pending |

## Queued: Performance And Polish

| ID | Finding | Evidence | Status | Required validation | Evidence record |
| --- | --- | --- | --- | --- | --- |
| P3-15 | PWA bundle and service-worker precache are larger than needed. | BUILD | queued | Build-size comparison and service-worker manifest check. | Pending |
| P3-16 | Dev console logs a routine script-fetch error. | OBSERVED | queued | Production-build console check or documented dev-only suppression. | Pending |
| P3-17 | Duplicate status badges add visual noise. | MEASURED | queued | Fixture check or screenshot showing one truthful status per surface. | Pending |

## Operating Rule

Do not start a new slice until the active slice has either:

1. moved all active items to `verified` with evidence, or
2. moved a blocked item to `deferred` with a specific blocker and next action.

When a slice is completed, update `docs/current-loop-state.md` to name the next
active slice.
