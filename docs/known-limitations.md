# Known limitations

Glasstunnel is pre-1.0. The following boundaries are intentional public-beta
disclosures, not hidden implementation details.

## Support boundaries

- Preview and Experimental paths are not public-beta promises. They may break when
  third-party coding apps change local storage, Accessibility trees, CLIs, or UI.
- An integration moves to Supported only after repeatable real-app prompt, result,
  stop/recovery, relaunch, and mobile-browser evidence exists for its promised scope.
- Terminal supports a practical shell-command transcript and visible Terminal.app
  continuity. It is not a general-purpose terminal emulator, and full-screen TUIs
  may not render faithfully in the mobile transcript.
- Generic mirroring exposes no app-specific project, model, progress, or result state.
- The Claude desktop card drives the real app window through Accessibility, which is
  best-effort on Electron apps; it offers no window video, its runtime controls are
  read-only, and permission prompts reach the phone only through the Claude Code hooks
  Glasstunnel installs in `~/.claude/settings.json`. Current Claude builds keep their
  `claude://code` deep links gated off, so switching sessions from the phone relies on
  Accessibility, and a prompt is refused when the app verifiably shows another session.
- The Cursor card drives the real Cursor window through Accessibility after enabling
  Electron's accessibility switch (Cursor may behave as if an assistive client were
  attached while the card runs); it offers no window video, keeps runtime controls
  read-only, takes live turn state from hooks Glasstunnel merges into
  `~/.cursor/hooks.json`, and refuses a prompt when the window verifiably shows
  another chat. Cursor writes a chat's turns to its store late, and not at all for a
  turn stopped within a couple of seconds, so the phone's own copy of a prompt
  stands in until the store shows it. The Cursor Agent card runs the CLI headless in ask or plan mode only
  (agent mode stays off until tool permissions can reach the phone), needs a valid
  `cursor-agent login`, and spends account credit on every turn.

## Mobile and network

- Automated Chromium, Playwright WebKit, and iOS Simulator coverage does not prove
  cellular handoff, every device GPU, background suspension, or every carrier NAT.
- Physical-phone checks are optional unless a release gate specifically names a
  hardware or network behavior that simulators cannot prove.
- WebRTC quality depends on the Mac, browser, network path, and TURN availability.

## Security and privacy

- Screen Recording and Accessibility are powerful macOS permissions. Grant them only
  to a Glasstunnel build you trust and revoke them in System Settings when unused.
- Secret redaction is best-effort. Do not intentionally display or send credentials,
  recovery codes, private keys, or production secrets through remote sessions.
- A compromised signed-in phone, browser profile, Mac account, or self-hosted control
  plane can defeat protections outside Glasstunnel's trust boundary.
- Raw QA screenshots and transcripts can contain private content and therefore are
  not retained in the public Git repository.

See `SECURITY.md` and `docs/security.md` for the disclosure policy and threat model.
