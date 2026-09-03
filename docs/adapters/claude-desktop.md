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

- **Bringing a session to the front** — the adapter reads the name of the session in
  front from the Code UI's "<name>, rename session" control (the window title is a
  bare "Claude" on build 1.40609.1) and compares it with the selected session's title.
  If they differ it tries `claude://code/continue?session=<id>`, then presses the
  session's sidebar entry through Accessibility (entries are titled "Idle …" /
  "Running …" / "Unread response …", so the match is by substring), and re-checks.
  Current Claude builds answer every `claude://code` link with "deep link gated off" in
  their own log, so the Accessibility path is the one that matters today.
- **Prompts** — only once the app is confirmed to show the selected session (or when
  neither the rename control nor the window title can be read), the adapter writes
  into the composer via Accessibility (an editable text area described "Prompt", or
  the older placeholder "Ask Claude a question or start a task"), falling back to a
  click on the composer strip plus synthetic keystrokes, and posts Return to submit.
  If the app verifiably shows another session, the prompt is refused with "Switch
  Claude to “<title>” before sending this prompt" rather than typed into the wrong
  conversation.
- **Switching sessions** — the same bring-to-front sequence; a selected session the app
  is not yet showing is published with `isActive: false` so the phone retries.
- **Permission prompts** — the phone shows Allow / Deny as a structured question; the
  answer presses the dialog's "Allow once" / "Allow" or "Deny" button. Typed text always
  goes to the composer.
- **Questions** — answering an `AskUserQuestion` brings the session in front, presses
  the chosen option by exact label inside the session pane (the newest match, so an
  earlier answer's bubble or a sidebar control such as "Dispatch Beta" is never hit),
  then "Submit" / "Continue" / "Send" when the UI exposes one. When the app is not
  showing the question yet (its own tool-permission dialog comes first in "auto"
  mode), the question stays open on the phone with "open the question in Claude to
  answer" so it can be retried. Permission and Stop buttons are pressed inside the
  session pane the same way.
- **Interrupt** — presses "Stop" / "Interrupt" when exposed, else focuses the app and
  sends Escape.

## Product boundaries

- No window video: the phone gets a structured chat, targets, and status. Use Mac
  Screen for the raw window.
- Read-only runtime controls; model and effort are managed in the app.
- New sessions are not created from the phone yet (`supportsNewThread: false`).

## Known limitations

- Two Glasstunnel hosts on one Mac (the installed app and a lab or development
  build) share `~/Library/Application Support/Glasstunnel/cc.sock` and the hooks in
  `~/.claude/settings.json`; the host whose Claude adapter started last receives the
  hook events, and the other one sees turns end only through the transcript. Run one
  host at a time.
- The app's `claude://code/…` deep links are feature-gated off on current builds
  (verified against the app's `~/Library/Logs/Claude/main.log`), so session switching
  depends on Accessibility exposing the session rows.
- Accessibility on Electron is best-effort; if the composer is not exposed, the click
  fallback assumes the composer sits near the bottom of the window.
- Transcript-derived status trails the app by about two seconds (the poll interval);
  hooks close the gap for turn ends and permission prompts.
- The desktop app must already be running with a window; the card launches it, but a
  fresh install still needs its onboarding completed by hand.

## Verification lanes

- `pnpm qa:claude-desktop` — privacy-safe local contracts (bundle id, `claude://`
  scheme, desktop-owned transcripts, installed hooks, CLI flags).
- `pnpm qa:claude-desktop:live-ax` — the same plus a read-only Accessibility probe of
  the running window's composer; run it from a terminal that has Accessibility access.
- `GT_CLAUDE_REAL_STATE=1 swift test --package-path apps/host-macos --filter testRealDesktopSessionsParse`
  — parses the newest desktop sessions on this Mac and prints their status and titles.
- `pnpm lab:e2e:claude-desktop` — the phone-driven journey through the Local Test Lab
  against the real Claude app: a mobile Chromium signs in, switches the card to the
  session named by `GT_LAB_CLAUDE_SESSION` (default "Glasstunnel live evidence"),
  sends a prompt that the Mac types into the app, answers a permission prompt and an
  AskUserQuestion from the phone, and checks that a Claude Code CLI card started
  alongside never moves. Needs the app open with that session created, an
  Accessibility-trusted lab process, and a signed-in account; it spends three short
  turns. Keep your hands off the Claude window while it runs. Quit the installed
  Glasstunnel app first: it shares the Claude hook socket with the lab host, and
  whichever Claude adapter starts last takes the hooks, so a running installed app
  can steal the lane's permission prompt mid-run (the runner warns when it is running). A session in the app's
  "auto" permission mode approves a harmless shell command itself, so the permission
  dialog is answered only when it appears (the lane records which happened); sessions
  set to ask before running exercise it.

## Implementation compatibility

| Glasstunnel host | Claude desktop app                 | Implementation status |
| ---------------- | ---------------------------------- | --------------------- |
| 0.1.x            | Code sessions with hooks + transcripts | adapter implemented |

This table is not a release-readiness claim. Use
`docs/agent-app-support-matrix.md` for public support status and real mobile
verification requirements.
