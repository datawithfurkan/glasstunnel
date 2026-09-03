# Agent App Release Evidence

- Date: 2026-09-03T08:07:25Z
- App: Mac Screen
- Result: pass
- Environment: local lab host with authenticated mobile Chromium and WebKit screen E2E plus automated state regression coverage
- Glasstunnel commit: 2e4b25ff
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Mac Screen rendered in authenticated mobile Chromium and WebKit local lab lanes.
Sharing opened from the mobile workspace, reached the Mac Screen panel, started,
switched quality, stopped, restarted, and stayed recoverable through the
screen-specific mobile flow after a page refresh. Automated state coverage also
passed for serialized capture transitions, superseded peer cleanup,
start/off/restart snapshots, stale stopping snapshots, stale and far-future
relay-frame rejection, render-gated control, stop confirmation copy, video-peer
cleanup, and quality-change feedback. Re-recorded at the 0.1.8 source commit after the transcript polish landed on the
phone (live timers, copy buttons, diff colouring, follow-or-chip scrolling).

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
