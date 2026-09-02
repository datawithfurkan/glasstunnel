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

Each hook is configured to run a tiny shell command that emits one JSON line to a Unix-domain socket at `~/Library/Application Support/Glasstunnel/cc.sock`. Because these hooks live in the user-global `~/.claude/settings.json`, they fire for every Claude Code session by **any** client — the CLI and the Claude desktop app alike — so the socket is owned by a single process-wide `ClaudeHookRouter`. Adapters subscribe to the router with a session-ownership predicate; this adapter only receives events for CLI-owned sessions (plus session-less events from older Claude Code builds), and events for sessions no adapter owns are dropped.

### Session ownership

Claude Code stores every session as `~/.claude/projects/**/<sessionId>.jsonl`, shared across clients. The `entrypoint` field on user/assistant records identifies the client (`claude-desktop` for the desktop app; CLI builds stamp their own values, and legacy transcripts may have none — those count as CLI). This adapter lists and resumes CLI-owned sessions only.

The adapter always knows which session its PTY is driving: it launches `claude --resume <id>` for an existing session or `claude --session-id <uuid>` for a fresh one (unless you passed your own `--resume`/`--continue`/`--session-id` arguments). Hook events are matched against that id, so neither a desktop-app session nor a separate `claude` you run in Terminal can move this adapter's status or selection. Session listings are memoized by transcript modification time, so the 2-second refresh only re-reads transcripts that changed.

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

## Implementation compatibility

| Glasstunnel host | Claude Code version | Implementation status |
| ---------------- | ------------------- | --------------------- |
| 0.1.x            | 1.0+ (hooks system) | adapter implemented   |
| 0.1.x            | < 1.0               | hooks never fire; the adapter degrades to PTY idle-detection heuristics |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
