# Agent App Release Evidence

- Date: 2026-07-28T02:33:37Z
- App: Mac Screen
- Result: pass
- Environment: signed local Mac host with authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: c457c2b2d271186716d7301bad14cb4a3132defd
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Changing screen output rendered remotely; pointer input was delivered; sharing
started, stopped, restarted, recovered from stale stopping state, rejected stale
relay frames, and cleaned up superseded video peers.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
