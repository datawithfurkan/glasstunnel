# Agent App Release Evidence

- Date: 2026-09-04T06:52:47Z
- App: Codex desktop
- Result: pass
- Environment: Local Test Lab host on the development Mac (Accessibility-trusted), phone-sized mobile Chromium (Pixel 7 emulation) and mobile WebKit (iPhone 15 emulation), real Codex desktop inside ChatGPT.app 26.831.21537 (bundle `com.openai.codex`) with a dedicated thread named "Glasstunnel live" in a project folder; the Codex home held about 9,000 rollouts
- Glasstunnel commit: 1f980121
- Artifact: artifacts/codex-desktop-phone-driven.txt
- Privacy review: pass

## Passed

From the phone-sized browser: signed in, linked the lab host, and opened the
Codex card. The card listed the app's projects and threads by name and linked
within the first minute even with thousands of rollouts on disk (the catalog
scan opens only the newest files). Selecting the dedicated thread made the Mac
open its `codex://threads/<id>` link, and the card's title changed to the thread
name with the project label under it. The model chip showed the model and effort
the thread's own newest turn record names (GPT-5.6-Sol, ultra), read from the
thread rather than the global config; the lane compared the label against the
rollout on disk. A prompt sent from the phone was typed into the app's composer
through Accessibility and answered: the reply carried the marker, the rollout
recorded `task_complete`, and the status read "Response ready" (pill "done"); the
reply landed in the dedicated thread's own rollout, which proves the routing. A
shell command (`seq 1 40`) came back as a structured row titled with the command
pulled out of Codex's exec script, with its line count and wall time from the
output header; "Show all 41 lines" fetched the full output from the Mac on
request. A long reply was interrupted from the phone: the Mac pressed the app's
own "Stop" control (status detail "Stopping (pressed Stop)"), Codex wrote
`turn_aborted`, and the card read "idle" with a "Stopped" divider while the
reply's closing marker never arrived. Codex's injected context blocks
(`<environment_context>`, `<recommended_plugins>`) never rendered as the user's
words, and the prompt the app stored with Markdown escapes showed on the phone
as typed. The lane passed on mobile Chromium and on mobile WebKit, rendering the
transcript with the reading layout.

## Limitations

The lane needs the Codex window left alone while it runs and spends three short
turns on the account. The dedicated thread must exist before the run; its first
message is executed by Codex as a task like any other prompt, so it should be
created with a harmless message and renamed. In-app approval dialogs are not
published to the phone yet, so the lane's shell command must be one the thread's
permission mode runs without asking. Runtime controls stay read-only ("Managed
in Codex"). A live restart of the app is not part of this record.
