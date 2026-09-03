# Cursor Agent adapter

**Source:** `apps/host-macos/Sources/Adapters/Cursor/CursorAgentAdapter.swift`,
with the stream parser (`CursorAgentStreamParser.swift`), the chat store reader
(`CursorAgentChatStore.swift`), the shared message codec
(`CursorConversationCodec.swift`), and the hook plumbing (`CursorHooks.swift`).

Runs the standalone `cursor-agent` CLI headlessly: one `cursor-agent --print` call per
turn on a chat the CLI can `--resume`, with its events streamed as JSON lines. The
phone renders the card as a chat (Markdown replies, structured tool rows, a chat
switcher), not as a terminal.

## How it works

### Chats and workspaces

The CLI keeps every chat under `~/.cursor/chats/<md5 of the workspace path>/<chatId>/`
as `store.db` (a content-addressed blob store: the `meta` row names the latest root
blob, whose protobuf field 1 lists the message blobs in order; each message is the
Vercel AI SDK `{role, content}` shape with `tool-call` / `tool-result` parts) plus
`meta.json` (`createdAtMs`, `updatedAtMs`, `hasConversation`). The store also carries
the chat's `name` and `mode`.

The adapter lists those chats newest first and resolves their workspace through
`~/.cursor/projects/<slug>/.workspace-trusted` (`workspacePath`) or a workspace it
knows itself. Targets carry the workspace as the project and the chat name as the
thread; a "New chat" row per workspace creates one with
`cursor-agent create-chat --workspace <path> --trust`, which works offline.

When the card starts it resumes the newest chat of the folder it runs in. A folder
without a chat starts one on the first prompt; chats from other folders stay listed as
switches but are never adopted, because resuming one here would carry its history into
a folder it never ran in (the CLI then keeps a second store for the same chat id under
the new folder's hash, and the catalog shows the newest copy). Switching to another
folder's chat moves the workspace to that folder.

Cursor's own text travels as parts of the user message: the first user message is a
block of tagged context (`<user_info>`, `<rules>`, …) and in ask or plan mode a
`<system_reminder>` part precedes the typed prompt. Those parts are dropped part by
part; only the typed words reach the transcript.

The workspace a chat runs in is, in order: the folder the adapter was given, the host's
own working directory when it is a real folder (the Local Test Lab runs the host in the
repository), the most recently trusted Cursor workspace, else
`~/Library/Application Support/Glasstunnel/CursorAgent`.

### A turn

`sendInput` spawns

```
cursor-agent --print --output-format stream-json --stream-partial-output --trust \
  --workspace <path> --resume <chatId> [--mode ask|plan] [--model <id>] "<prompt>"
```

and parses stdout as it arrives:

| Event | Effect on the card |
| ----- | ------------------ |
| `system` / `init` | session id and model noted |
| `user` | the prompt echo (the card already showed it optimistically) |
| `assistant` text deltas | the reply grows in place |
| `tool_call` `started` | a pending row titled from the arguments (a command, a file, a pattern) |
| `tool_call` `completed` | the row gets its result (a 12-line preview; the full text on request), duration, and failure flag |
| `result` | the turn ends: `done` / "Response ready", or an error |

A non-zero exit with "Authentication required" reports "Sign in with cursor-agent login
on the Mac"; other failures show the CLI's last words as an event. After the turn the
chat's `store.db` is re-read and replaces the live rows, so the transcript is the CLI's
own record (the live rows are kept until the store has caught up).

Interrupt terminates the process (SIGTERM, then SIGKILL); the turn ends as "Stopped" with
a divider in the transcript, and the composer recovers.

### Modes and models

Ask mode is the default and read-only. The phone can send `/mode plan` (read-only
planning) or `/mode ask`; `/model <id>` and the model chips change the model for the next
prompt (any single token is accepted; the CLI validates it). Agent mode (file edits and
shell) is refused with a note until tool permissions can be routed to the phone. The
default model is `gpt-5.4-nano`, the cheapest on the account; `/new` starts a fresh chat.

### Hooks

The adapter installs Glasstunnel's entries into `~/.cursor/hooks.json` (see
`docs/adapters/cursor.md`) and subscribes to the shared `CursorHookRouter` for the chats
it created or resumed. The stream already reports the turn, so hooks only refresh the
history when a chat this card owns is driven elsewhere.

## Product boundaries

- Headless only: `cursor-agent ls` / `resume` need a TTY and are not used.
- No attachments; prompts are text.
- The CLI's saved login must be valid; the card cannot sign in for you.
- Every turn spends account credit; the lane uses the nano model and one-line prompts.

## Verification lanes

- `swift test --package-path apps/host-macos --filter CursorAgentRuntimeTests` — the
  parser and the adapter against a fake `cursor-agent`.
- `GT_CURSOR_REAL_STATE=1 swift test --package-path apps/host-macos --filter testRealCursorStoresParse`
  — reads the real chat stores on this Mac and prints counts only.
- `pnpm lab:e2e:cursor-agent` (and `:safari`) — the phone-driven journey through the
  Local Test Lab: a prompt answered on the nano model, a plan-mode file read shown as a
  tool row, and a long reply interrupted from the phone. Needs a signed-in CLI; it spends
  three short turns.
