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
  Glasstunnel installs in `~/.claude/settings.json`.

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
