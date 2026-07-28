# Agent App Release Evidence

- Date: 2026-07-28T02:33:37Z
- App: Mac Screen
- Result: pass
- Environment: signed local Mac host with authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: 4a2ef67e4e75a1e9c2fcd796d7b1eed62c47dfb4
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Changing screen output rendered remotely; pointer input was delivered; sharing
started, stopped, restarted, recovered from stale stopping state, rejected stale
relay frames, and cleaned up superseded video peers.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
