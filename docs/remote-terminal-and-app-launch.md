# Remote Terminal And App Launch

## Goal
Let a signed-in user recover remote work when the target coding app was not already open on the Mac. The normal web flow stays simple: choose an app, then either continue the existing session or start/open it on the Mac.

## User Experience
- The coding app switcher can include Terminal alongside Codex, Claude Code, Cursor, OpenCode, and Codex CLI.
- Selecting an app that is off or unavailable shows one primary action: start it or open it on the Mac.
- Terminal starts a shared local session through the Glasstunnel host and opens Terminal.app into the same session when macOS allows it.
- When Terminal is already open, the mobile Terminal view can request a new session. The Mac creates a new remembered Glasstunnel Terminal `screen` session, makes it active, opens Terminal.app into that session, and clears stale mobile output as soon as the new state arrives.
- Remembered Terminal sessions appear as selectable session targets. Selecting a different existing session switches the remote Terminal adapter to that `screen` session without opening another Terminal.app window. Selecting the already-active target is a no-op.
- When Terminal is already open, the mobile Terminal view can close the current shared session. Closing the default session stops Terminal and returns it to the open/start state. Closing another remembered session removes only that session, then reopens the next remembered/default session so users are not trapped in stale terminal history.
- The current shared Terminal session can be renamed from mobile. The Mac stores the label locally and republishes it as the selected Terminal session name.
- In the Mac Workspace, the Terminal access switch uses the same start/stop path. Turning it on asks macOS to open Terminal.app with the shared Glasstunnel terminal session, then starts the remote Terminal session.
- Unavailable states stay explicit and short: "Start", "Open on Mac", or "Syncing".

## Protocol
The web app sends `remoteAppActionRequest` through the authenticated relay:

- `remoteAppId`: app family identifier, such as `terminal` or `codex`.
- `action`: `enable`, `disable`, `launch`, `start`, `stop`, `newSession`, or `closeSession`.

The Mac remains the source of truth for whether the action actually starts an adapter.

The web app can also send `targetSelectionRequest` and `targetRenameRequest`
for Terminal session targets. The current implementation supports one active
remote Terminal adapter at a time; selecting a remembered session switches the
adapter to that `screen` session.

## macOS Boundary
- Same-account relay access is required before any action is accepted.
- Existing read-only/lock gates still block control actions.
- `launch` uses the native app bundle when one is known.
- CLI-backed apps start host-side PTY adapters.
- Terminal uses a host-side PTY attached to a shared `/usr/bin/screen` session when available. Terminal.app opens the same `glasstunnel-terminal` session so a user can continue locally after using the phone. Attach commands must use `screen -xRR -S <session-name>` so similarly prefixed sessions do not make `screen` choose an ambiguous target.
- `newSession` is Terminal-only. It creates a new remembered
  `glasstunnel-terminal-*` screen session, marks it active, and opens
  Terminal.app into that session without resetting the previous session.
- `closeSession` is Terminal-only. It quits the active Terminal screen session
  when `/usr/bin/screen` is available and stops the remote Terminal adapter.
  Closing the default shared session disables Terminal and returns the UI to
  `Open Terminal`; closing a non-default remembered session keeps Terminal
  enabled and opens the next remembered/default session.
- Terminal session selection is Terminal-only. It persists the active session
  and restarts the remote Terminal adapter on that session. It must not open a
  new Terminal.app window for an existing remembered session; users use `New`
  when they intentionally want a new visible Terminal.app session.
- Terminal session rename is Terminal-only. It updates the locally persisted
  display label for the selected session and republishes the label to mobile
  without changing the underlying `screen` session name.
- Old generated Glasstunnel `screen` sessions can be audited with
  `pnpm qa:terminal:screen-sessions`. The cleanup workflow is intentionally
  dry-run by default and only classifies detached generated session names as
  candidates; it must preserve the shared default session, attached sessions,
  and manually named sessions.

## Web Boundary
- The UI sends app actions only over an active relay.
- A successful send optimistically marks the app as starting.
- If the relay is unavailable, the web app shows a clear recovery error instead of silently failing.

## Follow-Up
The mobile Terminal view is still a command/output surface, not a full terminal emulator. Full-screen TUIs such as Codex CLI should be continued in the visible Terminal.app window when exact terminal rendering matters.

If product requirements change later, this can gain per-app policy controls, terminal profiles, or audited command restrictions. For now the feature intentionally gives engineers a broad recovery surface after account sign-in.
