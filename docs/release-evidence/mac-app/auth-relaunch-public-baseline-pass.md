# Mac App Release Evidence

- Date: 2026-07-24T12:04:23Z
- Scope: auth-relaunch
- Result: pass
- Environment: notarized release build with a disposable test account
- Glasstunnel commit: 922b4a4100a2d61d9fcd960cab2fba07be0115a7
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

Account linking completed after permission onboarding and remained linked across an
app relaunch without returning to permission or sign-in screens.

## Limitations

Revoking the account or macOS permissions correctly requires the corresponding flow again.
