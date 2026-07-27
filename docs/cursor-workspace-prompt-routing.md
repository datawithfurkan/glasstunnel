# Cursor workspace prompt routing

## Decision

Defer shipping workspace-name `/prompt` routing in the Glasstunnel UI.

Cursor exposes a deeplink that can name a workspace. Workspace `/prompt` is a
separate product path; its existence does not prove that Glasstunnel can use it as existing-chat
target switching. Current diagnostics have not established deterministic visible
prefill, destination acknowledgement, or exact existing-composer routing.

## Current contract

- The active visible Cursor chat can use the verified Accessibility delivery path.
- Non-current parsed targets are `Browse only` and must reject prompt delivery.
- Cursor does not advertise `supportsNewThread` through this unverified route.
- Model controls remain read-only and managed in Cursor.

## Reconsideration Criteria

Revisit only when Cursor exposes an existing-composer switch/acknowledgement path, or
when a repeatable diagnostic proves visible delivery to the exact intended workspace
without leaking private paths. A future workspace prompt would be a separate product
path, not evidence of existing-chat continuation.

Run `pnpm qa:cursor:workspace-prompt-policy` to guard this boundary.
