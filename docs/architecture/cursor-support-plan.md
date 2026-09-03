# Cursor support — implementation plan

Goal: bring the two Cursor cards to the standard the Claude cards reached in 0.1.7 and
0.1.8: readable transcripts with structured tool rows, live turn state from the app's
own signals, chat discovery and switching, prompts delivered into the real chat,
interrupt from the phone, phone-driven Local Test Lab lanes, and recorded evidence that
lets the support matrix say Preview honestly. Product shape stays the `cursor` /
`cursor-agent` split: two cards, one vendor.

Every file/line anchor was verified against the tree at the time of writing
(`aab9db1d`, 2026-09-03). Facts about Cursor were verified on the development Mac
against Cursor 3.18.25 and Cursor Agent CLI 2026.06.24.

## Verified premises

- **Install.** `/Applications/Cursor.app`, bundle `com.todesktop.230313mzl4w4u92`,
  version 3.18.25 (Electron 40). The CLI is `~/.local/bin/cursor-agent` (also `agent`),
  version 2026.06.24-00-45-58-9f61de7; `~/.cursor/cli-config.json` pins the default
  model `gpt-5.4-nano` ("GPT-5.4 Nano None"), the cheapest option on the account.
- **The desktop app exposes no accessibility tree until asked.** A plain walk of the
  "Cursor Agents" window sees 13 elements (window chrome only). Setting Electron's
  documented switch `AXManualAccessibility = true` on the application element makes
  Chromium build the tree after roughly three seconds; `AXEnhancedUserInterface`
  answers `kAXErrorNotImplemented` on this build. The exposed tree carries the composer
  as an `AXTextArea` whose empty-state *value* is the placeholder
  "Plan, Build, / for skills, @ for context" (the placeholder attribute itself is
  empty; `AccessibilityInjector.isPlaceholderValue` already knows the string), the
  model pop-up ("Composer 2.5 Fast"), the "Add agents, context, tools" toolbar, the
  sidebar ("New Chat ⌘N", "Search ⌘K", "Repositories", "Open Workspace", "Account
  menu", "Settings"), and "IDE" / "Chat actions" controls. PR #21 (Codex desktop parity)
  adds the same switch to `AccessibilityInjector.application(for:)`.
- **Two chat stores, one message format.**
  - The desktop app keeps chats in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
    The `composerHeaders` table (3.x) lists chats: `composerId`, `workspaceId`,
    `createdAt`, `lastUpdatedAt`, `isArchived`, `isSubagent`, and a JSON `value` with
    `name`, `unifiedMode` (`agent` / `chat`), `isDraft`, `hasBlockingPendingActions`,
    `hasPendingPlan`, `hasUnreadMessages`, `subtitle`, `agentLocation`.
    `cursorDiskKV` holds `composerData:<id>` (14 rows on this Mac): older chats keep
    `fullConversationHeadersOnly` + `bubbleId:<composer>:<bubble>` rows (type 1 = user,
    2 = assistant, plus `thinking`), which `CursorSQLiteReader` already parses; 3.x
    agent chats instead carry a base64 protobuf `conversationState` whose repeated
    field 1 lists 32-byte blob ids, each an `agentKv:blob:<sha256>` row holding a JSON
    message `{role, content}` (Vercel AI SDK shape: `system` / `user` strings, `user`
    `[{type:"text"}]`, `assistant` `[{type:"text"|"redacted-reasoning"|"tool-call"}]`,
    `tool` `[{type:"tool-result", toolCallId, toolName, result, experimental_content}]`).
    The first user blob (about 42 KB) is injected context (`<user_info>`, `<rules>`,
    `<agent_skills>`, `<mcp_file_system>`…), never the typed prompt; the typed prompt is
    the next user message. Messages carry no timestamps; field 26 of the state is the
    last-update time in ms. Today's `CursorStateWatcher` shows **no messages** for these
    chats (`pnpm qa:cursor:live-state`: "Selected target messages readable: no").
  - The CLI keeps chats in `~/.cursor/chats/<md5(workspace path)>/<chatId>/store.db`
    (`meta` = hex-encoded JSON `{agentId, latestRootBlobId, name, mode, isRunEverything,
    createdAt}`; `blobs` = the same JSON messages plus protobuf root blobs whose
    field 1 lists the message ids in order) and `meta.json`
    (`createdAtMs`, `updatedAtMs`, `hasConversation`). Tool calls persist as
    `tool-call` / `tool-result` parts (`ReadFile`, `ApplyPatch`, …).
    `~/.cursor/projects/<slug>/.workspace-trusted` records `workspacePath` for
    workspaces the CLI trusted, which resolves the md5 directory names.
  - Agent-mode chats of both clients also get
    `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl` (records
    `{role, message:{content:[…]}}` and `{type:"turn_ended", status}`; no timestamps,
    no tool results). Useful as a fallback, not as the primary source.
- **Hooks fire for both clients.** Cursor 3.18 and the CLI read `~/.cursor/hooks.json`
  (`{"version":1,"hooks":{"<event>":[{"command":"…"}]}}`; project files
  `<workspace>/.cursor/hooks.json` and even `.claude/settings.json` are merged in).
  Events: `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure`,
  `stop` (`status` ∈ `completed` / `aborted` / `error`), `afterAgentResponse`,
  `afterAgentThought`, `beforeShellExecution`, `afterShellExecution`,
  `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`,
  `sessionStart`, `sessionEnd`, `subagentStart`, `subagentStop`, `preCompact`. Every
  payload carries `conversation_id` (the composer id / CLI chat id), `generation_id`,
  `hook_event_name`, `cursor_version`, `workspace_roots`, `model`, `transcript_path`,
  `user_email`; `beforeSubmitPrompt` adds `prompt`, `composer_mode`, `attachments`.
  The desktop app watches its config files and reloads them (`setupConfigFileWatcher`
  + `reloadHooks`); no restart should be needed, to be confirmed live. A hook that
  prints nothing lets the action proceed.
- **Cursor Agent CLI.** `-p --output-format stream-json [--stream-partial-output]`
  prints one JSON event per line (`system/init`, `user`, `assistant`, `tool_call`
  `started`/`completed` with `readToolCall` / `grepToolCall` / `globToolCall` /
  `lsToolCall` / `semSearchToolCall` / `partialToolCall` cases, `result`); `--resume
  <chatId>` continues a chat, `create-chat --workspace <path> --trust` creates one
  offline, `--mode ask|plan` limits it to read-only, `--model` picks the model,
  `--list-models` needs a valid login. **The saved login on this Mac is currently
  rejected** ("Authentication required" from a real prompt, while `cursor-agent status`
  still claims to be logged in); `cursor-agent login` must be run by the user before
  any live CLI lane. `ls` / `resume` need a TTY (Ink raw mode) and are not used.
- **Costs.** The account is a small paid plan. Every live lane uses the nano model and
  one-line prompts; nothing in this plan sends a prompt outside the lanes.

## Product decisions

- **D1 — naming and kinds stay.** `cursor` (display "Cursor", kind 2) and
  `cursor-agent` ("Cursor Agent", kind 8). No protocol enum change, no protocol version
  bump: the structured transcript fields of 0.2.2 already cover Cursor.
- **D2 — Cursor Agent becomes a chat-style card.** The CLI runs headless (no TUI), so
  the phone renders its transcript with `TranscriptView` (Markdown replies, tool rows,
  decisions) instead of the terminal frame, with a chat switcher in the card and
  "New chat" per workspace. It stays a direct app (one card, no project grid).
- **D3 — ask mode by default, edits opt-in.** The CLI card runs `--mode ask` unless the
  phone switches the card's mode. Agent mode (file edits and shell) is offered only once
  the `preToolUse` hook can route permission to the phone (Stage 3 stretch); until then
  the card refuses it with a clear note rather than running with `--force`.
- **D4 — read-only runtime controls on the desktop card**, model from the store /
  the model pop-up ("Managed in Cursor"), like Codex desktop and Claude desktop.
- **D5 — never type into an unverified chat.** The desktop card confirms which chat the
  window shows before writing, exactly as the Claude desktop card does with the rename
  control; when the front chat cannot be read, prompts are still typed (no marker
  exists), but a verifiable mismatch refuses with "Switch Cursor to … first".
- **D6 — no window video, Mac Screen stays the escape hatch** (unchanged).

## Stage 0 — Shared foundations (host)

- [x] **T0.1 Hook installer** (S) — `CursorHookInstaller` merges Glasstunnel entries
  for `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure`, and
  `stop` into `~/.cursor/hooks.json` (creating `{"version":1,"hooks":{}}` when absent),
  preserving user entries verbatim and replacing only entries whose command names the
  Glasstunnel socket. The command forwards routing and status metadata only
  (`conversation_id`, `generation_id`, `hook_event_name`, `status`, `tool_name`, a
  one-line tool title, `transcript_path`, `workspace_roots`, `model`, `composer_mode`)
  to `~/Library/Application Support/Glasstunnel/cursor.sock`; prompt text and tool
  output never travel through the hook. An unparsable user file is left alone and
  reported, never overwritten.
- [x] **T0.2 Hook listener and router** (S) — a generic `HookSocketListener` (bind,
  accept, read to EOF, one JSON line per event) and `CursorHookRouter.shared`, which
  owns the single socket process-wide and routes by `conversation_id` ownership,
  mirroring `ClaudeHookRouter` so both Cursor cards can subscribe at once.
- [x] **T0.3 Conversation store** (L) — `CursorConversationStore` turns either store
  into `[AgentChatMessage]` with the 0.2.2 structured fields: the protobuf root /
  `conversationState` walk (field 1 = message ids), JSON message decoding, injected
  context skipped, `tool-call` → `.toolCall` rows titled from the arguments (`command`,
  `path`, `pattern`, `query`, `url`, `description`), `tool-result` → `.toolResult` rows
  paired by `toolCallId` with 12-line previews and full text on request, reasoning
  parts dropped, turn state derived from the last message (`tool-call` without a
  result → working, `AskQuestion` without a result → waiting, assistant text → done).
  Old-style bubbles keep working through the existing reader; the agent transcript
  JSONL is the third fallback. Everything is read-only and privacy-safe (no content
  in logs).
- [x] **T0.4 Tests** (M) — fixtures for both stores built in temp SQLite files (the
  `CursorSQLiteReaderTests` pattern), the protobuf walk, injected-context detection,
  tool titles, previews, status, and the hook installer's merge/idempotency.
- [~] **T0.5 Diagnostics** (S, live-state done; `qa:cursor-agent` and `qa:cursor:hooks` below) — `pnpm qa:cursor:live-state` reports the new store
  path (counts only) so "Selected target messages readable" can turn to yes; a
  `pnpm qa:cursor:hooks` check reads `~/.cursor/hooks.json` back.

**Acceptance:** `swift test --package-path apps/host-macos --filter Cursor` green; the
live snapshot on this Mac lists 4 real chats with messages and per-call tool rows;
`~/.cursor/hooks.json` carries the five entries next to any user entries.

## Stage 1 — Cursor Agent card (CLI)

- [x] **T1.1 Chats and workspaces** (M) — list CLI chats from `~/.cursor/chats`
  (title from the store's `name`, mode, last update from `meta.json`), grouped by
  workspace path resolved through `.workspace-trusted`; targets carry
  `projectPath`, `threadLabel`, `supportsNewThread: true`. The selected chat is
  remembered; "New chat" runs `create-chat --workspace … --trust`. The default
  workspace is the most recently trusted one, else the existing
  `~/Library/Application Support/Glasstunnel/CursorAgent` folder.
- [x] **T1.2 Streaming turn** (L) — `sendInput` spawns
  `cursor-agent -p --output-format stream-json --stream-partial-output --trust
  --workspace <ws> --resume <chatId> [--mode ask|plan] [--model <id>] <prompt>` and
  parses events live: the prompt is echoed as the user bubble, assistant deltas grow
  one reply, `tool_call started/completed` become rows with titles, durations, and
  previews, `result` ends the turn (`is_error` → error), a non-zero exit with
  "Authentication required" reports "Sign in with `cursor-agent login` on the Mac".
  After the turn the chat's `store.db` is re-read so history is durable across host
  restarts and equals what the CLI shows.
- [x] **T1.3 Interrupt** (S) — terminates the process group; the turn ends as
  "Stopped" (system event) and the composer recovers.
- [~] **T1.4 Runtime controls** (M, model and mode done; the `--list-models` cache waits for a valid login) — model options from `--list-models` (cached per
  start, nano first) with the cli-config default preselected, editable and applied on
  the next prompt; mode (ask / plan) as the second control; agent mode listed but
  refused with the D3 note until Stage 3 lands.
- [x] **T1.5 Hooks as confirmation** (S) — subscribe for the live chat id so a `stop`
  event confirms the turn end even if the stream is cut, and so the CLI adapter never
  reacts to desktop chats.
- [x] **T1.6 Tests** (M) — a fake `cursor-agent` script that prints documented
  stream-json events (started/completed tool calls, partial deltas, result, an auth
  failure), chat listing from fixture directories, interrupt, and runtime validation.

**Acceptance:** with a fresh login, one nano prompt from the phone lands in a chat the
CLI can `--resume`, tool rows show for a `plan`-mode read, interrupt works, and the
card's history reloads after a host restart.

## Stage 2 — Cursor desktop card

- [x] **T2.1 Chat list and selection** (M) — targets from `composerHeaders` (name,
  workspace path via `workspaceStorage/<id>/workspace.json`, drafts and archived
  chats hidden, mode shown), messages from T0.3, the selected chat remembered;
  optimistic echo on send.
- [x] **T2.2 Accessibility driver** (L) — `CursorDesktopUIDriving` (fake in tests):
  enables `AXManualAccessibility` and waits for the web area; finds the composer by
  the placeholder vocabulary or by the "Add agents, context, tools" toolbar next to
  it; reads the front chat's title (control learned from a live inventory with a chat
  open); presses a chat's sidebar entry to switch and re-checks; presses the Stop
  control to interrupt (Escape fallback). All AX writes verify by reading back.
- [x] **T2.3 Live status** (M) — hooks for the selected composer: `beforeSubmitPrompt`
  → working, `preToolUse` → a running row, `postToolUse` → its result, `stop` →
  done / Stopped / error; the store poll (2 s, mtime-gated) fills in text and pairs
  rows; `hasBlockingPendingActions` → waiting for the user in Cursor.
- [~] **T2.4 Questions** (M, stretch: options are pressed in the app; not yet seen live) — `AskQuestion` tool calls become a decision on
  the phone; the answer presses the option inside the chat pane.
- [x] **T2.5 Tests and doc** (M) — adapter tests with a fake driver and hook source,
  a real-state opt-in test (`GT_CURSOR_REAL_STATE=1`), `docs/adapters/cursor.md`
  rewritten to the truth above.

**Acceptance:** from the phone, list the app's chats with their names, switch to a
dedicated chat, send a prompt that the Mac types into the real composer, watch
working → done from hooks, see the reply and tool rows, interrupt a long reply.

## Stage 3 — Mobile PWA

- [x] **T3.1 Chat-style Cursor Agent** (S) — `isCliBackedApp` drops `cursor-agent`, so
  the card renders `TranscriptView` and the decision card; the chat switcher shows for
  `cursor-agent` (`shouldShowCommandTargetSwitcher`); attachments stay off.
- [ ] **T3.2 Runtime controls** (S) — the mode control rides on the existing effort
  control slot with Cursor labels; model chips list the cheap models first.
- [x] **T3.3 Cursor desktop targets** (S) — "Browse only" becomes "Switch" with the
  Claude-style retry (`shouldRequestTargetSelection` for `cursor` when
  `isActive === false`); the composer gate only blocks while a switch is unverified.
- [~] **T3.4 Fixtures and tests** (S, tests updated; the dev fixture rows are still the old shape) — `workspace-all-apps` fixture rows for both
  cards with structured rows; AgentCard, AgentCarousel, store, and fixture tests.
- [ ] **T3.5 Permission routing** (L, stretch) — `preToolUse` hook answered from the
  phone (Allow / Deny) for both cards, which is what unlocks agent mode on the CLI card.

## Stage 4 — Lanes, evidence, promotion

- [x] **T4.1 Lanes** (M) — `tests/e2e/account-cursor-agent.spec.ts`
  (`@cursor-agent-account`: start, a nano prompt answered with a marker, a plan-mode
  read producing a tool row, interrupt, history after reselecting the chat) and
  `tests/e2e/account-cursor.spec.ts` (`@cursor-desktop-account`: switch to the
  dedicated chat "Glasstunnel live evidence", prompt typed through Accessibility,
  reply, interrupt); Playwright projects for Pixel 7 and iPhone 15; `e2e.mjs` modes
  and `package.json` scripts `lab:e2e:cursor-agent[:safari]` and
  `lab:e2e:cursor[:safari]`, added next to the Codex desktop entries of PR #21.
- [ ] **T4.2 Local contracts** (S) — `pnpm qa:cursor-agent` (CLI present, login
  state, flags, store readable) and `pnpm qa:cursor:hooks`.
- [ ] **T4.3 Evidence and matrix** (M) — `pnpm qa:agent-app:record` for "Cursor" and
  "Cursor Agent", concise public records, matrix rows to Preview with the exact scope,
  known-limitations and CHANGELOG entries, `pnpm qa:agent-app-claims`,
  `pnpm release:readiness`.

### Live steps that need the person at the Mac

1. `cursor-agent login` (the stored token is rejected), then `cursor-agent --list-models`
   once so the card can cache the list.
2. Keep the Cursor window open at normal size (not the compact widget) with a
   dedicated chat named "Glasstunnel live evidence" created in a throwaway folder, and
   leave that window alone while the desktop lane runs, as for the Claude lane.
3. Approve the one-time `~/.cursor/hooks.json` change if Cursor prompts about hooks.

## Risks

- **Electron accessibility.** The tree appears only after `AXManualAccessibility` and a
  few seconds; a compact "Cursor Agents" widget shows no chat list. The driver waits,
  retries, and degrades loudly through `statusDetail`.
- **Store format drift.** Cursor rewrote its chat storage between 3.8 and 3.18; the
  protobuf walk is minimal (repeated length-delimited fields) and every reader keeps
  the previous shapes as fallbacks. Fixtures pin today's shapes; the real-state test
  catches drift on this Mac.
- **Hooks config ownership.** `~/.cursor/hooks.json` is user-owned; the installer merges
  and never overwrites unparsable content. If Cursor requires a restart to load new
  hooks, the desktop card says so and falls back to store polling for state.
- **Concurrency with PR #21.** Shared files (`package.json`, `playwright.config.ts`,
  `scripts/lab/e2e.mjs`, `e2e.test.mjs`, `AccessibilityInjector.swift`) get additive
  edits placed next to the Codex entries; new Cursor tests live in new files.
- **Account budget.** Lanes run the nano model with one-line prompts; nothing runs on
  a schedule.

## Status (2026-09-03)

Stages 0–2 and the phone changes are implemented and unit-tested (`swift test`
412 green, `pnpm --filter=@glasstunnel/mobile-pwa test` 202 green); the two lanes are
written and wired but have not run live: the CLI lane waits for `cursor-agent login`,
the desktop lane for a dedicated chat in a normal-sized Cursor window. Evidence records
and the matrix rows change only after those runs.

## Sequencing

Stage 0 → Stage 1 (testable with a fake CLI now, live after the login) → Stage 3
(T3.1–T3.4) → Stage 2 (needs the dedicated chat and the live inventory) → Stage 4.
Stretch items (T2.4, T3.5) come after the first evidence records.
