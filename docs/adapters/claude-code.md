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

Each hook is configured to run a tiny shell command that emits one JSON line to a Unix-domain socket at `~/Library/Application Support/Glasstunnel/cc.sock`. The adapter listens on that socket and converts the events into `AgentStatus` transitions on the wire.

### Host path resolution

We try `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, and `~/.claude/local/bin/claude` in that order, falling back to the unqualified `claude` on `$PATH`.

## Status mapping

| Hook            | AgentStatus               |
| --------------- | ------------------------- |
| `Stop`          | `done`                    |
| `SubagentStop`  | `working` (not terminal)  |
| `Notification`  | `waitingInput`            |

## Preserving your hooks

The installer only modifies the three entries above. Anything else under `hooks` is left exactly as you wrote it. If you already have a custom `Stop` hook, glasstunnel's socket-write command runs **in addition** to yours (Claude Code supports multiple hooks per event).

## Known limitations

- Claude Code's hook payload schema is an evolving surface; we currently parse only `kind` + `session` and fall back to "dumb idle" detection if the JSON is missing.
- A PTY-wrapped Claude Code runs under glasstunnel's env vars. If your terminal profile exports special `CLAUDE_*` env, make sure they are in your login shell profile (`.zshenv`), not just your interactive shell.

## Implementation compatibility

| Glasstunnel host | Claude Code version | Implementation status |
| ---------------- | ------------------- | --------------------- |
| 0.1.x            | 1.0+ (hooks system) | adapter implemented   |
| 0.1.x            | < 1.0               | mirror fallback       |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
