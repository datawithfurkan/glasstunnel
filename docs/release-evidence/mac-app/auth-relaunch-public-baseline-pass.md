# Mac App Release Evidence

- Date: 2026-10-30T09:16:05Z
- Scope: auth-relaunch
- Result: pass
- Environment: published 0.1.11 app updated in place to the notarized 0.1.12 release by its own updater, with an existing linked account, on macOS 27.0.1
- Glasstunnel commit: f094160b
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

With the published `0.1.11` app running, **Glasstunnel > Check for Updates…** read
the live feed at glasstunnel.io/appcast.xml and showed "A new version of
Glasstunnel is available! Glasstunnel 0.1.12 is now available—you have 0.1.11"
with the 0.1.12 release notes. **Install Update** downloaded the DMG, verified it,
replaced the app in Applications, and relaunched it with no further prompt. The
relaunched app reports version 0.1.12 and source commit `f094160b`, Gatekeeper
accepts it, it came back signed in and linked on its Access page (the account menu
and Sign Out present) without a sign-in, device-link, or permission screen, and it
held two established connections to the relay and signaling front end. The
isolated install smoke separately proved a clean 0.1.11 → 0.1.12 upgrade of the
same DMG.

## Limitations

This check did not include a phone-sized browser session against the updated app;
the Mac Screen lanes at `2033fef2` cover the phone side, and the app code is
unchanged since then apart from its version. Revoking the account or macOS
permissions correctly requires the corresponding flow again.
