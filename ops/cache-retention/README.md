# Cache Retention Operations

Scope: hosted Cloudflare relay replicas (24 hours per host publication), offline
signaling envelopes (60 seconds), and browser offline workspace copies (24 hours,
account + Mac scoped). Original coding-app history/files, Mac attachments, account
and device records, credentials and revocation tombstones are excluded.

The maintainer approved the policy and legacy-copy purge on 2026-09-07. Do not
reuse this approval for a different data class or a wider deletion operation.

## Local Gates

- `pnpm worker:typecheck` and `pnpm worker:test`
- `node --test ops/cache-retention/sweep.test.mjs`
- PWA lint/test/build and `pnpm lab:test`
- `node scripts/lab/e2e.mjs retention` (disposable local account, expiry, reload,
  reconnect, Profile clearing, sign-out and a second local account)
- Ordinary account/Terminal, Chromium/WebKit fixtures and revocation regression
- Security/privacy and public-repository audits

The retention operator tests run against disposable Miniflare objects. Its
production credentials and object IDs must never be written to public evidence.

## Activation And Existing Objects

The new Worker immediately refuses unverifiable/expired replays. Existing objects
with legacy cache records do not delete them until inventoried and activated by
the operator. Empty new objects start with retention active. Once activated,
alarms maintain expiry even without a connected host/client. Reads and heartbeats
do not renew content. Identity and denial records are never whole-object deleted.

After one protected PR and exact-SHA deploy, stay on that source commit and run:

```sh
node ops/cache-retention/sweep.mjs inventory .cache/retention/ledger.json
node ops/cache-retention/sweep.mjs apply .cache/retention/ledger.json
node ops/cache-retention/sweep.mjs verify .cache/retention/ledger.json
```

Inspect inventory counts and namespace scope before apply. Each phase is bounded:
at most 2,000 objects per namespace, 100 pages per object, and 125 agent keys plus
three fixed keys on the first page. Unexpected growth fails closed. Restart an
interrupted phase with the same ledger and commit; completed objects are skipped
for inventory/apply. An interrupted page can be safely revisited. Verification
enumerates the namespaces again, including dormant/orphaned objects, and requires
zero expired/legacy records, active retention and zero cleanup failures. Do not
claim complete migration if enumeration, a page or verification fails.

The CLI reads Wrangler's existing OAuth token only in memory. It creates a
temporary remote-preview Worker with bindings to the two production namespaces,
an unpredictable operation token and a loopback proxy; it does not deploy a
permanent public maintenance route. Only the count-only `cacheMaintenance` RPC
is available through this helper. The owned process group and temporary token
directory are removed on completion/failure. The private, atomically updated
ledger and redacted operator log stay ignored under `.cache/` with mode 0600.

Signaling already prunes queues during object restoration. Its dry-run counts
therefore reflect the state after that normal cleanup, not a historical count of
every envelope removed when a dormant object wakes.

## Deletion And Recovery Limits

Read/replay expiry is strict. Alarms use bounded key batches, content-free failure
counters and retry backoff (up to 15 minutes). Deletion within 15 minutes of expiry
is a healthy-service target, not an outage guarantee. The operator's verification
reports failures without exposing content. Browser code cannot run while closed;
it rejects expired content at restore/resume and deletes touched expired copies.
Legacy browser keys are discarded, never assigned to whichever account signs in.

Cache deletion is intentionally irreversible in the application. A live Mac can
publish a new snapshot containing old messages. This is not source-message
deletion or end-to-end encryption. Cloudflare SQLite point-in-time recovery can
retain earlier storage for 30 days, and provider logs/backups are outside this
active-key policy. Old PWA versions must reload to adopt browser expiry.

## Rollback Boundary

Retain the tested stage 4 source SHA as the expiry-aware recovery candidate. Do
not roll the Worker back to stage 3 or earlier, and do not restore old cache keys
from backups: those versions lack the expiry gate. During the first rollout,
recover by redeploying the tested retention source or applying a forward fix.
If a UI rollback is necessary, keep this expiry-aware Worker deployed; old PWA
builds do not provide the new browser retention guarantee. No Mac binary rollback
is involved. Record exact deployed IDs and migration counts in the security plan
and current loop state before moving to the next stage.

References:
- [Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)
- [SQLite storage and recovery](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Namespace object enumeration](https://developers.cloudflare.com/api/resources/durable_objects/subresources/namespaces/subresources/objects/methods/list/)
- [Remote development bindings](https://developers.cloudflare.com/workers/local-development/bindings-per-env/)
