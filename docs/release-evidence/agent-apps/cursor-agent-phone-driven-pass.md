# Agent App Release Evidence

- Date: 2026-09-03T13:45:20Z
- App: Cursor Agent
- Result: pass
- Environment: Local Test Lab host on the development Mac, phone-sized mobile Chromium (Pixel 7 emulation) and mobile WebKit (iPhone 15 emulation), real signed-in Cursor Agent CLI 2026.06.24 on gpt-5.4-nano
- Glasstunnel commit: 3e930f7d
- Artifact: artifacts/cursor-agent-phone-driven.txt
- Privacy review: pass

## Passed

From the phone-sized browser: signed in, linked the lab host, opened the Cursor
Agent card, and started it. The Mac read the CLI's chat store, listed the folder's
chats plus "New chat", and reported ready. A prompt sent from the phone ran
`cursor-agent` headlessly on the nano model; the reply streamed into the transcript
and the card reported "Response ready" with the marker visible. `/mode plan`
switched the CLI to plan mode ("settings updated", the mode divider in the
transcript); a prompt asking for the workspace's package.json produced a Read tool
row titled with the file and a reply carrying the package name. `/mode ask`
switched back, and a long reply was interrupted from the phone: the turn ended as
"Stopped", the closing marker never landed, and the composer accepted input again.
The same lane passed on mobile WebKit (`pnpm lab:e2e:cursor-agent:safari`). Both
browsers were re-run after the process runner was fixed to judge a turn only once
its output was fully delivered (a race that CI and loaded local runs had exposed);
the Cursor Agent code is identical between the Chromium re-run's commit and this one.

## Limitations

Agent mode (file edits and shell commands) stays off on the card until tool
permissions can reach the phone, so no permission prompt is part of this record.
Model switching from the phone is covered by host tests only. The lane spends
three short nano-model turns on the signed-in Cursor account each time it runs.
