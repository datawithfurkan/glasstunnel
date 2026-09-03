# Agent App Release Evidence

- Date: 2026-09-03T06:18:32Z
- App: Claude desktop
- Result: pass
- Environment: Local Test Lab host on the development Mac (Accessibility-trusted), phone-sized mobile Chromium (Pixel 7 emulation) and mobile WebKit (iPhone 15 emulation), real Claude desktop app 1.40609.1 with a dedicated session titled "Glasstunnel live evidence"
- Glasstunnel commit: 7bde8143
- Artifact: artifacts/claude-desktop-phone-driven.txt
- Privacy review: pass

## Passed

From the phone-sized browser: signed in, linked the lab host, started the Claude
Code CLI card (answering its trust dialog) and then opened the Claude card. The
card listed the app's sessions, and selecting the dedicated one made the Mac press
its sidebar entry and confirm the switch through the app's "rename session"
control. A prompt sent from the phone was typed into the app's composer through
Accessibility and answered ("Response ready" from the Stop hook, the marker in the
reply). With the session switched to the app's Manual permission mode by the lane,
a file write asked for permission: the phone showed "Claude needs your permission
to use Write", Allow was chosen there, the Mac pressed the app's Allow control, and
the file's contents came back in the reply; the mode was put back to Auto
afterwards. An AskUserQuestion prompt produced a decision on the phone; the chosen
option was pressed inside the session pane and Claude replied with the picked
label. A long reply was interrupted from the phone: the Mac pressed the app's
Stop control and the card read "Stopped" without the reply's closing marker ever
arriving, and stayed stopped when the app filed the interrupted turn's tool
result afterwards. The CLI card started alongside never showed "Response ready"
or a decision, so the two cards' hook events stay separate. The lane passed on
mobile Chromium and on mobile WebKit, rendering the transcript with the new
reading layout (Markdown replies, folded tool rows).

## Limitations

A live restart of the Claude app is not part of this record; the host's behavior
for it (the card drops out while the app is gone and a fresh adapter starts when
the app returns) is covered by RemoteAppControllerTests. The lane needs the Claude
window left alone while it runs and spends four short turns on the account. A
read-only shell command such as echo runs without a dialog even in Manual mode,
which is why the permission step writes a file. Claude Code may run a long shell
command in the background and finish the turn at once, which is why the interrupt
step stops a long reply rather than a command.
