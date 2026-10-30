# Agent App Release Evidence

- Date: 2026-10-29T13:22:28Z
- App: Mac Screen
- Result: pass
- Environment: local lab host with authenticated mobile Chromium and WebKit screen E2E plus automated state regression coverage
- Glasstunnel commit: 2033fef2
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
cleanup, and quality-change feedback. Re-recorded at 1ff17e4f after the screen-sharing stability fixes (pull request
#23): exactly one screen panel is mounted per layout, the phone watches decoded
and painted frames and restarts a silent stream, a rendering stream survives
relay and signaling drops, and the Mac keeps one video sender per phone and
repeats the last frame once a second while idle (protocol 0.2.3). Automated
coverage now also includes the liveness tracker, sender reuse on the peer,
capture restart after a stream error, and the relay hub's host-liveness alarm.
Re-recorded at 7ffe2d45 after the Cursor cards (pull request #22) changed the lab
lanes and the phone app; both Mac Screen lanes and `pnpm qa:screen-state` passed again.
Re-recorded at f660996b after the Codex desktop parity merge (pull request #21)
changed the host, the accessibility injector, and the lab lanes.
Re-recorded at 8f7305fc after the 0.1.10 changes (Readable screen quality at
1080p-class size, per-host hook sockets, the Claude 1.46 accessibility opt-in,
the reconnect backoff, the lane switch-step fix) with the installed Glasstunnel
app left running.
Re-recorded at 8550bec4 for the 0.1.10 release after the September security
stages and their follow-ups (pull requests #32-#36: truthful relay disclosure,
acknowledged revocation, Mac-owned read-only control, 24-hour cache replicas,
in-place relay renewal, clock-safe cache deadlines), again with the installed
Glasstunnel app left running; both browsers passed.
Re-recorded at 2033fef2 for the 0.1.11 release after the account and Mac app
changes (pull requests #38-#47: accounts on Convex, Mac rename and removal,
account-wide access, Open on Phone, in-app updates, the menu bar icon and
background mode); both Mac Screen lanes and `pnpm qa:screen-state` passed.
For 0.1.12 (`f094160b`) only release packaging changed (the DMG installer
window, the build script, the cask, the marketing site); `pnpm qa:screen-state`
passed again at that commit, and the live lanes were not re-run because another
project held the lab's web-app port.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
