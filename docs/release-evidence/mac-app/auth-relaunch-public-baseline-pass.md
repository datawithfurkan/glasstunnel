# Mac App Release Evidence

- Date: 2026-10-30T08:45:13Z
- Scope: auth-relaunch
- Result: pass
- Environment: notarized 0.1.11 release build installed over the published 0.1.10 app with an existing linked account, on macOS 27.0.1
- Glasstunnel commit: 2033fef2
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The running `0.1.10` app was quit from its Glasstunnel menu, the notarized
`0.1.11` app from `2033fef2` replaced it in Applications, and on launch it came
back signed in and linked on its Access page (the account menu and Sign Out
present) without a sign-in, device-link, or permission screen. Gatekeeper
accepted the installed bundle as "Notarized Developer ID", the bundle reports
version 0.1.11 and source commit `2033fef2`, and within ten seconds of launch the
app held two established TLS connections to the relay and signaling front end.
The same check passed a second time after the maintainer deleted the app and
installed the published 0.1.10 DMG from the website before 0.1.11 went over it.
The isolated install smoke separately proved a clean 0.1.10 → 0.1.11 upgrade of
the same DMG.

## Limitations

This check did not include a phone-sized browser session against the installed
app; the Mac Screen lanes at `2033fef2` cover the phone side with the lab host.
Revoking the account or macOS permissions correctly requires the corresponding
flow again. In-app updating itself starts with this version, so the first real
Sparkle update is the move from 0.1.11 to the next release; the update smoke
(`pnpm qa:mac:update-smoke`) covers the mechanism with a throwaway app.
