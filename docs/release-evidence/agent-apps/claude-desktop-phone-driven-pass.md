# Agent App Release Evidence

- Date: 2026-09-02T14:24:08Z
- App: Claude desktop
- Result: pass
- Environment: Local Test Lab host on the development Mac (Accessibility-trusted), phone-sized mobile Chromium (Pixel 7 emulation), real Claude desktop app 1.40609.1 with a dedicated session titled "Glasstunnel live evidence"
- Glasstunnel commit: b1c19228
- Artifact: artifacts/claude-desktop-phone-driven.txt
- Privacy review: pass

## Passed

From the phone-sized browser: signed in, linked the lab host, started the Claude
Code CLI card (answering its trust dialog) and then opened the Claude card. The
card listed the app's sessions, and selecting the dedicated one made the Mac press
its sidebar entry and confirm the switch through the app's "rename session"
control. A prompt sent from the phone was typed into the app's composer through
Accessibility and answered ("Response ready" from the Stop hook, the marker in the
reply). A shell-command prompt ran and its output came back. An AskUserQuestion
prompt produced a decision on the phone; the chosen option was pressed inside the
session pane and Claude replied with the picked label. The CLI card started
alongside never showed "Response ready" or a decision, so the two cards' hook
events stay separate.

## Limitations

The session's "auto" permission mode approved the shell command itself, so the
permission dialog and its Allow/Deny from the phone are covered by unit tests and
the hook wiring, not by this run; a session in ask-before-running mode would record
it. Interrupting a running turn on the desktop card, mobile WebKit, and the card
after an app restart are not part of this record. The lane needs the Claude
window left alone while it runs and spends three short turns on the account.
