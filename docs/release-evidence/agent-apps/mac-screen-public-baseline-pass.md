# Agent App Release Evidence

- Date: 2026-07-28T01:01:41Z
- App: Mac Screen
- Result: pass
- Environment: signed local Mac host with authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: fdc3cd07920f9ec555d3d82715912c8503e89cd5
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Changing screen output rendered remotely; pointer input was delivered; sharing
started, stopped, restarted, recovered from stale stopping state, rejected stale
relay frames, and cleaned up superseded video peers.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
