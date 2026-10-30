# Mac App Release Evidence

- Date: 2026-10-30T11:58:39Z
- Scope: auth-relaunch
- Result: pass
- Environment: published 0.1.12 app updated in place to the notarized 0.1.13 release by its own updater, with an existing linked account, on macOS 27.0.1
- Glasstunnel commit: a1d3537f
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

With the published `0.1.12` app running, **Glasstunnel > Check for Updates…** read
the live feed and showed "Glasstunnel 0.1.13 is now available—you have 0.1.12"
with the 0.1.13 release notes. **Install Update** downloaded and verified the DMG
("Ready to Install"), and **Install and Relaunch** replaced the app and started it
again. The relaunched app reports version 0.1.13 and source commit `a1d3537f`,
Gatekeeper accepts it, it held established connections to the relay and
signaling front end within seconds, and the Claude Code hook commands it rewrote
at launch run Python in isolated mode. The isolated install smoke separately
proved a clean 0.1.12 → 0.1.13 upgrade of the same DMG.

## Limitations

This check did not include a phone-sized browser session against the updated app;
the Mac Screen lanes at `a1d3537f` cover the phone side with the lab host. The
Cursor hook commands are rewritten when the Cursor card starts, not at launch.
