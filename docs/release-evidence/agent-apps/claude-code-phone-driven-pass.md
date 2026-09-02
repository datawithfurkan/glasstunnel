# Agent App Release Evidence

- Date: 2026-09-02T15:29:24Z
- App: Claude Code
- Result: pass
- Environment: Local Test Lab host on the development Mac, phone-sized mobile Chromium (Pixel 7 emulation), real signed-in Claude Code CLI 2.1.226
- Glasstunnel commit: afa93663
- Artifact: artifacts/claude-code-phone-driven.txt
- Privacy review: pass

## Passed

From the phone-sized browser: signed in, linked the lab host, opened the Claude
Code card, and started it. The Mac launched `claude` in a PTY, resumed the newest
CLI session, and hit the workspace-trust dialog, which the card published as a
decision; the phone answered it. The resume was then refused because a background
agent held that session, so the card started a fresh session in the same folder,
whose trust dialog the phone answered again. The card stayed "Starting Claude Code"
until the composer appeared, then reported ready. A prompt sent from the phone was
answered end to end ("Response ready" from the Stop hook, the marker visible in
the transcript), and a second, longer prompt was interrupted from the phone, after
which the composer recovered. Re-recorded at the commit that also makes the card
verify a submitted prompt against the transcript and resubmit it once when the TUI
kept it in the composer, which a resumed session had done in the run before.

## Limitations

Mobile Chromium only (no WebKit pass yet). A Bash permission prompt on the CLI
card and relaunch persistence across a host restart are not part of this record.
The lane spends two short turns on the signed-in account each time it runs.
