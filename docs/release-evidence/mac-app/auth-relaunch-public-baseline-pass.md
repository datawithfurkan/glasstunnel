# Mac App Release Evidence

- Date: 2026-07-24T12:04:23Z
- Scope: auth-relaunch
- Result: pass
- Environment: notarized release build with a disposable test account
- Glasstunnel commit: PUBLIC_BASELINE_COMMIT
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

Account linking completed after permission onboarding and remained linked across an
app relaunch without returning to permission or sign-in screens.

## Limitations

Revoking the account or macOS permissions correctly requires the corresponding flow again.
