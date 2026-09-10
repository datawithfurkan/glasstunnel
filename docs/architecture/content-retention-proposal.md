# Content Retention Proposal

Status: approved and deployed; stage 4 passed on 2026-09-07 at `0f98a93d`.
Approval includes the 24-hour lifetime and bounded, inventory-verified removal
of legacy cache copies. The hosted sweep inspected 183 objects, removed 503
expired/unverifiable records and preserved six fresh records. Verification found
zero remaining invalid records and zero cleanup failures, with retention active.
Pre-implementation source inspected: `cc3377b1` on 2026-09-06. No personal content
was returned by the operator; original chats/files and security records were excluded.

## Approved Decision

Adopt a **24-hour maximum offline cache age** in the hosted relay and browser.
Clear browser workspace copies on sign-out, account switch, access revocation,
and forgetting that Mac. Discard legacy copies that lack trustworthy age or
account ownership. Preserve original coding-app history, repositories, files,
accounts, device keys and revocation records.

This changes offline convenience: after the deadline, an offline Mac has no
cached transcript to show until it reconnects. It does not delete the source
conversation. A live Mac may publish a fresh snapshot containing older messages;
this is a cache-replica lifetime, not a promise that all copies of a message
disappear 24 hours after that message was originally written.

## Verified Pre-Implementation Gaps (2026-09-06)

- `RelayHub.loadRelayState` restores hello, app list, legacy aggregate snapshots
  and per-agent snapshots without an expiry record. Snapshot size compaction is
  not time-based deletion.
- `RelayHub.alarm` manages host silence and client authorization. With no host
  or clients it does not currently maintain a content-cleanup alarm.
- The PWA uses `gt.relay.cache.<host>` keys. `savedAtUnixMs` is written but not
  checked on load; the cache is not keyed by account. Sign-out and Forget clear
  selected-host state but do not erase all relevant transcript cache keys.
- Signaling queues have a 60-second logical lifetime; cleanup depends on runtime
  events rather than a dedicated persistent cleanup alarm. Keep the lifetime,
  but prove deletion when the destination never returns.

## Approved Contract

| Surface | Lifetime and clearing behavior |
| --- | --- |
| Hosted hello, app list and recent transcript replicas | Expire 24 hours after the host's last accepted publication of each item. A replay, viewer read or host heartbeat must not extend it. |
| Browser workspace cache | Account + host + schema scoped, at most 24 hours since live receipt, capped by any earlier relay expiry. Cached replay/reload must not restart its age. Clear the relevant account/host copies on teardown actions above. |
| Expanded tool detail and screen frames | Remain non-persistent in these cache paths. Clear in-memory content on session teardown; do not extend guarantees to provider logs or source transcripts. |
| Offline signaling envelopes | Keep the existing 60-second cutoff, fail closed at the deadline, and schedule deletion without requiring another connection. |
| Identity, authorization and revocation data | Do not expire with content. Never use whole-object deletion: it would erase security tombstones. |
| Original chats, received Mac attachments and project files | Unchanged. Their lifetime is outside this cache-only stage and must remain disclosed. |

For legacy or malformed cache records, do not infer their creation time from the
host's last-seen timestamp. Do not migrate unscoped browser content into the
currently signed-in account. Discard it with a short refresh explanation.

An updated browser talking to an older relay may still display authenticated live
content, but must not persist a cached replay that has no trustworthy expiry.
Additive protocol fields must preserve that mixed-version behavior explicitly.

## Implementation And Validation

1. Use versioned cache envelopes with receipt/expiry timestamps. Test zero,
   missing, non-finite, future and malformed values and exact expiry boundaries.
2. Enforce expiry on every read, replay and restoration, including in-memory
   entries. Return an explicit cache-empty/expired state so the PWA cannot keep
   showing a stale workspace after the host goes offline.
3. Share the relay's one alarm across content expiry, host liveness and auth
   deadlines. Use idempotent, bounded-key deletion batches, preserve tombstones,
   and record content-free cleanup failures with bounded retry/backoff.
4. Serialize browser cache writes with account/connection generations and clearing.
   Test a delayed write racing logout, account switch, removal and revocation;
   stale work must not recreate erased keys. Clear only Glasstunnel cache keys,
   not unrelated IndexedDB data or local credentials.
5. Add a small Profile action for clearing this browser's offline copies with
   truthful success/failure feedback. Document that connected streams may refill
   caches; clearing one browser is not an account-wide server deletion operation.
6. Verify real local offline/reconnect behavior, two-account isolation and Worker
   restart/alarm behavior. Run the ordinary local compatibility suite afterward.

## Hosted Migration Gate

The maintainer approved this policy and the legacy purge on 2026-09-07. Routine
implementation, local disposable tests, protected PR checks and this planned
deployment do not need another approval. Inventory, apply and verification still
have to pass; approval does not substitute for evidence.

Before migration, produce a bounded, content-free inventory/dry run of target
cache records. Include dormant relay objects, not just currently connected Macs;
a deployment alone does not visit objects that have no pending event. Use a
resumable operator-only sweep and verify its complete scope, including orphaned
objects that no longer have an account row. If enumeration is incomplete, report
that gap rather than claim complete hosted cleanup. No public bulk-delete API.

Read-time expiry is a strict serving rule. Background deletion must have a
measured operational target and failure visibility, not an unconditional
wall-clock guarantee during a provider outage. The proposed healthy-service
target is deletion within 15 minutes after expiry. Do not create a continuous
agent loop or GitHub workflow polling to enforce it.

## Provider And Rollback Limits

Glasstunnel uses SQLite-backed Durable Objects. Cloudflare documents point-in-time
recovery for the previous 30 days, so deleting active cache keys is **not** a
claim of immediate provider-backup erasure. Cloudflare and Supabase logs/backups
need separate operational verification; this proposal does not alter them.
See [Cloudflare storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/).

Cloudflare allows one alarm per object, with at-least-once execution and limited
automatic retries. The implementation must coordinate deadlines, tolerate replay,
and recover cleanup failures rather than assuming a timer always succeeds.
See [Cloudflare alarms](https://developers.cloudflare.com/durable-objects/api/alarms/).

Rollback must not restore expired cache content from a backup or switch to an
older Worker that serves timestamp-free records. Keep an expiry-aware rollback
candidate. Cache deletion is intentionally irreversible at the application level;
the Mac can publish fresh state after reconnect. Publish this limitation before
activation and record the approved scope, migration counts and validation.

Implementation and operator instructions: `ops/cache-retention/README.md`.
Current deployment/migration evidence: `docs/current-loop-state.md` and the
stage 4 record in `security-hardening-plan.md`.
