# Agent App Release Evidence

- Date: 2026-07-28T02:18:00Z
- App: Mac Screen
- Result: pass
- Environment: signed local Mac host with authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: 24f43df44470ba3ff15557913916e7f807c0a672
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Changing screen output rendered remotely; pointer input was delivered; sharing
started, stopped, restarted, recovered from stale stopping state, rejected stale
relay frames, and cleaned up superseded video peers.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
