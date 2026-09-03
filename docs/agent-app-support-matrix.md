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
| Codex desktop  | Local project/thread discovery and guarded prompt delivery                                   | Partial       | No            | Exact visible labels, existing-thread routing, result state, and relaunch persistence need broader live verification |
| Codex CLI      | PTY launch, prompt delivery, stop, and runtime controls                                      | Partial       | No            | Structured final-result parsing and deterministic thread resume are incomplete                                       |
| Cursor         | Current-chat discovery and guarded Accessibility-based prompt delivery                       | Partial       | No            | Non-current chat routing and exact project/chat parity remain unproven                                               |
| Cursor Agent   | CLI-backed prompt and stop subset                                                            | Partial       | No            | Remote editing/tool behavior and broad model support remain unverified                                               |
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
