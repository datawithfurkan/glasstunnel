# Changelog

Notable user-facing changes are recorded here. Glasstunnel follows semantic
versioning after the first public beta; pre-release compatibility may still change.

## Unreleased

### Changed

- Chat-style cards (Claude, Codex, Cursor) render their transcripts for reading
  instead of as raw records: replies are rendered Markdown in the app's sans
  face, tool calls fold into one-line rows grouped per turn with their output
  behind a tap, system events become thin dividers, one time stamp marks each
  cluster, and long prompts fold after six lines. A Focus/Full switch on the
  first activity block (remembered per device) keeps every output open when
  wanted. The open card's heading now names the session first and its project
  second instead of the folder path.

## 0.1.7 - Claude cards in Preview

### Added

- Experimental "Claude" card for Claude Code sessions hosted by the Claude desktop
  app: session discovery and switching, prompts delivered into the real window,
  Allow/Deny for permission prompts, structured answers to Claude's questions, and
  a read-only model display.
- The Claude Code CLI card now offers its session switcher on the phone.
- The Claude Code CLI card turns Claude Code's workspace-trust dialog into a
  decision on the phone (trust the folder, or exit) instead of dropping the prompt
  typed over it, and starts a fresh session when the one it tried to resume is
  still held by another process (a background agent or a second terminal).
- Decisions raised by CLI cards (Codex's update prompt, Claude Code's trust check)
  now render their choices on the phone; before, only the terminal text showed.
- Phone-driven Local Test Lab lanes for both Claude cards: `pnpm lab:e2e:claude-code`
  and `pnpm lab:e2e:claude-desktop`, each with a mobile WebKit variant
  (`pnpm lab:e2e:claude-code:safari`, `pnpm lab:e2e:claude-desktop:safari`).
  The desktop lane now also switches its dedicated session to the app's
  Manual permission mode for a file-write step, so the permission dialog is
  answered from the phone, and interrupts a running turn from the phone
  through the app's own Stop control.

### Changed

- The Claude Code CLI card pins the session it drives (`--resume`/`--session-id`),
  so Claude desktop sessions and other `claude` processes never move its status.
- Claude Code hooks are routed through one shared listener and forward the
  notification type, so idle prompts no longer read as input requests.
- Claude transcripts render tool output as tool output, show "Stopped" for
  interrupted turns, and use the session's title records.
- Both Claude cards are now Preview. The CLI card has a recorded phone-driven run
  (trust decision, session fallback, prompt, interrupt), and the desktop card has
  one too: session switching and prompts through Accessibility on the real app,
  and an AskUserQuestion answered from the phone. The app's `claude://code` links
  stay gated off, so switching relies on Accessibility.
- The Claude desktop card no longer flips a finished turn back to "working" when
  the app reports its background work as a subagent finishing, and its dialog
  presses stay inside the session pane (a question option once matched the
  sidebar's "Dispatch Beta" button by substring and navigated the app away).

### Fixed

- The signaling and relay Workers no longer fail a connection's authentication
  when the socket closes, or a quick reconnect replaces it, while the Worker is
  still waiting on the account service. Frames for closed sockets are dropped
  and the socket is forgotten, so a dead connection can no longer stay registered
  as the Mac's relay and block the next one.
- Mac Screen no longer reports "Screen unavailable" when the phone announces
  itself twice in quick succession (for example while switching screen quality):
  the Mac now keeps the newer WebRTC session instead of tearing it down while the
  earlier one was still preparing its offer.
- CLI cards no longer drop terminal output when a read boundary splits a
  multi-byte character, and they keep what a process prints as it exits (Claude
  Code's "session held elsewhere" message, a shell's error) instead of showing a
  bare "process exited".
- The Claude desktop card recognises the app's composer and the session in front
  on build 1.40609.1 (composer described as "Prompt", session name on the
  "rename session" control) instead of refusing every prompt.

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
