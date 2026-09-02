# Claude desktop adapter

**Source:** `apps/host-macos/Sources/Adapters/ClaudeCode/ClaudeDesktopAdapter.swift`
(shares the transcript parser and hook router with the CLI adapter in the same
directory).

Mirrors Claude Code sessions that run inside the Claude desktop app
(`/Applications/Claude.app`, bundle ID `com.anthropic.claudefordesktop`). The app owns
the session, so Glasstunnel never spawns a second process; it reads what the app
writes and drives the app's own window.

## State sources

| What                         | Where it comes from                                                                 |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| Session list, titles, cwd    | `~/.claude/projects/**/<sessionId>.jsonl` records with `entrypoint: "claude-desktop"`; `custom-title` / `ai-title` records (newest wins), else the first prompt |
| Transcript                   | `user` / `assistant` records; tool results render as tool output; sidechain records are skipped |
| Busy / done                  | `assistant.stop_reason`: `tool_use` → working, `end_turn` → done; a `[Request interrupted by user…]` record → stopped |
| Structured questions         | an `AskUserQuestion` tool call → `pendingInputRequest`, cleared by its `tool_result` |
| Permission prompts           | the `Notification` hook with `notification_type: permission_prompt` (no transcript record exists), published as an Allow / Deny question; `idle_prompt` notifications change nothing; `Stop` / `SubagentStop` hooks confirm turn ends |
| Model                        | `message.model` on the newest assistant record, shown read-only ("Managed in Claude") |

The adapter installs the same user-global hooks the CLI adapter does (either card may be
the first one enabled). Hook events reach it through the shared `ClaudeHookRouter`; the
adapter claims only sessions whose transcript is desktop-owned, so CLI sessions never
move it. A hook-reported state stands until the transcript changes again, which is how
a permission prompt stays visible on the phone until it is answered.

## Driving the app

- **Prompts** — the adapter opens `claude://code/continue?session=<id>` so the selected
  session is frontmost, then writes into the composer via Accessibility (placeholder
  hint "Ask Claude a question or start a task"), falling back to a click on the composer
  strip plus synthetic keystrokes, and posts Return to submit.
- **Switching sessions** — the same deep link, which is the app's own entry point for a
  session; the adapter then re-reads the transcript.
- **Permission prompts** — the phone shows Allow / Deny as a structured question; the
  answer presses the dialog's "Allow once" / "Allow" or "Deny" button. Typed text always
  goes to the composer.
- **Questions** — answering an `AskUserQuestion` presses the chosen option, then
  "Submit" / "Continue" / "Send" when the UI exposes one. The question stays open on the
  phone until the transcript records the answer, so a press the app did not take can
  simply be retried.
- **Interrupt** — presses "Stop" / "Interrupt" when exposed, else focuses the app and
  sends Escape.

## Product boundaries

- No window video: the phone gets a structured chat, targets, and status. Use Mac
  Screen for the raw window.
- Read-only runtime controls; model and effort are managed in the app.
- New sessions are not created from the phone yet (`supportsNewThread: false`).

## Known limitations

- Accessibility on Electron is best-effort; if the composer is not exposed, the click
  fallback assumes the composer sits near the bottom of the window.
- Transcript-derived status trails the app by about two seconds (the poll interval);
  hooks close the gap for turn ends and permission prompts.
- The desktop app must already be running with a window; the card launches it, but a
  fresh install still needs its onboarding completed by hand.

## Implementation compatibility

| Glasstunnel host | Claude desktop app                 | Implementation status |
| ---------------- | ---------------------------------- | --------------------- |
| 0.1.x            | Code sessions with hooks + transcripts | adapter implemented |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
