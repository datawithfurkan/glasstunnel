# Claude Code adapter

**Source:** `apps/host-macos/Sources/Adapters/ClaudeCode/`.

Wraps Anthropic's `claude` CLI in a PTY and subscribes to its hook system for rich, reliable agent-state signals.

## How it works

### PTY wrapper

`PTYWrapper` spawns `claude` with `openpty(3)` so the CLI thinks it's running in a real terminal. All output flows to the adapter (ANSI-stripped + secret-redacted), all input from the phone writes to stdin.

### Hooks

On `start()` the adapter calls `ClaudeCodeHookInstaller.installIfNeeded()`, which:

1. Locates `~/.claude/settings.json`.
2. Loads the existing JSON so your personal hooks are preserved.
3. Adds or updates three entries under `hooks`:
   - `Stop` — fires when Claude Code finishes its turn.
   - `SubagentStop` — fires when a subagent finishes.
   - `Notification` — fires when Claude Code asks for user confirmation.
4. Writes `~/.claude/settings.json` back.

Each hook is configured to run a tiny shell command that emits one JSON line to every running Glasstunnel host's own Unix-domain socket under `~/Library/Application Support/Glasstunnel/hooks/` (and the pre-0.1.10 single path `…/Glasstunnel/cc.sock`). Because these hooks live in the user-global `~/.claude/settings.json`, they fire for every Claude Code session by **any** client — the CLI and the Claude desktop app alike — so the socket is owned by a single process-wide `ClaudeHookRouter`. Adapters subscribe to the router with a session-ownership predicate; this adapter only receives events for CLI-owned sessions (plus session-less events from older Claude Code builds), and events for sessions no adapter owns are dropped.

### Session ownership

Claude Code stores every session as `~/.claude/projects/**/<sessionId>.jsonl`, shared across clients. The `entrypoint` field on user/assistant records identifies the client (`claude-desktop` for the desktop app; CLI builds stamp their own values, and legacy transcripts may have none — those count as CLI). This adapter lists and resumes CLI-owned sessions only.

The adapter always knows which session its PTY is driving: it launches `claude --resume <id>` for an existing session or `claude --session-id <uuid>` for a fresh one (unless you passed your own `--resume`/`--continue`/`--session-id` arguments). Hook events are matched against that id, so neither a desktop-app session nor a separate `claude` you run in Terminal can move this adapter's status or selection. Session listings are memoized by transcript modification time, so the 2-second refresh only re-reads transcripts that changed.

### Dialogs that would swallow a prompt

Two Claude Code screens are not the composer, and text typed into them is lost:

- **Workspace trust.** A folder Claude Code has not seen from this launch opens with
  its "Quick safety check" dialog. The adapter publishes it as a decision for the
  phone ("Yes, I trust this folder" / "No, exit"), reports `waitingInput` with
  "Trust this folder?", and refuses prompts until it is answered. The dialog's
  option order and default differ by build and launch context (a terminal shows
  "❯ 1. Yes, I trust this folder" first; under the host's PTY it is "❯ No, exit"
  first), so the adapter never presses a number or a bare Return: it moves the
  highlight with Down, reads the redraw back, and confirms only once the highlight
  sits on the chosen option.
- **Session held elsewhere.** `claude --resume <id>` exits with status 1 and
  "Session … is currently running as a background agent … add --fork-session" when
  another process still holds that session. The adapter then relaunches once with a
  fresh `--session-id`, keeping the same folder, and says so in the status detail.

### Host path resolution

`ClaudeCodeAdapter.executableCandidates()` is the single list used for both availability detection and process launch: unqualified `claude` on `$PATH` first, then `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local/bin`, `~/.cargo/bin`, `~/.bun/bin`, and `~/.npm-global/bin`.

## Status mapping

| Hook                                  | AgentStatus               |
| ------------------------------------- | ------------------------- |
| `Stop`                                | `done`                    |
| `SubagentStop`                        | `working` (not terminal)  |
| `Notification` (`permission_prompt`, `elicitation_dialog`, other) | `waitingInput` |
| `Notification` (`idle_prompt`)        | unchanged — Claude is merely idle after a finished turn |

Session titles come from the transcript's `custom-title` / `ai-title` records (a user-set
title outranks any AI title; within a type the newest wins), falling back to the first
prompt. Tool results render as tool output, and an interrupted turn shows as "Stopped".

## Preserving your hooks

The installer only modifies the three entries above. Anything else under `hooks` is left exactly as you wrote it. If you already have a custom `Stop` hook, glasstunnel's socket-write command runs **in addition** to yours (Claude Code supports multiple hooks per event).

## Known limitations

- Claude Code's hook payload schema is an evolving surface; we currently parse only `kind` + `session` and fall back to "dumb idle" detection if the JSON is missing.
- A PTY-wrapped Claude Code runs under glasstunnel's env vars. If your terminal profile exports special `CLAUDE_*` env, make sure they are in your login shell profile (`.zshenv`), not just your interactive shell.

## Verification lanes

- `pnpm qa:claude-code` — privacy-safe launch-surface checks (binary, `--resume`,
  `--session-id`, hook settings shape).
- `GT_CLAUDE_LIVE=1 swift test --package-path apps/host-macos --filter ClaudeCodeLiveTests`
  — the adapter drives the real signed-in CLI through one turn in a clean environment
  with a temporary settings file (one short turn on your account).
- `pnpm lab:e2e:claude-code` — the phone-driven journey through the Local Test Lab: a
  mobile Chromium signs in, starts the card (the Mac launches `claude` in a PTY and
  resumes your newest CLI session), sends a prompt, waits for "Response ready", then
  interrupts a second prompt from the phone and checks the composer recovers. Needs a
  signed-in CLI; it spends two short turns. When you run it from inside a Claude Code
  session, clear the inherited `CLAUDE*`/`ANTHROPIC*` variables first.

## Implementation compatibility

| Glasstunnel host | Claude Code version | Implementation status |
| ---------------- | ------------------- | --------------------- |
| 0.1.x            | 1.0+ (hooks system) | adapter implemented   |
| 0.1.x            | < 1.0               | hooks never fire; the adapter degrades to PTY idle-detection heuristics |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
