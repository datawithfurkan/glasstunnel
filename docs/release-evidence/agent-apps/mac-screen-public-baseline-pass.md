# Agent App Release Evidence

- Date: 2026-08-01T14:18:00Z
- App: Mac Screen
- Result: pass
- Environment: signed local Mac host with authenticated mobile Chromium plus WebKit fixture coverage
- Glasstunnel commit: 8eb429ceeca762a499955f2df3dbab51e950bb1f
- Artifact: artifacts/mac-screen-public-baseline.txt
- Privacy review: pass

## Passed

Changing screen output rendered remotely; pointer input was delivered; sharing
started, stopped, restarted, survived browser reload, recovered from stale stopping
state, rejected stale relay frames, and cleaned up superseded video peers. Both relay
image fallback and direct WebRTC video rendering were recognized by the signed lane.

## Limitations

Physical-device cellular handoff and every carrier/TURN path remain optional hardening.
