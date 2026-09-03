# Cursor adapter

**Source:** `apps/host-macos/Sources/Adapters/Cursor/` — `CursorAdapter.swift` (the
card), `CursorStateWatcher.swift` and `CursorDesktopStore.swift` (the app's store),
`CursorDesktopDriver.swift` (Accessibility), `CursorHooks.swift` (hooks), and the
message codec shared with the Cursor Agent card (`CursorConversationCodec.swift`).

Mirrors the chats of the Cursor desktop app (`/Applications/Cursor.app`, bundle
`com.todesktop.230313mzl4w4u92`). The app owns the chats, so Glasstunnel never spawns a
second process; it reads what the app writes and drives the app's own window.

## State sources

| What | Where it comes from |
| ---- | ------------------- |
| Chat list, titles, workspace, mode | the `composerHeaders` table of `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (Cursor 3.x); older builds' `composerData:` rows and per-workspace databases are still read. Drafts, subagents, and archived chats are hidden. The workspace comes from `User/workspaceStorage/<id>/workspace.json` or a folder-like subtitle |
| Transcript | 3.x chats: the `conversationState` snapshot lists the message blobs (`agentKv:blob:<sha256>`), Vercel AI SDK messages whose `tool-call` / `tool-result` parts become structured rows with 12-line previews and full output on request; older chats: `fullConversationHeadersOnly` + `bubbleId:` rows. Cursor's injected context block is skipped; the typed prompt is the next user message |
| Busy / done from the store | the last message: a tool call without its result → working, an `AskQuestion` call without a result → waiting for an answer, an assistant reply → done; `hasBlockingPendingActions` on the chat → waiting for the person in the app |
| Live turn state | Cursor hooks (`beforeSubmitPrompt` → working, `preToolUse` → a running row, `postToolUse` / `postToolUseFailure` → the row's end, `stop` → done / Stopped / error), which stand until the store itself moves on |
| Model | `modelConfig.modelName` of the chat, shown read-only ("Managed in Cursor") |

Everything is read-only: the databases are opened `SQLITE_OPEN_READONLY` (a WAL store
without sidecars falls back to an immutable open), and nothing here logs names, prompts,
responses, or database values.

### Hooks

On `start()` the adapter (either Cursor card) merges Glasstunnel entries into
`~/.cursor/hooks.json` for `beforeSubmitPrompt`, `preToolUse`, `postToolUse`,
`postToolUseFailure`, and `stop`, preserving your own entries verbatim and replacing only
the ones that name the Glasstunnel socket. Each entry runs a small command that forwards
routing and status metadata (`conversation_id`, `generation_id`, `hook_event_name`,
`status`, `tool_name`, a one-line tool title, `transcript_path`, `workspace_roots`,
`model`) to `~/Library/Application Support/Glasstunnel/cursor.sock`; prompt text and
tool output never travel through the hook. The command prints nothing, so Cursor
proceeds. Cursor watches the file and reloads it; a file that is not valid JSON is left
alone and reported in the card's status.

Hook events reach the card through the process-wide `CursorHookRouter`, which routes by
`conversation_id`: the desktop card owns the composer ids in the app's store, the Cursor
Agent card the chats it created or resumed.

## Driving the app

- **Accessibility opt-in.** Cursor exposes its web content only after
  `AXManualAccessibility` is set on the application (Electron's switch for assistive
  clients); the driver sets it and waits a few seconds for the web area.
- **Composer.** The settable text area whose empty value is Cursor's placeholder
  ("Plan, Build, / for skills, @ for context", "Send follow-up", …), else the text area
  beside the "Add agents, context, tools" toolbar; a code editor is never picked. The
  text is written through Accessibility and read back; if the app ignores the write the
  driver focuses the field and types, then pastes. Return submits.
- **Which chat is in front.** The window title when it names a chat, else a selected
  sidebar entry or tab, else a heading, matched against the titles in the store. A
  prompt is refused with "Switch Cursor to “<title>” before sending this prompt" when
  the front chat is readable and differs; when no title can be read at all (a new
  chat, a compact window), the composer in front is used.
- **Switching chats** presses the chat's sidebar entry and re-checks; a selected chat
  the app is not showing yet is published with `isActive: false` so the phone retries.
  "New chat" presses the app's New Chat control; the chat appears in the list after
  its first prompt.
- **Interrupt** presses the Stop control, else sends Escape; the `stop` hook with
  status `aborted` then reads as "Stopped". The message shapes alone cannot tell an
  aborted turn from a running one (both end with the prompt and no reply), so the
  store's status comes from Cursor's own record on the composer (`status`:
  completed, aborted, none; `generatingBubbleIds` while a turn runs), and a
  hook-ended turn keeps the hook's verdict until a new turn starts: a
  `beforeSubmitPrompt` hook, a prompt from the phone, or a chat switch. While a
  turn runs, that record still names the previous generation, so its stale
  "aborted" does not stop the running turn. The prompt echoed from the phone
  stays in the transcript until the store shows the turn itself, even when a
  stop hook ends the turn first.
- **A prompt that never reached the window** (another chat in front, no composer,
  or a write the composer did not take) is recorded as "Prompt not delivered:
  <reason>" in the transcript and the card enters the error state, so the phone
  shows why nothing happened.
- **Questions** — an `AskQuestion` tool call becomes a decision on the phone; the
  answer presses the chosen option in the app and the question stays open until the
  store records the answer.

## Product boundaries

- No window video: the phone gets a structured chat, targets, and status. Use Mac
  Screen for the raw window.
- Read-only runtime controls; model and mode are managed in Cursor.
- Cursor Agent is a separate CLI-backed card (`docs/adapters/cursor-agent.md`).
- Schema changes can make the store unreadable; the card then says so rather than
  guessing.

## Privacy-safe checks

```bash
pnpm qa:cursor-state
pnpm qa:cursor:live-state
GT_CURSOR_REAL_STATE=1 swift test --package-path apps/host-macos --filter testRealCursorStoresParse
pnpm qa:cursor:workspace-prompt-policy
```

The state checks print aggregate counts and source categories only. An intentional
live Accessibility input or submit probe requires its explicit environment gate; do
not run it against a private draft or paid model without a named test plan.

## Debugging

Launch the Mac host with `GLASSTUNNEL_ADAPTER_LOG=cursor` to inspect watcher and AX
targeting decisions in Console.app. Review output for private content before sharing.
