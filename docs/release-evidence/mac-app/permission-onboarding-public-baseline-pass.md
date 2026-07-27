# Mac App Release Evidence

- Date: 2026-07-24T12:04:23Z
- Scope: permission-onboarding
- Result: pass
- Environment: notarized release build on macOS
- Glasstunnel commit: PUBLIC_BASELINE_COMMIT
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The app reflected current Screen Recording and Accessibility state, blocked Continue
while either permission was missing, and advanced after both native checks passed.

## Limitations

macOS can still require an app relaunch after changing Screen Recording permission.
