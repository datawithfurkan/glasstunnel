# Agent App Release Evidence

- Date: 2026-07-27T14:01:12Z
- App: Mac Screen
- Result: pass
- Environment: signed local Mac host with authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: 922b4a4100a2d61d9fcd960cab2fba07be0115a7
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Changing screen output rendered remotely; pointer input was delivered; sharing
started, stopped, restarted, recovered from stale stopping state, rejected stale
relay frames, and cleaned up superseded video peers.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
