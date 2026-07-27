# Cursor adapter

**Source:** `apps/host-macos/Sources/Adapters/Cursor/`

The Cursor adapter reads local Cursor state when the installed version exposes a
compatible chat-shaped SQLite schema. It must degrade to an honest unavailable or
browse-only state when parity cannot be verified.

## Data source

- Cursor Application Support databases under the current user's Library.
- `state.vscdb` and recent workspace storage databases.
- Chat/composer-shaped `cursorDiskKV` and `ItemTable` rows.
- A file-system watcher that refreshes state without constant polling.

The reader opens Cursor databases read-only and never writes to Cursor storage. It
must not log names, prompts, responses, raw JSON, workspace hashes, or database values.

## Input delivery

For the active Cursor chat, Glasstunnel:

1. Activates Cursor through the Accessibility API.
2. Finds a settable chat input in the focused window.
3. Writes the prompt and reads it back to verify the target.
4. Falls back to PID-targeted keyboard replacement only when direct AX replacement
   cannot be verified.
5. Submits Return only after the written value matches.

This path is intentionally guarded to avoid typing into another app or another Cursor
chat. Accessibility permission is required.

## Product boundaries

- Only the visibly active Cursor chat is a verified prompt target.
- Parsed non-current chats are browse-only until Cursor provides a deterministic
  switch/acknowledgement path.
- Generated labels such as `Cursor chat 1` distinguish unnamed records but do not
  prove exact label parity.
- Header-only rows prove discovery, not message-history parity.
- Model and settings controls are read-only and shown as `Managed in Cursor`.
- Cursor Agent is a separate CLI-backed Preview integration.
- Schema changes can temporarily make the adapter unavailable.

See `docs/cursor-workspace-prompt-routing.md` for the deeplink decision and
`docs/agent-app-support-matrix.md` for the public tier.

## Privacy-safe checks

```bash
pnpm qa:cursor-state
pnpm qa:cursor:live-state
pnpm qa:cursor:workspace-prompt-policy
```

The state checks print aggregate counts and source categories only. An intentional
live Accessibility input or submit probe requires its explicit environment gate; do
not run it against a private draft or paid model without a named test plan.

## Debugging

Launch the Mac host with `GLASSTUNNEL_ADAPTER_LOG=cursor` to inspect watcher and AX
targeting decisions in Console.app. Review output for private content before sharing.
