# OpenCode adapter

**Source:** `apps/host-macos/Sources/Adapters/OpenCode/`.

Wraps the OpenCode CLI/TUI in a PTY. Same shape as the Codex adapter, slightly tighter idle threshold (2 seconds) because OpenCode's output pacing is snappier.

## How it works

- PTY wrapper launches `opencode`.
- All output is ANSI-stripped and redacted.
- Agent-done detection is time-based idle; OpenCode's TUI emits enough stream output that the buffer tail is reliable.

## Host path resolution

`/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`, `~/.local/bin/opencode`, `~/.bun/bin/opencode`, then unqualified `opencode`.

## Known limitations

- OpenCode's TUI uses alternate-screen mode occasionally. The adapter strips the escape sequences but if OpenCode redraws in a way that doesn't emit new characters for a while, the phone may show stale content until the next redraw. We are tracking an improvement that sniffs OpenCode's state-file emissions and would eliminate this entirely.

## Implementation compatibility

| Glasstunnel host | OpenCode version | Implementation status |
| ---------------- | ---------------- | --------------------- |
| 0.1.x            | any              | adapter implemented   |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
