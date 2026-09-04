# Changelog

Notable user-facing changes are recorded here. Glasstunnel follows semantic
versioning after the first public beta; pre-release compatibility may still change.

## 0.1.10 - Unreleased

### Fixed

- Claude desktop 1.46 starts with accessibility support disabled, which left
  the Claude card unable to confirm a session switch or type a prompt ("open …
  in Claude to continue"). The Mac now opts the Claude app in once per process
  with Electron's light switch, without the screen-reader mode that an earlier
  attempt turned on.
- Two Glasstunnel hosts on one Mac (the installed app next to a lab or
  development build) no longer fight over the Claude and Cursor hooks. Each
  host binds its own socket under `~/Library/Application Support/Glasstunnel/hooks/`
  and the installed hook commands send every event to all running hosts, plus
  the single path that hosts before 0.1.10 bind; sockets left behind by a dead
  host are cleaned up on the next start.

### Changed

- The phone's "Readable" screen quality now drives the WebRTC stream, not
  only the JPEG fallback: the Mac captures the display at up to 1920 pixels
  on the long side (1080p-class instead of 720p-class) with a 6 Mbps ceiling,
  and the source is marked as a screencast so the encoder keeps the resolution
  under network pressure and lowers the frame rate instead. "Fast" sends the
  stream every earlier release sent. Switching quality mid-stream restarts the
  capture on the track the phone already has, so nothing renegotiates.
- The Mac Screen panel shows the received picture size next to "Screen ready".


## 0.1.9 - Cursor cards, Codex parity, and steady screen sharing

### Fixed

- Mac Screen no longer goes black until the page is refreshed. The phone now
  watches decoded and painted frames instead of trusting the video element,
  shows "Screen paused" when frames stop, and restarts the stream on its own
  with a growing wait; a stream that never renders is restarted after 10 s.
- The Mac keeps one video sender per phone for the life of the connection and
  repeats the last screen frame once a second while the screen is idle
  (protocol 0.2.3), so a paused capture resumes on the track the phone already
  has and a silent track means a dead one. A capture that ScreenCaptureKit
  stops is restarted with backoff, and display changes, wake, and login
  restart it too.
- The web app mounted two copies of every panel (one per layout) and only hid
  one with CSS; the hidden Mac Screen copy sent its own start request and
  restarted the visible stream on every focus. Exactly one layout is mounted
  now, chosen by viewport width.
- A screen stream now survives relay reconnects, lifecycle recoveries and
  signaling socket drops; the signaling socket pings every 20 s; a video flow
  that fails before its first frame is retried with backoff; a flow requested
  while the page was hidden starts on return; and Retry no longer restarts the
  whole connection while the relay is healthy.
- The Mac publishes its remote-app list only when it changed instead of every
  5 s, and the relay Worker closes a Mac socket that stopped pinging so phones
  stop seeing a dead Mac as online and screen requests are no longer
  acknowledged into the void.
- The Codex desktop card's model chip showed the global Codex default (the
  `config.toml` model and effort) for every thread. It now shows what the
  selected thread actually runs, from the thread's own turn records and
  settings events, so a thread on GPT-5.5 no longer reads "GPT-5.6-Sol".
- Codex's machine-written context blocks (`<environment_context>`,
  `<recommended_plugins>`, skill text, image markers) no longer render as the
  user's own messages; attached images show as "[image]". Prompts typed into
  the Codex composer are stored as Markdown, so a marker such as `GT_APP_1`
  reached the phone as `GT\_APP\_1`; user messages now show the text the way
  the app does.
- Current Codex threads write shell commands and patches as `custom_tool_call`
  records with list-shaped outputs. The card ignored the first and showed
  "no output" for the second; both now become titled rows (the command, the
  files a patch touches, "Update plan") with the exit code and wall time read
  from the output header, and "Show all N lines" fetches long outputs.
- A Codex turn stopped from the phone now shows a "Stopped" divider like the
  Claude cards.
- Linking the Codex card no longer stalls on "loading Codex context" for a
  Codex home with thousands of threads: the catalog scan opens only the 200
  newest rollouts and reads a small tail of each; the full 8 MB tail is read
  only for the thread the card shows.

### Added

- The Cursor Agent card streams each turn (`cursor-agent --print --output-format
  stream-json`): the reply grows in place and every tool call becomes a row with
  its result, duration, and failure flag. The card lists the CLI's chats with
  their workspaces, resumes them, starts new ones, switches between ask and plan
  mode and between models from the phone (`/mode`, `/model`, the model chips),
  interrupts, reports a rejected login, and reads the chat's own store for
  history, so it survives host restarts. It resumes the folder's newest chat,
  starts one where none exists, keeps other folders' chats as switches, and
  keeps Cursor's injected context and mode reminders out of the transcript. It
  renders as a chat on the phone instead of a terminal frame.
- The Cursor card reads Cursor 3.x's chat store (the chats that showed no
  messages before), including tool calls and results as structured rows, takes
  live turn state from Cursor's hooks (entries merged into `~/.cursor/hooks.json`
  next to yours), switches chats from the phone by pressing them in the app and
  confirming the window shows them, refuses to type into a chat the window
  verifiably does not show, offers "New chat", and interrupts through the app's
  Stop control.
- Phone-driven Local Test Lab lanes for both Cursor cards
  (`pnpm lab:e2e:cursor-agent` and `pnpm lab:e2e:cursor`, each with a `:safari`
  variant) and a privacy-safe `pnpm qa:cursor-agent` smoke.

### Changed

- The Mac pauses the JPEG screen fallback while every phone that asked for the
  screen reports a live WebRTC track, and resumes it the moment one stalls.
  The fallback is rebuilt after the Mac's relay reconnects instead of feeding
  a dead socket.
- Screen, capture, and peer lifecycle events are logged at notice level, so
  `log show` can reconstruct a screen-sharing incident.
- Cursor chats on the phone are switchable ("Switch to", "Open chat" until the
  app confirms, "Current chat") instead of "Browse only".
- Codex now ships inside ChatGPT.app. The Mac opts that shell into
  Accessibility (once per process) before searching its window, so the composer
  is found (placeholder "Do anything"). Other apps, Claude included, are left as
  they are. Interrupt presses the app's own stop control when it is exposed and
  falls back to Escape.
- New lab lanes `pnpm lab:e2e:codex-desktop` and `pnpm lab:e2e:codex-desktop:safari`
  drive the Codex desktop card from a phone-sized browser against the real app.
  The lab runner warns when the installed Glasstunnel app is running before a
  Claude lane, because both hosts share the Claude hook socket.

## 0.1.8 - Readable transcripts

### Added

- Tool activity now arrives on the phone as structured rows (protocol 0.2.2):
  the Mac names each call (a Bash command, a file name, a search pattern),
  pairs results with their calls, and sends a 12-line preview with the full
  line count, duration, and failure flag. The full output stays on the Mac and
  is fetched on request from the row's "Show all" button, over the direct
  connection or the relay. Older phones and Macs keep working: the fields are
  optional and the old wording is still sent.
- The Codex card shows the shell and tool calls Codex runs, as the same rows.
- Transcript polish: running tool rows show their elapsed time, activity blocks
  show their total time, unified diffs in output are coloured, terminal colour
  codes are stripped, and output blocks and code blocks have a Copy button.
  New messages no longer yank the view to the bottom while you are reading
  earlier ones; a "New messages" chip offers the jump instead.

### Fixed

- The Claude cards no longer flip from "Stopped" back to "Claude is working" when
  the app files the interrupted tool's result after an interrupt; only a real
  prompt or a reply starts the next turn.

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
