# Agent app support

Support labels describe what Glasstunnel can responsibly promise today. A feature
does not become Supported from unit tests alone; it needs current, repeatable
end-to-end evidence on the relevant Mac and browser surfaces.

## Tiers

- **Supported:** maintained as a public-beta contract and covered by release gates.
- **Preview:** useful and actively tested, but important parity or lifecycle gaps remain.
- **Experimental:** exploratory integration with no compatibility promise.

## Support Summary

| App / Feature  | Capability                                                                                   | Status        | Release ready | Key remaining risk                                                                                                   |
| -------------- | -------------------------------------------------------------------------------------------- | ------------- | ------------- | -------------------------------------------------------------------------------------------------------------------- |
| Mac Screen     | ScreenCaptureKit sharing, pointer/text input, start/stop/restart, and stale-session recovery | Release-ready | Yes           | Physical-device network transitions remain optional hardening                                                        |
| Terminal       | PTY-backed shell commands, streamed output, interrupt/recovery, and named sessions           | Release-ready | Yes           | The mobile transcript is not a full terminal emulator; rich TUI fidelity is adapter-specific                         |
| Codex desktop  | Project/thread discovery from Codex's local state (bounded to the newest rollouts), thread switching through `codex://` links, prompt delivery through Accessibility into the ChatGPT-hosted shell, the thread's own model and effort on the card, structured tool rows for Codex's exec scripts and patches with full output on request, interrupt through the app's Stop control | Partial       | No            | Phone-driven evidence covers thread switching, the model chip, prompt → "Response ready", a shell command row with full output, and interrupt, on mobile Chromium and mobile WebKit; in-app approval dialogs are not published to the phone, runtime controls stay read-only, and relaunch persistence is unrecorded |
| Codex CLI      | PTY launch, prompt delivery, stop, and runtime controls                                      | Partial       | No            | Structured final-result parsing and deterministic thread resume are incomplete                                       |
| Cursor         | Chat discovery from the app's own store (Cursor 3.x blob store and older bubble rows) with structured tool rows, turn status from Cursor's generation record and hooks, chat switching and prompt delivery through Accessibility confirmed by the chat the window shows, "New chat", and interrupt through the app's Stop control | Partial       | No            | Phone-driven evidence covers the chat switch, prompt → "Response ready", and interrupt on mobile Chromium and mobile WebKit against a local test chat; Cursor exposes its Accessibility tree only through Electron's opt-in switch, writes a chat's turns to its store late or, for a promptly stopped turn, not at all (the phone's echo carries them), and model and settings stay read-only on the phone; the lane's check that an interrupted prompt's echo stays visible is nondeterministic (Cursor persists a stopped prompt late or never) |
| Cursor Agent   | Headless CLI turns streamed as structured rows, chat discovery and resume per folder, new chats, ask and plan modes and model choice from the phone, interrupt, and durable history from the chat store | Partial       | No            | Phone-driven evidence covers ready, prompt → "Response ready", a plan-mode file read as a tool row, both mode switches, and interrupt on mobile Chromium and mobile WebKit in the lab; agent mode (file edits and shell) stays off until tool permissions can reach the phone |
| Gemini CLI     | Authenticated headless prompt and stop subset                                                | Partial       | No            | Interactive TUI/auth behavior and broader model coverage remain unverified                                           |
| OpenCode       | CLI/session discovery, free-model prompt/stop subset, and provider/model controls            | Partial       | No            | Provider variance, private-model auth, session switching, and full TUI fidelity remain incomplete                    |
| Claude desktop | Desktop-session discovery from the shared transcript store, session switching and prompt delivery through Accessibility (verified via the app's rename control), hook-driven turn state, permission and AskUserQuestion answers from the phone, transcripts rendered for reading with structured tool rows and full output on request | Partial       | No            | Phone-driven evidence covers session switching, prompt/response, the permission dialog (session switched to Manual mode, Allow from the phone), an AskUserQuestion answered from the phone, and interrupt, on mobile Chromium and mobile WebKit; a live app restart is covered only by a host test. The app's `claude://code` links stay gated off, so switching relies on Accessibility |
| Claude Code    | PTY launch pinned to a session id, hook-driven status, session resume with fallback, workspace-trust decisions, runtime controls, and a session switcher; chat-style transcripts use the same structured tool rows | Partial       | No            | Phone-driven evidence covers start, the trust decision, a held-session fallback, prompt → "Response ready", and interrupt on mobile Chromium and mobile WebKit in the lab; permission prompts on the CLI card and relaunch persistence are not yet recorded |
| Generic mirror | Window capture with generic input delivery                                                   | Experimental  | No            | No app-specific state, lifecycle, or semantic guarantees                                                             |

## Evidence policy

Release evidence committed to Git is deliberately concise and privacy-reviewed.
Raw screenshots, transcripts, account data, absolute paths, and browser dumps stay
in ignored local storage. The public records under `docs/release-evidence/` contain
only the scope, environment class, commands, result, and remaining limitations.

To change a tier:

1. Reproduce the relevant journey in the Local Test Lab.
2. Run the adapter's targeted checks and the applicable real-app lane.
3. Record a sanitized summary with `pnpm qa:agent-app:record`.
4. Update this matrix without overstating unverified behavior.
5. Run `pnpm qa:agent-app-claims` and `pnpm release:readiness`.
