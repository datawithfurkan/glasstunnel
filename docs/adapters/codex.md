# Codex adapters

Glasstunnel supports two Codex surfaces:

- **Codex desktop** through the installed Mac app bundle `com.openai.codex`.
- **Codex CLI** through a PTY-backed `codex` executable.

## Codex desktop adapter

**Source:** `apps/host-macos/Sources/Adapters/Codex/CodexDesktopAdapter.swift`.

The desktop adapter does not spawn a second Codex process. It reads Codex's local state and delivers prompts to the running app through Accessibility.

Current state sources:

- `~/.codex/sessions/**/*.jsonl` for workspace roots, recent messages, planning prompts, and session metadata.
- `~/.codex/session_index.jsonl` for current thread names when the session JSONL does not contain a `thread_name_updated` event.
- `~/.codex/.codex-global-state.json` for project order, saved workspace roots, active workspace roots, and standalone chat grouping hints.

Release behavior:

- Project rows use the workspace folder label.
- Thread/chat rows use the Codex thread name when available.
- Standalone chats stay separate from project-backed threads.
- If Codex changes its local state shape, the row should degrade to the project folder label instead of inventing a stale label from another device.

## Codex CLI adapter

**Source:** `apps/host-macos/Sources/Adapters/Codex/`.

Wraps the Codex CLI in a PTY. Codex does not (yet) expose a hook system, so we rely on heuristic agent-done detection.

## How it works

- PTY wrapper launches `codex`.
- All output is ANSI-stripped and redacted before it leaves the Mac.
- Agent-done detection uses two signals in tandem:
  1. **Idle** — no output for 2.5 seconds (configurable via `idleThresholdSeconds`).
  2. **Prompt detected** — the last non-empty line is `>`, `$`, `#`, or ends with one of those prompt suffixes after a space.

When both fire, we transition to `AgentStatus.done`.

## Host path resolution

`/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex`, `~/.cargo/bin/codex`, then unqualified `codex`.

## Known limitations

- Done detection is still heuristic because Codex CLI does not expose first-class lifecycle hooks. Silence without a returned prompt stays `working`, so mobile should not claim a turn is done during long quiet reasoning/tool phases.
- If Codex adds first-class hook support in a future release, we'll wire it up here the same way the Claude Code adapter does.

## Implementation compatibility

| Glasstunnel host | Codex CLI version | Implementation status |
| ---------------- | ----------------- | --------------------- |
| 0.1.x            | any               | adapter implemented   |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
