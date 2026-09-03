# Cursor workspace prompt routing

## Decision

Defer shipping workspace-name `/prompt` routing in the Glasstunnel UI.

Cursor exposes a deeplink that can name a workspace. Workspace `/prompt` is a
separate product path; its existence does not prove that Glasstunnel can use it as existing-chat
target switching. Current diagnostics have not established deterministic visible
prefill, destination acknowledgement, or exact existing-composer routing.

## Current contract

- The chat the Cursor window shows can use the verified Accessibility delivery path.
- Selecting another chat on the phone presses its entry in Cursor's sidebar and is
  confirmed only when the window's title matches; until then the target reads
  `Open this chat`, the phone retries, and prompts are refused rather than typed
  into the wrong chat. A workspace `/prompt` deep link is not used for this.
- "New chat" presses Cursor's own New Chat control; chats do not advertise
  `supportsNewThread` through the unverified deep-link route.
- Model controls remain read-only and managed in Cursor.

## Reconsideration Criteria

Revisit only when Cursor exposes an existing-composer switch/acknowledgement path, or
when a repeatable diagnostic proves visible delivery to the exact intended workspace
without leaking private paths. A future workspace prompt would be a separate product
path, not evidence of existing-chat continuation.

Run `pnpm qa:cursor:workspace-prompt-policy` to guard this boundary.
