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
- The thread's own `turn_context` records (one per turn, with `model` and `effort`)
  and `thread_settings_applied` events (`model`, `reasoning_effort`, `service_tier`)
  for the model chip. The newest of either wins; `~/.codex/config.toml` is only the
  fallback for a thread that has neither, because threads regularly run a different
  model than the global default.

Transcript records:

- Shell commands and patches arrive as `custom_tool_call` records whose `input`
  is an `exec` script (`tools.exec_command({cmd: …})`) or an `apply_patch`
  patch; older threads use `function_call` with JSON arguments. Both become
  structured rows: the row title is the command pulled out of the script, the
  file names a patch touches, "Update plan", or the most descriptive argument
  (a path, a task name, a URL).
- Tool outputs are strings or lists of content parts, usually with a header
  above `Output:` (`Exit code: 1`, `Process exited with code 0`,
  `Wall time: 2.5 seconds`, `Script completed`). The header becomes the row's
  failed flag and duration and the text under it is the output; the older JSON
  shape with `metadata.exit_code` is still read.
- Codex prepends machine-written blocks to user turns (`<environment_context>`,
  `<recommended_plugins>`, `<skill>`, image markers, "# Files mentioned by the
  user"). They are dropped before the message reaches the phone; attached
  images show as "[image]". Any block shaped like `<some_tag>` with an
  underscore in its name is treated the same way, so new injected blocks do not
  render as the user's words.
- A `turn_aborted` event becomes a "Stopped" divider and puts the card back to
  idle.
- The composer stores what the person typed as Markdown (`GT_APP` becomes
  `GT\_APP` in the rollout); user messages have those backslash escapes removed
  so the phone shows the text the way the app does. Assistant Markdown is left
  for the phone to render.

Driving the app (the ChatGPT-hosted shell, 2026):

- Codex now ships inside `ChatGPT.app` with the same bundle id; the front window
  is titled "ChatGPT", so the window title no longer names the thread. Thread
  routing relies on `codex://threads/<id>` links and on the thread's rollout.
- The app is Electron-based and exposes its web content to Accessibility only
  after a client sets `AXManualAccessibility`; the injector does that once per
  process for this bundle id only (Claude exposes its tree without it, and the
  opt-in would push it into a heavier screen-reader mode).
- The composer is the window's only text area, placeholder "Do anything"; the
  adapter tries that hint, the older placeholders, and finally no hint at all.
- Interrupt presses the app's stop control when one is exposed ("Stop", "Stop
  streaming", …) and otherwise sends Escape, the key the Codex TUI understands.
  The status detail records which path ran.

Scan budget: the catalog opens only the 200 newest rollout files (by
modification time) and reads 256 KB from each end of a large one; the session
index supplies thread names. Only the thread the card shows reads the full
8 MB tail for its message history. A Codex home on this scale (9,000+ rollouts,
18 GB) links in seconds instead of minutes.

Release behavior:

- Project rows use the workspace folder label.
- Thread/chat rows use the Codex thread name when available.
- Standalone chats stay separate from project-backed threads.
- If Codex changes its local state shape, the row should degrade to the project folder label instead of inventing a stale label from another device.

## Verification lanes

- `swift test --package-path apps/host-macos --filter "TranscriptStructureTests|CodexDesktopSessionParserTests"`
  — parser contracts against real record shapes (custom tool calls, list
  outputs, output headers, per-thread model, injected context).
- `pnpm lab:e2e:codex-desktop` (and `:safari` for mobile WebKit) — the
  phone-driven journey through the Local Test Lab against the real Codex app: a
  phone-sized browser signs in, switches the card to the thread named by
  `GT_LAB_CODEX_THREAD` (default "Glasstunnel live evidence"), checks that the
  model chip matches the model that thread's newest turn ran with, sends a prompt
  that the Mac types into the app, reads a shell command back as a titled row and
  fetches its full output from the Mac, interrupts a long reply from the phone,
  and checks that injected context never renders as the user's words. Needs the
  app open with that thread created (any project), an Accessibility-trusted lab
  process, and a signed-in account; it spends three short turns. Keep your hands
  off the Codex window while it runs.

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
