# Mac App Release Evidence

- Date: 2026-09-10T13:31:17Z
- Scope: auth-relaunch
- Result: pass
- Environment: notarized 0.1.10 release build installed over an unreleased 0.1.10 build from 1f980121 (itself installed over the published 0.1.9 app) with an existing linked account, on macOS 26.6.2
- Glasstunnel commit: 8550bec4
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

After the running app was quit and the `0.1.10` build from `8550bec4` was dragged
into Applications (Replace) and launched, the app came back signed in and linked
without returning to a sign-in, device-link, or permission screen; the installed
bundle reports source commit `8550bec4`, and the Mac's connection log shows the
relay and signaling sockets authenticated within two seconds of launch. A phone-sized
browser (iOS 26.5 Simulator, Safari) signed into the same account then listed the
Mac as online, opened its workspace, and stayed "Connected" for the next seven
minutes: 132 screen captures taken every three seconds were pixel-identical in the
header, tabs, and body, including the four-minute relay renewal and the five-minute
mark at which earlier relays closed the socket. The isolated install smoke separately
proved a clean 0.1.9 → 0.1.10 upgrade of the same DMG.

## Limitations

Revoking the account or macOS permissions correctly requires the corresponding flow
again. The three-second capture cadence would miss a reconnect shorter than that;
the in-place renewal itself is covered by Worker and web-app unit tests and the
revocation and retention lanes at the same commit.
