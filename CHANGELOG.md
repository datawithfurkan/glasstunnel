# Changelog

Notable user-facing changes are recorded here. Glasstunnel follows semantic
versioning after the first public beta; pre-release compatibility may still change.

## Unreleased

### Added

- Experimental "Claude" card for Claude Code sessions hosted by the Claude desktop
  app: session discovery and switching, prompts delivered into the real window,
  Allow/Deny for permission prompts, structured answers to Claude's questions, and
  a read-only model display.
- The Claude Code CLI card now offers its session switcher on the phone.

### Changed

- The Claude Code CLI card pins the session it drives (`--resume`/`--session-id`),
  so Claude desktop sessions and other `claude` processes never move its status.
- Claude Code hooks are routed through one shared listener and forward the
  notification type, so idle prompts no longer read as input requests.
- Claude transcripts render tool output as tool output, show "Stopped" for
  interrupted turns, and use the session's title records.

## 0.1.5 - Codex compatibility and Mac hardening

### Added

- Privacy-safe diagnostics copying from Mac Settings.
- Launch at Login control backed by the real macOS registration state.
- Installed version/build display and an official release-page update action.

### Fixed

- Restored Codex project names after the desktop app moved project state to
  `local-*` identifiers.
- Restored mobile prompt delivery by opening the exact selected Codex task before
  typing, including when the current desktop app reports a generic window title.
- Kept the signed Local Test Lab on its dedicated signing identity when Xcode
  certificates are added or removed.

### Changed

- Corrected Homebrew update guidance and removed the unsupported automatic-update
  declaration from the cask.
- Tightened public security and privacy wording to match implemented behavior.

## 0.1.4 - First public beta

### Added

- Account-first Local Test Lab for disposable end-to-end development.
- Public support tiers and privacy-reviewed release evidence summaries.
- Contributor, security, conduct, and public-visibility guidance.

### Changed

- Mac Screen and scoped Terminal are the only Supported public-beta surfaces.
- Codex, Cursor, Cursor Agent, Gemini CLI, and OpenCode are explicitly Preview.
- Claude Code and generic mirroring are Experimental.
- Production deployment is an explicit release action.

### Security

- Raw screenshots, transcripts, local paths, and account-specific QA artifacts are
  excluded from the public repository.
- Patched release dependencies and added full-history secret and privacy checks for
  the public source tree.

## 0.1.3 - Pre-public beta

- Added notarized macOS distribution, account-first onboarding, screen-sharing
  lifecycle recovery, Terminal sessions, and initial coding-agent adapters.
- This version was used for private validation and was not a general public release.
