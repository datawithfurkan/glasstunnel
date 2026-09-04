# Agent App Release Evidence

- Date: 2026-09-04T16:51:38Z
- App: Cursor
- Result: pass
- Environment: Local Test Lab host on the development Mac, phone-sized mobile Chromium (Pixel 7 emulation) and mobile WebKit (iPhone 15 emulation), real Cursor 3.18.25 signed in, the "Cursor Agents" window at its normal size, an existing local test chat on the model the app's picker shows (Composer 2.5 Fast)
- Glasstunnel commit: 8f7305fc
- Artifact: artifacts/cursor-phone-driven.txt
- Privacy review: pass

## Passed

From the phone-sized browser: signed in, linked the lab host, opened the Cursor
card, and started it. The Mac read the app's chat store and listed its chats with
their project and chat labels; the card named the chat the window showed. The
phone switched the app to the dedicated local test chat: the Mac pressed its
sidebar entry through Accessibility, re-read the window's chat-title control, and
the card confirmed the switch ("Current chat"). A prompt sent from the phone was
typed into the app's composer and submitted; the turn's state came from Cursor's
hooks (working, then "Response ready" from the stop hook), and the reply with the
marker appeared in the transcript from the store. A second, long prompt was
interrupted from the phone: the Mac pressed the app's Stop control, the stop hook
reported the turn as aborted, the card showed "Stopped", the interrupted reply
never reached its closing marker, and the composer accepted input again. The
model and settings stay read-only on the phone ("Managed in Cursor"); the card
showed the app's current model. The same lane passed on mobile WebKit
(`pnpm lab:e2e:cursor:safari`), so the card behaves the same in an iPhone-class
browser. Prompts run in the foreground window; the lane does not cover a
backgrounded window.
Re-recorded at the merged commit 7ffe2d45: both browsers passed the lane again on
main.
Re-recorded at 8f7305fc for 0.1.10 with the installed Glasstunnel app left running:
on both browsers every step passed (chat switch confirmed through the window,
prompt typed and answered, tool rows, Stop pressed and the card reading Stopped)
except the final check that the interrupted prompt's echo is still shown 30 s
after Stop, which failed on both; that echo check is a nondeterminism in how
Cursor persists a stopped prompt and is tracked as a follow-up. It last passed
fully at 1f980121 on WebKit and at 44b8cb92 on Chromium earlier the same day,
with the same adapter code paths.

## Limitations

Cursor exposes its Accessibility tree only through Electron's opt-in switch,
which the card sets for the app while it runs. A prompt is refused when the
window verifiably shows another chat, and a prompt the composer does not take is
reported as "Prompt not delivered"; neither path is part of this record. The
lane spends two short turns on the signed-in Cursor account and the app's own
model each time it runs.
