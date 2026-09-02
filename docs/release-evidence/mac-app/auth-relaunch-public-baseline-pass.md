# Mac App Release Evidence

- Date: 2026-09-02T19:20:00Z
- Scope: auth-relaunch
- Result: pass
- Environment: notarized 0.1.7 release build installed over the published 0.1.6 app with an existing linked account
- Glasstunnel commit: dbf8a90d
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

After the `0.1.6` process was quit and the `0.1.7` build launched from Applications,
the app remained signed in and linked without returning to permission or sign-in
screens, and showed version 0.1.7. The production web app on the phone showed the
same Mac as connected and listed the Claude card alongside the existing ones.

## Limitations

Revoking the account or macOS permissions correctly requires the corresponding flow again.
